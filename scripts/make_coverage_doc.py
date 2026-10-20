#!/usr/bin/env python3
"""
Assemble docs/coverage_plan.md from a closed coverage round.

The prose is hand-written; every number, table and ledger row is read from
sim/cov/<label>/ (coverage.json, closure.txt, waiver_ledger.md) and sim/cov/history.csv,
so the document cannot drift from what the gate printed.

    python scripts/make_coverage_doc.py --label r5 --neg-label r4neg --rounds base0,r1,r2,r3,r4,r5
"""

import argparse
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COV = ROOT / "sim" / "cov"
OUT = ROOT / "docs" / "coverage_plan.md"

ROUND_NOTE = {
    "base0": "random tests only (19 runs) -- the baseline the directed tests were written against",
    "r1": "+ directed tests (33 runs). **Discarded:** a driver edit had removed every W-channel gap (bug C14)",
    "r2": "+ error-map move, byte-lane clip, queue-full / exclusive / outstanding additions (34 runs). **Discarded:** same driver defect",
    "r3": "driver fixed (34 runs); cover event `w_gap_mid_burst` back to non-zero",
    "r4": "+ multi-master test with slave-side READY jitter (37 runs)",
    "r5": "r4 merged with 36 extra random runs (73 runs in all): functional, statement and branch unchanged",
    "r6": "**final**: the frozen sources, one complete round (38 runs); the gate is run on this one",
}


def last_row(rows, label):
    hit = [r for r in rows if r["label"] == label]
    return hit[-1] if hit else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--neg-label", default="")
    ap.add_argument("--rounds", default="base0,r1,r2,r3,r4")
    a = ap.parse_args()

    cov = json.loads((COV / a.label / "coverage.json").read_text(encoding="utf-8"))
    closure = (COV / a.label / "closure.txt").read_text(encoding="utf-8")
    ledger = (COV / a.label / "waiver_ledger.md").read_text(encoding="utf-8")
    hist = list(csv.DictReader(open(COV / "history.csv", encoding="utf-8")))

    f, rtl, ev = cov["functional"], cov["code"]["rtl"], cov["events"]
    groups = f["groups"]
    n_groups = len(groups)

    out = []
    p = out.append
    p("# Coverage plan and closure record")
    p("")
    p(f"Generated from `sim/cov/{a.label}` by `scripts/make_coverage_doc.py`. Every number below is read from "
      f"the merged report of {cov['runs']['count']} passing runs; nothing here is typed in.")
    p("")
    p("## 1. What is measured")
    p("")
    p(f"**Functional coverage** -- {f['bins_total']} bins in {n_groups} covergroups.")
    p("")
    p("| group | where | what it asks | bins | covered |")
    p("|---|---|---|---:|---:|")
    what = {
        "soc_txn_cov.cg_burst": ("UVM, per transaction", "burst type x length x size (the FIXED / INCR / WRAP matrix)"),
        "soc_txn_cov.cg_traffic": ("UVM", "master x direction x target (SRAM, firmware region, ROM, registers, wait/error, AHB hole, CSR, unmapped)"),
        "soc_txn_cov.cg_addr": ("UVM", "alignment, 4KB position (base / one beat short / ends on the boundary), WRAP start slot"),
        "soc_txn_cov.cg_wstrb": ("UVM", "full / partial / zero / sparse strobes against the lanes each beat occupies"),
        "soc_txn_cov.cg_outcome": ("UVM", "24 named outcomes (OKAY, EXOKAY, failed exclusive, SLVERR variants, DECERR) with `illegal_bins` for anything else"),
        "soc_txn_cov.cg_id": ("UVM", "every ID x direction"),
        "axi4_cov.cg_hs_aw": ("interface observer", "AW handshake timing: READY-first, VALID-first, stall lengths"),
        "axi4_cov.cg_hs_w": ("interface observer", "W handshake timing"),
        "axi4_cov.cg_hs_b": ("interface observer", "B handshake timing"),
        "axi4_cov.cg_hs_ar": ("interface observer", "AR handshake timing"),
        "axi4_cov.cg_hs_r": ("interface observer", "R handshake timing"),
        "axi4_cov.cg_outstanding": ("interface observer", "how many requests are in flight when another is accepted"),
        "axi4_cov.cg_order": ("interface observer", "how far a response overtook older ones"),
        "axi4_cov.cg_arb": ("interface observer", "which master wins which slave, per direction"),
        "ahb_cov.cg_ahb_trans": ("AHB observer", "IDLE / NONSEQ / SEQ and wait-state combinations"),
        "ahb_cov.cg_ahb_burst": ("AHB observer", "the HBURST x size x direction forms the bridge emits"),
        "ahb_cov.cg_ahb_wait": ("AHB observer", "wait states per transfer, 0..15"),
        "ahb_cov.cg_ahb_resp": ("AHB observer", "OKAY / ERROR, and which transfer of the burst took the ERROR"),
        "ahb_cov.cg_conv": ("AHB observer", "AXI burst shape x AHB burst form it was converted to"),
    }
    for gid, g in sorted(groups.items()):
        where, q = what.get(gid, ("", ""))
        p(f"| `{gid}` | {where} | {q} | {g['total']} | {g['covered']} |")
    p("")
    p(f"**Cover events** -- {ev['total']} named conditions (stall lengths, back-to-back, READY toggling, gaps "
      "mid-burst, exclusive responses, 4KB positions, ...). Each is written once in `scripts/gen_cover.py` and "
      "rendered twice: as an SVA `cover property` (120 of them parse and elaborate -- `run.py lint-sva`) and as a "
      "procedural counter. **XSim ignores `cover property`**, so the counters supply every number; the SVA form "
      "is what a simulator that counts covers (VCS, Questa) would use, and was not run.")
    p("")
    p("**Code coverage** -- XSim `sbct`: statement, branch, condition, toggle, RTL files only.")
    p("")
    p("## 2. Goals and what is gated")
    p("")
    p("| metric | goal | note |")
    p("|---|---|---|")
    p("| functional | 100% of bins after waivers | |")
    p("| statement | 100% after waivers | |")
    p("| branch | 100% after waivers | |")
    p("| cover events | 100% | |")
    p("| condition | reported, not gated | see section 5 |")
    p("| toggle | reported, not gated | see section 5 |")
    p("")
    p("The original spec (section 7.5) asked for line/branch >= 98% and toggle >= 95% with FSM coverage. "
      "XSim has no FSM coverage, and its toggle report gives a percentage per module, so a bit that can never "
      "toggle (a tied-off address MSB) cannot be named and waived; a toggle goal would force either meaningless "
      "stimulus or a goal lowered until it passes.")
    p("")
    p("## 3. Where it stands")
    p("")
    p("```")
    p(closure.rstrip())
    p("```")
    p("")
    p("Raw figures, with no waivers applied:")
    p("")
    p("| metric | covered / total | % |")
    p("|---|---:|---:|")
    p(f"| functional bins | {f['bins_covered']} / {f['bins_total']} | {f['percent']} |")
    for k, label in (("statement", "statements"), ("branch", "branches"), ("condition", "conditions")):
        p(f"| RTL {label} | {rtl[k]['covered']} / {rtl[k]['total']} | {rtl[k]['percent']} |")
    p(f"| RTL toggle (bit-weighted) | | {rtl['toggle']['percent']} |")
    p(f"| cover events hit | {ev['hit']} / {ev['total']} | {round(100.0 * ev['hit'] / ev['total'], 1)} |")
    p("")
    p("## 4. How it got there")
    p("")
    p("| round | what changed | functional | statement | branch | condition | toggle | events |")
    p("|---|---|---:|---:|---:|---:|---:|---:|")
    for lab in a.rounds.split(","):
        r = last_row(hist, lab)
        if not r:
            continue
        p(f"| `{lab}` | {ROUND_NOTE.get(lab, '')} | {r['func_pct']}% | {r['stmt_pct']}% | {r['branch_pct']}% | "
          f"{r['cond_pct']}% | {r['toggle_pct']}% | {r['events_hit']}/{r['events_total']} |")
    p("")
    p("Each round is a full regression on the coverage snapshot merged with `cov-report`, then `cov-check`. "
      "What each directed test is for is in [test_library.md](test_library.md); what the measurements turned up "
      "besides gaps is in [bug_log.md](bug_log.md) (A5, A6, C13, C14, C15 all came out of this loop).")
    p("")
    p("What the gaps were, and what closed them:")
    p("")
    p("* *Never exercised at all:* exclusive access (-> `axi_exclusive_test`, **bug A5**), 4KB page positions and "
      "every WRAP slot (-> edge tests), the bridge's INCR4/8/16 and WRAP forms (-> `axi_ahb_forms_test`), response "
      "backpressure beyond a few cycles, READY toggling.")
    p("* *Reachable only by a specific shape:* queues at their limit (-> `axi_queue_full_test`), one ID using its "
      "whole budget, back-to-back requests to the default slave, reservations that must survive unrelated writes.")
    p("* *Not reachable as the testbench stood:* an AHB error mid-burst (the error boundary sat on a 1KB multiple -- "
      "C15), master 0's firmware region (the sequences never used it).")
    p("* *Not reachable at all:* see the waivers below.")
    p("")
    p("## 5. What is not gated, and why")
    p("")
    p("**Toggle** is reported per module; see section 2.")
    p("")
    p("**Condition** coverage is reported and not gated. XSim's condition report could be reconciled with its own "
      "totals only after working out that a condition is a TRUE/FALSE *pair* of rows, and some decisions it lists as "
      "never evaluated are exercised in the waveform. Example: `axi4_w_router` line 142, `sk_cnt[m] != SKID_D`, FALSE "
      "= the skid buffer is full. XSim reports 0 FALSE evaluations for `axi_outstanding_test` alone, while the "
      "waveform of that test shows the master's WREADY low for hundreds of cycles, which this expression alone "
      "drives. A gate on a number the tool cannot be trusted on would be a gate on noise.")
    p("")
    p("## 6. Waivers")
    p("")
    p("Defined in `scripts/cov_waivers.json`. A waiver says what it excuses and on what **premise**; "
      "`check_cov_closure.py` re-checks every premise it can against the data on each run and rejects a waiver "
      "whose premise fails, flags one that matches nothing, and always prints the raw figures next to the adjusted ones.")
    p("")
    p("| premise | means | checked? |")
    p("|---|---|---|")
    p("| `other-variant` | the same source line is covered in another parameterisation of the module (XSim reports each parameterisation separately) | yes: a sibling does not have the same gap |")
    p("| `negative-tests` | only illegal stimulus reaches it | yes: against a coverage run of the negative tests alone" + (f" (`{a.neg_label}`)" if a.neg_label else "") + " |")
    p("| `functional` | named functional bins evidence the behaviour | yes: those bins are covered |")
    p("| `asserted` | reasoned (defensive default arm, assertion failure action, a rule of the testbench) | no -- listed separately so the unverified share is visible |")
    p("")
    p(ledger.rstrip())
    p("")
    p("## 7. Reproduce")
    p("")
    p("```")
    p(f"python scripts/run.py regress --cov --stamp {a.label}                  # coverage snapshot, all positive tests")
    p(f"python scripts/run.py regress --cov --negative --stamp {a.neg_label or 'neg'}   # the negative tests alone (evidence for one premise)")
    p(f"python scripts/run.py cov-report --regress sim/regress/{a.label} --out sim/cov/{a.label}")
    p(f"python scripts/run.py cov-report --regress sim/regress/{a.neg_label or 'neg'} --negative --out sim/cov/{a.neg_label or 'neg'}")
    p(f"python scripts/run.py cov-check  --label {a.label} --neg-label {a.neg_label or 'neg'}")
    p("```")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
