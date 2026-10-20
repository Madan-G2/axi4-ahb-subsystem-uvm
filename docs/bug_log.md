# Bug Log

Every genuine bug found during development, with root cause and fix. Per spec
§2.1, only real bugs are recorded here — nothing is injected.

**Status of the resume claim "caught 3 RTL bugs": SUBSTANTIATED (6 found).**

| # | Where | Caught by | How it was found |
|---|---|---|---|
| A1 | arbiter | SVA (`a_aw_payload_stable`) | first multi-master run |
| A2 | AXI→AHB bridge | scoreboard vs C++ model | bridge random test |
| A3 | AXI→AHB bridge | scoreboard vs C++ model | bridge random test |
| A4 | AXI→AHB bridge | scoreboard vs C++ model | bridge random test; traced AHB transfers |
| A5 | exclusive monitor | scoreboard vs spec-derived model | directed exclusive test |
| A6 | SRAM slave READY | watchdog / liveness | first test to turn slave backpressure on |

A1 was found while building the crossbar; A2-A4 came with the AXI2AHB bridge, where
the spec predicted they would live (width conversion, byte-lane rotation and
sparse-strobe decomposition are exactly the places where "looks right" and "is
right" diverge). A5 and A6 came out of the coverage-closure phase: both sat in code
that no earlier test reached, and both were found because a test was written to
reach it.

**How to talk about them honestly.** None of these was root-caused by opening a
waveform viewer at the time; they were found by an assertion, by a scoreboard
mismatch, or by a watchdog, and traced from the log. What the project does have is a
**replay** for each one (`docs/bug_replays.md`): the original defective code sits
behind `ifdef REPLAY_Ax`, and `python scripts/replay.py run A5` rebuilds it, shows the
testbench failing the way it did, and walks the failure back to its cause in the
waveform. Those are re-enactments of the same bugs, not new ones, and are not counted.

The remaining entries below are defects caught before simulation, or in the
testbench and build flow. They are kept separate on purpose -- "an RTL bug caught
by the testbench" is a much stronger claim than "a mistake I fixed while
writing", and conflating them is the easy way to end up unable to answer an
interview question.

---

## Category A — RTL defects caught by the testbench

### A1 — Round-robin arbiter switched grants mid-handshake
**File:** `rtl/common/axi4_rr_arbiter.sv`  **Found:** Phase 2, first
`soc_multi_master_test` run  **Caught by:** `a_aw_payload_stable` (slave side)

The arbiter re-evaluated its grant every cycle. With one master requesting a
slave the grant was stable, so Phase 1 and every single-master test passed. As
soon as a second master requested the same slave, the round-robin scan could
select the newcomer **while the first master's AWVALID was still asserted and
AWREADY had not yet arrived** -- changing AWADDR, AWLEN and AWID in the middle of
a handshake.

AXI requires address and control to stay stable from VALID until READY. The
failure surfaced as `a_aw_payload_stable` firing on the slave-side checker, one
level of hierarchy away from the arbiter that caused it.

**Fix:** the arbiter now holds a grant once offered until it is accepted
(`locked` / `lock_idx`). Rotation still happens only on acceptance, so fairness
is unchanged. Two assertions now sit at the source: `a_gnt_held_until_accept`
(an offered, unaccepted grant must be locked on the same index next cycle) and
`a_gnt_is_requesting` (a held grant must still have a live request -- the opposite
error, which would let the arbiter present one master's payload to a slave it was
never destined for).

**Why it matters:** this is exactly the class of bug a protocol checker exists
for. The data path was completely clean; every transaction still reached the
right slave with the right data, because the payload settled before the handshake
cycle. Only the timing rule was broken, and only under multi-master contention.
No amount of scoreboard checking would have found it. (The replay confirms it: the
scoreboard reports 0 errors over 600 transactions while the checker reports
tens of thousands of violations.)

### A2 — Read data ignored AHB byte-lane rotation and overran the AXI word
**File:** `rtl/bridge/axi2ahb_bridge.sv`  **Caught by:** scoreboard vs C++ model

The bridge captured AHB read data as a fixed 32 bits at `8*(lane & 7)`. Two
things wrong with that. AHB places a byte on the lane its *address* selects, so
the bytes have to be rotated back to the AXI lanes they belong to. And when the
AXI lane was 5 or above, `+: 32` ran off the end of the 64-bit word, so the
upper bytes were dropped entirely.

**Symptom:** reads returning `0x00` in the upper lanes. (Since the scoreboard was
made 4-state, see C8, the same bug reads as "X on a defined lane".) **Fix:** copy
only the bytes the transfer moved, rotating each from `hrdata[(addr[1:0]+k) % 4]`.

### A3 — General path skipped a whole beat when its first lane was inactive
**File:** `rtl/bridge/axi2ahb_bridge.sv`  **Caught by:** scoreboard vs C++ model

When a byte was disabled -- outside the beat's active lanes, or with its strobe
clear -- the byte-walk advanced to the next **beat** instead of the next
**byte**. Every unaligned or narrow beat starts with lane 0 inactive, so those
beats were discarded whole: no AHB transfer was ever issued for them.

This is the bug the general path exists to avoid, and it was invisible to
anything except a byte-exact reference model. **Fix:** advance the byte pointer
by one and re-examine; only move to the next beat when the pointer passes the
end of the bus.

### A4 — Byte pointer advanced by 1 instead of the run length
**File:** `rtl/bridge/axi2ahb_bridge.sv`  **Caught by:** scoreboard vs C++ model

After emitting a 2- or 4-byte transfer the pointer advanced by one byte, so the
bridge re-wrote the second byte of the run as a separate transfer and then never
reached the rest of the beat. A 4-byte word write ended up writing 2 bytes.

**Root cause is a tool behaviour worth remembering.** The step was computed into
an `automatic` variable *with an initializer* inside the `always_ff`:

```systemverilog
automatic int unsigned run = run_at(g_beat, g_byte, base);   // not re-evaluated every time
```

XSim does not re-evaluate that initializer on each execution of the block, so the
variable holds a STALE value. In the random traffic that first exposed the bug the
stale value was 0, so `step` was 1 and the pointer re-covered the second byte of a
2-byte run. (The replay, `docs/bug_replays.md`, shows the mechanism more precisely:
the variable is refreshed only when the byte pointer wraps to 0 at the start of a
beat, and the stale value is reused for the rest of it.) The combinational block
computed the same expression correctly, which is why the transfer *size* in the
waveform looked right while the *advance* did not.

**Fix:** the step is now produced by the same `always_comb` evaluation that
chooses the transfer, so the pointer cannot advance by a different amount than
the transfer covered. The identical pattern in `ahb_slave_mem` was fixed at the
same time -- a `grep` for procedural `automatic ... = ...` found both.

**How it was found:** bisecting by capping the transfer size. Byte-only passed;
halfword failed. Then tracing every AHB transfer showed a halfword at byte 2
immediately followed by a byte transfer at byte 3 -- the same byte twice.

### A5 — A successful exclusive write did not clear other IDs' reservations
**File:** `rtl/axi/axi4_sram_ctrl.sv` (also the CSR file, which is the same module)
**Caught by:** scoreboard vs the C++ model, in `axi_exclusive_test`

AXI exclusive access is load-linked / store-conditional. A reservation belongs to
one ID; any write that changes the location must cancel everybody else's. The RTL
cleared overlapping reservations on a **normal** write only. An exclusive write that
succeeded is a write like any other as far as the other reservation holders are
concerned, but it cleared nobody.

So: IDs 3 and 4 both read the same location exclusively. ID 3 stores and gets EXOKAY
-- correct, first one wins. ID 4 stores and also got EXOKAY -- wrong, ID 3's store had
changed the location under ID 4's reservation, so ID 4 must fail. Two masters doing a
read-modify-write on the same word both "succeed", and one update is lost. That is the
precise failure the mechanism exists to prevent.

**Fix:** `if (!cur.lock || excl_ok)` instead of `if (!cur.lock)` on the clearing
block. A *failed* exclusive write changes nothing and so clears nothing.

**How it was found, and why it needed the model rewrite.** The C++ model's exclusive
monitor was first written to mirror what the RTL did, which agrees with the RTL by
construction and checks nothing. It was rewritten from the AXI4 text (per-slave
tables, a successful exclusive write clears the others, an exclusive access to the
AHB window returns plain OKAY), and `axi_exclusive_seq` case 5 was written to hit the
two-IDs-one-location case directly. The first run of it failed with
`WRITE resp mismatch: DUT=1 expected=0`.

**Lesson for the interview:** a reference model must be derived from the specification,
not from the implementation under test. This bug sat in a block that had passed every
test for two phases.

### A6 — Slave READY backpressure latched low by a function with a hidden dependency
**File:** `rtl/axi/axi4_sram_ctrl.sv`  **Caught by:** the testbench watchdog and the
bounded-liveness assertions, the first time a test turned slave backpressure on

`awready`, `wready` and `arready` were gated by `bp_stall(shift)`, a function that
read the free-running LFSR and the backpressure percentage straight from module scope,
called from `assign` statements. A continuous assignment re-evaluates when one of its
*operands* changes, and variables read inside a called function are not operands. So
READY was recomputed only when the occupancy counter moved. A READY that happened to
evaluate low stayed low while the LFSR it was meant to follow ran freely, and with no
traffic changing the counters, nothing ever recomputed it. The bus hung.

The path was latent from the beginning: `BP_PERCENT` defaulted to 0 and no test had
ever set it, so `bp_stall()` always took its early `return 0`. It surfaced as soon as
`+SLV_BP=30` was added to give the READY-toggling cover events something to hit.

**Symptom:** `axi_random_test` stalled at ~225 ns with `AWREADY` and `WREADY` both low
while the slave's occupancy counters showed room (`aw_cnt=6 < 8`, `b_cnt=0`).

**How it was found:**
1. The watchdog dump (handshake state of every master port and the slave) showed
   VALID high, READY low, and counters that did not justify it.
2. A trace of S0 handshakes showed the bus going silent after five AWs and three W
   beats.
3. The decisive step: re-evaluating the READY expression from the watchdog every cycle
   for 24 cycles. The re-evaluated value flipped between 0 and 1 as the LFSR advanced;
   the port stayed at 0. A READY that does not track its own input is not a stall
   policy, it is a stale evaluation.

**Fix:** `bp_stall(lfsr, bp_pct, shift)` -- everything it reads is an argument.

**Why it matters:** the same trap is in any RTL that calls a function from an `assign`
and has the function read module state. Synthesis tools treat it as ordinary
combinational logic, so the design would "work" in silicon and hang in simulation.

---

## Category B — RTL defects caught by self-review before simulation

### B1 — Exclusive-access decision re-evaluated per beat
**File:** `rtl/axi/axi4_sram_ctrl.sv`
The exclusive monitor looked up the reservation on every W beat. A reservation
broken mid-burst by an intervening write could therefore leave memory partially
written *and* still return `EXOKAY`, or vice versa. AXI exclusive access is
all-or-nothing: the response must describe what actually happened to memory.
**Fix:** decide once at beat 0, latch, and use the same latched value for both
the byte commit and the final `BRESP`.

### B2 — `RVALID` gated by a free-running LFSR
**File:** `rtl/axi/axi4_sram_ctrl.sv`
Random backpressure was applied to `rvalid` directly, so `RVALID` could be
withdrawn before `RREADY` arrived — a protocol violation from the DUT itself,
which the checker would then have correctly flagged as an RTL bug. AXI permits
`READY` to be withdrawn freely but never `VALID`.
**Fix:** backpressure gates only `READY` outputs. R-channel jitter is applied by
reloading the inter-beat delay counter at a beat boundary, i.e. decided *before*
`RVALID` rises and therefore stable once it has.

---

## Category C — Testbench and checker defects

### C1 — Missing power-of-two rule in exclusive-access constraints
**File:** `verif/uvm/axi4_agent/axi4_seq_item.sv`
`c_lock_legal` checked burst length, size and address alignment but never
required the total byte count to be a power of two. It generated requests like
7 beats x 1 byte, which satisfy every other exclusive rule and are still illegal
per AXI4 A7.2.4. Caught by `a_ar_excl_legal` / `a_aw_excl_legal` firing during
the random test — the checker doing exactly its job.
**Found via:** printing the failing values, which showed totals of 7, 3, 12, 15,
14, 9 and 10 bytes — none powers of two.
**Fix:** added `(len + 1) inside {1,2,4,8,16}`. Since total = (len+1) * 2**size
and 2**size is already a power of two, the total is a power of two exactly when
(len+1) is.

### C2 — Lost `uvm_event` trigger deadlocked every sequence
**File:** `verif/uvm/seq_lib/soc_seq_lib.sv`
`uvm_event.wait_trigger()` only catches triggers raised *after* the call. The
driver routinely completed a transaction between `issue()` returning and the
waiter reaching `wait_trigger()`, and that trigger was lost permanently. The
sequence then blocked until the global watchdog with no diagnostic — it looked
like a DUT hang.
**Fix:** per-item completion uses `wait_ptrigger()` (persistent, race-free for a
one-shot event). The reused "any transaction finished" signal cannot be
persistent, so it polls instead.

### C3 — Randomizable address window
**File:** `verif/uvm/seq_lib/soc_seq_lib.sv`
`win_lo` / `win_hi` were declared `rand`, so any `seq.randomize()` would replace
the SRAM bounds with arbitrary values and quietly send traffic out of range.
**Fix:** made them plain (non-rand) members.

### C4 — Associative-array read with side effects
**File:** `verif/uvm/axi4_agent/axi4_driver.sv`
`wr_out[bid].size()` on a missing key can create the entry as a side effect,
masking the very "response for a transaction that was never issued" error the
branch existed to report.
**Fix:** `exists()` check first.

### C5 — Constraints unsolvable under XSim
**File:** `verif/uvm/axi4_agent/axi4_seq_item.sv`
Three separate solver limitations, all surfacing as the same bare "randomize
failed to meet constraint": `soft` constraints (3 GB memory runaway), `dist`
winning over a hard inline constraint, and unsized `'1` inside a constraint.
Documented in full in [xsim_notes.md](xsim_notes.md).
**Fix:** switched distributions instead of `soft`; explicit-width literals;
`if (cond)` guards instead of `->` implications.

### C6 — Monitor dropped W beats that arrived before their AW
**File:** `verif/uvm/axi4_agent/axi4_monitor.sv`  **Found:** Phase 2
AXI4 permits WVALID before AWVALID, and once a crossbar is in the path it happens
constantly: AW gets stalled by arbitration or the ID-hazard check while the W
skid buffer keeps accepting data. The monitor logged a warning and **dropped**
those beats, so the beat counter started from zero when the AW finally arrived.
It reported `WLAST at beat 11, AWLEN implies 12` -- short by exactly the number
of beats dropped, which reads like an RTL burst-length bug.
**Fix:** a pending-beat queue, drained into each AW as it arrives, plus an
end-of-test check that nothing is left stranded.

### C7 — Reset asserted without a falling edge
**File:** `verif/tb/tb_top.sv`  **Found:** Phase 2
`aresetn` was initialised to 0 and never had a negedge, so every
`always_ff @(posedge clk or negedge aresetn)` held X through the whole reset
window instead of taking its reset branch. Real hardware asserts reset; the
testbench was only pretending to.
**Fix:** initialise high, drop at `#1`.

### C8 — The scoreboard could not see X on the read bus
**File:** `verif/uvm/axi4_agent/axi4_seq_item.sv`, `soc_scoreboard.sv`
The captured read data was `bit [63:0] rdata[]`. A `bit` silently turns X into 0 at
the moment of capture, so a DUT driving X into an *active* byte lane compared equal to
a model value of 0 and passed. XSim returns X for memory that was never written, so
the hole was open for every first read of every location.
**Fix:** `logic` capture; the model reports which bytes it vouches for
(`ref_txn_rmask`: written bytes, plus ROM, which is now pre-initialised in both the
model and the RTL); the scoreboard compares only those lanes and treats X/Z on one of
them as its own failure. A model that "defaults to zero" for unwritten bytes is the
other way to get this wrong, and is why the mask exists.

### C9 — Eleven checker properties were silently dead
**File:** `verif/sva/axi4_protocol_checker.sv`
XSim ignores an assertion that uses a queue, an unpacked array indexed by a signal,
`$isunknown`, or a parameterised ranged delay -- with a warning that is easy to miss
and a clean regression as the result. Both beat-count checks, all five no-X checks and
both bounded-liveness checks (and more) were dead, and the regression was green
throughout.
**Found by:** `tb_checker_neg.sv`, a unit harness that drives one violation per property
and reports FIRED / DEAD. The first run listed 11 DEAD.
**Fix:** rewritten with scalars, fixed arrays and watchdog counters (patterns in
[xsim_notes.md](xsim_notes.md)). 38 of 38 scenarios now fire; `run.py comp` also
prints how many statements XSim says it is ignoring.

### C10 — `a_gnt_is_requesting` was wrong for the R channel
**File:** `rtl/common/axi4_rr_arbiter.sv`
The assertion required a held grant to have a live request. On the R channel the grant
is *meant* to outlive the request: it is pinned until RLAST is accepted, and a slave
may legally drop RVALID between beats. Until slave-side R gaps existed (`+SLV_BP`) it
never fired; the moment they did, it fired thousands of times against correct hardware.
**Fix:** a `HOLD_ACROSS_GAPS` parameter set on the R arbiters. They keep the
grant-held-until-accept property; the strict "still requesting" check applies only
where the request cannot legitimately gap. Both are written over the arbiter's
registers -- see the `$sampled` note in [xsim_notes.md](xsim_notes.md).

### C11 — Master-side `a_wlast_beat_count` was blind when W ran ahead of AW
**File:** `verif/sva/axi4_protocol_checker.sv`
A write burst that finished before its AW had been accepted was paired with that AW
later and never length-checked. Behind a crossbar under backpressure that is the normal
ordering (the skid buffer accepts data ahead of the address), so the master-side check
went quiet exactly when the slave was slow. The slave-side copy caught the same
violation, which is what hid the gap.
**Found by:** `axi_inj_wlast_early_test` (WLAST one beat early) -- only `s0:` reported it.
**Fix:** remember the lengths of early bursts and compare when the AW lands; also check
the burst that ends in the same cycle as its AW. Two new scenarios in the unit harness.

### C12 — A directed sequence issued an illegal read
**File:** `verif/uvm/seq_lib/soc_directed_seqs.sv`
A burst at the end of ROM crossed a 4KB boundary. The master-side `a_ar_no_4k_cross`
fired -- the checker catching the testbench's own mistake, and a small proof that the
checkers are watching the stimulus as well as the design.

### C13 — The reference model (and the lane function) walked byte lanes that do not exist
**Files:** `verif/ref_model/soc_ref_model.cpp`, `rtl/common/axi4_pkg.sv`
For a FIXED burst with an unaligned start, `axi_byte_lanes` computed the lanes of every
beat after the first as `lo .. lo + beat_bytes - 1`. With a start of `...6` and 8-byte beats
that is lanes 6..13 on an 8-lane bus. The C++ model iterated those lanes: it shifted a 64-bit
word by up to 104 bits (undefined behaviour) and asked whether a byte in the NEXT 8-byte word
would take an AHB error. Nobody noticed because nothing in the next word ever erred.
**Found by:** moving the AHB error boundary (C15). `soc_all_targets_test` seed 42 then failed
with `READ resp mismatch: DUT=0 expected=2` on a FIXED read at `0x100205fe`: the model predicted
an error from bytes at `0x600`, which the bridge -- walking only the 8 bytes of the bus -- never
touched. The RTL was right; the model was wrong.
**Fix:** clip `hi` to the top lane, in the C++ model and in `axi4_pkg`, with a selftest case
(`FIXED unaligned lanes later beat, clipped to the bus`).

### C14 — A driver edit silently removed every W-channel gap; one cover event noticed
**File:** `verif/uvm/axi4_agent/axi4_driver.sv`
While adding protocol-violation injection, the W thread's `repeat (t.w_delay[b])` became
`repeat ((b <= len) ? t.w_delay[b] : 0)`. XSim evaluated that count as 0. Every random write
burst became back-to-back, the regression stayed green (33/33), and the stimulus was quietly
much easier than before.
**Found by:** the cover event `w_gap_mid_burst` ("WVALID dropped between beats of a burst"),
which read 0 across 34 coverage runs after having read thousands. `w_back_to_back` had gone
from 1,120 to 4,829 in the same log.
**Fix:** compute the count into an `int unsigned` first, then `repeat (wd)`. Coverage rounds
r1 and r2 were discarded and re-run.
**Lesson:** a green regression says the design passed the stimulus it was given, not that the
stimulus is still what it was. Cover events are the cheap way to notice the difference.

### C15 — The AHB wait/error slave could not produce an error in the middle of an AHB burst
**Files:** `rtl/ahb/ahb_subsystem.sv`, `verif/ref_model/soc_ref_model.h`, `verif/sva/ahb_cov.sv`
The slave answered ERROR when `addr[11]` was set, so the error zone began at `0x800`. AHB bursts
may not cross a 1KB boundary and the bridge restarts every burst with a fresh NONSEQ at one --
and `0x800` is a 1KB multiple. An ERROR therefore always landed on the FIRST transfer of a
burst. The case the bridge's cancel-the-next-address logic exists for, an ERROR on a SEQ transfer
with the next address phase already presented, could never be produced, although the Phase 3
table said "mid-burst ERROR abort: PASS" (it was mid-*AXI*-burst).
**Found by:** coverage: `cg_ahb_resp.cp_err_beat` bins `second`, `third` and `later` empty after
every round. A waveform of the error transfers showed `dp_beat = 0` on all 60 error cycles.
**Fix:** the error zone is now `addr[9]` (alternating 512-byte zones), which an AHB burst can
cross. The coverage bins were also corrected: with 8-byte-aligned bursts the error lands on an
even word index, so a `second` bin (index 1) could never be hit; the bins are now
first / near-start / later. `axi_wait_error_seq` was rewritten around the new boundary.

---

## Category D — Build and regression infrastructure

### D1 — Parallel regression jobs silently reported each other's results
**File:** `scripts/run.py`
Concurrent `xsim` processes ran in one shared directory and collided over
`xsim.log`, the waveform database and runtime state under `xsim.dir`. Four
200-transaction random runs reported the smoke test's one-write/one-read totals
— **and still reported PASS**. A regression that passes against the wrong test is
worse than one that fails, because nothing prompts you to look.
**Fix:** each job gets its own copy of the elaborated tree under
`sim/work/<test>_<seed>/`. `--xsimdir` alone is insufficient. Added a guard that
fails any run producing no scoreboard line at all.

### D2 — Regression summary showed the wrong scoreboard figures
**File:** `scripts/run.py`
The log parser matched bare `[SCB]`, which also appears in UVM's end-of-test
"Report counts by id" table. Because that line comes last it overwrote the real
counts with the tally `1`.
**Fix:** match `[SCB] checked`. Worth noting this one masked D1 for a while — the
summary column was useless, so the wrong transaction counts were not visible.

### D3 — `.bat` tool wrappers unlaunchable from Python
**File:** `scripts/run.py`
Every Vivado call failed with `FileNotFoundError: [WinError 2]`, which reads like
Vivado is not installed.
**Fix:** resolve the executable through `shutil.which` against the tool PATH.

### D4 — Regression parser was blind to two thirds of the assertions
**File:** `scripts/run.py`  **Found:** Phase 2
The log parser counted lines containing the word "violated". That matched the
protocol checker's generic message but **not** `a_reset_valids_low`, nor the
assertions inside `axi4_id_hazard` and `axi4_w_router`, which print their own
text. Phase 1 had a reset-assertion failure on every run and the regression
reported 7/7 green throughout.
**Fix:** match XSim's `Error:` prefix, which covers every failed concurrent
assertion regardless of message. Switching it immediately surfaced a real
pre-existing failure -- see the note on `bind` in
[xsim_notes.md](xsim_notes.md).
**Lesson:** a checker you cannot see fire is a checker you do not have. The negative
suite (C9) is the same principle applied to the assertions themselves.

### D5 — Two concurrent regressions corrupted each other and one simulation ran away
**File:** `scripts/run.py`
A second regression started while an earlier one was still running. They share
`sim/work/<test>_<seed>/`, so the second overwrote the elaborated tree under a
simulation the first was executing. One job ended with XSim's solver printing
`Invalid consttrain id ... exceeds total number of constraints (0)` and the simulator
at ~10 GB and climbing, in a test that passes alone in 50 s. The runner itself died on
`WinError 1224` copying the tree.
**Fix:** a lock file (second regression refuses to start); every simulation inside a
Windows job object with a memory ceiling and a wall-clock limit, so the whole process
tree dies with it; an unpreparable run directory fails that job instead of the
regression.

### D6 — Coverage flow: five separate ways to measure nothing
**Files:** `scripts/run.py`, `scripts/cov_report.py`
Code coverage read 0.0% across the board until the static coverage database was
produced at elaboration under a fixed name and copied into every run directory; the
merged report omitted toggle coverage until the per-module detail was switched off;
`xcrg` wanted absolute paths; its HTML had to be parsed because text output is not
implemented; and compressed cross-bin listings dropped bins until the parser expanded
them and checked the total against the tool's own. Each is in
[xsim_notes.md](xsim_notes.md). The parser's self-check (parsed total vs the tool's
total) exists because the last of these looked like a real coverage hole.

---

## Verification status

Final run on the frozen sources (XSim 2024.1):

| Item | Result |
|---|---|
| C++ reference model selftest (`ref_selftest`) | passes in every run — C++ and `axi4_pkg` agree on AXI address arithmetic; exclusive monitor and FIXED-lane cases included |
| Regression (`run.py regress`) | **50/50 jobs pass**: 38 positive (random + directed), 12 negative; SVA failures 0 on the positive set |
| Negative tests (deliberate protocol violations) | 12/12 pass: each fires exactly the assertions designed for it, on master 0 only |
| Checker unit harness (`neg-checker`) | 38/38 scenarios fire (36 properties; one property has 3 scenarios) |
| SVA cover properties (`lint-sva`) | 120 parse and elaborate; **not simulated by XSim** (procedural mirror supplies the counts) |
| Bug replays (`replay.py all`) | 6/6 reproduce, and the fixed design passes the same test and seed |
| Coverage gate (`cov-check`) | closed **after waivers**; raw and adjusted figures and the waiver ledger are in [coverage_plan.md](coverage_plan.md) |
| Regression wall time | ~7 min on 4 workers; a coverage round ~13 min |
