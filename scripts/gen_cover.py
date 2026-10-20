#!/usr/bin/env python3
"""
Generate the AXI4 cover-event code from ONE table of events.

WHY THIS EXISTS
---------------
Vivado XSim 2024.1 does not simulate `cover property`. It compiles the statement,
prints

    WARNING: [XSIM 43-4127] The "System Verilog Cover" is not supported yet for
    simulation. The statement will be ignored.

and never counts a hit. So SVA cover properties written for this project cannot
be measured on the simulator it runs on.

Rather than write them blind, every event is defined once, here, as a chain of
single-cycle terms joined by ##1 (with optional [*n] repetition). The generator
emits two renderings of that same definition:

  * `cover property (...)`        under  +define+AXI_COVER_SVA
                                   -- for VCS / Questa / Xcelium / VC Formal.
  * a procedural matcher + counter otherwise (the XSim default)
                                   -- an exact shift-register implementation of
                                   the same ##1 chain, so XSim measures the
                                   same events the SVA describes.

Because both come from one source they cannot drift apart. What this does NOT
give you is proof that the SVA rendering is semantically right when a real
SVA-capable simulator runs it -- XSim only parse-checks it (`run.py lint-sva`).
That gap is stated in docs/coverage_plan.md rather than hidden.

OUTPUTS
-------
    verif/sva/axi4_cov_terms.svh    per-channel term wires + handshake covergroups
    verif/sva/axi4_cov_req.svh      request-shape terms for the address channels
    verif/sva/axi4_cov_events.svh   the cover events + the end-of-sim report
    docs/cover_events.md            human-readable catalogue of every event

Re-run after editing this file:  python scripts/gen_cover.py
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (valid, ready) signal names per AXI channel, as seen on the module ports.
CHANNELS = {
    "aw": ("awvalid", "awready"),
    "w":  ("wvalid",  "wready"),
    "b":  ("bvalid",  "bready"),
    "ar": ("arvalid", "arready"),
    "r":  ("rvalid",  "rready"),
}

CH_LONG = {"aw": "write address", "w": "write data", "b": "write response",
           "ar": "read address", "r": "read data"}


# ---------------------------------------------------------------------------
# Event model: a name, a one-line meaning, and a list of (term, repeat) pairs.
# ---------------------------------------------------------------------------
class Event:
    def __init__(self, name, doc, seq, group):
        self.name, self.doc, self.group = name, doc, group
        # seq: list of (term, reps)
        self.seq = [(t, 1) if isinstance(t, str) else t for t in seq]

    def flat(self):
        out = []
        for term, n in self.seq:
            out += [term] * n
        return out

    def sva_text(self):
        parts = []
        for term, n in self.seq:
            parts.append(term if n == 1 else f"{term}[*{n}]")
        return " ##1 ".join(parts)


EVENTS = []


def ev(name, doc, *seq, group="misc"):
    EVENTS.append(Event(name, doc, seq, group))


# ---- per-channel handshake and timing events -------------------------------
for ch in CHANNELS:
    g = f"handshake.{ch}"
    L = CH_LONG[ch]
    ev(f"{ch}_ready_first",
       f"{L}: READY was already high when VALID rose (READY-before-VALID)",
       f"{ch}_hs_ready_first", group=g)
    ev(f"{ch}_same_cycle",
       f"{L}: VALID and READY rose in the same cycle",
       f"{ch}_hs_same_cycle", group=g)
    ev(f"{ch}_valid_first",
       f"{L}: VALID waited for READY (VALID-before-READY)",
       f"{ch}_hs_after_stall", group=g)
    ev(f"{ch}_back_to_back",
       f"{L}: two handshakes in consecutive cycles (zero-gap)",
       f"{ch}_hs", f"{ch}_hs", group=g)
    ev(f"{ch}_stall_1",
       f"{L}: stalled exactly 1 cycle, then accepted",
       f"{ch}_stall0", f"{ch}_hs_after_stall", group=g)
    ev(f"{ch}_stall_2",
       f"{L}: stalled exactly 2 cycles, then accepted",
       f"{ch}_stall0", f"{ch}_hold", f"{ch}_hs_after_stall", group=g)
    ev(f"{ch}_stall_3",
       f"{L}: stalled exactly 3 cycles, then accepted",
       f"{ch}_stall0", (f"{ch}_hold", 2), f"{ch}_hs_after_stall", group=g)
    ev(f"{ch}_stall_ge4",
       f"{L}: stalled for at least 4 cycles",
       f"{ch}_stall0", (f"{ch}_hold", 3), group=g)
    ev(f"{ch}_stall_ge8",
       f"{L}: stalled for at least 8 cycles",
       f"{ch}_stall0", (f"{ch}_hold", 7), group=g)
    ev(f"{ch}_stall_ge16",
       f"{L}: stalled for at least 16 cycles",
       f"{ch}_stall0", (f"{ch}_hold", 15), group=g)
    ev(f"{ch}_ready_toggle",
       f"{L}: READY withdrawn while idle (legal; VALID is not yet asserted)",
       f"{ch}_idle_rdy", f"{ch}_idle_nrdy", group=g)

# ---- burst-internal gaps ---------------------------------------------------
ev("w_gap_mid_burst", "write data: WVALID dropped between beats of a burst (legal gap)",
   "w_hs_notlast", "w_idle", group="burst")
ev("r_gap_mid_burst", "read data: RVALID dropped between beats of a burst (legal gap)",
   "r_hs_notlast", "r_idle", group="burst")
ev("w_single_beat", "write data: a one-beat burst (first beat is WLAST)",
   "w_single_ev", group="burst")

# ---- response timing -------------------------------------------------------
ev("wlast_bvalid_1", "BVALID visible the cycle right after the last write beat",
   "w_last_hs", "bvalid_s", group="timing")
ev("wlast_bvalid_2", "BVALID first visible 2 cycles after the last write beat",
   "w_last_hs", "bvalid_n", "bvalid_s", group="timing")
ev("wlast_bvalid_3", "BVALID first visible 3 cycles after the last write beat",
   "w_last_hs", ("bvalid_n", 2), "bvalid_s", group="timing")
ev("ar_rvalid_1", "RVALID visible the cycle right after the read address",
   "ar_hs", "rvalid_s", group="timing")
ev("ar_rvalid_2", "RVALID first visible 2 cycles after the read address",
   "ar_hs", "rvalid_n", "rvalid_s", group="timing")
ev("ar_rvalid_3", "RVALID first visible 3 cycles after the read address",
   "ar_hs", ("rvalid_n", 2), "rvalid_s", group="timing")

# ---- outstanding depth and ordering ---------------------------------------
for k, nm in ((2, "ge2"), (4, "ge4")):
    ev(f"aw_out_{nm}", f"at least {k} write transactions outstanding", f"aw_out_{nm}_s",
       group="outstanding")
    ev(f"ar_out_{nm}", f"at least {k} read transactions outstanding", f"ar_out_{nm}_s",
       group="outstanding")
ev("aw_out_full", "write outstanding count reached the configured maximum",
   "aw_out_full_s", group="outstanding")
ev("ar_out_full", "read outstanding count reached the configured maximum",
   "ar_out_full_s", group="outstanding")
ev("ooo_read", "a read completed ahead of an older read with a different ID",
   "ooo_r_ev", group="ordering")
ev("ooo_write", "a write response returned ahead of an older write with a different ID",
   "ooo_b_ev", group="ordering")
ev("w_before_aw", "a write-data beat was accepted with no write address outstanding",
   "w_ahead_ev", group="ordering")
ev("w_stall_no_aw", "write data stalled while no write address was outstanding (skid full)",
   "w_stall_no_aw_ev", group="ordering")

# ---- responses -------------------------------------------------------------
ev("b_okay", "write response OKAY", "b_okay_ev", group="response")
ev("b_exokay", "write response EXOKAY (exclusive write succeeded)", "b_exokay_ev", group="response")
ev("b_slverr", "write response SLVERR", "b_slverr_ev", group="response")
ev("b_decerr", "write response DECERR", "b_decerr_ev", group="response")
ev("b_excl_fail", "exclusive write answered OKAY (reservation lost)", "b_excl_fail_ev",
   group="response")
ev("r_okay_last", "read burst completed OKAY", "r_okay_ev", group="response")
ev("r_exokay_last", "read burst completed EXOKAY (exclusive read)", "r_exokay_ev", group="response")
ev("r_slverr_last", "read burst completed SLVERR", "r_slverr_ev", group="response")
ev("r_decerr_last", "read burst completed DECERR", "r_decerr_ev", group="response")
ev("r_err_midburst", "an error response on a read beat that is not the last",
   "r_err_mid_ev", group="response")

# ---- request shape (address channels) --------------------------------------
for ch in ("aw", "ar"):
    g = f"request.{ch}"
    L = CH_LONG[ch]
    for nm, doc in (("fixed", "FIXED burst"), ("incr", "INCR burst"), ("wrap", "WRAP burst"),
                    ("wrap2", "WRAP, 2 beats"), ("wrap4", "WRAP, 4 beats"),
                    ("wrap8", "WRAP, 8 beats"), ("wrap16", "WRAP, 16 beats"),
                    ("incr_len1", "INCR, single beat"), ("incr_len256", "INCR, 256 beats"),
                    ("size0", "1-byte beats"), ("size1", "2-byte beats"),
                    ("size2", "4-byte beats"), ("size3", "8-byte beats"),
                    ("unaligned", "start address not aligned to the beat size"),
                    ("ends_4k", "INCR burst ending exactly on a 4KB boundary"),
                    ("one_short_4k", "INCR burst ending one beat before a 4KB boundary"),
                    ("page_start", "burst starting at a 4KB page base"),
                    ("lock", "exclusive access (AxLOCK)")):
        ev(f"{ch}_{nm}", f"{L}: {doc}", f"{ch}_{nm}_ev", group=g)


# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------
def emit_terms():
    o = []
    w = o.append
    w("// GENERATED by scripts/gen_cover.py -- do not edit by hand.")
    w("// Per-channel handshake terms and handshake covergroups.\n")
    for ch, (v, r) in CHANNELS.items():
        w(f"// ---- {ch}: {CH_LONG[ch]} channel ----")
        w(f"logic {ch}_v_q, {ch}_r_q;")
        w("always_ff @(posedge aclk or negedge aresetn)")
        w(f"  if (!aresetn) begin {ch}_v_q <= 1'b0; {ch}_r_q <= 1'b0; end")
        w(f"  else begin {ch}_v_q <= {v}; {ch}_r_q <= {r}; end")
        w(f"wire {ch}_hs        = {v} & {r};")
        w(f"wire {ch}_pend_q    = {ch}_v_q & ~{ch}_r_q;          // last cycle was a stall")
        w(f"wire {ch}_stall0    = {v} & ~{r} & ~{ch}_pend_q;     // first stalled cycle of a transfer")
        w(f"wire {ch}_hold      = {v} & ~{r} &  {ch}_pend_q;     // a continuing stall")
        w(f"wire {ch}_hs_after_stall  = {ch}_hs &  {ch}_pend_q;")
        w(f"wire {ch}_hs_b2b          = {ch}_hs &  {ch}_v_q &  {ch}_r_q;")
        w(f"wire {ch}_hs_ready_first  = {ch}_hs & ~{ch}_v_q &  {ch}_r_q;")
        w(f"wire {ch}_hs_same_cycle   = {ch}_hs & ~{ch}_v_q & ~{ch}_r_q;")
        w(f"wire {ch}_idle_rdy  = ~{v} &  {r};")
        w(f"wire {ch}_idle_nrdy = ~{v} & ~{r};")
        w(f"wire {ch}_idle      = ~{v};")
        w(f"logic [7:0] {ch}_slen;          // consecutive stalled cycles so far")
        w("always_ff @(posedge aclk or negedge aresetn)")
        w(f"  if (!aresetn) {ch}_slen <= 8'd0;")
        w(f"  else if ({v} & ~{r}) {ch}_slen <= ({ch}_slen == 8'hFF) ? {ch}_slen : {ch}_slen + 8'd1;")
        w(f"  else {ch}_slen <= 8'd0;")
        w(f"wire [2:0] {ch}_kind = {ch}_hs_ready_first ? 3'd1 : {ch}_hs_same_cycle ? 3'd2 :")
        w(f"                       {ch}_hs_after_stall  ? 3'd3 : {ch}_hs_b2b        ? 3'd4 : 3'd0;\n")
        w(f"covergroup cg_hs_{ch} @(posedge aclk);")
        w(f"  cp_kind : coverpoint {ch}_kind iff (aresetn && {ch}_hs) {{")
        w("    bins ready_first = {3'd1};  bins same_cycle = {3'd2};")
        w("    bins valid_first = {3'd3};  bins back_to_back = {3'd4};")
        w("  }")
        w(f"  cp_stall : coverpoint {ch}_slen iff (aresetn && {ch}_hs_after_stall) {{")
        w("    bins s1 = {1};  bins s2 = {2};  bins s3 = {3};")
        w("    bins s4_7 = {[4:7]};  bins s8_15 = {[8:15]};  bins s16p = {[16:255]};")
        w("  }")
        w("endgroup")
        w(f"cg_hs_{ch} cg_hs_{ch}_i = new();\n")
    return "\n".join(o) + "\n"


def emit_events():
    o = []
    w = o.append
    w("// GENERATED by scripts/gen_cover.py -- do not edit by hand.")
    w("// Every cover event, once as SVA and once as a procedural matcher.")
    w("// Select the SVA rendering with +define+AXI_COVER_SVA (VCS / VC Formal /")
    w("// Questa); the default is the procedural rendering, which XSim can run.\n")
    for e in EVENTS:
        flat = e.flat()
        n = len(flat)
        w(f"// ---- {e.name}: {e.doc}")
        w(f"//      {e.sva_text()}")
        w("`ifdef AXI_COVER_SVA")
        w(f"c_{e.name} : cover property (@(posedge aclk) disable iff (!aresetn) {e.sva_text()});")
        w("`else")
        w(f"logic cov_hit_{e.name};")
        if n == 1:
            w(f"assign cov_hit_{e.name} = {flat[0]};")
        else:
            vec = ", ".join(reversed(flat))        # t[0] is the earliest term
            w(f"axi_cov_chain #(.N({n})) u_cov_{e.name} "
              f"(.clk(aclk), .rstn(aresetn), .t({{{vec}}}), .hit(cov_hit_{e.name}));")
        w(f"integer cnt_{e.name} = 0;")
        w("always_ff @(posedge aclk)")
        w(f"  if (aresetn && cov_hit_{e.name}) cnt_{e.name} <= cnt_{e.name} + 1;")
        w("`endif\n")
    w("`ifndef AXI_COVER_SVA")
    w("// One line per event; scripts/cov_report.py aggregates these across runs.")
    w("final begin")
    for e in EVENTS:
        w(f'  $display("COVEVT %s {e.name} %0d", IFNAME, cnt_{e.name});')
    w("end")
    w("`endif")
    return "\n".join(o) + "\n"



def emit_req():
    """Request-shape wires for the two address channels."""
    o = []
    w = o.append
    w("// GENERATED by scripts/gen_cover.py -- do not edit by hand.")
    w("// Request-shape terms for the address channels (burst type, size, 4KB position).")
    for ch in ("aw", "ar"):
        a, ln, sz, bu, lk = (f"{ch}addr", f"{ch}len", f"{ch}size", f"{ch}burst", f"{ch}lock")
        w(f"// ---- {ch} ----")
        w(f"wire [ADDR_W-1:0] {ch}_bytes   = ADDR_W'(axi_bytes_per_beat({sz}));")
        w(f"wire [ADDR_W-1:0] {ch}_last_b  = axi_aligned_addr({a}, {sz}) + ADDR_W'({ln}) * {ch}_bytes + {ch}_bytes - ADDR_W'(1);")
        w(f"wire {ch}_x4k = axi_crosses_4k({a}, {ln}, {sz}, {bu});")
        w(f"wire {ch}_fixed_ev = {ch}_hs & ({bu} == AXI_BURST_FIXED);")
        w(f"wire {ch}_incr_ev  = {ch}_hs & ({bu} == AXI_BURST_INCR);")
        w(f"wire {ch}_wrap_ev  = {ch}_hs & ({bu} == AXI_BURST_WRAP);")
        for n, ln_v in ((2, 1), (4, 3), (8, 7), (16, 15)):
            w(f"wire {ch}_wrap{n}_ev = {ch}_wrap_ev & ({ln} == 8'd{ln_v});")
        w(f"wire {ch}_incr_len1_ev   = {ch}_incr_ev & ({ln} == 8'd0);")
        w(f"wire {ch}_incr_len256_ev = {ch}_incr_ev & ({ln} == 8'd255);")
        for k in range(4):
            w(f"wire {ch}_size{k}_ev = {ch}_hs & ({sz} == 3'd{k});")
        w(f"wire {ch}_unaligned_ev    = {ch}_hs & ((ADDR_W'({a}) & ({ch}_bytes - ADDR_W'(1))) != '0);")
        w(f"wire {ch}_ends_4k_ev      = {ch}_incr_ev & ~{ch}_x4k & ({ch}_last_b[11:0] == 12'hFFF);")
        w(f"wire {ch}_one_short_4k_ev = {ch}_incr_ev & ~{ch}_x4k & ({ch}_last_b[11:0] == (12'hFFF - {ch}_bytes[11:0]));")
        w(f"wire {ch}_page_start_ev   = {ch}_hs & ({a}[11:0] == 12'h000);")
        w(f"wire {ch}_lock_ev         = {ch}_hs & {lk};")
        w("")
    return "\n".join(o) + "\n"


def emit_catalogue():
    o = ["# AXI4 cover-event catalogue", "",
         "Generated by `scripts/gen_cover.py` from a single event table. Each event is",
         "rendered twice from the same definition: as an SVA `cover property` (for",
         "VCS / VC Formal / Questa, `+define+AXI_COVER_SVA`) and as a procedural matcher",
         "that Vivado XSim can run, because XSim ignores `cover property`.", "",
         f"{len(EVENTS)} events.", ""]
    groups = {}
    for e in EVENTS:
        groups.setdefault(e.group, []).append(e)
    for g, evs in groups.items():
        o += [f"## {g}", "", "| Event | Meaning | Sequence |", "|---|---|---|"]
        for e in evs:
            o.append(f"| `{e.name}` | {e.doc} | `{e.sva_text()}` |")
        o.append("")
    return "\n".join(o)


def main():
    (ROOT / "verif/sva/axi4_cov_terms.svh").write_text(emit_terms(), encoding="utf-8")
    (ROOT / "verif/sva/axi4_cov_req.svh").write_text(emit_req(), encoding="utf-8")
    (ROOT / "verif/sva/axi4_cov_events.svh").write_text(emit_events(), encoding="utf-8")
    (ROOT / "docs/cover_events.md").write_text(emit_catalogue(), encoding="utf-8")
    print(f"generated {len(EVENTS)} cover events, {len(CHANNELS)} channels")


if __name__ == "__main__":
    main()
