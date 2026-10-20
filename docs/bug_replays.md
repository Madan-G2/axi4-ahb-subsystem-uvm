# Bug replays

Each RTL bug in [bug_log.md](bug_log.md) (category A) was fixed in place, so the repository no longer contains the buggy design. A **replay** brings one back: the original defective code sits behind `ifdef REPLAY_Ax` in the RTL, [`scripts/replay.py`](../scripts/replay.py) builds that variant, runs the test that caught it, confirms the testbench fails the way the bug log says, runs the same test and seed on the fixed design as a control, and walks the failure back through the waveform ([`scripts/vcd_tool.py`](../scripts/vcd_tool.py)).

**What a replay is not.** It is not a new bug and is not counted as one. It re-enacts a defect that was found the ordinary way (the *How it was found* line under each says how), so that the root-cause workflow can be repeated, inspected and explained -- and so the claim 'the testbench detects this class of bug' is something that can be re-run rather than something that was once true.

```
python scripts/replay.py list              # the six replays
python scripts/replay.py run A5            # build the buggy variant, run, control run, analyse
python scripts/replay.py all               # everything below
python scripts/replay.py analyze A5        # redo only the waveform step from saved artifacts
```

Artifacts land in `sim/replay/<bug>/` (log, `waves.vcd`, `analysis.txt`, `result.json`). The tables below are read from them by `scripts/make_replay_doc.py`.

| bug | test (seed) | buggy design | fixed design (control) | caught by |
|---|---|---|---|---|
| A1 | `soc_multi_master_test` (1) | FAIL | pass | `a_aw_payload_stable` |
| A2 | `axi_bridge_probe_test` (1) | FAIL | pass | `[SCB] READ (data mismatch / X/Z)` |
| A3 | `axi_bridge_probe_test` (1) | FAIL | pass | `[SCB] READ (data mismatch / X/Z)` |
| A4 | `axi_bridge_probe_test` (1) | FAIL | pass | `[SCB] READ (data mismatch / X/Z)` |
| A5 | `axi_exclusive_test` (1) | FAIL | pass | `[SCB] WRITE resp mismatch` |
| A6 | `axi_random_test` (1) | FAIL | pass | `[TBTOP] global timeout` |

## A1 — Round-robin arbiter re-decided its grant every cycle

**Run it:** `python scripts/replay.py run A1`   (`-d REPLAY_A1`)

**How it was originally found.** Found by the protocol checker (`a_aw_payload_stable`, slave side) on the first multi-master run -- not by a waveform. The scoreboard never saw a problem.

**What the replay shows.**

* buggy design: `checked 327 writes, 273 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 97344 assertion failure(s), 0 UVM_ERROR(s)
* fixed design, same test and seed: `checked 319 writes, 281 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 145 ns: `s1: a_aw_payload_stable violated`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  m0_awv  m1_awv  m2_awv  s1_awv  s1_awr  s1_awid  s1_awaddr  locked  gnt
--------  ------  ------  ------  ------  ------  -------  ---------  ------  ---
    65.0       0       0       0       0       0        0          0       0    0
    75.0       0       0       0       0       0        0          0       0    0
    85.0       0       0       0       0       0        0          0       0    0
    95.0       0       0       0       0       0        0          0       0    0
   105.0       0       0       0       0       0        0          0       0    0
   115.0       1       0       0       0       0        a       dd3c       0    0
   125.0       0       0       0       0       0        a       dd3c       0    0
   135.0       0       1       0       1       0       11   100103e0       0    1
   145.0       1       1       1       1       0        e   100105d1       0    0 <== failure
   155.0       1       1       1       1       0        e   100105d1       0    0
   165.0       1       1       1       1       0        e   100105d1       0    0
```

**Reading it.**

`m*_awv` are the three masters' AWVALIDs into the crossbar; `s1_*` is the AW channel the
crossbar presents to slave 1 (the AHB bridge); `locked` and `gnt` are the state of that
slave's AW arbiter.

Follow `gnt`, `s1_awid` and `s1_awaddr` on the rows where `s1_awv=1` and `s1_awr=0` -- a request
is on offer and the bridge has not accepted it. With a grant hold they cannot change in that
state. Here they do: when another master ranks ahead of the one on offer, the arbiter simply
re-scans, and the ID and address on the bus change **inside the handshake**. That is the marker
row (`a_aw_payload_stable`). `locked` is 0 on every row: nothing ever pinned the first choice.
(The arbiter's own assertion, `a_gnt_held_until_accept`, fires earlier still, on the first cycle
a grant is offered and not taken; it did not exist when the bug was first found.)

**The fix.** `locked` / `lock_idx` registers: the first choice is held until it is accepted. Rotation still happens only on acceptance. Two assertions now sit at the arbiter itself (`a_gnt_held_until_accept`, `a_gnt_is_requesting`) so the next regression of this kind is caught where it happens rather than at a slave port two hops away.

**What to take from it.** The data path was perfect -- the scoreboard reported zero errors over 600 transactions while the checker reported tens of thousands of violations. That is the argument for having a protocol checker at all: a scoreboard can only compare values, and here only the timing was wrong.

## A2 — Bridge read data ignored AHB byte-lane rotation and overran the AXI word

**Run it:** `python scripts/replay.py run A2`   (`-d REPLAY_A2`)

**How it was originally found.** Found by the scoreboard against the C++ model (originally as zeros in the upper byte lanes; since the scoreboard was made 4-state, as X on a defined lane).

**What the replay shows.**

* buggy design: `checked 3 writes, 6 reads; 0 response errors, 3 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s), 3 UVM_ERROR(s)
* fixed design, same test and seed: `checked 3 writes, 6 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 715.0 ns: `[SCB] READ data mismatch beat=0 lane=2: DUT=0x87 expected=0x30  (RD id=2 addr=0x10010102 len=3 size=1 burst=1 lock=0 resp=0)`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  st  beat  byte  step  htrans     haddr  hsize  hready    hrdata  dp_v  dp_ln  rv             rdata
--------  --  ----  ----  ----  ------  --------  -----  ------  --------  ----  -----  --  ----------------
   415.0   2     0     2     2       2  10010102      1       1         0     0      1   0  xxxxxxxxxxxxxxxx
   425.0   2     0     4     1       0         0      2       1  be30b987     1      2   0  xxxxxxxxxxxxxxxx
   505.0   2     1     4     2       2  10010104      1       1         0     0      3   0  xxxxbe30b987xxxx
   515.0   2     1     6     1       0         0      2       1  6276724d     1      4   0  xxxxbe30b987xxxx
   595.0   2     2     6     2       2  10010106      1       1         0     0      5   0  xxxxbe30b987xxxx
   605.0   2     3     0     2       2  10010108      1       1  6276724d     1      6   0  xxxxbe30b987xxxx
   615.0   2     3     2     1       0         0      2       1  5d120999     1      0   0  xxxxbe30b987xxxx
   685.0   5     3     0     1       0         0      2       1         0     0      0   1  xxxxbe30b987xxxx
   695.0   5     3     0     1       0         0      2       1         0     0      0   1  6276724dxxxxxxxx
   705.0   5     3     0     1       0         0      2       1         0     0      0   1  724dxxxxxxxxxxxx
   715.0   5     3     0     1       0         0      2       1         0     0      0   1  xxxxxxxx5d120999 <== failure
```

**Reading it.**

Rows are the AHB halfword transfers (`haddr`, `hsize=1`) that make up one four-beat halfword read
starting at `...102`, the whole 32-bit word the AHB slave returned for each (`hrdata`), and last the
four R beats the bridge hands the master (`rv=1`; `rdata` is 64 bits, `x` marks a nibble that is X).

For the halfword at `...102` the slave returns the word at `...100`, with the halfword on the lanes
its *address* selects -- the upper half of `hrdata`. A correct bridge picks those two bytes out and
puts them in the AXI lanes the beat occupies (lanes 2-3). This one copies a fixed 32 bits at
`8*(lane & 7)` instead. Look at `rdata` for beat 0, `xxxxbe30b987xxxx`: the entire word `be30b987`
has been dropped in starting at lane 2, so lanes 2-3 hold `87 b9` -- the half the address did *not*
select -- and the bytes that belong there, `30 be`, sit two lanes too high, in lanes 4-5. Every other
beat is the same kind of mess, with X wherever the bridge never wrote.

**The fix.** Capture only the bytes the transfer moved, rotating each from `hrdata[(addr[1:0]+k) % 4]` into AXI lane `dp_lane + k`.

**What to take from it.** The failure is invisible to a test that only checks 'the right number of beats came back'. It took a byte-exact reference model, and then a scoreboard that treats X as a failure.

## A3 — Bridge general path skipped a whole beat when its first lane was inactive

**Run it:** `python scripts/replay.py run A3`   (`-d REPLAY_A3`)

**How it was originally found.** Found by the scoreboard against the C++ model.

**What the replay shows.**

* buggy design: `checked 3 writes, 6 reads; 0 response errors, 2 data errors, 4 x errors (0 illegal skipped)` — 0 assertion failure(s), 6 UVM_ERROR(s)
* fixed design, same test and seed: `checked 3 writes, 6 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 485.0 ns: `[SCB] READ X/Z on defined lane: beat=0 lane=2 got=xxxxxxxx  (RD id=2 addr=0x10010102 len=3 size=1 burst=1 lock=0 resp=0)`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  st  beat  byte  step  htrans     haddr  hsize  hready    hrdata  dp_v  dp_ln  dp_run
--------  --  ----  ----  ----  ------  --------  -----  ------  --------  ----  -----  ------
   345.0   2     0     0     4       3  1001013c      2       1         0     1      0       4
   355.0   2     0     0     1       0         0      2       1         0     1      4       4
   365.0   2     0     0     1       0         0      2       1         0     0      0       0
   375.0   4     0     0     1       0         0      2       1         0     0      0       0
   385.0   0     0     0     1       0         0      2       1         0     0      0       0
   395.0   2     0     0     8       0         0      2       1         0     0      0       0
   405.0   2     1     0     8       0         0      2       1         0     0      0       0
   415.0   2     2     0     8       0         0      2       1         0     0      0       0
   425.0   2     3     0     2       2  10010108      1       1         0     0      0       0 <== here
   435.0   2     3     2     8       0         0      2       1  5d120999     1      0       2
   445.0   2     3     0     1       0         0      2       1         0     0      2       0
   455.0   5     3     0     1       0         0      2       1         0     0      0       0
```

**Reading it.**

`beat` and `byte` are the bridge's walk position (AXI beat; byte within the 64-bit bus), `step` is how
far the walk moves after this slot, `htrans` is what it issued. The read is four halfword beats
starting at `...102`, so beat 0 occupies lanes 2-3 and its byte 0 is *not* part of it.

The three rows before the marker are the walk at beats 0, 1 and 2: byte 0 is inactive, nothing is
issued (`htrans=0`), and `step` is **8** -- the width of the bus. The pointer jumps to the end of the
beat and on to the next one, so beats 0, 1 and 2 are thrown away without a single AHB transfer. The first
transfer of the whole burst is the marker row, a halfword at `...108`: beat 3, the one beat whose byte 0
happens to be active. A correct bridge steps by 1 over an inactive byte and looks at the next.

**The fix.** A disabled or inactive byte advances the pointer by one byte, not to the next beat.

**What to take from it.** Every narrow or unaligned beat starts with inactive low lanes, so the bug hit exactly the traffic the general path exists for, and nothing else.

## A4 — Bridge byte pointer advanced by 1 instead of the transfer's run length

**Run it:** `python scripts/replay.py run A4`   (`-d REPLAY_A4`)

**How it was originally found.** Found by the scoreboard, then localised by tracing every AHB transfer and bisecting by transfer size (byte-only passed; halfword failed). The mechanism is a simulator behaviour.

**What the replay shows.**

* buggy design: `checked 3 writes, 6 reads; 0 response errors, 0 data errors, 1 x errors (0 illegal skipped)` — 0 assertion failure(s), 1 UVM_ERROR(s)
* fixed design, same test and seed: `checked 3 writes, 6 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 1745.0 ns: `[SCB] READ X/Z on defined lane: beat=0 lane=3 got=xxxxxxxx  (RD id=9 addr=0x10010140 len=0 size=3 burst=1 lock=0 resp=0)`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  st  beat  byte  step  htrans     haddr  hsize  hready    hrdata  dp_v  dp_ln  dp_run
--------  --  ----  ----  ----  ------  --------  -----  ------  --------  ----  -----  ------
  1625.0   1     0     0     1       0         0      2       1         0     0      0       0
  1635.0   2     0     0     2       2  10010140      1       1         0     0      0       0 <== here
  1645.0   2     0     2     1       0         0      2       1         0     1      0       2
  1655.0   2     0     4     1       0         0      2       1         0     0      2       0
  1665.0   2     0     6     1       0         0      2       1         0     0      4       0
  1675.0   2     0     0     1       0         0      2       1         0     0      6       0
  1685.0   4     0     0     1       0         0      2       1         0     0      0       0
  1695.0   0     0     0     1       0         0      2       1         0     0      0       0
  1705.0   2     0     0     4       2  10010140      2       1         0     0      0       0
  1715.0   2     0     0     4       3  10010144      2       1  xxxxe33a     1      0       4
  1725.0   2     0     0     1       0         0      2       1  xxxxxxxx     1      4       4
```

**Reading it.**

This is the write half of the probe: one 64-bit beat with strobes `0b1011` -- bytes 0-1 (a halfword),
byte 2 disabled, byte 3 on its own -- followed by the read-back.

The marker row issues the halfword for bytes 0-1 (`NONSEQ`, `hsize=1`, `step=2`). Every row after it
advances `byte` by **2** (0, 2, 4, 6, then the next beat) although the correct step, `step`, which comes
from the combinational decision, is 1: byte 2 is the gap, so the walk should reach byte 3 next and issue
it. It never does. Byte 3 is skipped, its strobe silently ignored, and the read-back returns
`hrdata = xxxxe33a` at `...140`: bytes 0-1 written, byte 2 never written (legitimately X), byte 3 X -- a
write that was lost.

The cause: the advance was recomputed in the `always_ff` into an `automatic` variable *with an
initializer*. XSim does not re-evaluate such an initializer on every execution of the block; here it is
refreshed only when the byte pointer wraps to 0 at the start of a beat, and the stale value (2, from
the halfword at byte 0) is reused for the rest of the beat. The combinational copy (`step`) is
always right, which is why the transfer *size* is correct while the *advance* is not. (In the random
traffic that first found the bug the stale value was usually 1, so the same defect showed up as duplicate
byte transfers and X on reads rather than as this clean lost byte.)

**The fix.** Take the advance from the same `always_comb` evaluation that chose the transfer, so the two cannot disagree. A `grep` for procedural `automatic ... = ...` found the same pattern in the AHB slave.

**What to take from it.** A tool behaviour, not a design misunderstanding -- but the lesson is portable: never keep two copies of one decision, one combinational and one in a clocked block.

## A5 — Exclusive write that succeeded did not clear other IDs' reservations

**Run it:** `python scripts/replay.py run A5`   (`-d REPLAY_A5`)

**How it was originally found.** Found by the scoreboard against the spec-derived C++ model, in the directed exclusive-access test (case: two IDs reserve one location).

**What the replay shows.**

* buggy design: `checked 98 writes, 127 reads; 8 response errors, 6 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s), 14 UVM_ERROR(s)
* fixed design, same test and seed: `checked 98 writes, 127 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 935.0 ns: `[SCB] WRITE resp mismatch: DUT=1 expected=0  (WR id=4 addr=0x9130 len=0 size=3 burst=1 lock=1 resp=1)`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  awv  awr  awid  awlock  awaddr  wv  wlast  xpass  bv  bid  bresp
--------  ---  ---  ----  ------  ------  --  -----  -----  --  ---  -----
   935.0    0    1     4       1    9130   0      0      0   0   xx      x <== failure
```

**Reading it.**

Every row is a write to the CSR file: `awlock=1` marks an exclusive write, `bresp` the response
(1 = EXOKAY, 0 = OKAY = the exclusive store failed).

At the last two AWs: ID 3 stores exclusively to `...130` and gets EXOKAY (`bresp=1`) -- correct, it
holds a reservation and nobody has written since. ID 4 then stores exclusively to the **same**
address and also gets EXOKAY. ID 3's store changed the location, so ID 4's reservation must have
been cancelled and its store must fail. (`xpass` is the slave's latched decision for the write in
progress; on the row where the second AW is first presented it still shows the previous write's value.)

**The fix.** A write that actually changes memory -- normal, or exclusive-and-successful -- clears every overlapping reservation. A failed exclusive write changes nothing and clears nothing (`if (!cur.lock || excl_ok)`).

**What to take from it.** Two masters both 'win' a read-modify-write on the same word and one update is lost. And the reason it survived for two phases: the model's exclusive monitor had been written to match the RTL.

## A6 — Slave READY stuck low: a function with a hidden dependency inside a continuous assign

**Run it:** `python scripts/replay.py run A6`   (`-d REPLAY_A6`)

**How it was originally found.** Found by the testbench watchdog the first time a test turned slave-side READY backpressure on (`+SLV_BP`); the bounded-liveness assertions would have fired later still.

**What the replay shows.**

* buggy design: `<no scoreboard output>` — 19883 assertion failure(s), 0 UVM_ERROR(s)
* fixed design, same test and seed: `checked 61 writes, 39 reads; 0 response errors, 0 data errors, 0 x errors (0 illegal skipped)` — 0 assertion failure(s)
* first failure at 101175 ns: `m0: a_write_completes violated`

**Waveform** (values just before each clock edge, around the first failure):

```
time(ns)  awv  awr  wv  wr  aw_cnt  b_cnt      lfsr
--------  ---  ---  --  --  ------  -----  --------
   995.0    0    1   0   1       6      0  46926990
  1005.0    0    1   0   1       6      0  8d24d320
  1015.0    0    1   0   1       6      0  1a49a640
  1025.0    1    1   1   1       6      0  34934c80
  1035.0    1    0   0   1       7      0  69269900
  1045.0    1    0   0   1       7      0  d24d3201
  1055.0    1    0   1   1       7      0  a49a6402 <== here
  1065.0    1    0   0   1       6      1  4934c804
  1075.0    1    0   1   0       6      0  92699009
  1085.0    1    0   1   0       6      0  24d32013
  1095.0    1    0   1   0       6      0  49a64026
  1105.0    1    0   1   0       6      0  934c804c
  1115.0    1    0   1   0       6      0  26990099
  1125.0    1    0   1   0       6      0  4d320133
  1135.0    1    0   1   0       6      0  9a640267
  1145.0    1    0   1   0       6      0  34c804ce
  1155.0    1    0   1   0       6      0  6990099d
  1165.0    1    0   1   0       6      0  d320133b
  1175.0    1    0   1   0       6      0  a6402676
  1185.0    1    0   1   0       6      0  4c804cec
  1195.0    1    0   1   0       6      0  990099d8
  1205.0    1    0   1   0       6      0  320133b1
  1215.0    1    0   1   0       6      0  64026763
  1225.0    1    0   1   0       6      0  c804cec6
  1235.0    1    0   1   0       6      0  90099d8c
  1245.0    1    0   1   0       6      0  20133b19
  1255.0    1    0   1   0       6      0  40267633
  1265.0    1    0   1   0       6      0  804cec67
  1275.0    1    0   1   0       6      0    99d8cf
  1285.0    1    0   1   0       6      0   133b19e
  1295.0    1    0   1   0       6      0   267633c
```

**Reading it.**

`awv`/`awr` and `wv`/`wr` are the AW and W channels at the SRAM slave; `aw_cnt` is the slave's
queue occupancy and `lfsr` the pseudo-random source its READY is meant to follow.

The marker row is the last handshake this slave ever completes. From the next row on, AWREADY and
WREADY are both 0 -- with `aw_cnt` well below its limit of 8 and `b_cnt=0` -- while `lfsr` changes on
every single clock. READY depends on the LFSR, the LFSR is running, and READY does not move. Nothing
changes `aw_cnt` or `b_cnt`, so nothing ever causes the continuous assignment to be re-evaluated.

**The fix.** Pass `lfsr` and the backpressure percentage to `bp_stall()` as arguments, so the continuous assignment is sensitive to them.

**What to take from it.** Legal SystemVerilog, synthesises fine, and hangs in simulation. The trap is a function reading module state from inside a continuous assignment. It was latent from the first day because the backpressure knob defaulted to 0 -- a feature nobody had ever turned on.
