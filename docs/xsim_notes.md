# Vivado XSim — Practical Notes

Behaviours of Vivado XSim 2024.1.2 hit while bringing up the design, the checkers and
the coverage flow, with the exact error text each one produces. Recorded because several of them fail in ways that
point nowhere near the actual cause, and all of them cost real debugging time.

Install in use: `E:\Vivado\2024.1` (UVM 1.2 at `data/system_verilog/uvm_1.2`).

---

## Environment

### PATH needs three directories, not one

```
E:/Vivado/2024.1/bin
E:/Vivado/2024.1/tps/mingw/6.2.0/win64.o/nt/bin
E:/Vivado/2024.1/lib/win64.o
```

`bin/` alone gets you through compile and elaboration, then the simulation dies
before time 0 with:

```
Simulation engine failed to start: Simulation exited with status code -1073741511.
```

`0xC0000139` is `STATUS_ENTRYPOINT_NOT_FOUND` — a missing DLL. `xsc` builds the
DPI object with Vivado's bundled MinGW g++, so the simulation needs that
toolchain's runtime DLLs at load time. Nothing in the message says so.

### GNU make is not present

Git Bash does not ship `make`, so the Makefile flow is unusable on this host even
though every Vivado tool works. `scripts/run.py` is the Windows entry point; the
Makefile remains the Linux / VCS path.

---

## DPI-C

### The library must be named `.a`, not `.so`

On Windows `xsc` links with `ar rcs`, producing a static archive, and
`xelab -sv_lib <name>` looks for `<name>.a`. Naming the output `.so` gives:

```
Invalid path for DPI library: ...\dpi_ref.so
```

### Scalars only across the boundary

`verif/ref_model/dpi_shim.cpp` passes nothing but plain scalars — no
`svOpenArrayHandle`, no `svLogicVecVal`, not even `#include <svdpi.h>`. This was
a deliberate choice (spec decision G5) and it paid off: the C++ model compiled
and linked first try, and `ref_selftest()` returned 0 on the first run that got
far enough to call it.

---

## Command line

### Plusargs must go through an options file

The `xsim` wrapper rewrites `-testplusarg NAME=value` into `NAME value`, so the
plusarg arrives without its value. UVM then reports:

```
UVM_FATAL @ 0: reporter [NOCOMP] No components instantiated...
```

because it never saw `UVM_TESTNAME`. Passing the same switches via `-f opts.f`
bypasses the wrapper's mangling. Quoting on the command line (`'"NAME=value"'`)
also survives, but the options file is what the scripts use.

### `-f` files use `--include`, not `+incdir+`

```
ERROR: [XSIM 43-4316] Can not find file: +incdir+../../rtl/common
```

### The tools are `.bat` wrappers

`CreateProcess` will not launch a `.bat` from a bare name, so Python's
`subprocess` needs the executable resolved via `shutil.which` first. Otherwise
every call dies with `FileNotFoundError: [WinError 2]`, which reads like Vivado
is missing entirely.

---

## SystemVerilog / SVA support gaps

### `bind` into an interface is rejected

```
ERROR: [VRFC 10-3535] module instantiation of 'axi4_protocol_checker'
       is not allowed in interface 'axi4_if_default'
```

The LRM permits it; XSim 2024.1 does not implement it. Binding to the DUT module
instead (`bind axi4_sram_ctrl ... (.*)`) elaborates, but has its own problem --
see "bind onto a module's OUTPUT ports samples as X" below. Both slave and master
checkers ended up explicitly instantiated.

### `default disable iff` is unsupported

```
ERROR: [XSIM 43-3980] The SystemVerilog feature "Default Disable iff
       declaration" is not supported yet for simulation.
```

Every property carries an explicit `disable iff (!aresetn)`. The reset property
deliberately does not — it is checking behaviour *during* reset.

### No non-blocking assignment to queues / associative / dynamic arrays

```
ERROR: [XSIM 43-3980] "Non-Blocking Assignment to Queue/Associative-Array/
       Dynamic-Array Types" is not supported yet for simulation.
```

The checker's per-ID bookkeeping uses fixed-size arrays indexed over the whole ID
space (16 entries at `ID_W=4`). Switching to blocking assignment inside
`always_ff` would silence the message but reintroduce a sampling race against the
properties reading the same state.

---

## Constraint solver

Three separate problems, all reported as the same unhelpful line:

```
WARNING: randomize failed to meet constraint.
```

No indication of *which* constraint. Bisecting by adding inline terms one at a
time is the only practical way in.

### `soft` constraints are broken

```
Invalid consttrain id : 0, exceeds total number of constraints (0).
Invalid consttrain id : 1, exceeds total number of constraints (0).
...
Out of memory on request for a fresh 8388608 bytes
Total memory consumed so far : 3192827920 bytes
```

A 3 GB runaway before the solver gives up. `soft` is the textbook fix for
"default distribution that a directed test can override", and it is unusable
here. `axi4_seq_item` gates its distributions with plain non-rand switches
(`shape_len`, `shape_burst`, `shape_strb`) instead; `soc_base_seq.make_item(...,
.directed(1))` clears them.

### `dist` beats a hard inline constraint

The solver picks a `dist` bin *before* checking an inline constraint and then
fails rather than backtracking. So `len == 0` against a dist that gives bin 0 a
weight of 30 fails roughly 70% of the time — intermittently, and only for some
seeds, which makes it look like a stimulus bug rather than a tool one.

### Unsized `'1` fails inside a constraint

```systemverilog
foreach (strb[i]) strb[i] == '1;              // fails to solve
foreach (strb[i]) strb[i] == {AXI_STRB_W{1'b1}};  // works
```

Deterministic, and reproducible with a single-element array and every other
constraint satisfied. `'1` is fine in procedural code; it only misbehaves inside
a constraint block.

### `->` implications are not reliable either

With `allow_lock` clear, `(!allow_lock) -> lock == 1'b0` still let occasional
`AxLOCK=1` requests through, tripping the protocol checker in a seed-dependent
way that vanished whenever anything shifted the RNG stream. Rewritten as
`if (!allow_lock) lock == 1'b0`, and belt-and-braces the sequence also takes
`lock` out of the solve entirely via `rand_mode(0)` when exclusive access is not
wanted.

---

## Assertion sampling (found in Phase 2)

Two separate ways XSim reports a passing design as failing. Both are worth
knowing because the failure looks exactly like an RTL bug.

### `bind` onto a module's OUTPUT ports samples as X

A checker bound with `bind axi4_sram_ctrl axi4_protocol_checker ... (.*)` reads
the target's output ports as X in the preponed region, even when they are driven
0 throughout. `a_reset_valids_low` then fires on every cycle of reset with
`$sampled()` reporting `x` for bvalid and rvalid -- while a `$display` inside the
same module at the same instant shows both are `0`.

The give-away was that the master-side checkers, running the same property set
but explicitly instantiated, never fired. The fix is to tap the wires
hierarchically from the testbench (`u_dut.s_bvalid[s]`) and instantiate the
checker normally. Verbose, but correct, and it names each slave port
individually where a single bind could not.

### Unpacked-array reads inside a property sample as X

```systemverilog
// Fails on every issue, with cnt and dest both reading as X:
assert property (issue_valid |-> (cnt[issue_id] == 0) || (dest[issue_id] == issue_slave));
```

`cnt[]` and `dest[]` are plain unpacked arrays indexed by a signal. Inside a
property XSim samples them as X, so the whole expression evaluates to X and the
assertion fails. `$sampled()` in the action block reports X for the same reason,
which is what makes it so confusing -- the diagnostic and the property agree with
each other and both disagree with reality.

This produced 400 assertion failures per run against a crossbar whose data path
was provably correct: 0 scoreboard mismatches over thousands of transactions.

The fix is to reduce the condition to a single bit in `always_comb` and assert on
that:

```systemverilog
always_comb split_violation = issue_valid && (cnt[issue_id] != 0) &&
                              (dest[issue_id] != issue_slave);
assert property (@(posedge clk) disable iff (!rstn) !split_violation);
```

Worth applying pre-emptively to any assertion that indexes an array with a
signal.

---

## Procedural `automatic` initializers are not re-evaluated (found in Phase 3)

```systemverilog
always_ff @(posedge clk) begin
  ...
  automatic int unsigned run = run_at(beat, ptr, base);   // evaluated ONCE
```

XSim does not re-evaluate the initializer on each execution of the block, so the
variable holds a stale value. Observed in the bug-A4 replay: it is refreshed only
when the byte pointer wraps to 0 at the start of a beat, and the value from that
moment is reused for the rest of the beat. (An earlier version of this note said
"keeps its time-0 value for the whole simulation"; that overstated it.)

This is the nastiest item on this page, because nothing about it looks wrong.
There is no warning, the code is legal SystemVerilog, and a combinational block
computing the identical expression a few lines away gets the right answer -- so
the waveform shows the correct transfer size next to an incorrect pointer
advance.

Avoid the pattern entirely: declare the variable at the top of the block and
assign it with a blocking statement, or compute the value in `always_comb` and
consume it in the `always_ff`. The latter is better anyway, because it removes a
duplicated expression that could otherwise disagree with itself.

Worth grepping for after any RTL is written:

```
grep -rn "automatic .* = " rtl/ --include=*.sv | grep -v "function\|task"
```

---

## Parallel regression

Concurrent `xsim` processes **cannot** share a working directory. They share
`xsim.log`, the waveform database and runtime state under `xsim.dir`, and jobs
end up reporting each other's results.

This is the most dangerous item on this page because it does not look like a
failure: the runs exit cleanly and report PASS, just against the wrong test's
numbers. It was caught only because four 200-transaction random runs all reported
the one-write/one-read totals of the smoke test.

`--xsimdir` alone does not fix it — xsim resolves both the snapshot and the DPI
library relative to the working directory, and still fails with
`Simulation engine failed to start: status code 1`. Each job gets its own copy of
the elaborated tree under `sim/work/<test>_<seed>/` (~12 MB each).


---

## Assertions that XSim drops or mis-samples (found while hardening the checker)

A property that never fires looks exactly like a property that holds. Everything in this
section is a way for an assertion to be silently dead or silently wrong, which is why
`python run.py neg-checker` exists: it feeds the checker one violation per property and
reports FIRED or DEAD (38/38 FIRED at the time of writing).

### Constructs that make XSim ignore the whole assertion

Each is a warning in `xelab.log` ("Unsupported feature in assertion/property/sequence"
or "...will be ignored"), and each took out an assertion that the full-design
regression then reported as clean. Eleven properties in `axi4_protocol_checker` were dead
this way until the negative harness was written.

| Construct inside a concurrent assertion | Rewritten as |
|---|---|
| a SystemVerilog queue or dynamic array | fixed array + read/write pointers + count, compared as scalars |
| an unpacked array indexed by a signal | a scalar `wire` computed outside the property |
| `$isunknown(x)` | `(^x) === 1'bx` — reduction XOR is X iff any bit is X or Z |
| a ranged delay with a parameter, `##[1:MAX]` | a watchdog counter and `counter <= MAX` |

### `cover property` is parsed and never simulated

```
WARNING: [XSIM 43-4100] "System Verilog Cover" is not supported yet for simulation.
```

120 SVA cover properties elaborate cleanly (`run.py lint-sva`) and count nothing. The
same 120 events are therefore generated twice from one table (`scripts/gen_cover.py`):
as `cover property` for a simulator that supports it, and as a procedural counter that
XSim does run. Both come from the same row, so they cannot disagree about what an
event is.

### `$past(...)` in an action block

```
ERROR: [XSIM 43-4463] Unable to infer clocking event for system function call "past".
```

Fine inside the property, rejected in the `else $error(...)` branch. Keep the previous
cycle's value in a register and print that.

### `$sampled` of a module output driven by `always_comb` can be X

Inside `axi4_rr_arbiter`, a property over the module's own output ports
(`gnt_valid`, `gnt_idx`) got X from the preponed sample in some instances, with the
registers beside them (`locked`, `lock_idx`) sampling correctly:

```
grant moved from idx 2 to idx X (valid=...x) [sampled: held=1 acc=1 req=100 locked=1 lock_idx=2]
```

113,000 failures from a design that was behaving. Same family as the `bind` and
unpacked-array findings above: the sampled copy of a combinational output is not
reliable. The assertions are written over the registers the outputs are derived from.

### A function called from a continuous assign is not sensitive to what it reads

```systemverilog
function bit bp_stall(input int unsigned shift);          // reads lfsr and bp_pct
  return (({lfsr, lfsr} >> shift) & 7'h7F) % 100 < bp_pct;
endfunction
assign awready = (aw_cnt < DEPTH) && !bp_stall(0);         // re-evaluated only on aw_cnt
```

This one is the LRM, not an XSim bug: a continuous assignment re-evaluates when one of
its operands changes, and variables read inside a called function are not operands.
`awready` was recomputed only when `aw_cnt` moved, so a READY that evaluated low stayed
low while the LFSR it was meant to follow ran freely. The bus hung. (Bug A6.)

Pass everything the function reads as an argument, or use `always_comb`, which does
include variables read inside called functions. The same pattern is still present in
`axi4_sram_ctrl.read_beat()` (reads `mem[]`) where it is harmless, because stale read
data is the intended behaviour there — but it is worth knowing it is there.

---

## Coverage flow

### Functional coverage

* Covergroups in a **class** are merged by type across instances. Covergroups in a
  **module** are reported once per instance path
  (`tb_top.g_chk[0].u_chk...::cg_hs_aw`), so "did this ever happen on some interface"
  needs the bins unioned across instances. `cov_report.py` does that.
* Uncovered **cross** bins are printed in a compressed form (tuples and wildcards,
  `(b2, b3, )`, `*`). The parser expands them and checks the expansion against the
  totals XSim prints for the same cross; a mismatch is reported instead of trusted. An
  early version of one cross lost bins in exactly this compression (6 of 20, then 9 of
  10 reported), which is why the form-level coverpoint uses explicit bins.
* `with function sample(...)` works in a class covergroup; `illegal_bins` and
  `ignore_bins` work.

### Code coverage

```
xelab ... --cc_type sbct --cov_db_dir cov --cov_db_name tb_snap_cov
```

* Statement, branch, condition and toggle are one switch (`sbct`).
* `--cov_db_dir` / `--cov_db_name` are **required at elaboration**, not decoration. Hit
  data is only saved when the static database written at elaboration already exists at
  `<run dir>/cov/xsim.codeCov/<name>`. Without them every run completes normally and
  records nothing — 0.0% across the board, with no error.
* Each job directory therefore gets its own copy of the static database before it runs.
* Coverage is an elaboration property, so the instrumented snapshot is separate from the
  plain one (it simulates roughly three times slower).

### `xcrg`

* `-report_format text` is not implemented for code coverage ("Text based reporting is
  not supported for Code Coverage yet") and for functional coverage it quietly writes HTML
  anyway. `cov_report.py` parses the HTML.
* `-cov_db_name` is mandatory; `-merge_dir` paths must be absolute because the tool is run
  from inside the output directory.
* A big merge splits each module's report across `modN_1.html`, `modN_2.html`, … and the
  split parts **omit the toggle section**. `-cc_instancescount 1` (module summary only)
  avoids the split; the toggle bit counts are taken from a report of a single run.

---

## Elaboration and language quirks

* **Interface-array element, runtime index.** `m_if[i].awvalid` with a non-constant `i`
  does not elaborate; `tb_top` flattens the signals into vectors indexed by `i`.
* **Reserved words.** `small` and `dist` cannot be identifiers (a bin name and a port
  name tripped on them).
* **Declarations must precede statements** in a task or function block, including ones in
  a sequence body; XSim's error is a bare "syntax error near '<identifier>'".
* **No declaration initialisers inside a loop in a task.** Same family as the
  `automatic` initializer above — declare, then assign.
* **`repeat (cond ? a : b)` evaluates to 0.** With an unsigned member on one side of the
  conditional (`t.w_delay[b]`, `int unsigned`) and a signed literal on the other, the repeat
  count came out as 0 and the loop body never ran. Assign the count to an `int unsigned`
  variable and `repeat` on that. (Bug C14: every write burst silently became back-to-back.)
* **Never-written memory reads X.** Useful: the scoreboard treats X on a lane the model
  says is defined as its own failure. It is why a bug that used to read as "zeros in the
  upper lanes" (bug A2) now reads as "X on a defined lane".
* `final` blocks run; the `XILINX_SIMULATOR` macro is predefined; plusargs only arrive
  through the `-f` options file.

---

## A simulation can run away

One regression showed `xsimk.exe` at 9.9 GB and still climbing in a test that passes
when run alone. The log held the solver message already recorded under "soft
constraints are broken" (`Invalid consttrain id : N, exceeds total number of
constraints (0)`), and the regression runner's own error was
`WinError 1224: ... a file with a user-mapped section open`.

Cause: two regressions were running at once. They share `sim/work/<test>_<seed>/`, so a
job in the second one overwrote the elaborated tree under a simulation the first one was
still executing. Nothing about the resulting failure points at that.

What the runner does about it now (`scripts/run.py`):

* `sim/regress.lock` — a second regression refuses to start while one is alive.
* every simulation runs inside a Windows **job object**: the whole process tree dies with
  it, it has a 4 GB memory ceiling, and a 25-minute wall-clock limit terminates it.
  Killing the `xsim.bat` wrapper is not enough — the real simulator is its grandchild.
* a run directory that cannot be prepared (executable still mapped by a straggler) is
  retried and then reported as a failed job instead of aborting the whole regression.
