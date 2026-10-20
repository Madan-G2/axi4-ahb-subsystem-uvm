//==============================================================================
// soc_txn_cov.sv
//
// Transaction-level functional coverage. One instance, fed by every master's
// monitor, so the covergroups report the union across all three ports.
//
// This answers a different question from the cycle-level covers in
// verif/sva/axi4_cov.sv. That module asks "did the BUS do this?" (stall lengths,
// outstanding depth); this class asks "did the TRAFFIC do this?" (every
// burst/length/size, every address alignment, every kind of outcome).
//
// Bin sets are chosen so that every bin is reachable by legal stimulus. Where a
// combination is illegal or impossible it is excluded in the cross with a
// comment saying why, never silently left to look "uncovered forever".
//==============================================================================
`ifndef SOC_TXN_COV_SV
`define SOC_TXN_COV_SV

class soc_txn_cov extends uvm_subscriber #(axi4_seq_item);

  `uvm_component_utils(soc_txn_cov)

  //--------------------------------------------------------------------------
  // Classification
  //--------------------------------------------------------------------------
  typedef enum int {
    TG_SRAM_SH, TG_SRAM_FW, TG_ROM, TG_REG, TG_WAIT, TG_AHB_NONE, TG_CSR, TG_BAD
  } tgt_e;

  typedef enum int {
    O_RD_SRAM, O_WR_SRAM, O_RD_ROM, O_RD_REG, O_WR_REG, O_RD_WAIT, O_WR_WAIT,
    O_RD_CSR, O_WR_CSR,
    O_RD_EXOKAY_SRAM, O_RD_EXOKAY_CSR, O_WR_EXOKAY_SRAM, O_WR_EXOKAY_CSR,
    O_WR_EXFAIL_SRAM, O_WR_EXFAIL_CSR,
    O_RD_LOCK_AHB, O_WR_LOCK_AHB,
    O_WR_ROM_SLVERR, O_RD_WAIT_SLVERR, O_WR_WAIT_SLVERR,
    O_RD_AHBNONE_SLVERR, O_WR_AHBNONE_SLVERR,
    O_RD_DECERR, O_WR_DECERR,
    O_OTHER
  } outcome_e;

  // kind of a write-strobe pattern relative to the byte lanes a beat occupies
  typedef enum int { SK_FULL = 0, SK_PARTIAL = 1, SK_ZERO = 2 } strb_kind_e;

  // 4KB position classes (INCR bursts)
  typedef enum int { P4_MID = 0, P4_BASE = 1, P4_ONE_SHORT = 2, P4_ENDS = 3 } pos4k_e;

  function tgt_e tgt_of(bit [AXI_ADDR_W-1:0] a);
    if (a >= SRAM_BASE && a < SRAM_BASE + SRAM_SIZE)
      return (a < FW_BASE + FW_SIZE) ? TG_SRAM_FW : TG_SRAM_SH;
    if (a >= AHB_ROM_BASE  && a < AHB_ROM_BASE  + AHB_ROM_SIZE)  return TG_ROM;
    if (a >= AHB_REG_BASE  && a < AHB_REG_BASE  + AHB_REG_SIZE)  return TG_REG;
    if (a >= AHB_WAIT_BASE && a < AHB_WAIT_BASE + AHB_WAIT_SIZE) return TG_WAIT;
    if (a >= AHB_BASE      && a < AHB_BASE      + AHB_SIZE)      return TG_AHB_NONE;
    if (a >= CSR_BASE      && a < CSR_BASE      + CSR_SIZE)      return TG_CSR;
    return TG_BAD;
  endfunction

  // What actually happened, as one named outcome. Anything that does not fit a
  // legal pattern lands in O_OTHER, which is an illegal bin: the scoreboard
  // reports the mismatch, and the coverage report names it too.
  function outcome_e outcome_of(axi4_seq_item t, tgt_e tg);
    bit wr = t.is_write;
    bit [1:0] r = t.resp;
    case (tg)
      TG_BAD:
        return (r == AXI_RESP_DECERR) ? (wr ? O_WR_DECERR : O_RD_DECERR) : O_OTHER;
      TG_SRAM_SH, TG_SRAM_FW:
        if (t.lock) begin
          if (!wr) return (r == AXI_RESP_EXOKAY) ? O_RD_EXOKAY_SRAM : O_OTHER;
          return (r == AXI_RESP_EXOKAY) ? O_WR_EXOKAY_SRAM :
                 (r == AXI_RESP_OKAY)   ? O_WR_EXFAIL_SRAM : O_OTHER;
        end
        else if (r == AXI_RESP_OKAY) return wr ? O_WR_SRAM : O_RD_SRAM;
      TG_CSR:
        if (t.lock) begin
          if (!wr) return (r == AXI_RESP_EXOKAY) ? O_RD_EXOKAY_CSR : O_OTHER;
          return (r == AXI_RESP_EXOKAY) ? O_WR_EXOKAY_CSR :
                 (r == AXI_RESP_OKAY)   ? O_WR_EXFAIL_CSR : O_OTHER;
        end
        else if (r == AXI_RESP_OKAY) return wr ? O_WR_CSR : O_RD_CSR;
      TG_ROM:
        if (r == AXI_RESP_OKAY && !wr) return t.lock ? O_RD_LOCK_AHB : O_RD_ROM;
        else if (r == AXI_RESP_SLVERR && wr) return O_WR_ROM_SLVERR;
      TG_REG:
        if (r == AXI_RESP_OKAY) begin
          if (t.lock) return wr ? O_WR_LOCK_AHB : O_RD_LOCK_AHB;
          return wr ? O_WR_REG : O_RD_REG;
        end
      TG_WAIT:
        if (r == AXI_RESP_OKAY) begin
          if (t.lock) return wr ? O_WR_LOCK_AHB : O_RD_LOCK_AHB;
          return wr ? O_WR_WAIT : O_RD_WAIT;
        end
        else if (r == AXI_RESP_SLVERR) return wr ? O_WR_WAIT_SLVERR : O_RD_WAIT_SLVERR;
      TG_AHB_NONE:
        if (r == AXI_RESP_SLVERR) return wr ? O_WR_AHBNONE_SLVERR : O_RD_AHBNONE_SLVERR;
      default: ;
    endcase
    return O_OTHER;
  endfunction

  // Position of an INCR burst relative to its 4KB page.
  function pos4k_e pos4k_of(axi4_seq_item t);
    bit [AXI_ADDR_W-1:0] last = axi_aligned_addr(t.addr, t.size)
                              + AXI_ADDR_W'(t.len) * AXI_ADDR_W'(axi_bytes_per_beat(t.size))
                              + AXI_ADDR_W'(axi_bytes_per_beat(t.size)) - 1;
    if (last[11:0] == 12'hFFF)                                          return P4_ENDS;
    if (last[11:0] == 12'(12'hFFF - axi_bytes_per_beat(t.size)))        return P4_ONE_SHORT;
    if (t.addr[11:0] == 12'h000)                                        return P4_BASE;
    return P4_MID;
  endfunction

  // Strobe kind of one beat: compare the strobe against the lanes the beat uses.
  function strb_kind_e strb_kind(axi4_seq_item t, int unsigned b);
    int unsigned lo, hi;
    bit [AXI_STRB_W-1:0] lanes;
    axi_byte_lanes(t.addr, t.len, t.size, t.burst, b, AXI_STRB_W, lo, hi);
    lanes = '0;
    for (int i = int'(lo); i <= int'(hi) && i < AXI_STRB_W; i++) lanes[i] = 1'b1;
    if ((t.strb[b] & lanes) == '0)    return SK_ZERO;
    if ((t.strb[b] & lanes) == lanes) return SK_FULL;
    return SK_PARTIAL;
  endfunction

  // A strobe is "sparse" when its enabled lanes are not one contiguous run.
  function bit is_sparse(bit [AXI_STRB_W-1:0] s);
    bit seen_run_end = 1'b0;
    bit in_run = 1'b0;
    for (int i = 0; i < AXI_STRB_W; i++) begin
      if (s[i]) begin
        if (seen_run_end) return 1'b1;
        in_run = 1'b1;
      end
      else if (in_run) seen_run_end = 1'b1;
    end
    return 1'b0;
  endfunction

  //--------------------------------------------------------------------------
  // Covergroups
  //--------------------------------------------------------------------------

  // Burst type x length x beat size. The headline "FIXED / INCR / WRAP" matrix.
  covergroup cg_burst with function sample(bit [1:0] burst, int beats, bit [2:0] size);
    cp_burst : coverpoint burst {
      bins fixed = {AXI_BURST_FIXED}; bins incr = {AXI_BURST_INCR};
      bins wrap = {AXI_BURST_WRAP};   illegal_bins rsvd = {AXI_BURST_RSVD}; }
    cp_len : coverpoint beats {
      bins b1 = {1}; bins b2 = {2}; bins b3 = {3}; bins b4 = {4};
      bins b5_8 = {[5:8]};     bins b9_16 = {[9:16]};
      bins b17_32 = {[17:32]}; bins b33_64 = {[33:64]};
      bins b65_128 = {[65:128]}; bins b129_256 = {[129:256]}; }
    cp_size : coverpoint size {
      bins sz1 = {0}; bins sz2 = {1}; bins sz4 = {2}; bins sz8 = {3}; }

    x_burst_len_size : cross cp_burst, cp_len, cp_size {
      // WRAP is only defined for 2, 4, 8 or 16 beats.
      ignore_bins wrap_bad_len = binsof(cp_burst.wrap) &&
        (binsof(cp_len.b1) || binsof(cp_len.b3) || binsof(cp_len.b17_32) ||
         binsof(cp_len.b33_64) || binsof(cp_len.b65_128) || binsof(cp_len.b129_256));
      // FIXED is capped at 16 beats.
      ignore_bins fixed_too_long = binsof(cp_burst.fixed) &&
        (binsof(cp_len.b17_32) || binsof(cp_len.b33_64) ||
         binsof(cp_len.b65_128) || binsof(cp_len.b129_256));
    }
  endgroup

  // Direction x target x which master. "Every master reaches every kind of slave."
  covergroup cg_traffic with function sample(int master, bit wr, tgt_e tgt);
    cp_master : coverpoint master { bins m0 = {0}; bins m1 = {1}; bins m2 = {2}; }
    cp_dir    : coverpoint wr     { bins read = {0}; bins write = {1}; }
    cp_tgt    : coverpoint tgt {
      bins sram_shared = {TG_SRAM_SH};
      // The low 32KB of SRAM holds CPU firmware. Master 0 (the CPU's slot) may
      // use it; masters 1 and 2 are constrained off it (spec decision G4), which is
      // excluded in the cross below.
      bins sram_fw     = {TG_SRAM_FW};
      bins ahb_rom     = {TG_ROM};      bins ahb_regs  = {TG_REG};
      bins ahb_wait    = {TG_WAIT};     bins ahb_hole  = {TG_AHB_NONE};
      bins csr         = {TG_CSR};      bins unmapped  = {TG_BAD}; }
    x_traffic : cross cp_master, cp_dir, cp_tgt {
      // Enforced by construction in the sequences (G4), not by the DUT: nothing in
      // the interconnect stops M1 reading the firmware region, so this is a rule of
      // the testbench, and it is written down here instead of left as holes.
      ignore_bins fw_is_cpu_only = binsof(cp_tgt.sram_fw) &&
                                   (binsof(cp_master.m1) || binsof(cp_master.m2));
    }
  endgroup

  // Start-address alignment, 4KB position and WRAP start slot.
  covergroup cg_addr with function sample(bit [1:0] burst, bit [2:0] size, bit unaligned,
                                          pos4k_e pos4k, int beats, int wrap_slot);
    cp_align : coverpoint unaligned { bins aligned = {0}; bins unaligned = {1}; }
    cp_burst : coverpoint burst { bins fixed = {AXI_BURST_FIXED}; bins incr = {AXI_BURST_INCR};
                                  bins wrap = {AXI_BURST_WRAP}; }
    cp_size  : coverpoint size  { bins sz1 = {0}; bins sz2 = {1}; bins sz4 = {2}; bins sz8 = {3}; }

    x_align : cross cp_align, cp_burst, cp_size {
      // WRAP requires an aligned start address.
      ignore_bins wrap_unaligned = binsof(cp_burst.wrap) && binsof(cp_align.unaligned);
      // A 1-byte beat is always aligned.
      ignore_bins byte_unaligned = binsof(cp_size.sz1)   && binsof(cp_align.unaligned);
    }

    // Where an INCR burst sits relative to its 4KB page.
    cp_4k : coverpoint pos4k iff (burst == AXI_BURST_INCR) {
      bins mid_page      = {P4_MID};       bins starts_at_base = {P4_BASE};
      bins one_beat_short = {P4_ONE_SHORT}; bins ends_at_boundary = {P4_ENDS}; }
    x_4k_size : cross cp_4k, cp_size;

    // WRAP: container size and where in the container the burst starts.
    cp_wrap_beats : coverpoint beats iff (burst == AXI_BURST_WRAP) {
      bins w2 = {2}; bins w4 = {4}; bins w8 = {8}; bins w16 = {16}; }
    // Position is classified relative to the container, so the same four bins
    // mean the same thing at every burst length: the first slot, the last slot,
    // the second slot, or anywhere in between.
    cp_wrap_pos : coverpoint wrap_slot iff (burst == AXI_BURST_WRAP) {
      bins first = {0}; bins second = {1}; bins middle = {2}; bins last = {3}; }
    x_wrap : cross cp_wrap_beats, cp_wrap_pos {
      // A 2-beat container has only a first and a last slot.
      ignore_bins w2_slots = binsof(cp_wrap_beats.w2) &&
                             (binsof(cp_wrap_pos.second) || binsof(cp_wrap_pos.middle));
    }
  endgroup

  // Write strobes, relative to the byte lanes each beat actually occupies.
  covergroup cg_wstrb with function sample(bit [2:0] size, strb_kind_e first_k, strb_kind_e last_k,
                                           bit any_sparse, bit any_zero, int beats);
    cp_first : coverpoint first_k { bins full = {SK_FULL}; bins partial = {SK_PARTIAL};
                                    bins zero = {SK_ZERO}; }
    cp_last  : coverpoint last_k iff (beats > 1) { bins full = {SK_FULL}; bins partial = {SK_PARTIAL};
                                                   bins zero = {SK_ZERO}; }
    cp_sparse : coverpoint any_sparse { bins no = {0}; bins yes = {1}; }
    cp_zero   : coverpoint any_zero   { bins no = {0}; bins yes = {1}; }
    cp_size   : coverpoint size { bins sz1 = {0}; bins sz2 = {1}; bins sz4 = {2}; bins sz8 = {3}; }
    x_first_size : cross cp_first, cp_size {
      // One lane is either enabled or not; it cannot be partially enabled.
      ignore_bins one_lane_partial = binsof(cp_size.sz1) && binsof(cp_first.partial);
    }
    x_sparse_size : cross cp_sparse, cp_size {
      // Sparse needs at least three lanes, and a 2-byte beat has only two.
      ignore_bins narrow_sparse = binsof(cp_sparse.yes) && (binsof(cp_size.sz1) || binsof(cp_size.sz2));
    }
  endgroup

  // What came back, as one named outcome.
  covergroup cg_outcome with function sample(outcome_e o);
    cp_outcome : coverpoint o {
      bins rd_sram = {O_RD_SRAM};      bins wr_sram = {O_WR_SRAM};
      bins rd_rom = {O_RD_ROM};
      bins rd_reg = {O_RD_REG};        bins wr_reg = {O_WR_REG};
      bins rd_wait = {O_RD_WAIT};      bins wr_wait = {O_WR_WAIT};
      bins rd_csr = {O_RD_CSR};        bins wr_csr = {O_WR_CSR};
      bins rd_exokay_sram = {O_RD_EXOKAY_SRAM};  bins rd_exokay_csr = {O_RD_EXOKAY_CSR};
      bins wr_exokay_sram = {O_WR_EXOKAY_SRAM};  bins wr_exokay_csr = {O_WR_EXOKAY_CSR};
      bins wr_exfail_sram = {O_WR_EXFAIL_SRAM};  bins wr_exfail_csr = {O_WR_EXFAIL_CSR};
      bins rd_lock_ahb = {O_RD_LOCK_AHB};        bins wr_lock_ahb = {O_WR_LOCK_AHB};
      bins wr_rom_slverr = {O_WR_ROM_SLVERR};
      bins rd_wait_slverr = {O_RD_WAIT_SLVERR};  bins wr_wait_slverr = {O_WR_WAIT_SLVERR};
      bins rd_hole_slverr = {O_RD_AHBNONE_SLVERR}; bins wr_hole_slverr = {O_WR_AHBNONE_SLVERR};
      bins rd_decerr = {O_RD_DECERR};  bins wr_decerr = {O_WR_DECERR};
      illegal_bins unexpected = {O_OTHER}; }
  endgroup

  covergroup cg_id with function sample(bit [AXI_ID_W-1:0] id, bit wr);
    cp_id  : coverpoint id { bins ids[] = {[0:15]}; }
    cp_dir : coverpoint wr { bins read = {0}; bins write = {1}; }
    x_id_dir : cross cp_id, cp_dir;
  endgroup

  //--------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_burst   = new();
    cg_traffic = new();
    cg_addr    = new();
    cg_wstrb   = new();
    cg_outcome = new();
    cg_id      = new();
  endfunction

  //--------------------------------------------------------------------------
  function void write(axi4_seq_item t);
    tgt_e        tg;
    int          beats, container, slot;
    bit          unaligned;
    pos4k_e      p4;
    strb_kind_e  fk, lk;
    bit          sparse, zero;

    // Illegal requests (master-side error injection) are not "traffic" in the
    // coverage sense: counting them would let a deliberately broken burst fill a
    // bin that legal stimulus never reached.
    if (!axi_req_legal(t.addr, t.len, t.size, t.burst, t.lock, AXI_STRB_W)) return;

    beats     = int'(t.len) + 1;
    tg        = tgt_of(t.addr);
    unaligned = (t.addr & AXI_ADDR_W'(axi_bytes_per_beat(t.size) - 1)) != '0;
    p4        = pos4k_of(t);
    container = beats * int'(axi_bytes_per_beat(t.size));
    slot      = 0;
    if (t.burst == AXI_BURST_WRAP) begin
      int raw = int'((t.addr % container) / axi_bytes_per_beat(t.size));
      // 0 first, 1 second, 2 middle, 3 last -- relative to this container.
      if (raw == 0)              slot = 0;
      else if (raw == beats - 1) slot = 3;
      else if (raw == 1)         slot = 1;
      else                       slot = 2;
    end

    cg_burst.sample(t.burst, beats, t.size);
    cg_traffic.sample(t.master_idx, t.is_write, tg);
    cg_addr.sample(t.burst, t.size, unaligned, p4, beats, slot);
    cg_outcome.sample(outcome_of(t, tg));
    cg_id.sample(t.id, t.is_write);

    if (t.is_write && t.strb.size() == beats) begin
      fk     = strb_kind(t, 0);
      lk     = strb_kind(t, beats - 1);
      sparse = 1'b0;
      zero   = 1'b0;
      for (int b = 0; b < beats; b++) begin
        if (is_sparse(t.strb[b]))           sparse = 1'b1;
        if (strb_kind(t, b) == SK_ZERO)     zero   = 1'b1;
      end
      cg_wstrb.sample(t.size, fk, lk, sparse, zero, beats);
    end
  endfunction

endclass : soc_txn_cov

`endif // SOC_TXN_COV_SV
