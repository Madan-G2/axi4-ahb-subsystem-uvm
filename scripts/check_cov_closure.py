#!/usr/bin/env python3
"""
Coverage closure gate.

Reads the output of `run.py cov-report` (sim/cov/<label>/), applies the waiver
file, and answers two questions:

  1. Is coverage closed?   -> exit status 0 only if every gated goal is met AFTER waivers.
  2. If not, what next?    -> a ranked list of the gaps, grouped so that one stimulus
                              idea closes as many as possible.

WHAT A WAIVER IS
    A waiver is a claim that a bin / statement / event cannot or should not be hit.
    "Cannot be hit" is easy to write down and easy to get wrong, so every waiver
    carries a PREMISE, and the premises that can be checked against data are checked:

      other-variant   the same source line is covered in another parameterisation of
                      the same module (XSim reports each parameterisation separately,
                      and e.g. `if (READ_ONLY)` can only take one side per instance).
                      Verified: some sibling variant does NOT have the same gap (same
                      line, same missing side) -- i.e. it takes the side this one misses.
      negative-tests  the line is reached only by illegal stimulus, which the negative
                      tests drive and the sign-off runs deliberately leave out.
                      Verified: the coverage of a negative-test-only run (--neg-cov)
                      has NO gap at that line.
      functional      the behaviour a code-coverage gap stands for is evidenced by
                      functional bins. Verified: those named bins are covered.
      asserted        reasoned, not checkable by this script (a defensive default arm,
                      an assertion's failure action, a rule of the testbench). Listed
                      separately so the unverified share of the ledger is visible.

    A waiver whose premise fails verification is NOT applied, and is reported.
    Beyond that:
      * a waiver with no reason is an error;
      * a waiver that matches nothing is reported as STALE;
      * RAW percentages (no waivers) are always printed next to the adjusted ones, so
        a closure figure cannot be quietly manufactured by waiving.

GOALS
    functional / statement / branch / events are gated. Condition and toggle coverage
    are REPORTED, not gated (goal null in the waiver file):
      * toggle: the report gives a per-module percentage only, so an individual
        untoggleable bit cannot be named and waived;
      * condition: XSim lists some decisions as never evaluated that are visibly
        exercised in the waveform (docs/coverage_plan.md, "what is not gated and why").
        A gate on a number the tool cannot be trusted on would be a gate on noise.

USAGE
    python check_cov_closure.py --cov sim/cov/<label> [--neg-cov sim/cov/<label>]
                                [--waivers scripts/cov_waivers.json] [--top 15] [--strict]
    (also reachable as:  python run.py cov-check --label <label>)
"""

import argparse
import csv
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WAIVERS = ROOT / "scripts" / "cov_waivers.json"
GATED = ("functional", "statement", "branch", "events")
KINDS = ("statement", "branch", "condition")


# ---------------------------------------------------------------------------
def _rx(pattern):
    return re.compile(pattern if pattern is not None else ".*", re.S)


def family(module_name):
    """'axi4_sram_ctrl(ID_W=6,...)' and 'axi4_sram_ctrl( .. axi4_sram_ctrl(...)' -> 'axi4_sram_ctrl'."""
    return module_name.split("(")[0].strip()


def load_waivers(path):
    if not Path(path).exists():
        return dict(goals={}, functional=[], code=[], events=[]), []
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    problems = []
    for kind in ("functional", "code", "events"):
        for i, w in enumerate(data.get(kind, [])):
            if not str(w.get("reason", "")).strip():
                problems.append(f"{kind} waiver #{i} ({w.get('id', w)}) has no reason")
            w.setdefault("premise", "asserted")
            w["_used"] = 0
            w["_rejected"] = 0
    data.setdefault("goals", {})
    for k in ("functional", "code", "events"):
        data.setdefault(k, [])
    return data, problems


def match_functional(w, g):
    return (_rx(w.get("group")).fullmatch(g["group"]) and
            _rx(w.get("point")).fullmatch(g["point"]) and
            _rx(w.get("bin")).fullmatch(g["bin"]))


def match_code(w, g):
    return (_rx(w.get("module")).search(g["module"]) is not None and
            (w.get("kind") in (None, g["kind"])) and
            _rx(w.get("text")).search(g["text"]) is not None and
            _rx(w.get("detail")).search(g["detail"]) is not None)


def pct(c, t):
    return round(100.0 * c / t, 2) if t else 100.0


# ---------------------------------------------------------------------------
class Evidence:
    """What the premises are checked against."""

    def __init__(self, cov, gaps_c, cov_dir, neg_dir):
        self.mods_by_family = defaultdict(list)
        for m in cov["code"]["modules"]:
            self.mods_by_family[family(m["module"])].append(m["module"])
        self.gap_keys = {(g["module"], g["line"], g["kind"], g["detail"]) for g in gaps_c}

        self.fbins = {}
        f = Path(cov_dir) / "functional_bins.csv"
        if f.exists():
            for r in csv.DictReader(open(f, encoding="utf-8")):
                self.fbins[(r["group"], r["point"], r["bin"])] = r["covered"] == "1"

        self.neg_gap_keys = None
        self.neg_mods = set()
        if neg_dir and (Path(neg_dir) / "coverage.json").exists():
            ncov = json.loads((Path(neg_dir) / "coverage.json").read_text(encoding="utf-8"))
            ngaps = json.loads((Path(neg_dir) / "gaps_code.json").read_text(encoding="utf-8"))
            self.neg_gap_keys = {(g["module"], g["line"], g["kind"], g["detail"]) for g in ngaps}
            self.neg_mods = {m["module"] for m in ncov["code"]["modules"]}

    def verify(self, w, g):
        """-> (ok, why_not)"""
        p = w["premise"]
        if p == "asserted":
            return True, ""
        if p == "other-variant":
            sibs = [m for m in self.mods_by_family.get(family(g["module"]), []) if m != g["module"]]
            if any((m, g["line"], g["kind"], g["detail"]) not in self.gap_keys for m in sibs):
                return True, ""
            return False, "no sibling parameterisation covers this line"
        if p == "negative-tests":
            if self.neg_gap_keys is None:
                return False, "no --neg-cov report given"
            if g["module"] not in self.neg_mods:
                return False, "module absent from the negative-test report"
            if (g["module"], g["line"], g["kind"], g["detail"]) in self.neg_gap_keys:
                return False, "the negative tests do not reach it either"
            return True, ""
        if p == "functional":
            bad = [b for b in w.get("evidence_bins", [])
                   if not self.fbins.get((b["group"], b["point"], b["bin"]), False)]
            if bad:
                return False, "evidence bin(s) not covered: " + ", ".join(b["bin"] for b in bad)
            return True, ""
        return False, f"unknown premise {p!r}"


def apply_waivers(items, waivers, matcher, evidence=None):
    """-> (open_items, [(item, waiver)]).  Items whose premise fails stay open."""
    kept, waived = [], []
    for it in items:
        hit, rejected = None, []
        for w in waivers:
            if matcher(w, it):
                if evidence is not None and w["premise"] != "asserted":
                    ok, why = evidence.verify(w, it)
                    if not ok:
                        rejected.append((w, why))
                        continue
                hit = w
                break
        if hit is None:
            kept.append(it)
            # Only an item that ends up UNWAIVED makes a failed premise a problem: a
            # broad waiver may be tried first on an item that a narrower one then covers.
            for w, why in rejected:
                w["_rejected"] += 1
                w.setdefault("_why", why)
        else:
            hit["_used"] += 1
            waived.append((it, hit))
    return kept, waived


# ---------------------------------------------------------------------------
def analyse(cov_dir, waiver_path, neg_dir=None):
    cov_dir = Path(cov_dir)
    cov = json.loads((cov_dir / "coverage.json").read_text(encoding="utf-8"))
    gaps_f = json.loads((cov_dir / "gaps_functional.json").read_text(encoding="utf-8"))
    gaps_c = json.loads((cov_dir / "gaps_code.json").read_text(encoding="utf-8"))
    wv, problems = load_waivers(waiver_path)
    ev = Evidence(cov, gaps_c, cov_dir, neg_dir)

    goals = dict(functional=100.0, statement=100.0, branch=100.0, condition=None, events=100.0)
    goals.update(wv.get("goals", {}))
    res = dict(label=cov["label"], goals=goals, problems=list(problems), metrics={}, notes=[])

    # ---- functional ------------------------------------------------------------
    f = cov["functional"]
    left, waived = apply_waivers(gaps_f, wv["functional"], match_functional)
    total, covered = f["bins_total"], f["bins_covered"]
    res["metrics"]["functional"] = dict(
        raw=pct(covered, total), covered=covered, total=total,
        waived=len(waived), open=len(left), adjusted=pct(covered, total - len(waived)))
    res["functional_open"], res["functional_waived"] = left, waived
    if f.get("parser_selfcheck_problems"):
        res["problems"] += [f"parser self-check: {p}" for p in f["parser_selfcheck_problems"]]

    # ---- code ------------------------------------------------------------------
    # XSim's own per-module totals are the authority for the NUMBERS. The parsed gap
    # lists are what a waiver is matched against, and for a few constructs the report
    # does not let them be reconstructed exactly (a ternary or `if` listed under two
    # rows, a statement inside a generate branch this parameterisation does not
    # elaborate, ...). So the waived count of a module is capped at what XSim says is
    # uncovered there: if the parser over-counts, the capped figure is still safe; if
    # it under-counts, the missing items simply cannot be waived.
    rtl = cov["code"]["rtl"]
    left_c, waived_c = apply_waivers(gaps_c, wv["code"], match_code, ev)
    mods = {m["module"]: m for m in cov["code"]["modules"]}
    approx = set()
    for kind in KINDS:
        t, c = rtl[kind]["total"], rtl[kind]["covered"]
        per_mod, parsed = defaultdict(int), defaultdict(int)
        for g in left_c:
            if g["kind"] == kind:
                parsed[g["module"]] += g.get("weight", 1)
        for g, _ in waived_c:
            if g["kind"] == kind:
                per_mod[g["module"]] += g.get("weight", 1)
                parsed[g["module"]] += g.get("weight", 1)
        w = sum(min(n, mods[name][kind]["uncovered"]) for name, n in per_mod.items() if name in mods)
        for name, m in mods.items():
            if parsed.get(name, 0) != m[kind]["uncovered"]:
                approx.add(name)
        res["metrics"][kind] = dict(raw=pct(c, t), covered=c, total=t, waived=w,
                                    open=(t - c) - w, adjusted=pct(c, t - w))
    if approx:
        res["notes"].append("gap lists are approximate (parsed != XSim's count) for: " +
                            "; ".join(sorted(n[:48] for n in approx)))
    res["metrics"]["toggle"] = dict(raw=rtl["toggle"]["percent"], gated=False)
    res["code_open"], res["code_waived"] = left_c, waived_c

    # ---- cover events -------------------------------------------------------------
    evn = cov["events"]
    zero = [dict(event=n) for n in evn["zero"]]
    left_e, waived_e = apply_waivers(zero, wv["events"],
                                     lambda w, e: _rx(w.get("event")).fullmatch(e["event"]))
    res["metrics"]["events"] = dict(raw=pct(evn["hit"], evn["total"]), covered=evn["hit"],
                                    total=evn["total"], waived=len(waived_e), open=len(left_e),
                                    adjusted=pct(evn["hit"], evn["total"] - len(waived_e)))
    res["events_open"], res["events_waived"] = left_e, waived_e

    # ---- waiver hygiene ----------------------------------------------------------
    res["stale"] = [(k, w) for k in ("functional", "code", "events")
                    for w in wv[k] if w["_used"] == 0 and w["_rejected"] == 0]
    res["rejected"] = [(k, w) for k in ("functional", "code", "events")
                       for w in wv[k] if w["_rejected"]]
    for k, w in res["rejected"]:
        res["problems"].append(f"waiver {w.get('id', '?')} REJECTED ({w['_rejected']} item(s)): "
                               f"premise '{w['premise']}' failed -- {w.get('_why', '')}")
    # ledger: how much of what was waived rests on a checked premise
    ledger = Counter()
    for lst in (res["functional_waived"], res["code_waived"], res["events_waived"]):
        for it, w in lst:
            ledger[w["premise"]] += it.get("weight", 1) if isinstance(it, dict) else 1
    res["ledger"] = dict(ledger)
    res["waivers"] = {k: wv[k] for k in ("functional", "code", "events")}
    res["closed"] = (all(res["metrics"][k]["adjusted"] >= goals[k] for k in GATED if goals.get(k) is not None)
                     and not res["problems"])
    return res


# ---------------------------------------------------------------------------
def rank_functional(open_items, top):
    by = Counter((g["group"], g["point"]) for g in open_items)
    lines = []
    for (grp, pt), n in by.most_common(top):
        ex = [g["bin"] for g in open_items if g["group"] == grp and g["point"] == pt][:4]
        lines.append(f"  {n:4d}  {grp}::{pt:24s}  e.g. {', '.join(ex)}")
    return lines


def rank_code(open_items, top):
    by = defaultdict(list)
    for g in open_items:
        by[(g["module"], g["kind"])].append(g)
    order = sorted(by.items(), key=lambda kv: -len(kv[1]))[:top]
    lines = []
    for (mod, kind), items in order:
        lines.append(f"  {len(items):4d}  {mod[:90]} [{kind}]")
        for g in sorted(items, key=lambda x: x["line"])[:3]:
            lines.append(f"          L{g['line']:<5d} {g['detail']:<18s} {g['text'][:70]}")
    return lines


def render(res, top):
    m, goals = res["metrics"], res["goals"]
    out = []
    p = out.append
    p(f"=== coverage closure check: {res['label']} ===")
    p(f"{'metric':12s} {'raw %':>8s} {'adjusted %':>11s} {'goal %':>8s}  {'open':>5s} {'waived':>7s}   status")
    for k in ("functional", "statement", "branch", "condition", "events"):
        x = m[k]
        g = goals.get(k)
        if g is None:
            st, gs = "info (not gated)", "-"
        else:
            st, gs = ("MET" if x["adjusted"] >= g else "OPEN"), f"{g:.1f}"
        p(f"{k:12s} {x['raw']:8.2f} {x['adjusted']:11.2f} {gs:>8s}  {x['open']:5d} {x['waived']:7d}   {st}")
    p(f"{'toggle':12s} {m['toggle']['raw']:8.2f} {'-':>11s} {'-':>8s}  (reported, not gated)")

    if res["problems"]:
        p("\nPROBLEMS (closure cannot be declared while these stand):")
        p("\n".join("  - " + x for x in res["problems"]))
    for n in res.get("notes", []):
        p("\nnote: " + n)
    if res["stale"]:
        p("\nSTALE WAIVERS (match nothing -- remove them or fix the pattern):")
        for kind, w in res["stale"]:
            p(f"  - [{kind}] {w.get('id', '?')}: {w.get('reason', '')[:80]}")

    if res["functional_open"]:
        p("\nOPEN functional gaps, most numerous first:")
        p("\n".join(rank_functional(res["functional_open"], top)))
    gated_open = [g for g in res["code_open"] if goals.get(g["kind"], 1) is not None]
    if gated_open:
        p("\nOPEN code gaps (statement / branch), most numerous first:")
        p("\n".join(rank_code(gated_open, top)))
    if res["events_open"]:
        p("\nOPEN cover events (never hit):")
        p("  " + ", ".join(e["event"] for e in res["events_open"]))

    lg = res["ledger"]
    nw = sum(lg.values())
    if nw:
        verified = sum(n for pr, n in lg.items() if pr != "asserted")
        p(f"\nWAIVER LEDGER: {nw} item(s) waived; {verified} rest on a premise this script checked "
          f"({', '.join(f'{pr}: {n}' for pr, n in sorted(lg.items()))})")
    p("\nRESULT: " + ("CLOSED" if res["closed"] else "NOT CLOSED"))
    return "\n".join(out)


def to_markdown(res):
    m, goals = res["metrics"], res["goals"]
    md = [f"# Closure check: {res['label']}", "",
          "| metric | raw % | adjusted % | goal % | open | waived |", "|---|---:|---:|---:|---:|---:|"]
    for k in ("functional", "statement", "branch", "condition", "events"):
        x = m[k]
        g = goals.get(k)
        md.append(f"| {k} | {x['raw']} | {x['adjusted']} | {g if g is not None else 'info'} | {x['open']} | {x['waived']} |")
    md.append(f"| toggle | {m['toggle']['raw']} | - | info | - | - |")
    md.append("")
    md.append("**" + ("CLOSED" if res["closed"] else "NOT CLOSED") + "**")
    if res["ledger"]:
        md.append("")
        md.append("Waiver ledger (items by premise): " + ", ".join(f"{k}: {v}" for k, v in sorted(res["ledger"].items())))
    return "\n".join(md)


def to_ledger_md(res):
    """The waivers, grouped by reason -- for docs/coverage_plan.md."""
    rows = []
    for kind in ("functional", "code", "events"):
        for w in res["waivers"][kind]:
            if w["_used"]:
                rows.append((kind, w))
    out = ["| id | kind | premise | items | reason |", "|---|---|---|---:|---|"]
    for kind, w in sorted(rows, key=lambda r: (r[1]["premise"], r[1].get("id", ""))):
        out.append(f"| {w.get('id', '')} | {kind} | {w['premise']} | {w['_used']} | {w['reason']} |")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cov", required=True, help="a sim/cov/<label> directory")
    ap.add_argument("--neg-cov", default="", help="a cov-report of the negative tests alone")
    ap.add_argument("--waivers", default=str(DEFAULT_WAIVERS))
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--strict", action="store_true", help="stale waivers also fail the run")
    a = ap.parse_args(argv)

    res = analyse(a.cov, a.waivers, a.neg_cov or None)
    text = render(res, a.top)
    print(text)
    out = Path(a.cov)
    (out / "closure.txt").write_text(text, encoding="utf-8")
    (out / "closure.md").write_text(to_markdown(res), encoding="utf-8")
    (out / "waiver_ledger.md").write_text(to_ledger_md(res), encoding="utf-8")
    ok = res["closed"] and not (a.strict and res["stale"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
