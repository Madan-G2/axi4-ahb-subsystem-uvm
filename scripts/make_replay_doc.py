#!/usr/bin/env python3
"""
Assemble docs/bug_replays.md from the artifacts of `replay.py all`.

The prose here is hand-written; every number, time and table in the output is read
from sim/replay/<bug>/ (result.json, analysis.txt), so the document cannot drift from
what the tooling actually printed. Re-run after `python scripts/replay.py all`.

    python scripts/make_replay_doc.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPLAY = ROOT / "sim" / "replay"
OUT = ROOT / "docs" / "bug_replays.md"

# ---------------------------------------------------------------------------
# The story of each bug. Keys: how it was ORIGINALLY found (honest), what the
# waveform shows, why the fix is the right one, and what to say about it.
# ---------------------------------------------------------------------------
STORY = {
    "A1": dict(
        found="Found by the protocol checker (`a_aw_payload_stable`, slave side) on the first "
              "multi-master run -- not by a waveform. The scoreboard never saw a problem.",
        reading="""\
`m*_awv` are the three masters' AWVALIDs into the crossbar; `s1_*` is the AW channel the
crossbar presents to slave 1 (the AHB bridge); `locked` and `gnt` are the state of that
slave's AW arbiter.

Follow `gnt`, `s1_awid` and `s1_awaddr` on the rows where `s1_awv=1` and `s1_awr=0` -- a request
is on offer and the bridge has not accepted it. With a grant hold they cannot change in that
state. Here they do: when another master ranks ahead of the one on offer, the arbiter simply
re-scans, and the ID and address on the bus change **inside the handshake**. That is the marker
row (`a_aw_payload_stable`). `locked` is 0 on every row: nothing ever pinned the first choice.
(The arbiter's own assertion, `a_gnt_held_until_accept`, fires earlier still, on the first cycle
a grant is offered and not taken; it did not exist when the bug was first found.)""",
        fix="`locked` / `lock_idx` registers: the first choice is held until it is accepted. "
            "Rotation still happens only on acceptance. Two assertions now sit at the arbiter itself "
            "(`a_gnt_held_until_accept`, `a_gnt_is_requesting`) so the next regression of this kind is "
            "caught where it happens rather than at a slave port two hops away.",
        say="The data path was perfect -- the scoreboard reported zero errors over 600 transactions "
            "while the checker reported tens of thousands of violations. That is the argument for having a "
            "protocol checker at all: a scoreboard can only compare values, and here only the timing was wrong.",
    ),
    "A2": dict(
        found="Found by the scoreboard against the C++ model (originally as zeros in the upper byte "
              "lanes; since the scoreboard was made 4-state, as X on a defined lane).",
        reading="""\
Rows are the AHB halfword transfers (`haddr`, `hsize=1`) that make up one four-beat halfword read
starting at `...102`, the whole 32-bit word the AHB slave returned for each (`hrdata`), and last the
four R beats the bridge hands the master (`rv=1`; `rdata` is 64 bits, `x` marks a nibble that is X).

For the halfword at `...102` the slave returns the word at `...100`, with the halfword on the lanes
its *address* selects -- the upper half of `hrdata`. A correct bridge picks those two bytes out and
puts them in the AXI lanes the beat occupies (lanes 2-3). This one copies a fixed 32 bits at
`8*(lane & 7)` instead. Look at `rdata` for beat 0, `xxxxbe30b987xxxx`: the entire word `be30b987`
has been dropped in starting at lane 2, so lanes 2-3 hold `87 b9` -- the half the address did *not*
select -- and the bytes that belong there, `30 be`, sit two lanes too high, in lanes 4-5. Every other
beat is the same kind of mess, with X wherever the bridge never wrote.""",
        fix="Capture only the bytes the transfer moved, rotating each from "
            "`hrdata[(addr[1:0]+k) % 4]` into AXI lane `dp_lane + k`.",
        say="The failure is invisible to a test that only checks 'the right number of beats came back'. "
            "It took a byte-exact reference model, and then a scoreboard that treats X as a failure.",
    ),
    "A3": dict(
        found="Found by the scoreboard against the C++ model.",
        reading="""\
`beat` and `byte` are the bridge's walk position (AXI beat; byte within the 64-bit bus), `step` is how
far the walk moves after this slot, `htrans` is what it issued. The read is four halfword beats
starting at `...102`, so beat 0 occupies lanes 2-3 and its byte 0 is *not* part of it.

The three rows before the marker are the walk at beats 0, 1 and 2: byte 0 is inactive, nothing is
issued (`htrans=0`), and `step` is **8** -- the width of the bus. The pointer jumps to the end of the
beat and on to the next one, so beats 0, 1 and 2 are thrown away without a single AHB transfer. The first
transfer of the whole burst is the marker row, a halfword at `...108`: beat 3, the one beat whose byte 0
happens to be active. A correct bridge steps by 1 over an inactive byte and looks at the next.""",
        fix="A disabled or inactive byte advances the pointer by one byte, not to the next beat.",
        say="Every narrow or unaligned beat starts with inactive low lanes, so the bug hit exactly the "
            "traffic the general path exists for, and nothing else.",
    ),
    "A4": dict(
        found="Found by the scoreboard, then localised by tracing every AHB transfer and bisecting by "
              "transfer size (byte-only passed; halfword failed). The mechanism is a simulator behaviour.",
        reading="""\
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
byte transfers and X on reads rather than as this clean lost byte.)""",
        fix="Take the advance from the same `always_comb` evaluation that chose the transfer, so the two cannot "
            "disagree. A `grep` for procedural `automatic ... = ...` found the same pattern in the AHB slave.",
        say="A tool behaviour, not a design misunderstanding -- but the lesson is portable: never keep two "
            "copies of one decision, one combinational and one in a clocked block.",
    ),
    "A5": dict(
        found="Found by the scoreboard against the spec-derived C++ model, in the directed exclusive-access test "
              "(case: two IDs reserve one location).",
        reading="""\
Every row is a write to the CSR file: `awlock=1` marks an exclusive write, `bresp` the response
(1 = EXOKAY, 0 = OKAY = the exclusive store failed).

At the last two AWs: ID 3 stores exclusively to `...130` and gets EXOKAY (`bresp=1`) -- correct, it
holds a reservation and nobody has written since. ID 4 then stores exclusively to the **same**
address and also gets EXOKAY. ID 3's store changed the location, so ID 4's reservation must have
been cancelled and its store must fail. (`xpass` is the slave's latched decision for the write in
progress; on the row where the second AW is first presented it still shows the previous write's value.)""",
        fix="A write that actually changes memory -- normal, or exclusive-and-successful -- clears every overlapping "
            "reservation. A failed exclusive write changes nothing and clears nothing (`if (!cur.lock || excl_ok)`).",
        say="Two masters both 'win' a read-modify-write on the same word and one update is lost. And the reason it "
            "survived for two phases: the model's exclusive monitor had been written to match the RTL.",
    ),
    "A6": dict(
        found="Found by the testbench watchdog the first time a test turned slave-side READY backpressure on "
              "(`+SLV_BP`); the bounded-liveness assertions would have fired later still.",
        reading="""\
`awv`/`awr` and `wv`/`wr` are the AW and W channels at the SRAM slave; `aw_cnt` is the slave's
queue occupancy and `lfsr` the pseudo-random source its READY is meant to follow.

The marker row is the last handshake this slave ever completes. From the next row on, AWREADY and
WREADY are both 0 -- with `aw_cnt` well below its limit of 8 and `b_cnt=0` -- while `lfsr` changes on
every single clock. READY depends on the LFSR, the LFSR is running, and READY does not move. Nothing
changes `aw_cnt` or `b_cnt`, so nothing ever causes the continuous assignment to be re-evaluated.""",
        fix="Pass `lfsr` and the backpressure percentage to `bp_stall()` as arguments, so the continuous "
            "assignment is sensitive to them.",
        say="Legal SystemVerilog, synthesises fine, and hangs in simulation. The trap is a function reading module "
            "state from inside a continuous assignment. It was latent from the first day because the backpressure "
            "knob defaulted to 0 -- a feature nobody had ever turned on.",
    ),
}


def load(bug):
    base = REPLAY / bug
    res = json.loads((base / "result.json").read_text(encoding="utf-8"))
    ana = (base / "analysis.txt").read_text(encoding="utf-8") if (base / "analysis.txt").exists() else ""
    return res, ana


def main():
    bugs = [b for b in STORY if (REPLAY / b / "result.json").exists()]
    if not bugs:
        sys.exit("no replay results found; run `python scripts/replay.py all` first")

    out = ["# Bug replays", "",
           "Each RTL bug in [bug_log.md](bug_log.md) (category A) was fixed in place, so the repository no longer "
           "contains the buggy design. A **replay** brings one back: the original defective code sits behind "
           "`ifdef REPLAY_Ax` in the RTL, [`scripts/replay.py`](../scripts/replay.py) builds that variant, runs the "
           "test that caught it, confirms the testbench fails the way the bug log says, runs the same test and "
           "seed on the fixed design as a control, and walks the failure back through the waveform "
           "([`scripts/vcd_tool.py`](../scripts/vcd_tool.py)).", "",
           "**What a replay is not.** It is not a new bug and is not counted as one. It re-enacts a defect that was "
           "found the ordinary way (the *How it was found* line under each says how), so that the root-cause "
           "workflow can be repeated, inspected and explained -- and so the claim 'the testbench detects this class "
           "of bug' is something that can be re-run rather than something that was once true.", "",
           "```",
           "python scripts/replay.py list              # the six replays",
           "python scripts/replay.py run A5            # build the buggy variant, run, control run, analyse",
           "python scripts/replay.py all               # everything below",
           "python scripts/replay.py analyze A5        # redo only the waveform step from saved artifacts",
           "```", "",
           "Artifacts land in `sim/replay/<bug>/` (log, `waves.vcd`, `analysis.txt`, `result.json`). "
           "The tables below are read from them by `scripts/make_replay_doc.py`.", "",
           "| bug | test (seed) | buggy design | fixed design (control) | caught by |",
           "|---|---|---|---|---|"]
    for b in bugs:
        r, _ = load(b)
        # The patterns are regexes; show them as the messages they match (and keep '|' out of a table cell).
        def pretty(rx):
            return rx.replace("\\", "").replace("|", " / ")
        caught = ", ".join(f"`{pretty(k)}`" for k, v in r["expect"].items() if v) or "-"
        out.append(f"| {b} | `{r['test']}` ({r['seed']}) | {'FAIL' if not r['buggy']['passed'] else 'pass'} | "
                   f"{'pass' if r['fixed']['passed'] else 'FAIL'} | {caught} |")
    out.append("")

    for b in bugs:
        r, ana = load(b)
        s = STORY[b]
        ff = r.get("first_failure") or {}
        out += [f"## {b} — {r['title']}", "",
                f"**Run it:** `python scripts/replay.py run {b}`   (`-d REPLAY_{b}`)", "",
                f"**How it was originally found.** {s['found']}", "",
                "**What the replay shows.**", "",
                f"* buggy design: `{r['buggy']['scb']}` — {r['buggy']['sva']} assertion failure(s), "
                f"{r['buggy']['uvm_error']} UVM_ERROR(s)",
                f"* fixed design, same test and seed: `{r['fixed']['scb']}` — {r['fixed']['sva']} assertion failure(s)",
                (f"* first failure at {ff.get('time_ns')} ns: `{ff.get('text', '')[:150]}`" if ff else ""), ""]
        if ana.strip():
            out += ["**Waveform** (values just before each clock edge, around the first failure):", "", "```", ana.rstrip(), "```", ""]
        out += ["**Reading it.**", "", s["reading"], "",
                f"**The fix.** {s['fix']}", "",
                f"**What to take from it.** {s['say']}", ""]
    OUT.write_text("\n".join(x for x in out if x is not None), encoding="utf-8")
    print(f"wrote {OUT} ({len(bugs)} replays)")


if __name__ == "__main__":
    main()
