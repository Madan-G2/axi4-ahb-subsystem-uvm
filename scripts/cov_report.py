#!/usr/bin/env python3
"""
Merge the coverage databases of one or more regressions and turn XSim's HTML
reports into data a script can reason about.

WHAT IT PRODUCES  (sim/cov/<label>/)
    coverage.json        everything below, machine-readable
    functional_bins.csv  every functional-coverage bin with its hit count
    code_modules.csv     statement/branch/condition/toggle per RTL module
    code_gaps.csv        every uncovered statement, branch side and condition
    cover_events.csv     hit counts of the 120 cover events (per interface)
    report.html          one-page summary
and appends one row to sim/cov/history.csv so progress across rounds can be
plotted.

WHY IT PARSES HTML
    xcrg's text mode is not implemented for code coverage ("Text based reporting
    is not supported for Code Coverage yet") and for functional coverage it
    silently writes HTML as well. The HTML is regular, so it is read directly.

TWO THINGS ABOUT XSIM'S REPORTS THAT THIS HAS TO WORK AROUND
  * Covergroups declared in a MODULE are reported once per instance path
    (tb_top.g_chk[0].u_chk...::cg_hs_aw), whereas covergroups in a CLASS are
    merged by type. For closure the useful question is "did this ever happen on
    some interface", so bins are unioned across instances of the same group.
    Per-instance detail is kept in functional_bins.csv.
  * Uncovered CROSS bins are printed compressed, as tuples and wildcards
    ("(b2, b3, )", "*"). They are expanded here, and the expansion is checked
    against the totals XSim itself reports; a mismatch is flagged rather than
    trusted.
"""

import csv
import html
import itertools
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COV_DB = "tb_snap_cov"


# ---------------------------------------------------------------------------
# HTML -> rows
# ---------------------------------------------------------------------------
def _clean(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()


def _cell_text(cell):
    """Text of a table cell. Source code sits in <pre> and is NOT escaped in these
    reports, so a condition such as `(i < N)` contains a bare '<'; stripping 'tags'
    from it would swallow everything up to the next '>' and leave "(i"."""
    m = re.search(r"<pre[^>]*>(.*?)</pre>", cell, flags=re.S)
    if m:
        return re.sub(r"\s+", " ", html.unescape(m.group(1))).strip()
    return _clean(cell)


def tokens(path):
    """Document-order stream of ('h', text) captions and ('row', [cells])."""
    t = Path(path).read_text(encoding="utf-8", errors="replace")
    t = re.sub(r"<(script|style).*?</\1>", "", t, flags=re.S)
    out = []
    # Any text node counts as a caption. Restricting this to h*/div/span/... missed
    # the "Statement Coverage of Module" headings, which sit in other elements,
    # and the code-coverage parse silently returned nothing.
    pat = re.compile(r"<tr[^>]*>(.*?)</tr>|>([^<>]{3,200})<", flags=re.S)
    for m in pat.finditer(t):
        if m.group(1) is not None:
            cells = [_cell_text(c) for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", m.group(1), flags=re.S)]
            if any(cells):
                out.append(("row", cells))
        else:
            txt = _clean(m.group(2))
            if txt:
                out.append(("h", txt))
    return out


def num(x, default=0.0):
    try:
        return float(x)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Functional coverage
# ---------------------------------------------------------------------------
HDR_CELLS = {"Name", "Hit Count", "At least", "Name ⇅", "Hit Count ⇅"}


def _owner(scope_and_group):
    """Logical group id: '<owner>.<covergroup>' with the instance path removed."""
    scope, _, grp = scope_and_group.rpartition("::")
    if "soc_txn_cov" in scope:
        owner = "soc_txn_cov"
    elif scope.endswith("u_ahb_cov"):
        owner = "ahb_cov"
    elif scope.endswith("u_cov"):
        owner = "axi4_cov"
    else:
        owner = scope.split("::")[-1] or "top"
    return f"{owner}.{grp}", scope


def _expand(cell, universe):
    cell = cell.strip()
    if cell == "*":
        return sorted(universe)
    if cell.startswith("("):
        return [x.strip() for x in cell.strip("()").split(",") if x.strip()]
    return [cell]


def parse_functional(fdir):
    """-> (bins, selfcheck_problems, dashboard_score)

    bins: list of dict(group, scope, point, kind, bin, hits, status)"""
    fdir = Path(fdir)
    bins, problems = [], []

    dash = 0.0
    dtk = tokens(fdir / "dashboard.html")
    for k, v in dtk:
        if k == "row" and len(v) >= 2 and re.fullmatch(r"[\d.]+", v[0]) and re.fullmatch(r"[\d.]+", v[1]):
            dash = num(v[0])
            break

    for gp in sorted(fdir.glob("grp*.html"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0)):
        tk = tokens(gp)
        gname = None
        point = kind = section = None
        crosshdr = []
        universe = defaultdict(set)         # coverpoint -> all its bin names
        pending_cross = []                  # (point, rows, status) expanded after cp pass
        summaries = {}                      # point -> (expected, uncovered)
        want_summary = None

        for k, v in tk:
            if k == "h":
                m = re.match(r"Group - (.+)", v)
                if m:
                    gname = m.group(1).strip()
                    continue
                m = re.match(r"Summary of Cover Point - (\S+)", v)
                if m:
                    point, kind, section = m.group(1), "cp", None
                    want_summary = point
                    continue
                m = re.match(r"Summary of Cross Point - (\S+)", v)
                if m:
                    point, kind, section = m.group(1), "cross", None
                    want_summary = point
                    continue
                low = v.lower()
                if low in ("covered bins", "uncovered bins", "illegal bins"):
                    section = low.split()[0]
                    crosshdr = []
                continue

            # ---- rows -----------------------------------------------------
            if want_summary and v and v[0] in ("User Defined Bins", "Total") and len(v) >= 3:
                summaries[want_summary] = (int(num(v[1])), int(num(v[2])))
                want_summary = None
                continue
            if not (point and section and gname):
                continue

            if kind == "cp":
                if v[0] in HDR_CELLS or len(v) < 2:
                    continue
                name, hits = v[0], int(num(v[1]))
                universe[point].add(name)
                status = {"covered": "covered", "uncovered": "uncovered", "illegal": "illegal"}[section]
                bins.append(dict(gname=gname, point=point, kind="cp", bin=name, hits=hits,
                                 status=status))
            else:                                       # cross
                if "Hit Count" in v and not crosshdr:
                    crosshdr = v[:v.index("Hit Count")]
                    continue
                if not crosshdr or len(v) < len(crosshdr) + 1:
                    continue
                cells, hits = v[:len(crosshdr)], int(num(v[len(crosshdr)]))
                pending_cross.append((point, cells, hits, section, list(crosshdr)))

        # Expand compressed cross rows now that every coverpoint's bin list is known.
        counted = defaultdict(lambda: [0, 0])          # point -> [expected, uncovered]
        for point_x, cells, hits, section, hdr in pending_cross:
            lists = [_expand(c, universe[h]) for c, h in zip(cells, hdr)]
            for combo in itertools.product(*lists):
                status = "covered" if section == "covered" else ("illegal" if section == "illegal" else "uncovered")
                bins.append(dict(gname=gname, point=point_x, kind="cross", bin="|".join(combo),
                                 hits=hits if status != "uncovered" else 0, status=status))
                if status != "illegal":
                    counted[point_x][0] += 1
                    if status == "uncovered":
                        counted[point_x][1] += 1

        # Self-check the expansion against XSim's own totals.
        for point_x, (exp_n, unc_n) in counted.items():
            if point_x in summaries and summaries[point_x] != (exp_n, unc_n):
                problems.append(f"{gname}::{point_x}: parsed expected/uncovered {exp_n}/{unc_n}"
                                f" but XSim reports {summaries[point_x][0]}/{summaries[point_x][1]}")
    return bins, problems, dash


def aggregate_functional(bins):
    """Union bins across instances of the same logical group."""
    merged = {}
    for b in bins:
        gid, scope = _owner(b["gname"])
        key = (gid, b["point"], b["bin"])
        e = merged.setdefault(key, dict(group=gid, point=b["point"], kind=b["kind"],
                                        bin=b["bin"], hits=0, illegal=False, instances=0))
        e["hits"] += b["hits"]
        e["instances"] += 1
        if b["status"] == "illegal":
            e["illegal"] = True
    out = list(merged.values())
    for e in out:
        e["covered"] = (e["hits"] >= 1) and not e["illegal"]
    return out


# ---------------------------------------------------------------------------
# Code coverage
# ---------------------------------------------------------------------------
def _module_section(tk, title):
    """Tokens of the MODULE-level section `title`, stopping before instance copies."""
    start = next((i for i, (k, v) in enumerate(tk)
                  if k == "h" and v.startswith(f"{title} Coverage of Module")), None)
    if start is None:
        return []
    end = next((i for i in range(start + 1, len(tk))
                if tk[i][0] == "h" and re.match(r"(Statement|Branch|Condition|Toggle) Coverage of", tk[i][1])),
               len(tk))
    return tk[start:end]


def _summary_row(sec, first_hdr):
    for i, (k, v) in enumerate(sec):
        if k == "row" and v and v[0] == first_hdr and i + 1 < len(sec) and sec[i + 1][0] == "row":
            return v, sec[i + 1][1]
    return None, None


def parse_code(cdir, rtl_only=True):
    cdir = Path(cdir)
    mods = []
    for k, v in tokens(cdir / "modules.html"):
        if k == "row" and len(v) >= 9 and v[0].isdigit():
            mods.append(dict(id=int(v[0]), name=v[1], instances=int(num(v[2])),
                             stmt=num(v[4]), branch=num(v[5]), cond=num(v[6]),
                             toggle=num(v[7]), file=v[8].replace("\\", "/")))
    out, gaps = [], []
    for m in mods:
        if rtl_only and "/rtl/" not in m["file"]:
            continue
        # A module with many instances is split across mod<ID>_1.html, _2, ... and
        # has no mod<ID>.html at all; concatenate whatever parts exist.
        parts = sorted(cdir.glob(f"mod{m['id']}.html")) +                 sorted(cdir.glob(f"mod{m['id']}_*.html"),
                       key=lambda q: int(re.search(r"_(\d+)\.html$", q.name).group(1)))
        page = parts[0] if parts else cdir / f"mod{m['id']}.html"
        tk = []
        for part in parts:
            tk += tokens(part)

        # statements
        sec = _module_section(tk, "Statement")
        h, r = _summary_row(sec, "Total Lines")
        st = dict(total=int(num(r[1])), covered=int(num(r[2])), uncovered=int(num(r[3]))) if r else dict(total=0, covered=0, uncovered=0)
        for k, v in sec:
            if k == "row" and len(v) >= 4 and v[0].isdigit() and v[3].isdigit() and int(v[3]) > 0:
                if v[2] in ("", "0"):
                    # XSim counts STATEMENTS, and one line can hold several (an `else
                    # $error(...)` is three), so a gap carries its statement count.
                    gaps.append(dict(module=m["name"], file=m["file"], kind="statement",
                                     line=int(v[0]), text=v[1][:120], detail="never executed",
                                     weight=int(v[3])))

        # branches
        sec = _module_section(tk, "Branch")
        h, r = _summary_row(sec, "Total Branches")
        br = dict(total=int(num(r[0])), covered=int(num(r[1])), uncovered=int(num(r[2]))) if r else dict(total=0, covered=0, uncovered=0)
        last_line = None
        prev_false_zero = False
        for k, v in sec:
            if k != "row" or len(v) < 4 or v[0] in ("LineNumber",):
                continue
            if v[0].isdigit():
                last_line = int(v[0])
            tf = v[3]
            sides = re.findall(r"(\d+)([TF])", tf)
            this_false_zero = False
            if sides and any(int(c) == 0 for c, _ in sides) and v[1].strip():
                zero_sides = ["TRUE" if s_ == "T" else "FALSE" for c, s_ in sides if int(c) == 0]
                this_false_zero = "FALSE" in zero_sides
                # A decision with BOTH sides at zero is two uncovered branches to XSim
                # (checked against its per-module totals: ahb_slave_mem's three
                # parameterisations reconcile exactly only on this reading), so it is two
                # gap items, one per side.
                for side in zero_sides:
                    gaps.append(dict(module=m["name"], file=m["file"], kind="branch",
                                     line=last_line or 0, text=v[1][:120], detail=f"never {side}"))
            elif v[1].startswith("MISSING ELSE") and v[3] == "0" and not prev_false_zero:
                # An `if` row ending "0F" and the MISSING ELSE row under it are the SAME
                # branch seen twice (the F side IS the implicit else); XSim counts it once.
                gaps.append(dict(module=m["name"], file=m["file"], kind="branch",
                                 line=last_line or 0, text=v[1][:120], detail="implicit else never taken"))
            prev_false_zero = this_false_zero

        # conditions
        sec = _module_section(tk, "Condition")
        h, r = _summary_row(sec, "Total Conditions")
        cd = dict(total=int(num(r[0])), covered=int(num(r[1])), uncovered=int(num(r[2]))) if r else dict(total=0, covered=0, uncovered=0)
        # A condition is a PAIR of rows, result TRUE and result FALSE; it is covered only
        # if both were seen. Counting zero ROWS would count a never-evaluated condition
        # twice (and disagree with the total XSim prints).
        pair = None

        def flush(pr):
            if pr is None:
                return
            cnt = pr["counts"]
            if all(c == 0 for c in cnt):
                detail = "never evaluated"
            elif len(cnt) > 1 and cnt[0] == 0:
                detail = "never TRUE"
            elif any(c == 0 for c in cnt):
                detail = "never FALSE"
            else:
                return
            gaps.append(dict(module=m["name"], file=m["file"], kind="condition",
                             line=pr["line"], text=re.sub(r"__(TRUE|FALSE)$", "", pr["text"])[:120],
                             detail=detail))

        for k, v in sec:
            if k == "row" and len(v) == 3 and v[0] != "LineNumber" and v[2].isdigit():
                if v[0].isdigit():                      # first row of a pair carries the line number
                    flush(pair)
                    pair = dict(line=int(v[0]), text=v[1], counts=[int(v[2])])
                elif pair is not None:
                    pair["counts"].append(int(v[2]))
        flush(pair)

        # toggle
        sec = _module_section(tk, "Toggle")
        tg = dict(bits=0, covered_bits=0, score=m["toggle"])
        for i, (k, v) in enumerate(sec):
            if k == "row" and v and v[0] == "Total Bits" and len(v) >= 3:
                tg["bits"] = int(num(v[1])); tg["covered_bits"] = int(num(v[2]))
                break

        out.append(dict(module=m["name"], file=m["file"], page=page.name, statement=st, branch=br,
                        condition=cd, toggle=tg, scores=dict(statement=m["stmt"], branch=m["branch"],
                                                              condition=m["cond"], toggle=m["toggle"])))
    return out, gaps


def rtl_summary(mods):
    tot = {}
    for key in ("statement", "branch", "condition"):
        t = sum(m[key]["total"] for m in mods)
        c = sum(m[key]["covered"] for m in mods)
        tot[key] = dict(total=t, covered=c, percent=round(100.0 * c / t, 2) if t else 0.0)
    # Toggle: XSim reports a per-module score; weight it by the module's bit count.
    bits = sum(m["toggle"]["bits"] for m in mods)
    wsum = sum(m["toggle"]["bits"] * m["scores"]["toggle"] for m in mods)
    if bits:
        tot["toggle"] = dict(bits=bits, percent=round(wsum / bits, 2), basis="bit-weighted")
    else:
        # No bit counts available: fall back to a plain mean and say so.
        sc = [m["scores"]["toggle"] for m in mods]
        tot["toggle"] = dict(bits=0, percent=round(sum(sc) / len(sc), 2) if sc else 0.0,
                             basis="unweighted mean of module scores")
    return tot


# ---------------------------------------------------------------------------
# Cover events (from the run logs)
# ---------------------------------------------------------------------------
def parse_events(log_paths):
    ev = defaultdict(lambda: defaultdict(int))        # event -> interface -> count
    for lp in log_paths:
        try:
            for line in Path(lp).read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("COVEVT "):
                    _, ifn, name, cnt = line.split()[:4]
                    ev[name][ifn] += int(cnt)
        except OSError:
            pass
    return ev


# ---------------------------------------------------------------------------
def run(regress_dirs, out_dir, env, work, include_negative=False):
    jobs, excluded = [], []
    for rd in regress_dirs:
        for r in json.loads((Path(rd) / "results.json").read_text(encoding="utf-8")):
            # Negative tests drive illegal stimulus; their coverage is only wanted when
            # asked for (it is the evidence for 'only illegal stimulus reaches this').
            if not r.get("cov") or (r.get("negative") is not None) != include_negative:
                continue
            # Coverage from a run that FAILED is not trusted: a test that broke
            # partway has exercised something it did not finish checking.
            (jobs if r["passed"] else excluded).append(r)
    if not jobs:
        raise SystemExit("no passing coverage runs found (did you run `regress --cov`?)")

    label = Path(out_dir).name if out_dir else "+".join(Path(d).name for d in regress_dirs)
    # Absolute, always: xcrg is run from inside `out`, so a relative merge/report
    # path would be resolved against the wrong directory.
    out = (Path(out_dir) if out_dir else ROOT / "sim" / "cov" / label).resolve()
    out.mkdir(parents=True, exist_ok=True)

    # ---- merge + report with xcrg ---------------------------------------------
    cmd = ["xcrg"]
    for j in jobs:
        cmd += ["-cov_db_dir", str(Path(j["rundir"]) / "cov"), "-cov_db_name", COV_DB]
    # -cc_instancescount 1: only module-level summaries are used, so there is no
    # need for the per-instance sections of every one of the N merged copies.
    # Beyond saving time, it matters for correctness: with the default (100) a
    # big merge makes XSim split each module across part-files, and the split
    # parts omit the toggle section altogether -- toggle coverage then read 0.0%.
    cmd += ["-merge_dir", str(out / "merged"), "-merge_db_name", "merged",
            "-report_dir", str(out / "report"), "-report_format", "html",
            "-cc_instancescount", "1"]
    import shutil
    exe = shutil.which("xcrg", path=env["PATH"])
    print(f"merging {len(jobs)} coverage databases with xcrg ...")
    r = subprocess.run([exe] + cmd[1:], cwd=str(out), env=env, capture_output=True, text=True)
    (out / "xcrg.out").write_text((r.stdout or "") + (r.stderr or ""), encoding="utf-8", errors="replace")
    if r.returncode != 0 or not (out / "report" / "functionalCoverageReport").exists():
        raise SystemExit(f"xcrg failed; see {out / 'xcrg.out'}")

    # ---- parse -------------------------------------------------------------------
    raw_bins, problems, dash = parse_functional(out / "report" / "functionalCoverageReport")
    fbins = aggregate_functional(raw_bins)
    mods, gaps = parse_code(out / "report" / "codeCoverageReport")

    # XSim splits a big merged report across part-files, and the split parts leave
    # the toggle section out entirely, so the merged report cannot say how many
    # toggle bits each module has. That count is a property of the design, not of
    # the run, so take it from a report of ONE run (which is not split) and weight
    # the merged toggle scores by it.
    ref = out / "ref"
    rr = subprocess.run([exe, "-cov_db_dir", str(Path(jobs[0]["rundir"]) / "cov"),
                         "-cov_db_name", COV_DB, "-report_dir", str(ref),
                         "-report_format", "html"],
                        cwd=str(out), env=env, capture_output=True, text=True)
    bits_ref = {}
    if (ref / "codeCoverageReport").exists():
        ref_mods, _ = parse_code(ref / "codeCoverageReport")
        bits_ref = {m["module"]: m["toggle"]["bits"] for m in ref_mods}
    for m in mods:
        m["toggle"]["bits"] = bits_ref.get(m["module"], 0)
    rtl = rtl_summary(mods)
    events = parse_events([j["log"] for j in jobs])

    legal = [b for b in fbins if not b["illegal"]]
    groups = defaultdict(lambda: dict(total=0, covered=0, points=defaultdict(lambda: dict(total=0, covered=0, kind=""))))
    for b in legal:
        g = groups[b["group"]]
        g["total"] += 1; g["covered"] += b["covered"]
        p = g["points"][b["point"]]
        p["total"] += 1; p["covered"] += b["covered"]; p["kind"] = b["kind"]
    for g in groups.values():
        g["percent"] = round(100.0 * g["covered"] / g["total"], 2) if g["total"] else 0.0
        g["points"] = {k: dict(v) for k, v in g["points"].items()}
    ftot = sum(g["total"] for g in groups.values())
    fcov = sum(g["covered"] for g in groups.values())

    ev_names = sorted(events)
    ev_zero = [n for n in ev_names if sum(events[n].values()) == 0]

    result = dict(
        label=label, created=time.strftime("%Y-%m-%d %H:%M:%S"),
        runs=dict(count=len(jobs), excluded_failed=len(excluded),
                  tests=sorted({j["test"] for j in jobs})),
        functional=dict(bins_total=ftot, bins_covered=fcov,
                        percent=round(100.0 * fcov / ftot, 2) if ftot else 0.0,
                        xsim_dashboard_score=dash, groups=dict(groups),
                        parser_selfcheck_problems=problems),
        code=dict(rtl=rtl, modules=mods),
        events=dict(total=len(ev_names), hit=len(ev_names) - len(ev_zero), zero=ev_zero,
                    by_event={n: dict(events[n]) for n in ev_names}),
    )
    (out / "coverage.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    (out / "gaps_functional.json").write_text(
        json.dumps([b for b in legal if not b["covered"]], indent=1), encoding="utf-8")
    (out / "gaps_code.json").write_text(json.dumps(gaps, indent=1), encoding="utf-8")

    with open(out / "functional_bins.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["group", "point", "kind", "bin", "hits", "covered"])
        for b in sorted(legal, key=lambda x: (x["group"], x["point"], x["bin"])):
            w.writerow([b["group"], b["point"], b["kind"], b["bin"], b["hits"], int(b["covered"])])
    with open(out / "code_modules.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["module", "stmt_total", "stmt_cov", "stmt_pct", "branch_total", "branch_cov",
                    "branch_pct", "cond_total", "cond_cov", "cond_pct", "toggle_pct"])
        for m in mods:
            w.writerow([m["module"], m["statement"]["total"], m["statement"]["covered"], m["scores"]["statement"],
                        m["branch"]["total"], m["branch"]["covered"], m["scores"]["branch"],
                        m["condition"]["total"], m["condition"]["covered"], m["scores"]["condition"],
                        m["scores"]["toggle"]])
    with open(out / "code_gaps.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["module", "kind", "line", "detail", "text"])
        for g in gaps:
            w.writerow([g["module"], g["kind"], g["line"], g["detail"], g["text"]])
    with open(out / "cover_events.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["event", "total_hits", "interfaces_hit"])
        for n in ev_names:
            hit_if = sorted(k for k, v in events[n].items() if v > 0)
            w.writerow([n, sum(events[n].values()), " ".join(hit_if)])

    write_html(out, result, gaps, legal)

    hist = ROOT / "sim" / "cov" / "history.csv"
    new = not hist.exists()
    with open(hist, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["label", "time", "runs", "func_bins", "func_covered", "func_pct",
                        "stmt_pct", "branch_pct", "cond_pct", "toggle_pct",
                        "events_hit", "events_total"])
        w.writerow([label, result["created"], len(jobs), ftot, fcov, result["functional"]["percent"],
                    rtl["statement"]["percent"], rtl["branch"]["percent"], rtl["condition"]["percent"],
                    rtl["toggle"]["percent"], result["events"]["hit"], result["events"]["total"]])

    print_summary(result, problems)
    return result


def print_summary(r, problems):
    f, c, e = r["functional"], r["code"]["rtl"], r["events"]
    print(f"\n=== coverage: {r['label']}  ({r['runs']['count']} passing runs"
          f"{', ' + str(r['runs']['excluded_failed']) + ' failed runs excluded' if r['runs']['excluded_failed'] else ''}) ===")
    print(f"functional bins : {f['bins_covered']}/{f['bins_total']}  = {f['percent']}%")
    for gid, g in sorted(f["groups"].items()):
        print(f"    {gid:34s} {g['covered']:4d}/{g['total']:<4d} {g['percent']:6.1f}%")
    print(f"code (RTL only) : statement {c['statement']['percent']}%  ({c['statement']['covered']}/{c['statement']['total']})"
          f"   branch {c['branch']['percent']}%  ({c['branch']['covered']}/{c['branch']['total']})"
          f"   condition {c['condition']['percent']}%  ({c['condition']['covered']}/{c['condition']['total']})"
          f"   toggle {c['toggle']['percent']}%")
    print(f"cover events    : {e['hit']}/{e['total']} hit at least once")
    if problems:
        print("\nPARSER SELF-CHECK PROBLEMS (do not trust the affected groups):")
        for p in problems:
            print("   ", p)
    print(f"\nreports -> {ROOT / 'sim' / 'cov' / r['label']}")


def write_html(out, r, gaps, legal):
    f, c, e = r["functional"], r["code"]["rtl"], r["events"]
    def row(cells, head=False):
        tag = "th" if head else "td"
        return "<tr>" + "".join(f"<{tag}>{html.escape(str(x))}</{tag}>" for x in cells) + "</tr>"
    parts = [f"<html><head><meta charset='utf-8'><title>coverage {html.escape(r['label'])}</title>"
             "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}"
             "table{border-collapse:collapse;margin:8px 0 22px}td,th{border:1px solid #ccc;padding:3px 9px;font-size:13px}"
             "th{background:#f0f0f0}.bad{background:#fde8e8}.ok{background:#e6f5e6}h2{margin-top:26px}</style></head><body>",
             f"<h1>Coverage report: {html.escape(r['label'])}</h1>",
             f"<p>{r['runs']['count']} passing coverage runs, generated {r['created']}.</p>",
             "<h2>Summary</h2><table>", row(["metric", "covered", "total", "percent"], True),
             row(["functional bins", f["bins_covered"], f["bins_total"], f["percent"]]),
             row(["RTL statements", c["statement"]["covered"], c["statement"]["total"], c["statement"]["percent"]]),
             row(["RTL branches", c["branch"]["covered"], c["branch"]["total"], c["branch"]["percent"]]),
             row(["RTL conditions", c["condition"]["covered"], c["condition"]["total"], c["condition"]["percent"]]),
             row(["RTL toggle (bit-weighted)", "", "", c["toggle"]["percent"]]),
             row(["cover events hit", e["hit"], e["total"], round(100.0 * e["hit"] / e["total"], 1) if e["total"] else 0]),
             "</table>", "<h2>Functional groups</h2><table>", row(["group", "covered", "total", "%"], True)]
    for gid, g in sorted(f["groups"].items()):
        parts.append(f"<tr class='{'ok' if g['percent'] >= 100 else 'bad'}'>" +
                     "".join(f"<td>{html.escape(str(x))}</td>" for x in (gid, g["covered"], g["total"], g["percent"])) + "</tr>")
    parts += ["</table>", "<h2>RTL modules (code coverage)</h2><table>",
              row(["module", "stmt %", "branch %", "cond %", "toggle %"], True)]
    for m in r["code"]["modules"]:
        s = m["scores"]
        parts.append(row([m["module"], s["statement"], s["branch"], s["condition"], s["toggle"]]))
    parts += ["</table>", "<h2>Uncovered functional bins</h2><table>", row(["group", "point", "bin"], True)]
    for b in sorted((b for b in legal if not b["covered"]), key=lambda x: (x["group"], x["point"], x["bin"])):
        parts.append(row([b["group"], b["point"], b["bin"]]))
    parts += ["</table>", "<h2>Cover events never hit</h2><ul>"]
    parts += [f"<li>{html.escape(n)}</li>" for n in e["zero"]] + ["</ul></body></html>"]
    (out / "report.html").write_text("\n".join(parts), encoding="utf-8")


if __name__ == "__main__":
    sys.exit("run via:  python run.py cov-report --regress <dir>")
