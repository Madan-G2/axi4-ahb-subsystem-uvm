# AXI4 / AHB-Lite subsystem with a UVM testbench

A small SoC subsystem in SystemVerilog and the testbench built around it to find bugs in it. Three AXI4 masters go through a 3x3 crossbar to an SRAM, a CSR block and a bridge onto an AHB-Lite bus. Anything that doesn't decode lands in a default slave that answers DECERR.

```
M0 --+                          +-- S0  SRAM, 64 KB
M1 --+-- 3x3 AXI4 crossbar -----+-- S1  AXI-to-AHB-Lite bridge, then ROM / registers / wait-error slave
M2 --+                          +-- S2  CSR block, 4 KB
                                +-- S3  default slave
```

Verification is UVM 1.2 with a C++ reference model called over DPI-C, SVA checkers, and functional plus code coverage. All of it has been run on Vivado XSim 2024.1 on Windows, and nowhere else. There is no VCS run and no formal work in here, although the original plan had both. The last section lists what's missing.

## Design

The RTL is in `rtl/`, about 3,300 lines. The AXI side has 64-bit data and 32-bit addresses; the AHB side is 32-bit.

```
0x0000_0000  64 KB   SRAM
0x1000_0000  1 MB    AHB window, through the bridge
  0x1000_0000  16 KB   boot ROM, read only (a write gets ERROR)
  0x1001_0000  4 KB    peripheral registers
  0x1002_0000  4 KB    wait/error slave
  rest of window       AHB default slave: ERROR, which becomes SLVERR on the AXI side
0x2000_0000  4 KB    CSR block
anything else        default slave, DECERR
```

Each window is exactly the size of what's behind it, so nothing aliases.

The crossbar has a round-robin arbiter per slave for AW and another for AR, and one per master for B and for R. A master can have 8 reads and 8 writes outstanding. The master index is put in front of the ID on the way in (4 bits become 6) so responses can find their way back. AXI says responses with the same ID must come back in order, and the simplest way to guarantee that across slaves of different speeds is to never let it happen: a request whose ID is already outstanding to a different slave waits until the earlier one finishes. Write data that arrives before its AW goes into a small skid buffer.

The SRAM and the CSR block are the same slave module, and both support exclusive access.

The bridge is where most of the work is. AHB-Lite has no write strobes and its bursts can't cross a 1 KB boundary, while AXI has byte strobes and allows 4 KB. So the bridge has two paths. Full 64-bit aligned beats with every strobe set go out as real AHB bursts: INCR4/8/16, WRAP4/8/16, or undefined-length INCR that starts a new NONSEQ at each 1 KB boundary. Everything else (narrow beats, unaligned starts, sparse strobes, FIXED bursts, 16-beat wraps) is walked a byte at a time and sent as SINGLE transfers, taking the biggest aligned run of enabled bytes each time. The bridge collects a whole burst before it starts on the other side. That costs buffer space but keeps the bookkeeping easy to check.

The wait/error slave on the AHB side takes its behaviour from the address. Bits 7:4 give the number of wait states (0 to 15) and bit 9 makes it answer ERROR. It's bit 9 so that an AHB burst can cross an error boundary. The first version used bit 11, which no burst can ever cross, so errors never landed mid-burst (that's C15 in the bug log).

## Testbench

Each of the three masters is a UVM agent with a driver, monitor and sequencer. There is no CPU; M0 is an agent like the other two. The driver keeps several transactions in flight and randomises VALID/READY delays and the gaps between beats. The scoreboard compares every completed transaction with a C++ model of the whole address map, called through DPI-C with scalar arguments only.

The model was written from the AXI4 and AHB-Lite rules and the address map, not from the RTL. The first version of its exclusive-access part copied what the RTL did, so it agreed with the RTL and checked nothing. Bug A5 sat behind that until the model was rewritten from the AXI text.

There are 24 tests that should pass, run over a few seeds for 38 regression jobs, plus 12 negative tests. The 24 are constrained-random traffic (mixed, per target, several masters at once) and directed tests for FIXED/INCR/WRAP edge cases, 4 KB boundaries, strobe patterns, exclusive access, outstanding limits, full queues, AHB wait states and errors, the bridge's burst forms, READY toggling and slave-side backpressure. `docs/test_library.md` has one line per test.

In the negative tests the driver breaks the protocol on purpose: it withdraws VALID before READY, changes a payload field while VALID is waiting, drives X on a control field, sends WLAST a beat early or a beat late, or sends an illegal request. Each one passes only if the assertions meant to catch that violation fire, and nothing else does.

The protocol checker (`verif/sva/axi4_protocol_checker.sv`) has 36 properties and sits on every master and slave port of the crossbar. XSim ignores assertions that use some constructs (queues, indexing an unpacked array, `$isunknown`, a parameterised `##[1:N]`) and only prints a warning that's easy to miss, and eleven of the first-draft properties never ran. `verif/sva/tb_checker_neg.sv` found that. It's a separate small harness that breaks each property on purpose and checks that it fires, with 38 scenarios for the 36 properties. The eleven were rewritten and all of them fire now. `python scripts/run.py neg-checker` runs it.

There is no AHB protocol checker. The AHB side is covered by the scoreboard and by AHB coverage.

## Running it

You need Vivado 2024.1 (XSim, plus the MinGW g++ that ships with it, which builds the DPI model), Python 3, and Perl if you want the log summary. The scripts look for Vivado in `E:/Vivado/2024.1`; set `VIVADO_HOME` if yours is somewhere else. It has only been run on Windows 11.

```
python scripts/run.py comp                         # C++ model, compile, elaborate
python scripts/run.py run --test soc_smoke_test    # one test
python scripts/run.py regress                      # 50 jobs, 4 at a time, about 7 minutes
python scripts/run.py neg-checker                  # does every SVA property still fire
python scripts/replay.py all                       # put the six RTL bugs back and watch them fail
perl scripts/parse_log.pl --dir sim/logs           # one line per log
```

For coverage, run the regression on the coverage build, merge the databases, and run the closure check. The second regression (negative tests only) is there because some waivers depend on it.

```
python scripts/run.py regress --cov --stamp r1
python scripts/run.py regress --cov --negative --stamp r1neg
python scripts/run.py cov-report --regress sim/regress/r1 --out sim/cov/r1
python scripts/run.py cov-report --regress sim/regress/r1neg --negative --out sim/cov/r1neg
python scripts/run.py cov-check --label r1 --neg-label r1neg
```

`cov-check` exits non-zero while any goal is still open after waivers. Logs, waveforms and coverage databases all go under `sim/`, which isn't committed. `python scripts/run.py list-tests` prints every job.

## What it found

Six RTL bugs turned up, some while the testbench was being brought up and some while closing coverage. None was found by staring at a waveform. Each was caught by an assertion, the scoreboard or the watchdog, and then traced from the log.

A1, arbiter. A second master asking for the same slave could take the grant while the first was still waiting for AWREADY, so AWADDR, AWLEN and AWID changed in the middle of a handshake. The data still arrived correctly, so the scoreboard saw nothing. Only the protocol checker caught it.

A2, bridge. Read data from AHB wasn't rotated back onto the AXI byte lanes it belonged to, and for the upper lanes it ran off the end of the 64-bit word.

A3, bridge. The byte-walking path skipped a whole beat if the first lane of that beat was disabled, which is every narrow or unaligned beat.

A4, bridge. After a 2- or 4-byte transfer the byte pointer moved on by one instead of by the length of the run. The cause was an `automatic` variable with an initialiser inside an `always_ff`; XSim doesn't re-evaluate the initialiser on each pass, so the step was stale.

A5, SRAM/CSR slave. A successful exclusive write didn't cancel other IDs' reservations, so two masters doing a read-modify-write on the same word could both succeed and one update was lost.

A6, SRAM slave. READY went through a function that read module variables instead of its arguments. A continuous assignment doesn't re-run when those change, so READY could stay low for good once slave backpressure was switched on, and the test hung.

The defective code for each is still in the RTL behind `` `ifdef REPLAY_A1 `` and so on. `scripts/replay.py` builds that variant, runs the test that caught it plus a control run on the fixed design, and walks the failure back through the VCD to the cause. The VCD reading is `scripts/vcd_tool.py`, so no waveform viewer is needed. The output is in `docs/bug_replays.md`. The rest of `docs/bug_log.md` covers smaller things, mostly mistakes in the testbench and the flow, like a driver edit that silently removed every gap in the write data channel and made a whole coverage round meaningless.

## Coverage

There are 550 functional bins in 19 covergroups (burst type, length and size; targets; alignment and 4 KB position; strobes; response outcomes; handshake timing on every channel; outstanding depth; response ordering; arbitration; AHB transfer types, wait states and errors), plus XSim's code coverage on the RTL.

On the final sources, with 38 runs merged and no waivers applied:

```
functional    547 / 550     99.45%
statement    2030 / 2063    98.40%
branch        443 / 490     90.41%
condition     146 / 187     78.07%   reported, not gated
toggle                      50.93%   reported, not gated
cover events  120 / 120
```

Random tests alone got 84.9% functional, 91.5% statement and 78.1% branch. The directed tests did the rest, and writing them for the gaps is what turned up A5 and A6.

The closure script (`scripts/check_cov_closure.py`) reports functional, statement and branch at 100% after 84 waivers, all in `scripts/cov_waivers.json`. It's worth knowing what those are. Twenty are lines covered in another parameterisation of the same module and 8 are reachable only by the negative tests; the script checks both kinds against the data. The other 56 are reasoned exclusions it can't check (defensive default branches, assertion failure actions, rules of the testbench). The ledger, with a reason for each, is at the end of `docs/coverage_plan.md`.

Toggle and condition aren't gated. XSim's toggle report is per module, so a bit that can never toggle can't be named and waived, and its condition numbers disagree with the waveform in places.

There are also 120 `cover property` statements, generated from one list in `scripts/gen_cover.py`. They parse and elaborate in XSim, but XSim never simulates them, so the same 120 events are counted with procedural code as well and the reports use those counts. A simulator that counts covers could use the SVA versions directly; that hasn't been tried.

## What's missing

VCS. `scripts/Makefile` has a VCS flow that has never been run.

Formal. The plan included VC Formal runs on the bridge and the arbiter. None were done, and there is no `formal/` directory.

An AHB protocol checker. Only the AXI side has one.

A CPU. The plan had a PicoRV32 as M0.

Anything beyond a single clock. There is no CDC.

## Layout

```
rtl/              common (package, interface, arbiter), axi, bridge, ahb, top
verif/uvm/        axi4_agent, env (scoreboard, coverage), seq_lib, tests
verif/sva/        protocol checker, cover events, AHB coverage, checker unit harness
verif/ref_model/  C++ model and DPI shim
verif/tb/         tb_top
scripts/          run.py, replay.py, coverage scripts, parse_log.pl, Makefile
docs/             SPEC, bug_log, bug_replays, coverage_plan, test_library, xsim_notes, cover_events
```

`docs/SPEC.md` is the plan as it was written before any code; the box at the top lists where the build ended up different. `docs/xsim_notes.md` collects the XSim quirks that cost time.

## Notes

Most of the code and docs were written with Claude Code, working from the spec in `docs/SPEC.md`. Every number above comes from runs on the files in this repo. The logs, waveforms and coverage databases from those runs are not committed.
