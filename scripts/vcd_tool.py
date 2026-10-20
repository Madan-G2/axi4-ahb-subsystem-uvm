#!/usr/bin/env python3
"""
Small VCD reader, for root-causing a failure from a waveform dump without a GUI.

WHAT IT DOES
    Streams a VCD, keeps only the signals asked for, and prints one row per rising
    edge of the clock showing the values those signals had just BEFORE the edge --
    which is what a synchronous design (and a concurrent assertion) sees at that
    edge. Rows can be limited to a window around a time of interest.

    It is deliberately dumb: no GUI, no derived signals. The point is that a
    failure found in a regression log can be walked back to its cause with a
    command line, and that the walk-through in docs/bug_replays.md is reproducible
    rather than a screenshot.

USAGE
    python vcd_tool.py waves.vcd --list [regex]                 # find signal names
    python vcd_tool.py waves.vcd --at 12345 --before 12 --after 3 \\
           -s awvalid=u_dut.s_awvalid\\[0\\] -s awready=u_dut.s_awready\\[0\\] ...
    Signal specs are  ALIAS=REGEX  matched with re.search against the full
    hierarchical name (scopes joined by '.'), and must match exactly one signal.
"""

import argparse
import re
import sys
from collections import namedtuple

Var = namedtuple("Var", "id name width")


def read_defs(f):
    """-> (vars_by_id, scopes). Consumes the header."""
    scope, vars_ = [], {}
    names = []                       # (fullname, id, width)
    timescale = "1ps"
    toks = []
    for line in f:
        line = line.strip()
        if not line:
            continue
        if line.startswith("$timescale"):
            body = line
            while "$end" not in body:
                body += " " + next(f).strip()
            timescale = body.replace("$timescale", "").replace("$end", "").strip()
        elif line.startswith("$scope"):
            parts = line.split()
            scope.append(parts[2])
        elif line.startswith("$upscope"):
            if scope:
                scope.pop()
        elif line.startswith("$var"):
            parts = line.split()
            width, vid, ref = int(parts[2]), parts[3], parts[4]
            # An optional bit-select ([7:0]) follows the reference name; keep it out
            # of the name so `sig` matches regardless of declared range.
            full = ".".join(scope + [ref])
            names.append((full, vid, width))
        elif line.startswith("$enddefinitions"):
            break
    return names, timescale


def unit_ps(ts):
    m = re.match(r"(\d+)\s*(fs|ps|ns|us|ms|s)", ts)
    mult = {"fs": 1e-3, "ps": 1, "ns": 1e3, "us": 1e6, "ms": 1e9, "s": 1e12}
    return int(m.group(1)) * mult[m.group(2)] if m else 1


class Wave:
    def __init__(self):
        self.names = []          # full names
        self.sig = {}            # alias -> id
        self.width = {}          # alias -> bits
        self.t_ps = 1
        self.rows = []           # (time_ps, {alias: value}) one per rising clock edge


def parse_spec(text):
    """ALIAS=REGEX[@LO:WIDTH]  ->  (alias, regex, lo, width).  The slice picks WIDTH
    bits starting at bit LO of a vector (VCD dumps a packed array as one vector)."""
    alias, _, rx = text.partition("=")
    lo, width = 0, None
    m = re.search(r"@(\d+):(\d+)$", rx)
    if m:
        lo, width = int(m.group(1)), int(m.group(2))
        rx = rx[:m.start()]
    return alias, rx, lo, width


def load(path, specs, clock="aclk"):
    """specs: list of (alias, regex[, lo, width]).  Returns Wave with one row per
    rising edge of the clock holding the values just before it."""
    specs = [tuple(sp) + (0, None) if len(sp) == 2 else tuple(sp) for sp in specs]
    w = Wave()
    with open(path, "r", errors="replace") as f:
        names, ts = read_defs(f)
        w.names = [n for n, _, _ in names]
        w.t_ps = unit_ps(ts)
        ids = {}
        slices = {}
        for alias, rx, lo, width in specs + [("__clk", rf"(^|\.){re.escape(clock)}$", 0, None)]:
            hits = [(n, i, wd) for n, i, wd in names if re.search(rx, n)]
            if alias == "__clk":
                hits = [h for h in hits if h[0].count(".") <= 1] or hits
            if len(hits) != 1:
                raise SystemExit(f"signal spec {alias}={rx!r} matches {len(hits)} signals"
                                 + ("" if not hits else ": " + ", ".join(h[0] for h in hits[:6])))
            ids[alias] = hits[0][1]
            total = hits[0][2]
            slices[alias] = (lo, width if width is not None else total, total)
            w.width[alias] = width if width is not None else total
        # Several aliases may share one VCD id (aliased nets); map id -> [aliases].
        by_id = {}
        for a, i in ids.items():
            by_id.setdefault(i, []).append(a)
        cur = {a: "x" for a in ids}
        t = 0
        prev_clk = "0"
        for line in f:
            line = line.strip()
            if not line:
                continue
            c = line[0]
            if c == "#":
                t = int(line[1:])
                continue
            if c in "01xzXZ" and len(line) > 1:
                val, vid = c.lower(), line[1:]
            elif c in "bB":
                val_s, _, vid = line[1:].partition(" ")
                val = val_s.lower()
            elif c in "rR":
                continue
            else:
                continue
            if vid not in by_id:
                continue
            for a in by_id[vid]:
                if a == "__clk":
                    if prev_clk != "1" and val == "1":
                        # rising edge: record the values held just before it
                        w.rows.append((t * w.t_ps, {k: cut(v, slices[k]) for k, v in cur.items() if k != "__clk"}))
                    prev_clk = val
                else:
                    cur[a] = val
    return w


def cut(raw, sl):
    """Bits [lo, lo+width) of a VCD value string (MSB first, leading zeros trimmed)."""
    lo, width, total = sl
    if len(raw) < total:                      # VCD drops leading zeros (x/z extend with themselves)
        raw = (raw[0] if raw and raw[0] in "xz" else "0") * (total - len(raw)) + raw
    bits = raw[::-1][lo:lo + width]
    return bits[::-1]


def fmt(v, width):
    """Hex, except that a nibble holding any x/z prints as 'x' -- so a half-defined
    bus reads 'fe7fxxxx' instead of collapsing to a bare 'x'."""
    if len(v) == 1:
        return v
    v = v.zfill(len(v) + (-len(v)) % 4) if not set(v) & set("xz") else \
        ("x" if v[0] == "x" else "0") * ((-len(v)) % 4) + v
    out = []
    for i in range(0, len(v), 4):
        nib = v[i:i + 4]
        out.append("x" if set(nib) & set("xz") else f"{int(nib, 2):x}")
    s = "".join(out).lstrip("0") or "0"
    return s


def table(w, aliases, t0_ps=None, t1_ps=None, mark_ps=None, keep=None, mark_label="failure"):
    cols = ["time(ns)"] + aliases
    lines = []
    for t, vals in w.rows:
        if t0_ps is not None and t < t0_ps:
            continue
        if t1_ps is not None and t > t1_ps:
            continue
        if keep is not None and not keep(vals) and not (mark_ps is not None and abs(t - mark_ps) < 5_000):
            continue
        row = [f"{t / 1000:.1f}"] + [fmt(vals[a], w.width[a]) for a in aliases]
        lines.append((t, row))
    width = [max(len(c), *(len(r[i]) for _, r in lines)) if lines else len(c) for i, c in enumerate(cols)]
    out = ["  ".join(c.rjust(width[i]) for i, c in enumerate(cols)), "  ".join("-" * x for x in width)]
    for t, r in lines:
        mark = f" <== {mark_label}" if (mark_ps is not None and abs(t - mark_ps) < 5_000) else ""
        out.append("  ".join(x.rjust(width[i]) for i, x in enumerate(r)) + mark)
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("--list", nargs="?", const=".", metavar="REGEX")
    ap.add_argument("-s", "--sig", action="append", default=[], help="ALIAS=REGEX")
    ap.add_argument("--at", type=float, help="time of interest, ns")
    ap.add_argument("--before", type=int, default=10, help="cycles before --at")
    ap.add_argument("--after", type=int, default=3, help="cycles after --at")
    ap.add_argument("--clock", default="aclk")
    a = ap.parse_args()

    if a.list is not None:
        with open(a.vcd, errors="replace") as f:
            names, _ = read_defs(f)
        rx = re.compile(a.list)
        for n, _, wd in names:
            if rx.search(n):
                print(f"{n}  [{wd}]")
        return
    specs = [parse_spec(x) for x in a.sig]
    w = load(a.vcd, specs, a.clock)
    aliases = [s[0] for s in specs]
    t0 = t1 = mark = None
    if a.at is not None:
        period = (w.rows[1][0] - w.rows[0][0]) if len(w.rows) > 1 else 10_000
        mark = a.at * 1000
        t0, t1 = mark - a.before * period, mark + a.after * period
    print(table(w, aliases, t0, t1, mark))


if __name__ == "__main__":
    sys.exit(main())
