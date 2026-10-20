# AXI4/AHB Memory Interface — SoC Subsystem RTL + UVM Verification
## Project Specification v1.0

| Field | Value |
|---|---|
| Spec date | 2026-08-19 |
| Target simulator | Xilinx Vivado XSim (UVM 1.2), VCS-compatible build |
| Formal tool | Synopsys VC Formal |
| Languages | SystemVerilog, UVM 1.2, Verilog-2005 (vendored CPU), C++ (DPI ref model), C (CPU firmware), Python 3.13, Perl 5 |
| Repo root | `E:\Project\AXI_AMBA` |

---

## As built — read this before the rest

This document is the **plan**, written before any code. What was actually built, and where it
departs from the plan, is below; the sections after it are left as originally written so the
two can be compared. Current numbers live in [coverage_plan.md](coverage_plan.md) and
[bug_log.md](bug_log.md); [../README.md](../README.md) is the overview.

**Built (phases 0-3, plus most of 6):** crossbar, SRAM and CSR slaves with exclusive access,
default slave, AXI→AHB bridge, AHB subsystem, UVM environment with a C++ reference model through
DPI-C, the AXI protocol checker with a unit harness that proves every property can fire, 120
SVA cover events, protocol-violation (negative) tests, functional and code coverage with a
checked-waiver closure gate, bug replays, Python and Perl automation. Everything ran on **XSim**.

**Not built:** phase 4's AHB protocol checker and bridge relational assertions; phase 5's PicoRV32
CPU master (M0 is a UVM agent like M1/M2); phase 7's VC Formal runs; any run on **VCS** (the Makefile's
VCS branch is untested).

**Departures from the plan, and why:**

| Plan | As built | Why |
|---|---|---|
| `scripts/tests.yaml` index, `run_regress.py` | the `TESTS` table in `scripts/run.py` | one less file to keep in step with the code; `run.py list-tests` prints it for the Makefile |
| Coverage goals §7.5: line/branch >= 98%, toggle >= 95%, FSM 100% | statement and branch 100% **after checked waivers**; functional 100% after waivers; toggle and condition reported, not gated | XSim has no FSM coverage; its toggle report is per-module only, so a dead bit cannot be named and waived; its condition report disagrees with the waveform in places. See coverage_plan.md |
| AHB wait/error slave: ERROR from `addr[11]` | ERROR from `addr[9]` | `0x800` is a 1KB multiple, which no AHB burst crosses, so an error could never land mid-burst (bug C15) |
| `ahb_error_test`: "ERROR at every beat index" | error at word index 0, 2, 4, ... of an AHB burst | an 8-byte-aligned burst reaches a 512-byte boundary on an even word index |
| `parse_log.pl` "coverage metric reporting" | Perl scrapes logs for failures and first-failure times; coverage reporting is Python | the coverage reports are HTML, which the Python side parses |
| §2 "waveform, root cause, fix commit" for each bug | bugs were found by assertions, the scoreboard and a watchdog; waveform root-cause is done by `replay.py`. The directory was not a repository while this was built, so the git history starts from the finished tree and has no per-bug fix commits | honest record; see bug_log.md |

---

## 1. Purpose and Scope

Build a synthesizable AXI4/AHB-Lite memory-interface SoC subsystem in RTL, then verify it with a
full UVM testbench: constrained-random stimulus, SVA protocol checkers, functional and code
coverage, a maintained test library, automated regression, and formal property checking.

The RTL is written first and is written by us — deliberately. Verifying third-party RTL that is
already correct produces no bug-find story. Writing the RTL ourselves means the bugs found during
verification are genuine, reproducible, and documentable.

### 1.1 In scope
- AXI4 (full) 3x3 crossbar interconnect with outstanding and out-of-order transaction support
- AXI4-to-AHB-Lite bridge including 64→32 data width conversion and burst-type conversion
- AXI4 SRAM controller with exclusive-access monitor
- AXI4 CSR register file
- AHB-Lite subsystem: decoder, mux, boot ROM, peripheral registers, wait-state/error slave
- RISC-V CPU (PicoRV32) as primary master M0, with an AXI4 burst-generating cache wrapper
- Complete UVM environment, SVA checkers, coverage model, test library, regression automation
- VC Formal property checking on the bridge FSM and crossbar arbiter

### 1.2 Explicitly out of scope
- Physical implementation, synthesis timing closure, DFT, power intent (UPF)
- AXI4 write-data interleaving (removed from the AXI4 spec; illegal by construction)
- Cache coherency (ACE / CHI), AXI5, AHB5
- APB layer (AHB peripherals are register slaves directly on AHB-Lite)
- Multi-clock / CDC between AXI and AHB domains (single clock in v1.0; see Risk R5)

---

## 2. Resume Claim Traceability

Every claim on the resume line maps to a concrete deliverable. This table is the acceptance
criteria for the project.

| Resume claim | Deliverable | Phase |
|---|---|---|
| "UVM testbench components for an AXI4/AMBA memory interface SoC subsystem" | `verif/uvm/` — agents, env, scoreboard, virtual sequencer | 1-3 |
| "constrained-random stimulus for outstanding transactions" | `axi4_outstanding_seq`, per-master outstanding-depth constraints | 2 |
| "...burst boundaries" | `axi4_burst_boundary_seq` — 4KB-approach / WRAP wrap-point / width-conversion boundaries | 3 |
| "...protocol corner cases" | `seq_lib/` narrow, unaligned, sparse-WSTRB, FIXED, exclusive, back-to-back handshake | 3-6 |
| "SVA assertions for AXI and AHB protocol compliance" | `verif/sva/axi4_protocol_checker.sv`, `ahb_protocol_checker.sv` + bind files | 4 |
| "functional and code coverage models" | `verif/uvm/env/*_coverage.sv` covergroups + XSim code coverage | 6 |
| "maintained the test library" | `scripts/tests.yaml` + `verif/uvm/tests/` (~21 tests) | 6 |
| "ran regression and drove coverage closure" | `scripts/run_regress.py`, `scripts/check_cov_closure.py`, `docs/coverage_plan.md` | 6 |
| "caught 3 RTL bugs" | `docs/bug_log.md` — real bugs found, with waveform, root cause, fix commit | 1-6 |
| "ran formal property checks (VC Formal)" | `formal/` — FPV setup TCL, assume/assert split, results | 7 |
| "automated coverage metric reporting with Python and Perl scripts" | `scripts/cov_report.py`, `scripts/parse_log.pl` | 6 |
| "C++" | `verif/ref_model/` — C++ golden memory model driven over DPI-C | 1 |

### 2.1 On the "caught 3 RTL bugs" claim

We do **not** inject fake bugs. `docs/bug_log.md` records only bugs genuinely found by the
testbench against RTL we believed was correct when written. The AXI2AHB bridge (burst conversion +
width conversion + response synthesis) and the crossbar (W-channel ordering, ID remapping,
outstanding tracking) are complex enough that real bugs are near-certain. If fewer than 3 genuine
bugs surface, the resume line gets corrected to the true number — not the other way round.

---

## 3. System Architecture

```
                     +--------------------------------------------------+
   M0 ============>  |                                                  |  ==> S0  AXI4 SRAM Controller
   PicoRV32 CPU      |                                                  |          + exclusive monitor
   + I$/line-fill    |          AXI4 CROSSBAR  (3 x 3)                  |          @ 0x0000_0000
   (AXI4, bursts)    |                                                  |
                     |   - address decoder (per AR/AW)                  |
   M1 ============>  |   - round-robin arbiter per slave port           |  ==> S1  AXI4 -> AHB-Lite BRIDGE
   UVM master agent  |   - ID remap  {master_idx, ID} -> 6-bit          |          64b -> 32b width conv
   (models DMA)      |   - outstanding tracker (AW/AR, depth 8)         |          burst-type conv
                     |   - out-of-order R/B return                      |          @ 0x1000_0000
   M2 ============>  |   - W-channel ordering enforcement               |              |
   UVM master agent  |   - DECERR default slave for unmapped            |              v
   (models test port)|                                                  |     +-------------------+
                     +--------------------------------------------------+     | AHB-Lite decoder  |
                                        |                                     |      + mux        |
                                        v                                     +-------------------+
                              S2  AXI4 CSR Register File                         |       |      |
                                  @ 0x2000_0000                                  v       v      v
                                                                                ROM   PERIPH  WAIT/ERR
                                                                               16KB    regs    slave
```

### 3.1 Global parameters

| Parameter | Default | Notes |
|---|---|---|
| `AXI_ADDR_W` | 32 | |
| `AXI_DATA_W` | 64 | Chosen so the bridge must downsize to AHB's 32b |
| `AXI_STRB_W` | 8 | `AXI_DATA_W/8` |
| `AXI_ID_W` | 4 | Master-side ID width |
| `AXI_XID_W` | 6 | Slave-side = `AXI_ID_W + $clog2(N_MASTERS)` |
| `AXI_LEN_W` | 8 | AXI4: up to 256 beats for INCR |
| `N_MASTERS` | 3 | |
| `N_SLAVES` | 3 | plus default slave |
| `OUTSTANDING_D` | 8 | Per master, per direction |
| `AHB_ADDR_W` | 32 | |
| `AHB_DATA_W` | 32 | |

### 3.2 Address map

| Region | Base | Size | Decode mask | Target | Notes |
|---|---|---|---|---|---|
| SRAM | `0x0000_0000` | 64 KB | `0xFFFF_0000` | S0 | CPU reset vector; `$readmemh` preload; exclusive-capable |
| AHB space | `0x1000_0000` | 1 MB | `0xFFF0_0000` | S1 (bridge) | |
| — AHB boot ROM | `0x1000_0000` | 16 KB | | AHB S0 | Read-only, `ERROR` on write |
| — AHB peripheral regs | `0x1001_0000` | 4 KB | | AHB S1 | Timer, scratch, GPIO-like |
| — AHB wait/error slave | `0x1002_0000` | 4 KB | | AHB S2 | Programmable wait states + `ERROR` injection |
| — AHB unmapped | rest of the 1 MB | — | | AHB default | `ERROR` → `SLVERR` at AXI |
| CSR | `0x2000_0000` | 4 KB | `0xFFFF_F000` | S2 | Control/status, error-injection enables |
| Unmapped | everything else | — | — | AXI default slave | `DECERR` |

Address decode uses base/mask compare, not equality — the mask is a parameter per slave so the map
is testable at other configurations.

**Decode windows are sized to the physical resource (decision G3).** There is no aliasing: a decode
window never extends past the memory behind it. This matters for two reasons.

First, it removes an ambiguity the C++ reference model would otherwise have to guess at — with a
256 MB window over 64 KB of SRAM, every comparison above 64 KB depends on whether the RTL aliases or
errors, and the model must agree exactly.

Second, it gives the two AXI error responses distinct, protocol-correct sources:

- **`DECERR`** comes from the AXI **default slave**, reached when an address falls outside every
  decode window. This is what the AMBA spec intends `DECERR` for — no slave exists at that address.
- **`SLVERR`** comes from the AHB **default slave** inside the bridge's 1 MB window: the transaction
  genuinely reached a slave, which then refused it. That `ERROR` propagates back through the bridge
  as `SLVERR`.

A slave returning `DECERR` for an out-of-range address inside its own window would be the less
correct alternative — the access *did* reach the slave, so `SLVERR` is the right code. Narrowing
the windows sidesteps the question entirely and gives `axi_decerr_test` and `ahb_error_test` two
genuinely different paths to exercise.

---

## 4. RTL Module Specifications

### 4.1 `rtl/common/axi4_pkg.sv`

Typedefs and enums for the whole project: `axi_burst_e {FIXED, INCR, WRAP}`,
`axi_resp_e {OKAY, EXOKAY, SLVERR, DECERR}`, `axi_size_e`, packed structs for AW/W/B/AR/R
payloads, and helper functions:

- `axi_bytes_per_beat(size)`
- `axi_burst_bytes(len, size)`
- `axi_crosses_4k(addr, len, size)` — used by both RTL asserts and the UVM checker
- `axi_wrap_boundary(addr, len, size)`
- `axi_next_addr(addr, len, size, burst, beat)` — the canonical address generator, reused by the
  SVA checker, the C++ ref model (mirrored implementation) and the scoreboard

### 4.2 `rtl/common/axi4_if.sv`, `ahb_if.sv`

SystemVerilog interfaces with `modport` for master/slave/monitor, plus clocking blocks for the UVM
driver/monitor. Interfaces carry the full AXI4 signal set including `AWLOCK`, `AWCACHE`, `AWPROT`,
`AWQOS`, `AWREGION`, `AWUSER`.

### 4.3 `rtl/axi/axi4_crossbar.sv`

The interconnect. Sub-blocks:

- `axi4_addr_decoder.sv` — base/mask decode, one-hot slave select, `decerr` flag
- `axi4_arbiter.sv` — parameterizable round-robin (default) or fixed-priority; QoS-aware mode reads
  `AxQOS` and elevates. One arbiter per slave port, per channel direction.
- `axi4_id_remap.sv` — prepends master index to ID on the way out, strips on the way back.
  Guarantees slave-side ID uniqueness so slaves can reorder freely.
- `axi4_outstanding_tracker.sv` — counting per (master, direction). Backpressures `AxREADY` at
  `OUTSTANDING_D`.
- `axi4_w_router.sv` — **critical**: AXI4 forbids write-data interleaving, so W beats from a master
  must reach slaves in exactly the order that master issued AW. Implemented as a per-master FIFO of
  destination slave IDs pushed at AW handshake, popped at `WLAST`.
  **Includes a W skid buffer (decision G2).** AXI4 permits `WVALID` before `AWVALID`, so W beats can
  arrive before the router knows where to send them. A small per-master FIFO (depth 2 beats) holds
  early data until the AW handshake resolves the destination, then drains in order. Our own driver
  may or may not exercise this, but the crossbar is protocol-complete either way — and a DUT that
  only works because the testbench is polite is a DUT with a latent bug.
- `axi4_id_hazard.sv` — **decision G1**: enforces same-ID response ordering across slaves. AXI4
  requires responses sharing an ID to return in issue order, which is unenforceable once the same ID
  is outstanding to two different slaves that may answer at different rates. This block maintains a
  per-master table of (ID → destination slave, count) and stalls `AWREADY`/`ARREADY` for any request
  whose ID is already outstanding to a *different* slave. Same ID to the *same* slave is allowed
  freely — the slave preserves its own ordering.
  Chosen over a full per-ID reorder buffer: roughly twenty lines against several hundred, with far
  less bug surface. The throughput cost is negligible because masters that want parallelism should
  use distinct IDs, which is exactly what the AXI ID mechanism is for. An SVA property asserts the
  stall condition is never violated, and `cg_id` covers the stall actually being hit.
- `axi4_default_slave.sv` — accepts any transaction, returns `DECERR` with correct beat counts and
  `RLAST`.

Design rules the crossbar must uphold (these become SVA and formal targets):

1. Responses with the same ID on the same channel must return in issue order.
2. Responses with different IDs may return in any order.
3. `BVALID` for a write must not assert before that write's `WLAST` has been accepted.
4. A master's W beats must reach slaves in AW order (no interleaving).
5. Backpressure must never deadlock: no combinational path from any `READY` to its own `VALID`.

### 4.4 `rtl/axi/axi4_sram_ctrl.sv`

AXI4 slave wrapping a byte-enabled single-port SRAM behavioural model.

- Full burst support: `INCR`, `WRAP`, `FIXED`; all `AxSIZE` up to bus width
- Narrow and unaligned transfers via `WSTRB` and computed byte lanes
- Configurable read latency and random `AxREADY` backpressure (test-controllable via CSR)
- **Exclusive access monitor**: per-ID reservation table (depth 4). `ARLOCK` sets a reservation on
  the address; a matching `AWLOCK` write returns `EXOKAY` and clears it; any non-exclusive write to
  a reserved address clears it; a failed exclusive write returns `OKAY` and must **not** update
  memory.
- May return out-of-order responses when `csr.ooo_en` is set (round-robin over a response queue)

### 4.5 `rtl/bridge/axi2ahb_bridge.sv`

The most complex block and the primary bug-hunting ground.

| Concern | Required behaviour |
|---|---|
| Width | 64b AXI beat → 2x 32b AHB beats; `WSTRB` selects which halves are actually written |
| `INCR` | Map to AHB `INCR4`/`INCR8`/`INCR16` when length and alignment permit, else `INCR` (undefined length) |
| `WRAP` | AXI `WRAP` (2/4/8/16 beats) → AHB `WRAP4/8/16` **after width conversion recomputes the wrap boundary**. A 4-beat 64b WRAP becomes an 8-beat 32b WRAP — the wrap point moves. |
| `FIXED` | No AHB equivalent. Must be split into repeated `NONSEQ` SINGLE transfers at the same address. |
| Narrow (`AxSIZE < 3`) | Drive `HSIZE` from `AxSIZE`, place address in the correct 32b lane, suppress the unused AHB beat |
| Unaligned start | Legal only for `INCR`; first beat is narrow-lane, subsequent beats align |
| Write response | AHB has no B channel. Bridge must not issue `BVALID` until the final AHB beat's `HREADY` is seen, so a late `HRESP=ERROR` is correctly reported as `SLVERR`. |
| `HRESP=ERROR` | Two-cycle AHB response. Bridge samples the first cycle, aborts the remaining burst (drives `HTRANS=IDLE`), and still returns the full number of AXI R beats with `RRESP=SLVERR` and correct `RLAST`. |
| Outstanding | AHB-Lite has none. Bridge serialises: one AXI transaction in flight at a time, `AxREADY` gated. |
| Read data assembly | Two 32b AHB beats packed into one 64b `RDATA`; on error the partially-assembled beat must still be emitted |
| `AxLOCK` | AHB-Lite has `HMASTLOCK` only, no exclusive semantics → bridge returns `OKAY` (never `EXOKAY`) for exclusive reads in AHB space |

Implemented as an explicit FSM (`IDLE, AW_ACCEPT, W_COLLECT, AHB_WR, AR_ACCEPT, AHB_RD, R_DRAIN,
RESP, ERR_ABORT`) so it is tractable for VC Formal.

### 4.6 `rtl/ahb/`

- `ahb_decoder.sv` — `HSEL` generation from `HADDR`, plus default-slave select
- `ahb_mux.sv` — `HRDATA`/`HREADYOUT`/`HRESP` mux driven by the **registered** `HSEL` (classic AHB
  pitfall: muxing on the current-phase select instead of the previous-phase select)
- `ahb_rom.sv` — `$readmemh` preloaded, zero wait states, `ERROR` on any write
- `ahb_regs.sv` — 32-bit register block: free-running timer, scratch regs, IRQ status
- `ahb_waitgen.sv` — programmable wait-state count (0-15) and `ERROR` injection at a programmable
  transfer index; the deliberate protocol-stress slave
- `ahb_default_slave.sv` — always `ERROR`

### 4.7 `rtl/cpu/` — RISC-V primary master

- `picorv32.v` — vendored from `github.com/YosysHQ/picorv32` (ISC licence, single file, no
  dependencies, Verilog-2005 so XSim compiles it fast). Configured RV32IM, `ENABLE_COUNTERS=1`. We
  use its **native** memory interface, not `picorv32_axi`, because the stock AXI wrapper is
  AXI4-**Lite** and would emit only single-beat transfers — no burst traffic at all.
- `cpu_icache.sv` — direct-mapped, 1 KB, 32-byte lines. A line fill is a **4-beat 64-bit INCR
  burst**, which is exactly the AXI4 traffic a CPU-centric design needs to generate.
- `cpu_axi_wrapper.sv` — arbitrates I-fetch (via cache) and D-access (write-through with a 2-entry
  write-combine buffer that merges adjacent stores into 2-beat INCR bursts), drives the M0 AXI4
  port. Reset vector `0x0000_0000`.

**Rationale for the cache:** without it, a CPU-centric topology produces only `AxLEN=0` single-beat
traffic and the burst/outstanding coverage on M0 stays at zero. The cache is what makes the CPU a
genuine AXI4 burst master.

**Cache coherency is not in scope, so the address map is partitioned (decision G4).** The I-cache
has no snooping, so a write by M1 or M2 to a line the CPU already holds leaves the CPU executing
stale instructions. That is correct behaviour for an incoherent design and the scoreboard must never
flag it as a DUT bug. Enforced by construction rather than by hoping it does not happen:

| SRAM sub-region | Range | Rule |
|---|---|---|
| Firmware / `.text` / `.rodata` | `0x0000_0000` – `0x0000_7FFF` (32 KB) | CPU-readable. M1/M2 sequences are **constrained never to write here.** |
| Shared data | `0x0000_8000` – `0x0000_FFFF` (32 KB) | Free for all masters. CPU accesses this region uncached (D-path is write-through, never cached). |

The constraint lives in `soc_base_seq` as an address-range constraint on every generated
transaction, so no individual sequence has to remember it, and the scoreboard carries a matching
comment explaining why the region is off-limits. Only the **I-cache** is a cache; the D-path is
write-through with no allocation, so CPU data accesses are always coherent with the fabric.

### 4.8 `rtl/top/soc_subsystem_top.sv`

Instantiates everything, exposes AXI interfaces for M1/M2 and monitor taps on every AXI and AHB
interface for the testbench to bind to.

---

## 5. Verification Architecture

```
                                   uvm_test
                                      |
                              soc_env (uvm_env)
        +----------------+-------------+--------------+----------------+
        |                |             |              |                |
  axi4_agent[M1]   axi4_agent[M2]  axi4_mon[M0]   ahb_agent      soc_virtual_seqr
   (ACTIVE)         (ACTIVE)      (PASSIVE, CPU)  (PASSIVE)
        |                |             |              |
        +----------------+-------------+--------------+
                                 |  analysis ports
                                 v
                  soc_scoreboard  <---DPI-C--->  C++ golden model
                                 |                (verif/ref_model/)
                                 v
                     soc_coverage (subscribers)
```

### 5.1 `verif/uvm/axi4_agent/`

| Component | Role |
|---|---|
| `axi4_seq_item.sv` | Full AXI4 payload: `addr, id, len, size, burst, lock, cache, prot, qos, region, data[], strb[], resp[]`, plus timing controls (`aw_delay`, `w_beat_delay[]`, `b_ready_delay`) |
| `axi4_driver.sv` | Independent per-channel threads (AW/W/AR/B/R). Honours `OUTSTANDING_D`. Never violates VALID-stability or the no-interleave rule. |
| `axi4_monitor.sv` | Reconstructs whole transactions from channel handshakes; matches B/R to AW/AR by ID and issue order; publishes on `uvm_analysis_port` |
| `axi4_sequencer.sv` | Standard |
| `axi4_agent.sv` | ACTIVE/PASSIVE configurable |
| `axi4_agent_cfg.sv` | Bus params, backpressure profile, protocol-error-injection enables |

### 5.2 `verif/uvm/ahb_agent/`

Passive monitor on the bridge's AHB port (the DUT drives both sides), plus an optional active AHB
**slave** responder used in bridge-standalone tests to inject wait states and errors under sequence
control.

### 5.3 `verif/ref_model/` — the C++ golden model

A cycle-independent, transaction-level model of the entire subsystem, called from the scoreboard via
DPI-C.

```
verif/ref_model/
  soc_ref_model.h/.cpp     // address map, memory arrays, exclusive monitor
  axi_txn.h                // POD struct crossing the DPI boundary
  dpi_shim.cpp             // extern "C" entry points
```

DPI entry points:

- `void ref_reset()`
- `int ref_write(addr, len, size, burst, lock, id, data[], strb[])` → returns expected `BRESP`
- `int ref_read (addr, len, size, burst, lock, id, data_out[])` → returns expected `RRESP`
- `int ref_peek (addr, *out)` — end-of-test memory comparison

The model owns the truth about: byte-level memory contents, which addresses return `DECERR` vs
`SLVERR` vs `OKAY`, exclusive-access pass/fail, and ROM write rejection. It deliberately knows
nothing about timing — timing is the SVA checkers' job.

### 5.4 `verif/uvm/env/soc_scoreboard.sv`

- Subscribes to all AXI and AHB monitors
- For each completed AXI transaction: calls the C++ model, compares `RDATA` byte-by-byte (masked by
  `WSTRB` history) and compares `RRESP`/`BRESP`
- Cross-checks the AHB monitor stream against the AXI stream through the bridge: every AXI beat into
  S1 must produce the expected number, order, `HSIZE` and address sequence of AHB beats
- End-of-test: full memory sweep vs. `ref_peek`
- Ordering checker: same-ID responses in order, different-ID responses may reorder

---

## 6. SVA Plan (`verif/sva/`)

Written as standalone checker modules bound to the interfaces with `bind`, so the same file serves
simulation **and** VC Formal.

**Scheduling note:** `axi4_protocol_checker.sv` is written in **Phase 1**, not Phase 4. A protocol
checker is only worth having while the RTL is still being written — bound from the first slave
onward, it makes every later phase self-checking and localises crossbar and bridge bugs to the
cycle they occur rather than to a downstream data mismatch. Phase 4 is where the AHB and bridge
checkers land and where we prove each property can actually fire.

### 6.1 `axi4_protocol_checker.sv` (~45 properties)

**Reset and X-propagation**
- `AWVALID/WVALID/BVALID/ARVALID/RVALID` low during and for one cycle after `ARESETn` low
- No `X`/`Z` on any control field while its `VALID` is high

**Handshake**
- Once `VALID` is high it must stay high until `READY` (no VALID withdrawal)
- All payload fields stable while `VALID && !READY`
- `READY` may be withdrawn freely (AXI permits this)

**Burst legality**
- `AxSIZE <= $clog2(AXI_STRB_W)`
- `AxBURST != 2'b11`
- `WRAP`: `AxLEN` in {1,3,7,15} and `AxADDR` aligned to `2**AxSIZE`
- `FIXED`: `AxLEN <= 15`
- **4KB boundary**: `INCR` burst must not cross a 4KB boundary
- Exclusive: `AxLOCK` → `AxLEN <= 15`, total bytes a power of 2 ≤ 128, address aligned to total
  burst size

**Data phase**
- W beat count equals `AWLEN+1`; `WLAST` on exactly the last beat and never earlier
- R beat count equals `ARLEN+1`; `RLAST` on exactly the last beat
- No `BVALID` before the corresponding `WLAST` handshake
- **Not a rule:** AXI4 explicitly permits `WVALID` before `AWVALID`. Write data arriving ahead of
  its address is legal and must not be asserted against. We may *constrain our own driver* to send
  AW first as a simplification, but that is a testbench assumption recorded in the agent config —
  never a compliance check on the DUT. See gap G2 in §13.

**Response**
- Every `BID` matches an outstanding `AWID`; every `RID` matches an outstanding `ARID`
- `EXOKAY` only in response to a transaction with `AxLOCK` set
- Same-ID responses return in request order
- No response for a never-issued ID

**Liveness** — bounded in *both* flows
- Every accepted `AWVALID` gets a `BVALID` within `MAX_WR_LATENCY` cycles
- Every accepted `ARVALID` gets `RLAST` within `MAX_RD_LATENCY` cycles

Written as `##[1:MAX_LATENCY]` windows, not `s_eventually`. Unbounded liveness is meaningless in
simulation (it can only fail at end-of-test, with no useful failure time) and XSim's `s_eventually`
support is not something we should depend on. The bound is a parameter so formal can be given a
looser one than simulation.

### 6.2 `ahb_protocol_checker.sv` (~25 properties)

- `HTRANS` legality: first transfer of a burst is `NONSEQ`; `SEQ`/`BUSY` only inside a burst; `IDLE`
  only between bursts
- Address/control (`HADDR, HWRITE, HSIZE, HBURST, HPROT`) stable while `HREADY` low
- `HADDR` increments by `2**HSIZE` for `SEQ` beats of `INCR*`; wraps correctly at the
  `HBURST`-implied boundary for `WRAP*`
- Beat count matches `HBURST` for fixed-length bursts
- `HSIZE <= $clog2(AHB_DATA_W/8)` — i.e. ≤ 2 for a 32-bit bus. `HSIZE` is a log2 encoding
  (0=byte, 1=halfword, 2=word), not a byte count
- `ERROR` response is exactly two cycles: `HRESP=1 && !HREADY` then `HRESP=1 && HREADY`
- Master must drive `HTRANS=IDLE` (or `NONSEQ` for a new burst) in the second `ERROR` cycle
- `HWRITE` constant for the duration of a burst
- No `HSEL` change while `HREADY` low

### 6.3 Bridge-specific assertions (`axi2ahb_checker.sv`)

Relational properties tying the two sides — these are the ones most likely to fire:

- Every AXI write beat with any `WSTRB` bit set produces ≥ 1 AHB write beat
- AHB beat address sequence for a converted `WRAP` matches the recomputed 32-bit wrap boundary
- `HRESP=ERROR` anywhere in a burst → the AXI response for that transaction is `SLVERR`
- AXI R beat count is always `ARLEN+1` even when the AHB burst was aborted early
- Bridge never has two AXI transactions in flight simultaneously

---

## 7. Coverage Plan

### 7.1 Functional coverage — AXI (per master, per slave)

| Covergroup | Bins |
|---|---|
| `cg_burst` | `burst` x `len` (1,2,4,8,16,32,64,128,256) x `size` (1,2,4,8 B) — illegal combos excluded |
| `cg_addr` | aligned / unaligned; 4KB-boundary distance bins {ends exactly at boundary, 1 beat short, mid-page}; wrap-point crossing |
| `cg_wstrb` | all-ones, all-zeros, sparse, first-beat-partial, last-beat-partial |
| `cg_resp` | `OKAY`, `EXOKAY`, `SLVERR`, `DECERR` x read/write |
| `cg_outstanding` | AW/AR depth 0..8, cross with master id |
| `cg_id` | ID reuse before completion; distinct IDs in flight; cross ID x slave |
| `cg_ooo` | response return distance from issue order: 0, 1, 2, >2 |
| `cg_lock` | exclusive pass, exclusive fail, exclusive to non-exclusive-capable slave |
| `cg_handshake` | VALID-before-READY, READY-before-VALID, same-cycle, back-to-back |
| `cg_arb` | cross(master, slave) — every master must win every slave |

### 7.2 Functional coverage — AHB

`cg_htrans` (all legal transitions incl. BUSY insertion), `cg_hburst` (all 8 types), `cg_hsize`,
`cg_waitstates` (0,1,2,3,4-7,8-15), `cg_hresp` (OKAY/ERROR), cross(HBURST, HSIZE).

### 7.3 Functional coverage — bridge conversion

`cg_conv` = cross(AXI burst type, AXI size, AHB burst type produced) — the covergroup that proves
the width/burst conversion matrix was actually exercised.

### 7.4 Code coverage

Line, toggle, branch, condition, FSM-state and FSM-transition on all `rtl/` **except** the vendored
`picorv32.v` (excluded via an exclusion file, since we do not own it).

### 7.5 Goals

| Metric | Goal |
|---|---|
| Functional coverage | 100% of non-waived bins |
| Line / branch | ≥ 98% |
| Toggle | ≥ 95% |
| FSM state | 100% |
| FSM transition | ≥ 95% |

Waivers documented with justification in `docs/coverage_plan.md`.

**XSim caveat (Risk R1):** Vivado XSim's covergroup and code-coverage support is materially weaker
than VCS/URG. Phase 0 must measure exactly what XSim reports. If native coverage is insufficient,
the fallback is a lightweight SV coverage-sampling package that writes bin hits to CSV, aggregated
by `scripts/cov_report.py`. This fallback is not a downgrade of the resume claim — it makes the
Python coverage-automation claim load-bearing rather than cosmetic.

---

## 8. Test Library (`verif/uvm/tests/`, indexed by `scripts/tests.yaml`)

| # | Test | Purpose |
|---|---|---|
| 1 | `soc_smoke_test` | Reset, single 32-bit write+read to SRAM |
| 2 | `axi_incr_burst_test` | All `INCR` lengths 1..256, all sizes |
| 3 | `axi_wrap_burst_test` | All legal `WRAP` combinations, wrap-point checking |
| 4 | `axi_fixed_burst_test` | `FIXED` bursts incl. to the bridge (split into SINGLEs) |
| 5 | `axi_narrow_transfer_test` | `AxSIZE` < bus width, all lane positions |
| 6 | `axi_unaligned_test` | Unaligned `INCR` start addresses |
| 7 | `axi_wstrb_test` | Sparse/zero/partial write strobes |
| 8 | `axi_4k_boundary_test` | Bursts ending exactly at, and one beat before, 4KB boundaries |
| 9 | `axi_outstanding_test` | Drive to max outstanding on both directions, verify backpressure |
| 10 | `axi_ooo_response_test` | Distinct IDs, force out-of-order returns, check reorder legality |
| 11 | `axi_same_id_order_test` | Same-ID must return in order (negative check of the above) |
| 12 | `axi_multi_master_arb_test` | All 3 masters hammering one slave; fairness check |
| 13 | `axi_decerr_test` | Unmapped addresses → `DECERR`, correct beat counts |
| 14 | `ahb_error_test` | AHB `ERROR` at every beat index → `SLVERR`, burst abort correctness |
| 15 | `ahb_waitstate_test` | 0..15 wait states, incl. wait states during ERROR response |
| 16 | `axi_exclusive_test` | Exclusive pass, fail-by-intervening-write, fail-by-eviction |
| 17 | `bridge_width_conv_test` | Every AXI size/burst → AHB conversion combination |
| 18 | `b2b_handshake_test` | Zero-delay back-to-back on every channel; READY toggling stress |
| 19 | `axi_random_stress_test` | Long constrained-random, all masters, all slaves, random seeds |
| 20 | `cpu_boot_test` | CPU executes firmware from SRAM, touches AHB peripherals |
| 21 | `cpu_dma_concurrent_test` | CPU + M1/M2 random traffic concurrently — the system-level test |

Every test derives from `soc_base_test`; every sequence from `soc_base_seq`. Test list, seed counts
and expected runtime live in `scripts/tests.yaml`.

---

## 9. Formal Plan (`formal/`, VC Formal)

| Target | Properties | Why formal |
|---|---|---|
| `axi2ahb_bridge` FSM | Deadlock-freedom, no illegal state, every request eventually responds, ERROR always propagates | Bounded state space; simulation cannot prove absence of a hang |
| `axi4_arbiter` | No starvation within N grants, one-hot grant, grant only to requesters | Fairness is hard to prove by random simulation |
| `axi4_w_router` | W beats always reach the slave chosen at AW time, in order | Exhaustive proof beats random |
| `axi4_addr_decoder` | Exactly one slave select or `decerr`, never both, never neither | Trivially provable, catches map bugs |

Setup:

- `formal/fpv_bridge.tcl`, `formal/fpv_arbiter.tcl` — VC Formal FPV app setup
- Constraints (`assume`) come from the **same** `axi4_protocol_checker.sv`, instantiated with a
  `FORMAL_ASSUME` parameter that flips `assert` to `assume` on the input side. One source of truth
  for the protocol, used as checker in simulation and as constraint in formal.
- AEP (Automatically Extracted Properties) run first for X-propagation, array-bound and
  arithmetic-overflow checks
- Abstractions: SRAM reduced to 4 words, `OUTSTANDING_D` reduced to 2, `AXI_DATA_W` kept at 64

---

## 10. Regression and Reporting Automation (`scripts/`)

| Script | Language | Function |
|---|---|---|
| `Makefile` | GNU Make | `make comp`, `make run TEST=x SEED=n`, `make regress`, `make cov`, `make formal`. Backend selected by `SIM=xsim\|vcs` so the VCS flow is a drop-in. |
| `run_regress.py` | Python 3 | Reads `tests.yaml`, expands seed sweeps, runs N jobs in parallel via `multiprocessing`, captures logs, writes `sim/regress/<timestamp>/results.json`, prints a pass/fail table, non-zero exit on failure |
| `parse_log.pl` | Perl 5 | Scrapes a UVM log for `UVM_ERROR`/`UVM_FATAL`/`UVM_WARNING`, SVA failures with file:line, and the simulation time of first failure; emits one-line-per-test summary |
| `cov_report.py` | Python 3 | Merges coverage output (XSim native or CSV fallback), produces `sim/cov/report.html` + `coverage.csv`, and a trend chart across regression runs |
| `check_cov_closure.py` | Python 3 | Compares measured coverage against goals, emits a ranked gap report ("which bins are empty and which test should be extended"), non-zero exit if below goal |
| `tests.yaml` | data | The maintained test library index: name, seeds, timeout, tags, expected coverage contribution |

---

## 11. Directory Structure

```
AXI_AMBA/
  docs/       SPEC.md  address_map.md  coverage_plan.md  bug_log.md
  rtl/        common/  axi/  bridge/  ahb/  cpu/  top/
  verif/      uvm/{axi4_agent,ahb_agent,env,seq_lib,tests}  sva/  ref_model/  tb/
  formal/     *.tcl  *.sv
  sw/         firmware C, linker script, build script, prebuilt .hex
  scripts/    Makefile  tests.yaml  run_regress.py  cov_report.py
              check_cov_closure.py  parse_log.pl
  sim/        build/  logs/  cov/  regress/    (git-ignored)
  README.md
```

---

## 12. Phased Delivery Plan

| Phase | Content | Exit criteria |
|---|---|---|
| **0** | Vivado install; then **DPI-C hello-world before any other work (G5)**; UVM hello-world in XSim; coverage capability measured; Makefile + skeleton | DPI-C proven end-to-end *first*; a UVM test compiles, elaborates and runs under XSim; coverage capability documented in `docs/coverage_plan.md` |
| **1** | `axi4_pkg`, interfaces, `axi4_sram_ctrl`, C++ ref model, axi4 agent, base env, scoreboard, **and `axi4_protocol_checker`** | Single-master random read/write vs. C++ model passes with 200 seeds; AXI checker bound and clean |
| **2** | `axi4_crossbar` + sub-blocks, multi-master env, virtual sequencer | 3-master random traffic to 3 slaves, ordering rules checked, no deadlock over 5000 transactions |
| **3** | `axi2ahb_bridge`, AHB subsystem, AHB agent + monitor, cross-domain scoreboard checks | All AXI burst/size combinations correctly converted; ERROR and wait-state cases pass |
| **4** | `ahb_protocol_checker`, `axi2ahb_checker`, negative-test suite that proves every property can actually fire | All checkers clean on the passing regression; each property fired at least once by a targeted negative test |
| **5** | PicoRV32 + `cpu_icache` + `cpu_axi_wrapper`, firmware build, SRAM address partition in `soc_base_seq` (G4), `cpu_boot_test` | CPU boots from SRAM, reads/writes AHB peripherals, emits multi-beat INCR bursts; M1/M2 provably never write the firmware region |
| **6** | Coverage model, full test library, regression + Python/Perl automation, coverage closure | Coverage goals met or waived with justification; regression green; `cov_report.py` output archived |
| **7** | VC Formal on bridge FSM, arbiter, W-router, decoder | Properties proven or bounded-proven; results in `docs/formal_results.md` |

---

## 13. Risks and Open Items

| ID | Risk | Mitigation |
|---|---|---|
| **R1** | Vivado XSim coverage support may be too weak for the coverage-closure claim | Measure in Phase 0. Fallback: SV coverage-sampling package + `cov_report.py` aggregation |
| **R2** | Vivado is **not installed** on this machine (`C:\Xilinx` contains only `Downloads`) | Phase 0 blocker. Needs Vivado 2020.2+ (2023.x preferred) with the UVM library |
| **R3** | XSim UVM performance is well below VCS; long random tests may be slow | Keep memory sizes small; parallelise regression; VCS-compatible Makefile so the same code runs faster wherever VCS is available |
| **R4** | RISC-V GCC toolchain needed to build firmware | Use WSL Ubuntu `gcc-riscv64-unknown-elf`, or the xPack toolchain on Windows. Ship prebuilt `.hex` so Phase 5 is not blocked on toolchain setup |
| **R5** | Single clock domain across AXI and AHB is unrealistic for a real SoC | Documented as out of scope for v1.0. A CDC variant is a possible v2.0 extension |
| **R6** | VC Formal is on a different machine/licence from the XSim flow | Checkers are written once, parameterised for assert/assume, so they port without edits |

### Specification gaps found on review — RESOLVED

These were found by reading the spec back against the AMBA specification. All five are now decided
and folded into the sections above; this table is the decision record.

| ID | Gap | Decision | Folded into |
|---|---|---|---|
| **G1** | **Same ID to two different slaves.** AXI4 requires same-ID responses to return in issue order. If M1 sends `ID=3` to S0 then `ID=3` to S1 and S1 answers first, something must hold S1's response back. §4.3 rule 1 stated the requirement; nothing implemented it. | **Stall, not reorder.** New `axi4_id_hazard.sv` blocks `AxREADY` for a request whose ID is already outstanding to a different slave. ~20 lines vs. several hundred for a reorder buffer, with far less bug surface. Masters wanting parallelism should use distinct IDs — that is what IDs are for. | §4.3 |
| **G2** | **W data before AW.** AXI4 permits `WVALID` before `AWVALID`, but `axi4_w_router` learned the destination only at the AW handshake, so early W beats had nowhere to go. | **W skid buffer**, depth 2 beats per master. The crossbar is protocol-complete whether or not our driver exercises it. A DUT that only works because the testbench is polite has a latent bug. | §4.3 |
| **G3** | **SRAM address aliasing.** A 256 MB decode window over 64 KB of physical memory left it undefined whether `0x1_0000` aliases to `0x0` or errors — and the C++ model had to agree exactly or mismatch on every comparison above 64 KB. | **Decode windows sized to the physical resource.** No aliasing anywhere. This also gives the two error responses protocol-correct and distinct sources: `DECERR` from the AXI default slave (no slave at that address), `SLVERR` from the AHB default slave (reached a slave, which refused). | §3.2 |
| **G4** | **CPU I-cache vs. DMA writes.** No coherency in scope, so an M1/M2 write to a cached line leaves the CPU on stale instructions — correct behaviour that the scoreboard must not flag as a bug. | **Partition the SRAM.** Firmware in the low 32 KB, constrained off-limits to M1/M2 in `soc_base_seq`; shared data in the high 32 KB. Enforced by construction. Only the I-path is cached; the D-path is write-through with no allocation, so CPU data stays coherent. | §4.7, Phase 5 |
| **G5** | **DPI-C on Windows XSim.** The whole C++ golden model — and the C++ resume claim — rests on DPI-C working under XSim on Windows. Filed under the coverage risk in R1, which under-weighted it. | **Prove it first in Phase 0**, before any other work, with a two-line DPI hello-world. Fallback: Vivado under WSL Ubuntu, where the DPI flow is far smoother. Last resort is a SystemVerilog model, which forfeits the C++ claim — so this gets proven up front, not discovered in Phase 1. | Phase 0 |

### Open items requiring a decision

1. **Vivado version** to install — 2023.2 recommended (best XSim UVM support). The free Vivado ML
   Standard edition is sufficient; no licence needed for XSim.
2. **Where VC Formal runs** — same WSL machine, or a remote university/company Linux server? Affects
   only `formal/` scripting, not the RTL or checkers.
3. **Git** — this directory is not a repository. Recommend `git init` immediately so the bug log can
   reference real fix commits.
