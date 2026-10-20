# Coverage plan and closure record

Generated from `sim/cov/r6` by `scripts/make_coverage_doc.py`. Every number below is read from the merged report of 38 passing runs; nothing here is typed in.

## 1. What is measured

**Functional coverage** -- 550 bins in 19 covergroups.

| group | where | what it asks | bins | covered |
|---|---|---|---:|---:|
| `ahb_cov.cg_ahb_burst` | AHB observer | the HBURST x size x direction forms the bridge emits | 33 | 33 |
| `ahb_cov.cg_ahb_resp` | AHB observer | OKAY / ERROR, and which transfer of the burst took the ERROR | 11 | 11 |
| `ahb_cov.cg_ahb_trans` | AHB observer | IDLE / NONSEQ / SEQ and wait-state combinations | 10 | 10 |
| `ahb_cov.cg_ahb_wait` | AHB observer | wait states per transfer, 0..15 | 6 | 6 |
| `ahb_cov.cg_conv` | AHB observer | AXI burst shape x AHB burst form it was converted to | 59 | 59 |
| `axi4_cov.cg_arb` | interface observer | which master wins which slave, per direction | 33 | 33 |
| `axi4_cov.cg_hs_ar` | interface observer | AR handshake timing | 10 | 10 |
| `axi4_cov.cg_hs_aw` | interface observer | AW handshake timing: READY-first, VALID-first, stall lengths | 10 | 10 |
| `axi4_cov.cg_hs_b` | interface observer | B handshake timing | 10 | 10 |
| `axi4_cov.cg_hs_r` | interface observer | R handshake timing | 10 | 10 |
| `axi4_cov.cg_hs_w` | interface observer | W handshake timing | 10 | 10 |
| `axi4_cov.cg_order` | interface observer | how far a response overtook older ones | 8 | 6 |
| `axi4_cov.cg_outstanding` | interface observer | how many requests are in flight when another is accepted | 12 | 11 |
| `soc_txn_cov.cg_addr` | UVM | alignment, 4KB position (base / one beat short / ends on the boundary), WRAP start slot | 69 | 69 |
| `soc_txn_cov.cg_burst` | UVM, per transaction | burst type x length x size (the FIXED / INCR / WRAP matrix) | 97 | 97 |
| `soc_txn_cov.cg_id` | UVM | every ID x direction | 50 | 50 |
| `soc_txn_cov.cg_outcome` | UVM | 24 named outcomes (OKAY, EXOKAY, failed exclusive, SLVERR variants, DECERR) with `illegal_bins` for anything else | 24 | 24 |
| `soc_txn_cov.cg_traffic` | UVM | master x direction x target (SRAM, firmware region, ROM, registers, wait/error, AHB hole, CSR, unmapped) | 57 | 57 |
| `soc_txn_cov.cg_wstrb` | UVM | full / partial / zero / sparse strobes against the lanes each beat occupies | 31 | 31 |

**Cover events** -- 120 named conditions (stall lengths, back-to-back, READY toggling, gaps mid-burst, exclusive responses, 4KB positions, ...). Each is written once in `scripts/gen_cover.py` and rendered twice: as an SVA `cover property` (120 of them parse and elaborate -- `run.py lint-sva`) and as a procedural counter. **XSim ignores `cover property`**, so the counters supply every number; the SVA form is what a simulator that counts covers (VCS, Questa) would use, and was not run.

**Code coverage** -- XSim `sbct`: statement, branch, condition, toggle, RTL files only.

## 2. Goals and what is gated

| metric | goal | note |
|---|---|---|
| functional | 100% of bins after waivers | |
| statement | 100% after waivers | |
| branch | 100% after waivers | |
| cover events | 100% | |
| condition | reported, not gated | see section 5 |
| toggle | reported, not gated | see section 5 |

The original spec (section 7.5) asked for line/branch >= 98% and toggle >= 95% with FSM coverage. XSim has no FSM coverage, and its toggle report gives a percentage per module, so a bit that can never toggle (a tied-off address MSB) cannot be named and waived; a toggle goal would force either meaningless stimulus or a goal lowered until it passes.

## 3. Where it stands

```
=== coverage closure check: r6 ===
metric          raw %  adjusted %   goal %   open  waived   status
functional      99.45      100.00    100.0      0       3   MET
statement       98.40      100.00    100.0      0      33   MET
branch          90.41      100.00    100.0      0      47   MET
condition       78.07       78.49        -     40       1   info (not gated)
events         100.00      100.00    100.0      0       0   MET
toggle          50.93           -        -  (reported, not gated)

WAIVER LEDGER: 84 item(s) waived; 28 rest on a premise this script checked (asserted: 56, negative-tests: 8, other-variant: 20)

RESULT: CLOSED
```

Raw figures, with no waivers applied:

| metric | covered / total | % |
|---|---:|---:|
| functional bins | 547 / 550 | 99.45 |
| RTL statements | 2030 / 2063 | 98.4 |
| RTL branches | 443 / 490 | 90.41 |
| RTL conditions | 146 / 187 | 78.07 |
| RTL toggle (bit-weighted) | | 50.93 |
| cover events hit | 120 / 120 | 100.0 |

## 4. How it got there

| round | what changed | functional | statement | branch | condition | toggle | events |
|---|---|---:|---:|---:|---:|---:|---:|
| `base0` | random tests only (19 runs) -- the baseline the directed tests were written against | 84.89% | 91.48% | 78.06% | 59.89% | 41.42% | 105/120 |
| `r1` | + directed tests (33 runs). **Discarded:** a driver edit had removed every W-channel gap (bug C14) | 97.48% | 98.64% | 89.8% | 74.33% | 55.7% | 119/120 |
| `r2` | + error-map move, byte-lane clip, queue-full / exclusive / outstanding additions (34 runs). **Discarded:** same driver defect | 99.64% | 98.4% | 90.41% | 76.47% | 51.98% | 119/120 |
| `r3` | driver fixed (34 runs); cover event `w_gap_mid_burst` back to non-zero | 99.45% | 98.4% | 90.41% | 77.54% | 52.38% | 120/120 |
| `r4` | + multi-master test with slave-side READY jitter (37 runs) | 99.45% | 98.4% | 90.41% | 77.54% | 51.5% | 120/120 |
| `r5` | r4 merged with 36 extra random runs (73 runs in all): functional, statement and branch unchanged | 99.45% | 98.4% | 90.41% | 78.07% | 54.51% | 120/120 |
| `r6` | **final**: the frozen sources, one complete round (38 runs); the gate is run on this one | 99.45% | 98.4% | 90.41% | 78.07% | 50.93% | 120/120 |

Each round is a full regression on the coverage snapshot merged with `cov-report`, then `cov-check`. What each directed test is for is in [test_library.md](test_library.md); what the measurements turned up besides gaps is in [bug_log.md](bug_log.md) (A5, A6, C13, C14, C15 all came out of this loop).

What the gaps were, and what closed them:

* *Never exercised at all:* exclusive access (-> `axi_exclusive_test`, **bug A5**), 4KB page positions and every WRAP slot (-> edge tests), the bridge's INCR4/8/16 and WRAP forms (-> `axi_ahb_forms_test`), response backpressure beyond a few cycles, READY toggling.
* *Reachable only by a specific shape:* queues at their limit (-> `axi_queue_full_test`), one ID using its whole budget, back-to-back requests to the default slave, reservations that must survive unrelated writes.
* *Not reachable as the testbench stood:* an AHB error mid-burst (the error boundary sat on a 1KB multiple -- C15), master 0's firmware region (the sequences never used it).
* *Not reachable at all:* see the waivers below.

## 5. What is not gated, and why

**Toggle** is reported per module; see section 2.

**Condition** coverage is reported and not gated. XSim's condition report could be reconciled with its own totals only after working out that a condition is a TRUE/FALSE *pair* of rows, and some decisions it lists as never evaluated are exercised in the waveform. Example: `axi4_w_router` line 142, `sk_cnt[m] != SKID_D`, FALSE = the skid buffer is full. XSim reports 0 FALSE evaluations for `axi_outstanding_test` alone, while the waveform of that test shows the master's WREADY low for hundreds of cycles, which this expression alone drives. A gate on a number the tool cannot be trusted on would be a gate on noise.

## 6. Waivers

Defined in `scripts/cov_waivers.json`. A waiver says what it excuses and on what **premise**; `check_cov_closure.py` re-checks every premise it can against the data on each run and rejects a waiver whose premise fails, flags one that matches nothing, and always prints the raw figures next to the adjusted ones.

| premise | means | checked? |
|---|---|---|
| `other-variant` | the same source line is covered in another parameterisation of the module (XSim reports each parameterisation separately) | yes: a sibling does not have the same gap |
| `negative-tests` | only illegal stimulus reaches it | yes: against a coverage run of the negative tests alone (`r6neg`) |
| `functional` | named functional bins evidence the behaviour | yes: those bins are covered |
| `asserted` | reasoned (defensive default arm, assertion failure action, a rule of the testbench) | no -- listed separately so the unverified share is visible |

| id | kind | premise | items | reason |
|---|---|---|---:|---|
| C-AHBMEM-IDX-GUARD | code | asserted | 3 | Defensive bounds guard on the byte index of a read. idx() already reduces the address modulo SIZE and the AHB decoder only selects this slave for addresses inside its window, so the false side (an address outside the slave) cannot occur. |
| C-ASSERT-ACTION | code | asserted | 8 | The failure action of an immediate or concurrent assertion. It executes only when the assertion fails, which in a design that passes means never. That the assertions CAN fire is shown separately: the arbiter's by REPLAY_A1 (docs/bug_replays.md), the AXI checker's by the negative tests and tb_checker_neg. |
| C-BRIDGE-ERRWAIT | code | asserted | 1 | ST_ERRWAIT waits for HREADY in the second cycle of an AHB ERROR response. That cycle always has HREADY high (the two-cycle ERROR response is fixed by the AHB spec and implemented that way by every slave here), so the 'HREADY low' side cannot occur. |
| C-DEFAULT-ARM | code | asserted | 14 | The default arm of a fully enumerated state machine (state register already holds one of the encoded values). Reachable only by corrupting the state register, which simulation cannot do without forcing it. It exists so synthesis resolves to a safe state. |
| C-HAZARD-UNDERFLOW | code | asserted | 2 | Underflow guard on the per-ID outstanding counter: a response arriving for an ID with nothing outstanding. The scoreboard and the checker both fail the test if a slave ever does that; the guard only keeps the counter sane afterwards. |
| C-PKG-REDUNDANT-128 | code | asserted | 1 | axi_exclusive_legal() tests len > 15 first, and with a 64-bit bus (size <= 3) at most 16 beats of 8 bytes is 128 bytes, so 'total > 128' cannot be true. It is kept for wider buses; on this one it is redundant, and no stimulus can reach it. |
| C-SRAM-PRELOAD | code | asserted | 2 | Optional memory preload ($readmemh) through the INIT_FILE parameter. No instance sets it; the simulation memories start undefined on purpose, so that the scoreboard's X check means something. |
| C-SRAM-RANGE | code | asserted | 2 | SLVERR for a write outside the slave's own window. Behind the crossbar an address outside the window decodes to the default slave and is answered DECERR, so the slave never sees one. (It was reachable, and tested, when the slave ran standalone in Phase 1.) |
| C-WROUTER-OVERFLOW | code | asserted | 2 | Overflow detector for the ordering queues. The queues are sized to the crossbar's per-master outstanding limit and are only pushed under that limit, so a push into a full queue is impossible unless the limit logic is broken (and is the thing the detector exists to catch). |
| F-ORDER-WR-DEEP | functional | asserted | 2 | A write response can overtake at most ONE older write by construction: AW and W are ordered per master, and the AHB bridge accepts one transaction at a time, so at most one slow write is in flight. Overtaking two or more older writes needs two older writes that are both still outstanding when a younger one's response is delivered, which the SRAM/CSR/default slaves (equally fast) and the single serialised AHB path produce only through a timing coincidence: depth 2 was seen ONCE in round r2 and in none of the 180+ runs since. Depth 1 is hit thousands of times, and depth 2 / 3+ exercise no mechanism depth 1 does not (the tracker's position in a queue). Read-side depth 3+ is covered. |
| F-OUTSTANDING-AR-D8 | functional | asserted | 1 | The bin is 'an AR accepted while eight are already outstanding'. A master port is limited to eight outstanding by the crossbar (the ninth is held back, never accepted), and the SRAM and CSR slaves have an eight-entry AR queue that deasserts ARREADY when full, so a ninth is never accepted at any port. The write-side bin (cp_aw d8) is reachable only because the observer counts writes until BRESP while the slave's queue frees at WLAST. Eight outstanding reads ARE reached (bin d5_7, and the queue-full test drives the SRAM AR queue to its limit). |
| C-PKG-ILLEGAL-ARMS | code | negative-tests | 8 | The 'return illegal' arms of the legality predicates in axi4_pkg (axi_req_legal, axi_exclusive_legal, axi_wrap_legal, ...). They run only for illegal requests, which the sign-off regression never sends; the negative tests do, deliberately. Checked per item against a coverage run of the negative tests alone. |
| C-AHBMEM-PARAM | code | other-variant | 20 | ahb_slave_mem is instantiated three ways (boot ROM READ_ONLY, peripheral registers, WAITGEN wait/error slave) and XSim reports each parameterisation separately. A branch on a parameter (READ_ONLY, WAITGEN) or on state only a WAITGEN/READ_ONLY slave can reach takes one side per variant. Checked per item: some other variant has no gap on the same source line. |

## 7. Reproduce

```
python scripts/run.py regress --cov --stamp r6                  # coverage snapshot, all positive tests
python scripts/run.py regress --cov --negative --stamp r6neg   # the negative tests alone (evidence for one premise)
python scripts/run.py cov-report --regress sim/regress/r6 --out sim/cov/r6
python scripts/run.py cov-report --regress sim/regress/r6neg --negative --out sim/cov/r6neg
python scripts/run.py cov-check  --label r6 --neg-label r6neg
```
