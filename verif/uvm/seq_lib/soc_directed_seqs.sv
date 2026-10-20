//==============================================================================
// soc_directed_seqs.sv
//
// Directed sequences: each one walks a specific corner of the protocol on
// purpose, rather than hoping constrained-random reaches it.
//
// WHY THESE EXIST. Coverage measured on the random tests alone (docs/coverage_plan.md,
// "baseline") showed what random stimulus does badly:
//   * multi-beat writes with FULL strobes on every beat are rare, so the bridge's
//     real AHB burst forms (INCR4/8/16, WRAP writes) were almost never produced;
//   * exclusive access was never exercised at all;
//   * bursts that start at a page base, or end exactly at / one beat short of a
//     4KB boundary, need an address chosen for the purpose.
//
// Every field is set explicitly. Nothing here goes through randomize(): XSim's
// constraint solver has several documented problems (docs/xsim_notes.md) and a
// directed sequence has no business depending on it.
//==============================================================================
`ifndef SOC_DIRECTED_SEQS_SV
`define SOC_DIRECTED_SEQS_SV

//------------------------------------------------------------------------------
class soc_dir_base extends soc_base_seq;

  `uvm_object_utils(soc_dir_base)

  typedef enum int { SM_FULL, SM_ZERO, SM_SPARSE, SM_RANDOM,
                     SM_FIRST_PARTIAL, SM_LAST_PARTIAL } smode_e;

  // Number of transactions issued by this sequence, for log context.
  int unsigned n_issued;

  function new(string name = "soc_dir_base");
    super.new(name);
  endfunction

  //--------------------------------------------------------------------------
  // The 4KB page a target's directed traffic should live in.
  //--------------------------------------------------------------------------
  function bit [AXI_ADDR_W-1:0] page_of(soc_target_e t);
    case (t)
      TGT_SRAM: return SHARED_BASE + 32'h1000;   // 0x9000: keeps clear of 0x8000 users
      TGT_AHB : return AHB_REG_BASE;             // the 4KB peripheral register block
      TGT_CSR : return CSR_BASE;
      TGT_WAIT: return AHB_WAIT_BASE;
      TGT_ROM : return AHB_ROM_BASE;
      default : return SHARED_BASE;
    endcase
  endfunction

  //--------------------------------------------------------------------------
  // Byte lanes a beat occupies, as a mask.
  //--------------------------------------------------------------------------
  function bit [AXI_STRB_W-1:0] lane_mask(axi4_seq_item t, int unsigned b);
    int unsigned lo, hi;
    bit [AXI_STRB_W-1:0] m;
    axi_byte_lanes(t.addr, t.len, t.size, t.burst, b, AXI_STRB_W, lo, hi);
    m = '0;
    for (int i = int'(lo); i <= int'(hi) && i < AXI_STRB_W; i++) m[i] = 1'b1;
    return m;
  endfunction

  //--------------------------------------------------------------------------
  // Build a fully specified transaction.
  //--------------------------------------------------------------------------
  function axi4_seq_item mk(bit wr, bit [AXI_ADDR_W-1:0] addr, int len, int size,
                            int burst, bit [AXI_ID_W-1:0] id = '0, bit lock = 1'b0,
                            smode_e sm = SM_FULL, int aw_dly = 0, int w_dly_max = 0);
    axi4_seq_item t;
    bit [AXI_STRB_W-1:0] m, s;
    int                  pop;

    t = axi4_seq_item::type_id::create("d");
    t.is_write = wr;
    t.addr     = addr;
    t.len      = len;
    t.size     = size;
    t.burst    = burst;
    t.id       = id;
    t.lock     = lock;
    t.cache    = '0; t.prot = '0; t.qos = '0; t.region = '0;

    t.data    = new[len + 1];
    t.strb    = new[len + 1];
    t.w_delay = new[len + 1];

    t.aw_delay      = aw_dly;
    t.ar_delay      = aw_dly;
    t.b_ready_delay = 0;
    t.r_ready_delay = 0;

    for (int b = 0; b <= len; b++) begin
      t.data[b]    = {$urandom, $urandom};
      t.w_delay[b] = (w_dly_max > 0) ? $urandom_range(w_dly_max, 0) : 0;
      m   = lane_mask(t, b);
      pop = $countones(m);
      s   = m;
      case (sm)
        SM_FULL:  s = m;
        SM_ZERO:  s = '0;
        SM_RANDOM: s = m & AXI_STRB_W'($urandom);
        SM_SPARSE: begin
          // Enabled lanes that are NOT one contiguous run. Needs >= 3 lanes.
          if (pop >= 3) begin
            s = m & 8'b1010_1010;
            if ($countones(s) < 2 || s == m) s = m & 8'b0101_0101;
            if ($countones(s) < 2) s = m;
          end
        end
        SM_FIRST_PARTIAL: begin
          // First beat loses its lowest enabled lane; the rest are full.
          if (b == 0 && pop > 1) begin
            s = m;
            for (int i = 0; i < AXI_STRB_W; i++) if (s[i]) begin s[i] = 1'b0; break; end
          end
        end
        SM_LAST_PARTIAL: begin
          if (b == len && pop > 1) begin
            s = m;
            for (int i = 0; i < AXI_STRB_W; i++) if (s[i]) begin s[i] = 1'b0; break; end
          end
        end
      endcase
      t.strb[b] = s;
    end

    if (!wr) begin
      t.strb = new[len + 1];                 // reads carry no strobes
      for (int b = 0; b <= len; b++) t.strb[b] = '0;
    end
    return t;
  endfunction

  //--------------------------------------------------------------------------
  // Issue and wait. Steps that depend on each other (a read-back after a write, an
  // exclusive write after an exclusive read) must not overlap in flight.
  //--------------------------------------------------------------------------
  task send(axi4_seq_item t);
    issue(t);
    n_issued++;
    t.done_ev.wait_ptrigger();
  endtask

  // Write then read the same footprint back. The scoreboard compares the read
  // against the C++ model, so this is a full data-path check of the write.
  task wr_rd(bit [AXI_ADDR_W-1:0] addr, int len, int size, int burst,
             bit [AXI_ID_W-1:0] id = '0, smode_e sm = SM_FULL);
    axi4_seq_item w, r;
    w = mk(1'b1, addr, len, size, burst, id, 1'b0, sm);
    send(w);
    r = mk(1'b0, addr, len, size, burst, id);
    send(r);
  endtask

  // Largest number of bytes a burst of this shape touches.
  function int unsigned span(int len, int size);
    return (len + 1) * (1 << size);
  endfunction

endclass : soc_dir_base


//------------------------------------------------------------------------------
// INCR: lengths, sizes, and where the burst sits in its 4KB page.
//------------------------------------------------------------------------------
class axi_incr_edge_seq extends soc_dir_base;

  `uvm_object_utils(axi_incr_edge_seq)

  soc_target_e tgt = TGT_SRAM;
  // Lengths are AxLEN values: 0 is one beat, 255 is 256.
  int lens [10];

  function new(string name = "axi_incr_edge_seq");
    super.new(name);
    lens = '{0, 1, 2, 3, 4, 7, 15, 16, 63, 255};
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] pg, a;
    int unsigned         nb, bytes, off;
    int                  l;

    pg = page_of(tgt);
    for (int size = 0; size <= 3; size++) begin
      nb = 1 << size;
      foreach (lens[i]) begin
        l     = lens[i];
        bytes = span(l, size);
        if (bytes > 4096) continue;

        // 1. Starts exactly at the page base.
        wr_rd(pg, l, size, AXI_BURST_INCR, 4'(i));

        // 2. Ends exactly on the 4KB boundary.
        a = pg + 4096 - bytes;
        wr_rd(a, l, size, AXI_BURST_INCR, 4'(i + 1));

        // 3. Ends one beat before the boundary.
        if (bytes + nb <= 4096) begin
          a = pg + 4096 - bytes - nb;
          wr_rd(a, l, size, AXI_BURST_INCR, 4'(i + 2));
        end

        // 4. Mid-page, aligned and 64-byte aligned (lets the bridge use a real
        //    AHB burst form when the width allows it).
        off = 64 * ((i % 8) + 1);
        if (off + bytes <= 4096) wr_rd(pg + off, l, size, AXI_BURST_INCR, 4'(i + 3));

        // 5. Unaligned start (not possible for 1-byte beats).
        if (size > 0 && 64 + 1 + bytes <= 4096)
          wr_rd(pg + 64 + 1, l, size, AXI_BURST_INCR, 4'(i + 4));
      end
    end
    drain();
  endtask

endclass : axi_incr_edge_seq


//------------------------------------------------------------------------------
// WRAP: every legal length, every beat size, every start slot in the container.
//------------------------------------------------------------------------------
class axi_wrap_edge_seq extends soc_dir_base;

  `uvm_object_utils(axi_wrap_edge_seq)

  soc_target_e tgt = TGT_SRAM;

  function new(string name = "axi_wrap_edge_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] pg, base, a;
    int unsigned         container;
    int                  beats;
    int                  lens_w [4];

    lens_w = '{1, 3, 7, 15};                       // AxLEN for 2/4/8/16 beats
    pg = page_of(tgt);

    for (int size = 0; size <= 3; size++) begin
      for (int li = 0; li < 4; li++) begin
        beats     = lens_w[li] + 1;
        container = beats * (1 << size);
        if (container > 1024) continue;

        // A container-aligned base well inside the page.
        base = (pg + 32'h400) & ~(AXI_ADDR_W'(container) - 1);

        // Start at every slot, so the wrap point lands at every position.
        for (int k = 0; k < beats; k++) begin
          a = base + AXI_ADDR_W'(k * (1 << size));
          wr_rd(a, lens_w[li], size, AXI_BURST_WRAP, 4'(k));
        end
      end
    end
    drain();
  endtask

endclass : axi_wrap_edge_seq


//------------------------------------------------------------------------------
// FIXED: every beat targets the same address.
//------------------------------------------------------------------------------
class axi_fixed_edge_seq extends soc_dir_base;

  `uvm_object_utils(axi_fixed_edge_seq)

  soc_target_e tgt = TGT_SRAM;

  function new(string name = "axi_fixed_edge_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] pg, a;
    int lens_f [5];

    lens_f = '{0, 1, 3, 7, 15};                    // FIXED is capped at 16 beats
    pg = page_of(tgt);

    for (int size = 0; size <= 3; size++) begin
      foreach (lens_f[i]) begin
        a = pg + 32'h80 + 32'(i * 16);
        wr_rd(a, lens_f[i], size, AXI_BURST_FIXED, 4'(i));
        if (size > 0) begin                        // unaligned start is legal for FIXED
          a = pg + 32'h200 + 32'(i * 16) + 1;
          wr_rd(a, lens_f[i], size, AXI_BURST_FIXED, 4'(i + 5));
        end
      end
    end
    drain();
  endtask

endclass : axi_fixed_edge_seq


//------------------------------------------------------------------------------
// Write strobes: zero, sparse, partial first/last beat, and narrow lane positions.
//------------------------------------------------------------------------------
class axi_strobe_seq extends soc_dir_base;

  `uvm_object_utils(axi_strobe_seq)

  soc_target_e tgt = TGT_SRAM;

  function new(string name = "axi_strobe_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] pg, a;
    smode_e              modes [6];
    int                  lens_s [3];
    int                  n;

    modes  = '{SM_FULL, SM_ZERO, SM_SPARSE, SM_RANDOM, SM_FIRST_PARTIAL, SM_LAST_PARTIAL};
    lens_s = '{0, 3, 15};
    pg = page_of(tgt);
    n  = 0;

    // Write a known background first so a strobe that fails to protect a byte is
    // visible as a changed byte, not just "still zero".
    send(mk(1'b1, pg, 255, 3, AXI_BURST_INCR, 4'd1));

    for (int size = 0; size <= 3; size++) begin
      foreach (modes[mi]) begin
        foreach (lens_s[li]) begin
          a = pg + 32'h40 * 32'(n % 24);
          n++;
          // Aligned, and offset to every lane position for narrow beats.
          wr_rd(a, lens_s[li], size, AXI_BURST_INCR, 4'(n), modes[mi]);
          if (size < 3)
            wr_rd(a + (1 << size), lens_s[li], size, AXI_BURST_INCR, 4'(n), modes[mi]);
        end
      end
    end
    drain();
  endtask

endclass : axi_strobe_seq


//------------------------------------------------------------------------------
// The wait/error AHB slave. Wait states come from addr[7:4]; addr[9] makes it answer
// ERROR, so 512-byte zones alternate good / error. Sweeping the address sweeps the
// behaviour -- in particular, WHICH TRANSFER OF AN AHB BURST takes the error: a burst
// that starts N dwords short of an error zone takes it at word index 2N.
//------------------------------------------------------------------------------
class axi_wait_error_seq extends soc_dir_base;

  `uvm_object_utils(axi_wait_error_seq)

  function new(string name = "axi_wait_error_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] w, a, edge_a;
    int                  e;

    w      = AHB_WAIT_BASE;
    edge_a = w + 32'h200;                 // first error address; 0x000..0x1FF is the good zone

    // 1. Every wait-state count 0..15, read and write, single and burst.
    for (int ws = 0; ws < 16; ws++) begin
      a = w + (32'(ws) << 4);
      wr_rd(a, 0, 2, AXI_BURST_INCR, 4'(ws));                // one word
      wr_rd(a, 0, 3, AXI_BURST_INCR, 4'(ws));                // aligned double word
      wr_rd(w + (32'(ws) << 4), 1, 3, AXI_BURST_INCR, 4'(ws)); // two beats
    end

    // 2. ERROR from the very first transfer.
    send(mk(1'b0, edge_a, 0, 2, AXI_BURST_INCR, 4'd1));
    send(mk(1'b1, edge_a, 0, 2, AXI_BURST_INCR, 4'd2));
    send(mk(1'b0, edge_a, 7, 3, AXI_BURST_INCR, 4'd3));
    send(mk(1'b1, edge_a, 7, 3, AXI_BURST_INCR, 4'd4));

    // 3. ERROR part-way through a burst. The burst starts in the good zone and runs into
    //    the error zone, so the abort lands at AHB word index 2e. The bridge must cancel
    //    the address phase it has already presented, stop issuing, and still return every
    //    AXI beat it promised. (These are 8-byte aligned, so the bridge runs them as one
    //    INCR burst: the erroring transfer is a SEQ one. The 512-byte boundary is not a
    //    1KB boundary, so the bridge does not restart the burst there.)
    for (e = 1; e <= 7; e++) begin
      a = edge_a - 32'(e * 8);                                // e double-words short of the zone
      send(mk(1'b0, a, 7, 3, AXI_BURST_INCR, 4'(e)));         // read
      send(mk(1'b1, a, 7, 3, AXI_BURST_INCR, 4'(e)));         // write
      // Half-offset start: lands in the byte-walking path (every transfer is a NONSEQ
      // single there, so this is the other kind of mid-burst error).
      send(mk(1'b0, a - 4, 7, 3, AXI_BURST_INCR, 4'(e)));
    end

    // 4. Wrapped and fixed bursts. A WRAP container is aligned to its own size, so it can
    //    never straddle the zone edge: it is wholly good or wholly error.
    send(mk(1'b0, edge_a - 32'h8, 3, 3, AXI_BURST_WRAP,  4'd5));   // good zone, last slot
    send(mk(1'b0, edge_a + 32'h8, 3, 3, AXI_BURST_WRAP,  4'd5));   // error zone, mid-container start
    send(mk(1'b0, edge_a,         3, 2, AXI_BURST_FIXED, 4'd6));
    send(mk(1'b1, edge_a,         3, 2, AXI_BURST_FIXED, 4'd7));

    // 5. The next good zone starts at 0x400: errors stop again.
    wr_rd(w + 32'h400, 7, 3, AXI_BURST_INCR, 4'd8);
    wr_rd(w + 32'h600 - 32'h20, 3, 3, AXI_BURST_INCR, 4'd9);  // good -> error zone at 0x600

    // 6. The hole: inside the AHB window, no slave there.
    send(mk(1'b0, AHB_BASE + 32'h30000, 0, 2, AXI_BURST_INCR, 4'd8));
    send(mk(1'b1, AHB_BASE + 32'h30000, 0, 2, AXI_BURST_INCR, 4'd9));
    send(mk(1'b0, AHB_BASE + 32'h30000, 3, 3, AXI_BURST_INCR, 4'd10));

    // 7. ROM: reads fine, writes refused.
    send(mk(1'b0, AHB_ROM_BASE + 32'h100, 3, 3, AXI_BURST_INCR, 4'd1));
    send(mk(1'b1, AHB_ROM_BASE + 32'h100, 3, 3, AXI_BURST_INCR, 4'd2));
    send(mk(1'b1, AHB_ROM_BASE + 32'h100, 0, 0, AXI_BURST_INCR, 4'd3));
    send(mk(1'b0, AHB_ROM_BASE + 32'h3FF0, 1, 3, AXI_BURST_INCR, 4'd4));   // ends on the last ROM byte
    drain();
  endtask

endclass : axi_wait_error_seq


//------------------------------------------------------------------------------
// AHB burst forms. The bridge picks INCR4/8/16, WRAP4/8/16 or undefined-length
// INCR only for aligned 8-byte beats with full strobes, so these are written to
// hit exactly those shapes, for both directions.
//------------------------------------------------------------------------------
class axi_ahb_forms_seq extends soc_dir_base;

  `uvm_object_utils(axi_ahb_forms_seq)

  function new(string name = "axi_ahb_forms_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] r, a;
    int                  lens_w [3];

    r = AHB_REG_BASE;

    // INCR with an exact 4/8/16-word length, aligned to its own size: INCR4/8/16.
    //   len 1 -> 4 words (16B), len 3 -> 8 words (32B), len 7 -> 16 words (64B)
    wr_rd(r + 32'h000, 1, 3, AXI_BURST_INCR, 4'd1);        // INCR4
    wr_rd(r + 32'h040, 3, 3, AXI_BURST_INCR, 4'd2);        // INCR8
    wr_rd(r + 32'h080, 7, 3, AXI_BURST_INCR, 4'd3);        // INCR16
    // Same lengths but NOT aligned to the burst size: undefined-length INCR.
    wr_rd(r + 32'h108, 1, 3, AXI_BURST_INCR, 4'd4);
    wr_rd(r + 32'h128, 3, 3, AXI_BURST_INCR, 4'd5);
    wr_rd(r + 32'h148, 7, 3, AXI_BURST_INCR, 4'd6);
    // Other word counts: undefined-length INCR.
    wr_rd(r + 32'h200, 0, 3, AXI_BURST_INCR, 4'd7);        // 2 words
    wr_rd(r + 32'h210, 2, 3, AXI_BURST_INCR, 4'd8);        // 6 words
    wr_rd(r + 32'h240, 15, 3, AXI_BURST_INCR, 4'd9);       // 32 words
    wr_rd(r + 32'h400, 63, 3, AXI_BURST_INCR, 4'd10);      // 128 words, crosses 1KB

    // INCR across a 1KB AHB boundary, which AHB forbids a burst to cross: the
    // bridge has to restart with a fresh NONSEQ.
    wr_rd(r + 32'h3F0, 7, 3, AXI_BURST_INCR, 4'd11);
    wr_rd(r + 32'h7E0, 15, 3, AXI_BURST_INCR, 4'd12);

    // WRAP of 2/4/8 beats of 8 bytes = WRAP4/8/16 on AHB, at every start slot.
    lens_w = '{1, 3, 7};
    foreach (lens_w[wi]) begin
      for (int k = 0; k <= lens_w[wi]; k++) begin
        a = r + 32'h800 + 32'h100 * 32'(wi) + 32'(k * 8);
        wr_rd(a, lens_w[wi], 3, AXI_BURST_WRAP, 4'(k));
      end
    end
    // 16-beat 8-byte WRAP = 32 words: no AHB equivalent, byte-walking fallback.
    wr_rd(r + 32'hC00, 15, 3, AXI_BURST_WRAP, 4'd1);
    wr_rd(r + 32'hC40, 15, 3, AXI_BURST_WRAP, 4'd2);
    drain();
  endtask

endclass : axi_ahb_forms_seq


//------------------------------------------------------------------------------
// Exclusive access. Each step waits for the previous one, because the outcome of
// an exclusive write depends on exactly what happened before it.
//------------------------------------------------------------------------------
class axi_exclusive_seq extends soc_dir_base;

  `uvm_object_utils(axi_exclusive_seq)

  soc_target_e tgt = TGT_SRAM;

  function new(string name = "axi_exclusive_seq");
    super.new(name);
  endfunction

  // exclusive read, then (optionally) the exclusive write
  task xr(bit [AXI_ADDR_W-1:0] a, int len, int size, bit [AXI_ID_W-1:0] id);
    send(mk(1'b0, a, len, size, AXI_BURST_INCR, id, 1'b1));
  endtask
  task xw(bit [AXI_ADDR_W-1:0] a, int len, int size, bit [AXI_ID_W-1:0] id);
    send(mk(1'b1, a, len, size, AXI_BURST_INCR, id, 1'b1));
  endtask
  task nr(bit [AXI_ADDR_W-1:0] a, int len, int size, bit [AXI_ID_W-1:0] id);
    send(mk(1'b0, a, len, size, AXI_BURST_INCR, id));
  endtask
  task nw(bit [AXI_ADDR_W-1:0] a, int len, int size, bit [AXI_ID_W-1:0] id);
    send(mk(1'b1, a, len, size, AXI_BURST_INCR, id));
  endtask

  task body();
    bit [AXI_ADDR_W-1:0] pg, a;
    pg = page_of(tgt);

    // Background data so a failed exclusive write is visible as "unchanged".
    nw(pg, 15, 3, 4'd0);

    // 1. Classic read-modify-write that succeeds.
    a = pg + 32'h100;
    xr(a, 0, 3, 4'd1);   xw(a, 0, 3, 4'd1);   nr(a, 0, 3, 4'd0);

    // 2. A normal write between the read and the write breaks the reservation.
    a = pg + 32'h108;
    xr(a, 0, 3, 4'd1);   nw(a, 0, 3, 4'd2);   xw(a, 0, 3, 4'd1);   nr(a, 0, 3, 4'd0);

    // 3. The exclusive write is to a different address than the read reserved.
    a = pg + 32'h110;
    xr(a, 0, 3, 4'd1);   xw(a + 32'h8, 0, 3, 4'd1);   nr(a + 32'h8, 0, 3, 4'd0);

    // 4. No prior exclusive read at all.
    a = pg + 32'h120;
    xw(a, 0, 3, 4'd7);   nr(a, 0, 3, 4'd0);

    // 5. Two IDs reserve the same location. The first to store wins, and that
    //    store is itself a write -- so the second must now fail. (Spec-driven;
    //    this is the case a model that copies the RTL's behaviour gets wrong.)
    a = pg + 32'h130;
    xr(a, 0, 3, 4'd3);   xr(a, 0, 3, 4'd4);
    xw(a, 0, 3, 4'd3);   xw(a, 0, 3, 4'd4);   nr(a, 0, 3, 4'd0);

    // 6. Sizes and lengths. Total bytes must be a power of two, <= 128, with the
    //    address aligned to the total.
    for (int size = 0; size <= 3; size++) begin
      a = pg + 32'h200 + 32'(size * 64);
      xr(a, 0, size, 4'd5);   xw(a, 0, size, 4'd5);   nr(a, 0, size, 4'd0);
    end
    a = pg + 32'h300;                                  // 16 bytes: 2 beats x 8
    xr(a, 1, 3, 4'd6);   xw(a, 1, 3, 4'd6);   nr(a, 1, 3, 4'd0);
    a = pg + 32'h380;                                  // 128 bytes: 16 beats x 8
    xr(a, 15, 3, 4'd6);  xw(a, 15, 3, 4'd6);  nr(a, 15, 3, 4'd0);

    // 6b. Re-arming. A second exclusive read by the same ID replaces its reservation
    //     instead of taking another slot, and the write that follows still succeeds.
    a = pg + 32'h440;
    xr(a, 0, 3, 4'd9);   xr(a, 0, 3, 4'd9);   xw(a, 0, 3, 4'd9);   nr(a, 0, 3, 4'd0);
    //     ... and re-arming at a DIFFERENT address moves it: the old address now fails.
    xr(a, 0, 3, 4'd9);   xr(a + 32'h10, 0, 3, 4'd9);   xw(a, 0, 3, 4'd9);   nr(a, 0, 3, 4'd0);

    // 6c. Writes that do not touch the reserved bytes leave the reservation alone --
    //     above it, below it, and next to it. (A monitor that cleared on ANY write would
    //     pass every test above and still be wrong.)
    a = pg + 32'h480;
    xr(a, 0, 3, 4'd10);
    nw(a + 32'h100, 0, 3, 4'd2);                 // well above
    nw(a - 32'h100, 0, 3, 4'd2);                 // well below
    nw(a + 32'h8,   0, 3, 4'd2);                 // the next dword up
    nw(a - 32'h8,   0, 3, 4'd2);                 // the next dword down
    xw(a, 0, 3, 4'd10);                          // must still succeed
    nr(a, 0, 3, 4'd0);

    // 7. Reservation capacity. The monitor holds four; the fifth ID's reservation
    //    is never installed, so its write fails while the others succeed.
    for (int id = 8; id < 13; id++) begin
      a = pg + 32'h500 + 32'((id - 8) * 16);
      xr(a, 0, 3, 4'(id));
    end
    for (int id = 8; id < 13; id++) begin
      a = pg + 32'h500 + 32'((id - 8) * 16);
      xw(a, 0, 3, 4'(id));
    end
    drain();
  endtask

endclass : axi_exclusive_seq


//------------------------------------------------------------------------------
// Several transactions in flight at once: outstanding depth, response reordering
// across slaves with different latency, the same-ID hazard stall, and write data
// arriving ahead of its address.
//------------------------------------------------------------------------------
class axi_outstanding_seq extends soc_dir_base;

  `uvm_object_utils(axi_outstanding_seq)

  function new(string name = "axi_outstanding_seq");
    super.new(name);
  endfunction

  // Fire a transaction without waiting for it.
  task fire(axi4_seq_item t);
    issue(t);
    n_issued++;
  endtask

  task body();
    axi4_seq_item t;
    bit [AXI_ADDR_W-1:0] sr, rg, cs;

    sr = SHARED_BASE + 32'h2000;
    rg = AHB_REG_BASE + 32'h800;
    cs = CSR_BASE + 32'h800;

    // Seed memory so the reads have defined data to compare.
    send(mk(1'b1, sr, 255, 3, AXI_BURST_INCR, 4'd0));
    send(mk(1'b1, rg, 255, 3, AXI_BURST_INCR, 4'd0));
    send(mk(1'b1, cs, 63,  3, AXI_BURST_INCR, 4'd0));

    // 1. Sixteen reads, distinct IDs, as fast as possible. The AHB bridge is slow
    //    and serialises, so the master piles up to the crossbar's outstanding
    //    limit and AR is stalled.
    for (int i = 0; i < 16; i++)
      fire(mk(1'b0, rg + 32'(i * 64), 7, 3, AXI_BURST_INCR, 4'(i)));
    drain();

    // 2. Writes to targets of very different speed, back to back, distinct IDs.
    //    Fast slaves answer first, so the write responses overtake older ones.
    for (int rep = 0; rep < 4; rep++) begin
      fire(mk(1'b1, rg + 32'h400 + 32'(rep * 64), 7, 3, AXI_BURST_INCR, 4'(rep * 4 + 0)));  // slow
      fire(mk(1'b1, sr + 32'(rep * 64),           3, 3, AXI_BURST_INCR, 4'(rep * 4 + 1)));  // fast
      fire(mk(1'b1, cs + 32'(rep * 64),           3, 3, AXI_BURST_INCR, 4'(rep * 4 + 2)));  // fast
      fire(mk(1'b1, sr + 32'h400 + 32'(rep * 64), 3, 3, AXI_BURST_INCR, 4'(rep * 4 + 3)));  // fast
    end
    drain();

    // 3. The same ID to different slaves. The crossbar must stall the later ones
    //    until the earlier one drains, or the responses could return out of order.
    for (int rep = 0; rep < 3; rep++) begin
      fire(mk(1'b0, rg + 32'(rep * 128),       7, 3, AXI_BURST_INCR, 4'd3));
      fire(mk(1'b0, sr + 32'h800 + 32'(rep * 128), 7, 3, AXI_BURST_INCR, 4'd3));
      fire(mk(1'b0, cs + 32'(rep * 128),       7, 3, AXI_BURST_INCR, 4'd3));
      fire(mk(1'b1, rg + 32'h600 + 32'(rep * 64),  3, 3, AXI_BURST_INCR, 4'd9));
      fire(mk(1'b1, sr + 32'hC00 + 32'(rep * 64),  3, 3, AXI_BURST_INCR, 4'd9));
    end
    drain();

    // 3b. One ID saturating its own outstanding budget. The crossbar tracks eight per
    //     ID; with all of them in flight to the slow AHB bridge the ninth must be held
    //     back by the hazard logic rather than overflow its counter.
    for (int i = 0; i < 12; i++)
      fire(mk(1'b0, rg + 32'(i * 32), 3, 3, AXI_BURST_INCR, 4'd5));
    drain();

    // 3c. Back-to-back requests to an unmapped address. The default slave serves one at
    //     a time, so the second AR/AW arrives while the first is still being answered.
    for (int i = 0; i < 6; i++)
      fire(mk(1'b0, 32'h3000_0000 + 32'(i * 64), 7, 3, AXI_BURST_INCR, 4'(i)));
    for (int i = 0; i < 4; i++)
      fire(mk(1'b1, 32'h3000_0400 + 32'(i * 64), 3, 3, AXI_BURST_INCR, 4'(i + 6)));
    drain();

    // 4. Write data ahead of the write address. The data is offered at once, the
    //    address 40 cycles later: the skid buffer has to absorb up to its depth
    //    and then push back on WREADY.
    for (int rep = 0; rep < 3; rep++) begin
      t = mk(1'b1, sr + 32'h1000 + 32'(rep * 256), 7, 3, AXI_BURST_INCR, 4'(rep), 1'b0, SM_FULL, 40);
      fire(t);
      t = mk(1'b1, cs + 32'h400 + 32'(rep * 256),  3, 3, AXI_BURST_INCR, 4'(rep + 4), 1'b0, SM_FULL, 40);
      fire(t);
    end
    drain();
  endtask

endclass : axi_outstanding_seq



//------------------------------------------------------------------------------
// Protocol-violation injection. Ordinary traffic first, so the DUT is in a normal,
// busy state when the violation lands; then flagged transactions until the driver
// reports that it corrupted one. The injected transaction is the LAST thing sent:
// what a DUT does after being fed a protocol violation is undefined, and the aim is
// to show the checker fired, not to see how far the damage spreads.
//------------------------------------------------------------------------------
class axi_inject_seq extends soc_dir_base;

  `uvm_object_utils(axi_inject_seq)

  axi_inject_e kind         = INJ_NONE;
  int unsigned max_attempts = 60;

  function new(string name = "axi_inject_seq");
    super.new(name);
  endfunction

  function bit reads_only();
    return kind inside {INJ_AR_DROP, INJ_AR_PAYLOAD, INJ_AR_X};
  endfunction

  // The W channel only stalls once the crossbar's skid buffer is full (it accepts
  // data ahead of the address), so the W kinds need a burst longer than the buffer.
  function int burst_len();
    return (kind inside {INJ_W_DROP, INJ_W_PAYLOAD, INJ_W_X}) ? 15 : 3;
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] a;
    axi4_seq_item        t;
    bit                  done;

    a = SHARED_BASE + 32'h4000;                  // 0xC000: SRAM, clear of the other directed tests

    for (int i = 0; i < 6; i++)
      wr_rd(a + 32'(i * 64), 3, 3, AXI_BURST_INCR, 4'(i));
    send(mk(1'b1, a + 32'h800, 15, 3, AXI_BURST_INCR, 4'd0));    // something for reads to read

    done = 1'b0;
    for (int i = 0; i < int'(max_attempts) && !done; i++) begin
      t = mk(!reads_only(), a + 32'h800, burst_len(), 3, AXI_BURST_INCR, 4'(i));
      t.inject = kind;
      send(t);
      done = t.injected;
    end
    if (!done)
      `uvm_error("INJSEQ", $sformatf("%0d attempts and the driver never found a stall window to inject %s in",
                                     max_attempts, kind.name()))
    drain();
  endtask

endclass : axi_inject_seq


//------------------------------------------------------------------------------
// Illegal REQUESTS: the handshake is perfectly legal, the content of the address
// phase is not. Each illegal request is followed by ordinary traffic that the
// scoreboard checks, so "the DUT carried on working afterwards" is part of the test.
//
// Illegal writes go to a scratch region that no checked read ever touches: what an
// interconnect does with an illegal burst is unspecified, so a stray byte it may or
// may not write must not be able to make a later, legal read look wrong.
//------------------------------------------------------------------------------
class axi_illegal_req_seq extends soc_dir_base;

  `uvm_object_utils(axi_illegal_req_seq)

  function new(string name = "axi_illegal_req_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] legal, scratch;
    axi4_seq_item        t;
    int                  k;
    // (burst, len, size, address offset in scratch, lock) -- one per rule.
    //   1 WRAP, 3 beats         2 WRAP, unaligned start      3 FIXED, 17 beats
    //   4 INCR across 4KB       5 reserved burst type        6 size wider than the bus
    //   7 exclusive, 3 bytes
    int          bu [7];
    int          ln [7];
    int          sz [7];
    int unsigned off[7];
    bit          lk [7];

    legal   = SHARED_BASE + 32'h1000;            // 0x9000
    scratch = SHARED_BASE + 32'h6000;            // 0xE000..0xFFFF, written by nothing else

    bu = '{AXI_BURST_WRAP, AXI_BURST_WRAP, AXI_BURST_FIXED, AXI_BURST_INCR, 3, AXI_BURST_INCR, AXI_BURST_INCR};
    ln = '{2, 3, 16, 7, 3, 1, 2};
    sz = '{3, 3, 3, 3, 3, 4, 0};
    off = '{32'h100, 32'h201, 32'h300, 32'hFF0, 32'h400, 32'h500, 32'h600};
    lk = '{0, 0, 0, 0, 0, 0, 1};

    for (k = 0; k < 7; k++) begin
      // illegal write, then illegal read of the same footprint
      t = mk(1'b1, scratch + off[k], ln[k], sz[k], bu[k], 4'(k), lk[k]);
      send(t);
      t = mk(1'b0, scratch + off[k], ln[k], sz[k], bu[k], 4'(k), lk[k]);
      send(t);
      // ordinary, checked traffic straight afterwards
      wr_rd(legal + 32'(k * 128), 7, 3, AXI_BURST_INCR, 4'(k));
      wr_rd(legal + 32'h400 + 32'(k * 64), 3, 2, AXI_BURST_WRAP, 4'(k));
    end
    drain();
  endtask

endclass : axi_illegal_req_seq


//------------------------------------------------------------------------------
// Slave queues at their limit. The SRAM slave holds eight writes, eight read requests
// and eight completed-but-unacknowledged write responses; each limit gates a READY, so
// each has to be reached to know the gating works. The test around this changes the
// master's response-READY gaps between phases (see axi_queue_full_test).
//------------------------------------------------------------------------------
class axi_queue_full_seq extends soc_dir_base;

  `uvm_object_utils(axi_queue_full_seq)

  // 0: AW queue (data late)   1: B queue (BREADY late)   2: AR queue (RREADY late)
  int unsigned phase_sel = 0;

  function new(string name = "axi_queue_full_seq");
    super.new(name);
  endfunction

  task fire(axi4_seq_item t);
    issue(t);
    n_issued++;
  endtask

  task body();
    bit [AXI_ADDR_W-1:0] sr;
    sr = SHARED_BASE + 32'h5000;

    case (phase_sel)
      0: begin
        // Addresses accepted far ahead of their data: the first burst's data dribbles
        // out, so the other AWs pile up in the slave until its queue is full and the
        // crossbar has to leave them waiting. AW first, data late -- the opposite of the
        // data-ahead-of-address case in axi_outstanding_seq.
        for (int i = 0; i < 12; i++)
          fire(mk(1'b1, sr + 32'(i * 64), 3, 3, AXI_BURST_INCR, 4'(i), 1'b0, SM_FULL, 0, 25));
        drain();
      end
      1: begin
        // Eight short writes complete at the slave while BREADY is held off: its response
        // queue fills and WREADY must drop.
        for (int i = 0; i < 12; i++)
          fire(mk(1'b1, sr + 32'h400 + 32'(i * 32), 0, 3, AXI_BURST_INCR, 4'(i)));
        drain();
      end
      default: begin
        // Seed, then read eight bursts while RREADY crawls: the slave's AR queue fills.
        send(mk(1'b1, sr + 32'h800, 15, 3, AXI_BURST_INCR, 4'd0));
        for (int i = 0; i < 12; i++)
          fire(mk(1'b0, sr + 32'h800 + 32'(i * 8), 3, 3, AXI_BURST_INCR, 4'(i)));
        drain();
      end
    endcase
  endtask

endclass : axi_queue_full_seq


//------------------------------------------------------------------------------
// A short, fixed set of reads through the bridge, each of a different shape. Used by
// the bug replays (scripts/replay.py): the three bridge bugs all failed on one random
// read among hundreds, which makes for an unreadable waveform; here the same defects
// show up in a handful of transfers a person can follow cycle by cycle.
//------------------------------------------------------------------------------
class axi_bridge_probe_seq extends soc_dir_base;

  `uvm_object_utils(axi_bridge_probe_seq)

  function new(string name = "axi_bridge_probe_seq");
    super.new(name);
  endfunction

  task body();
    bit [AXI_ADDR_W-1:0] r;
    axi4_seq_item        t;
    r = AHB_REG_BASE + 32'h100;

    // Known contents: 64 bytes, full strobes (the bridge's uniform path).
    send(mk(1'b1, r, 7, 3, AXI_BURST_INCR, 4'd1));

    // 1. Four halfwords starting on a halfword inside the word: lanes 2-3, 4-5, 6-7, then
    //    the next word's 0-1. Each AHB halfword arrives on the lanes its address selects.
    send(mk(1'b0, r + 32'h02, 3, 1, AXI_BURST_INCR, 4'd2));
    // 2. Bytes, from an odd address: every byte on a different lane.
    send(mk(1'b0, r + 32'h0D, 5, 0, AXI_BURST_INCR, 4'd3));
    // 3. Two words: the upper and then the lower half of consecutive 64-bit words.
    send(mk(1'b0, r + 32'h14, 1, 2, AXI_BURST_INCR, 4'd4));
    // 4. A sparse write and the read that proves which bytes landed.
    send(mk(1'b1, r + 32'h20, 0, 3, AXI_BURST_INCR, 4'd5, 1'b0, SM_SPARSE));
    send(mk(1'b0, r + 32'h20, 0, 3, AXI_BURST_INCR, 4'd6));
    // 4b. Strobes 0b1011: bytes 0-1 (a halfword) and byte 3 on its own, with byte 2 in the gap.
    //     The bridge must emit exactly two transfers; a walk that skips the gap's neighbour
    //     (bugs A3 and A4) never writes byte 3, and the read-back sees the old contents.
    t = mk(1'b1, r + 32'h40, 0, 3, AXI_BURST_INCR, 4'd8);
    t.strb[0] = 8'b0000_1011;
    send(t);
    send(mk(1'b0, r + 32'h40, 0, 3, AXI_BURST_INCR, 4'd9));
    // 5. A wrapped halfword read: 8 beats in a 16-byte container, so the walk crosses
    //    two 64-bit words and every beat starts with inactive low lanes. (This is the
    //    shape of the first random read that failed under bug A4.)
    send(mk(1'b0, r + 32'h30, 7, 1, AXI_BURST_WRAP, 4'd7));
    drain();
  endtask

endclass : axi_bridge_probe_seq


//------------------------------------------------------------------------------
// Random traffic across EVERY kind of target, for the arbitration and routing
// cross (every master x direction x target).
//------------------------------------------------------------------------------
class axi_all_targets_seq extends axi4_random_seq;

  `uvm_object_utils(axi_all_targets_seq)

  function new(string name = "axi_all_targets_seq");
    super.new(name);
    use_sram = 1'b1; use_ahb = 1'b1; use_csr = 1'b1;
    use_rom  = 1'b1; use_wait = 1'b1; use_hole = 1'b1; use_bad = 1'b1;
  endfunction

endclass : axi_all_targets_seq

`endif // SOC_DIRECTED_SEQS_SV
