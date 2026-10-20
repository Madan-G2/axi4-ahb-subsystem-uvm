#!/usr/bin/env python3
"""
Bug replays.

Every RTL bug this project found (docs/bug_log.md, category A) was fixed in place,
so the repository no longer contains the buggy design. A replay brings one back:
the original defective code sits behind `ifdef REPLAY_Ax` in the RTL, and this
script builds that variant, runs the test that caught it, shows that the
testbench fails the way the log says it did, and walks the failure back to its
cause in the waveform.

WHAT A REPLAY IS NOT
    It is not a new bug, and it is not counted as one. These are the same defects,
    re-enacted so that the root-cause workflow can be repeated and inspected, and so
    that the claim "the testbench detects this class of bug" is something that can
    be re-run rather than something that was once true.

    How each bug was ORIGINALLY found is recorded in bug_log.md and is not always
    by waveform (A1 by an assertion, A2/A3/A5 by the scoreboard, A4 by tracing the
    AHB transfers, A6 by a watchdog). The waveform analysis here is the confirming
    step: it shows the mechanism, so the fix can be argued to be the right one.

USAGE
    python replay.py list
    python replay.py run A5 [--no-waves]        # build, run buggy + control, analyse
    python replay.py all
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run as R            # noqa: E402  (build/run helpers shared with the regression)
import vcd_tool as V       # noqa: E402

ROOT = R.ROOT
OUT = ROOT / "sim" / "replay"
FIXED_BUILD, FIXED_WORK, FIXED_LOGS = R.BUILD, R.WORK, R.LOGS


# ---------------------------------------------------------------------------
# The replays.
#
#   expect : regexes that must each match at least one failure message of the buggy
#            run. A replay "reproduces" only if all of them match.
#   watch  : (alias, regex) signals for the waveform table; see vcd_tool.py.
#   focus  : the cycle window shown around the first failure.
# ---------------------------------------------------------------------------
REPLAYS = {
    "A1": dict(
        title="Round-robin arbiter re-decided its grant every cycle",
        files="rtl/common/axi4_rr_arbiter.sv",
        test="soc_multi_master_test", seed=1, n_txn=200, timeout=12_000_000, plus={},
        expect=[r"a_aw_payload_stable"],
        also=[r"grant to idx \d+ was not held"],
        focus_match=r"a_aw_payload_stable",
        watch=[("m0_awv", r"u_dut\.u_xbar\.m_awvalid@0:1"), ("m1_awv", r"u_dut\.u_xbar\.m_awvalid@1:1"),
               ("m2_awv", r"u_dut\.u_xbar\.m_awvalid@2:1"),
               ("s1_awv", r"u_dut\.u_xbar\.s_awvalid@1:1"), ("s1_awr", r"u_dut\.u_xbar\.s_awready@1:1"),
               ("s1_awid", r"u_dut\.u_xbar\.s_awid@6:6"), ("s1_awaddr", r"u_dut\.u_xbar\.s_awaddr@32:32"),
               ("locked", r"g_awarb\[1\]\.u_arb\.locked$"), ("gnt", r"g_awarb\[1\]\.u_arb\.gnt_idx$")],
        focus=(8, 2),
    ),
    "A2": dict(
        title="Bridge read data ignored AHB byte-lane rotation and overran the AXI word",
        files="rtl/bridge/axi2ahb_bridge.sv",
        test="axi_bridge_probe_test", seed=1, n_txn=0, timeout=20_000_000, plus={},
        expect=[r"\[SCB\] READ (data mismatch|X/Z)"],
        watch="bridge", focus=(80, 2),
    ),
    "A3": dict(
        title="Bridge general path skipped a whole beat when its first lane was inactive",
        files="rtl/bridge/axi2ahb_bridge.sv",
        test="axi_bridge_probe_test", seed=1, n_txn=0, timeout=20_000_000, plus={},
        expect=[r"\[SCB\] READ (data mismatch|X/Z)"],
        watch="bridge", focus=(80, 2),
    ),
    "A4": dict(
        title="Bridge byte pointer advanced by 1 instead of the transfer's run length",
        files="rtl/bridge/axi2ahb_bridge.sv",
        test="axi_bridge_probe_test", seed=1, n_txn=0, timeout=20_000_000, plus={},
        expect=[r"\[SCB\] READ (data mismatch|X/Z)"],
        watch="bridge", focus=(80, 2),
    ),
    "A5": dict(
        title="Exclusive write that succeeded did not clear other IDs' reservations",
        files="rtl/axi/axi4_sram_ctrl.sv",
        test="axi_exclusive_test", seed=1, n_txn=0, timeout=100_000_000, plus={},
        expect=[r"\[SCB\] WRITE resp mismatch"],
        watch=[("awv", r"u_dut\.u_xbar\.s_awvalid@2:1"), ("awr", r"u_dut\.u_xbar\.s_awready@2:1"),
               ("awid", r"u_dut\.u_xbar\.s_awid@12:6"), ("awlock", r"u_dut\.u_xbar\.s_awlock@2:1"),
               ("awaddr", r"u_dut\.u_xbar\.s_awaddr@64:32"),
               ("wv", r"u_dut\.u_xbar\.s_wvalid@2:1"), ("wlast", r"u_dut\.u_xbar\.s_wlast@2:1"),
               ("xpass", r"g_slv\[2\]\.g_mem\.u_slv\.w_excl_pass$"),
               ("bv", r"u_dut\.u_xbar\.s_bvalid@2:1"), ("bid", r"u_dut\.u_xbar\.s_bid@12:6"),
               ("bresp", r"u_dut\.u_xbar\.s_bresp@4:2")],
        keep=lambda v: v["awv"] == "1" or v["bv"] == "1",
        focus=(80, 2),
    ),
    "A6": dict(
        title="Slave READY stuck low: a function with a hidden dependency inside a continuous assign",
        files="rtl/axi/axi4_sram_ctrl.sv",
        test="axi_random_test", seed=1, n_txn=100, timeout=300_000, plus={"SLV_BP": "30"},
        expect=[r"\[TBTOP\] global timeout"],
        also=[r"a_write_completes", r"a_read_completes"],
        watch=[("awv", r"u_dut\.u_xbar\.s_awvalid@0:1"), ("awr", r"u_dut\.u_xbar\.s_awready@0:1"),
               ("wv", r"u_dut\.u_xbar\.s_wvalid@0:1"), ("wr", r"u_dut\.u_xbar\.s_wready@0:1"),
               ("aw_cnt", r"g_slv\[0\]\.g_mem\.u_slv\.aw_cnt$"), ("b_cnt", r"g_slv\[0\]\.g_mem\.u_slv\.b_cnt$"),
               ("lfsr", r"g_slv\[0\]\.g_mem\.u_slv\.lfsr$")],
        # the cycle after the last handshake this slave ever completed
        focus_fn=lambda w: max(t for t, v in w.rows if (v["awv"] == "1" and v["awr"] == "1")
                               or (v["wv"] == "1" and v["wr"] == "1")),
        focus=(6, 24),
    ),
}

# Signals shared by the three bridge replays (A2-A4). They all fail on the same read
# and differ only in what goes wrong inside the bridge on the way to its R data.
BRIDGE_WATCH = [
    ("st",    r"u_bridge\.st$"),
    ("beat",  r"u_bridge\.g_beat$"),   ("byte", r"u_bridge\.g_byte$"),
    ("step",  r"u_bridge\.ap_step$"),
    ("htrans", r"g_ahb\.u_slv\.htrans$"), ("haddr", r"g_ahb\.u_slv\.haddr$"),
    ("hsize", r"g_ahb\.u_slv\.hsize$"),   ("hready", r"g_ahb\.u_slv\.hready$"),
    ("hrdata", r"g_ahb\.u_slv\.hrdata$"),
    ("dp_v",  r"u_bridge\.dp_val$"), ("dp_ln", r"u_bridge\.dp_lane$"),
]
def _bits(v, key):
    """Integer value of a raw bit-string sample, or -1 if it holds x/z."""
    return int(v[key], 2) if set(v[key]) <= set("01") else -1


def _first(w, pred):
    return next(t for t, v in w.rows if pred(v))


# A3: the first AHB transfer of the halfword read is NOT beat 0 -- the walk threw the earlier
#     beats away. Show the idle walk that precedes it, row by row (no filtering).
REPLAYS["A3"]["watch"] = BRIDGE_WATCH + [("dp_run", r"u_bridge\.dp_run$")]
REPLAYS["A3"]["focus_fn"] = lambda w: _first(w, lambda v: v["htrans"] == "10" and _bits(v, "hsize") == 1)
REPLAYS["A3"]["focus"] = (8, 3)

# A4: the sparse write (strobes 0b1011) at ...140 -- a halfword, then the gap, then the walk
#     must come back for byte 3. Show every row of the walk.
REPLAYS["A4"]["watch"] = BRIDGE_WATCH + [("dp_run", r"u_bridge\.dp_run$")]
REPLAYS["A4"]["focus_fn"] = lambda w: _first(w, lambda v: v["htrans"] == "10" and _bits(v, "hsize") == 1 and
                                              _bits(v, "haddr") == 0x10010140)
REPLAYS["A4"]["focus"] = (1, 9)

# A2 is about what the bridge does with the data it reads back, so it also shows the R beats it
# returns (dp_run did not exist in the original code, hence not watched here). The first halfword
# read is the failing one: show its transfers and its four R beats.
REPLAYS["A2"]["watch"] = BRIDGE_WATCH + [("rv", r"g_ahb\.u_slv\.rvalid$"), ("rdata", r"g_ahb\.u_slv\.rdata$")]
REPLAYS["A2"]["keep"] = lambda v: v["htrans"] in ("10", "11") or v["dp_v"] == "1" or v["rv"] == "1"
REPLAYS["A2"]["focus"] = (30, 2)


# ---------------------------------------------------------------------------
def scan_failures(log_text):
    """-> list of dict(time_ns, kind, text). SVA: the line pair  'Time: N ns ...' /
    'Error: msg';  UVM: 'UVM_ERROR file(line) @ T: reporter [ID] msg'."""
    out, last_time = [], None
    for line in log_text.splitlines():
        s = line.strip()
        m = re.match(r"Time:\s+(\d+)\s*ns", s)
        if m:
            last_time = int(m.group(1))
            continue
        if s.startswith("Error:"):
            out.append(dict(time_ns=last_time, kind="SVA", text=s[len("Error:"):].strip()))
            continue
        m = re.match(r"UVM_(ERROR|FATAL)\s.*?@\s*(\d+)(?:\s*ns)?:\s*\S+\s*\[(\w+)\]\s*(.*)", s)
        if m:
            t = int(m.group(2))
            # UVM prints time in the simulator's resolution (ps), always; convert.
            out.append(dict(time_ns=t / 1000.0, kind="UVM_" + m.group(1),
                            text=f"[{m.group(3)}] {m.group(4)}"))
    return out


def use_build(kind):
    """Point run.py's module-level paths at the replay build or the real one."""
    if kind == "fixed":
        R.BUILD, R.WORK, R.LOGS = FIXED_BUILD, FIXED_WORK, FIXED_LOGS
    else:
        base = OUT / kind
        R.BUILD, R.WORK, R.LOGS = base / "build", base / "work", base / "logs"
    for d in (R.BUILD, R.WORK, R.LOGS):
        d.mkdir(parents=True, exist_ok=True)


def waveform_analysis(bug, first, base):
    """Walk the first failure back through the waveform. Returns the printed text."""
    rp = REPLAYS[bug]
    vcd = base / "run_buggy" / "waves.vcd"
    if not (first and first["time_ns"] is not None and vcd.exists() and rp["watch"]):
        return ""
    try:
        w = V.load(str(vcd), [V.parse_spec(f"{a}={rx}") for a, rx in rp["watch"]])
    except SystemExit as e:
        msg = f"(waveform analysis skipped: {e})"
        print("    " + msg)
        return msg
    before, after = rp["focus"]
    period = (w.rows[1][0] - w.rows[0][0]) if len(w.rows) > 1 else 10_000
    t = rp["focus_fn"](w) if "focus_fn" in rp else rp.get("focus_ns", first["time_ns"]) * 1000
    keep = rp.get("keep")
    label = "here" if "focus_fn" in rp else "failure"
    text = V.table(w, [a for a, _ in rp["watch"]], t - before * period, t + after * period, t, keep, label)
    print("\n    waveform around the first failure (values just before each clock edge):\n")
    print("\n".join("      " + l for l in text.splitlines()))
    return text


def run_replay(bug, waves=True):
    rp = REPLAYS[bug]
    base = OUT / bug
    base.mkdir(parents=True, exist_ok=True)
    define = f"REPLAY_{bug}"

    print(f"\n=== {bug}: {rp['title']} ===")
    print(f"    defect re-enabled with -d {define} in {rp['files']}")

    # ---- buggy build and run ---------------------------------------------------------
    use_build(bug)
    R.do_build(defines=[define], coverage=False)
    buggy = R._run_one(rp["test"], rp["seed"], rp["n_txn"], rp["timeout"], waves=waves,
                       rundir=base / "run_buggy", plus=rp["plus"])
    # ---- control: same test and seed on the fixed design ----------------------------
    use_build("fixed")
    fixed = R._run_one(rp["test"], rp["seed"], rp["n_txn"], rp["timeout"], waves=False,
                       rundir=base / "run_fixed", plus=rp["plus"])

    text = Path(buggy["log"]).read_text(encoding="utf-8", errors="replace")
    fails = scan_failures(text)
    msgs = [f["text"] for f in fails]
    found = {rx: any(re.search(rx, m) for m in msgs) for rx in rp["expect"]}
    also = {rx: any(re.search(rx, m) for m in msgs) for rx in rp.get("also", [])}
    reproduced = all(found.values()) and not buggy["passed"] and fixed["passed"]

    first = min(fails, key=lambda f: (f["time_ns"] is None, f["time_ns"] or 0)) if fails else None
    # Where to centre the waveform: the first failure, unless the replay names the failure
    # that is the interesting one (A1: the payload-stability violation, not the arbiter
    # assertion that now fires a cycle or so before it).
    focus_f = first
    if rp.get("focus_match"):
        cand = [f for f in fails if f["time_ns"] is not None and re.search(rp["focus_match"], f["text"])]
        if cand:
            focus_f = min(cand, key=lambda f: f["time_ns"])
    res = dict(bug=bug, title=rp["title"], test=rp["test"], seed=rp["seed"],
               buggy=dict(passed=buggy["passed"], sva=buggy["sva"], uvm_error=buggy["uvm_error"],
                          scb=buggy["scb"]),
               fixed=dict(passed=fixed["passed"], sva=fixed["sva"], uvm_error=fixed["uvm_error"],
                          scb=fixed["scb"]),
               expect=found, also=also, reproduced=reproduced,
               first_failure=first, focus_failure=focus_f, n_failures=len(fails))

    print(f"    buggy : {'PASS' if buggy['passed'] else 'FAIL'}  SVA={buggy['sva']} UVM_ERROR={buggy['uvm_error']}"
          f"  {buggy['scb']}")
    print(f"    fixed : {'PASS' if fixed['passed'] else 'FAIL'}  SVA={fixed['sva']} UVM_ERROR={fixed['uvm_error']}"
          f"  {fixed['scb']}")
    for rx, ok in {**found, **also}.items():
        print(f"    {'caught by' if ok else 'NOT seen  '}: {rx}")
    if first:
        print(f"    first failure: t={first['time_ns']} ns  [{first['kind']}] {first['text'][:110]}")

    analysis = waveform_analysis(bug, focus_f, base) if waves else ""
    (base / "analysis.txt").write_text(analysis, encoding="utf-8")
    (base / "result.json").write_text(json.dumps(res, indent=2, default=str), encoding="utf-8")
    print(f"\n    => {'REPRODUCED' if reproduced else 'NOT REPRODUCED'}")
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("run"); p.add_argument("bug"); p.add_argument("--no-waves", action="store_true")
    p = sub.add_parser("all"); p.add_argument("--no-waves", action="store_true")
    p = sub.add_parser("analyze", help="redo only the waveform analysis from saved artifacts")
    p.add_argument("bug")
    a = ap.parse_args()

    if a.cmd == "list":
        for k, v in REPLAYS.items():
            print(f"{k}  {v['title']}\n      {v['test']} seed {v['seed']}   ({v['files']})")
        return 0
    if a.cmd == "analyze":
        base = OUT / a.bug
        res = json.loads((base / "result.json").read_text(encoding="utf-8"))
        text = waveform_analysis(a.bug, res.get("focus_failure") or res["first_failure"], base)
        (base / "analysis.txt").write_text(text, encoding="utf-8")
        return 0
    bugs = [a.bug] if a.cmd == "run" else list(REPLAYS)
    results = [run_replay(b, waves=not a.no_waves) for b in bugs]
    print("\nreplay summary:")
    for r in results:
        print(f"  {r['bug']}  {'REPRODUCED    ' if r['reproduced'] else 'NOT REPRODUCED'}  {r['title']}")
    return 0 if all(r["reproduced"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
