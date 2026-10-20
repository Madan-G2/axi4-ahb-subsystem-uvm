//==============================================================================
// axi4_sram_ctrl.sv
//
// AXI4 slave over a byte-enabled behavioural SRAM.
//
// Supports the full AXI4 transfer model: INCR / WRAP / FIXED bursts, every
// AxSIZE up to the bus width, narrow transfers, unaligned starts, sparse WSTRB,
// and exclusive access. Multiple outstanding AW and AR transactions are
// accepted; responses are returned in order.
//
// Out-of-order response return is deliberately NOT implemented here. It is only
// observable once the crossbar can route interleaved responses from several
// slaves, and building it now would mean writing a reorder mechanism with no
// way to tell whether it works. It lands in Phase 2 alongside the crossbar.
//
// Memory is byte-addressed. That makes narrow and unaligned transfers fall out
// of the byte-lane arithmetic instead of needing special cases, which is where
// this kind of block usually goes wrong.
//==============================================================================
`ifndef AXI4_SRAM_CTRL_SV
`define AXI4_SRAM_CTRL_SV

module axi4_sram_ctrl
  import axi4_pkg::*;
#(
  parameter int          ADDR_W       = 32,
  parameter int          DATA_W       = 64,
  parameter int          ID_W         = 4,
  parameter int          STRB_W       = DATA_W/8,

  parameter logic [31:0] BASE_ADDR    = SRAM_BASE,
  parameter int          MEM_BYTES    = SRAM_SIZE,

  // Outstanding capacity, per direction.
  parameter int          AW_DEPTH     = 8,
  parameter int          AR_DEPTH     = 8,

  // Cycles from AR acceptance to the first R beat. 0 gives a same-cycle-capable
  // slave, which is the harder case for the protocol checker.
  parameter int          RD_LATENCY   = 2,

  // Exclusive-access reservation slots. One per concurrently reserving ID.
  parameter int          EXCL_SLOTS   = 4,

  // Pseudo-random READY backpressure, 0..100 percent. Off by default so early
  // tests are deterministic; the random stress tests turn it up.
  parameter int          BP_PERCENT   = 0,
  parameter int          BP_SEED      = 32'h1234_5678,

  // Optional memory preload.
  parameter string       INIT_FILE    = ""
) (
  input  logic                aclk,
  input  logic                aresetn,

  input  logic [ID_W-1:0]     awid,
  input  logic [ADDR_W-1:0]   awaddr,
  input  logic [7:0]          awlen,
  input  logic [2:0]          awsize,
  input  logic [1:0]          awburst,
  input  logic                awlock,
  input  logic [3:0]          awcache,
  input  logic [2:0]          awprot,
  input  logic                awvalid,
  output logic                awready,

  input  logic [DATA_W-1:0]   wdata,
  input  logic [STRB_W-1:0]   wstrb,
  input  logic                wlast,
  input  logic                wvalid,
  output logic                wready,

  output logic [ID_W-1:0]     bid,
  output logic [1:0]          bresp,
  output logic                bvalid,
  input  logic                bready,

  input  logic [ID_W-1:0]     arid,
  input  logic [ADDR_W-1:0]   araddr,
  input  logic [7:0]          arlen,
  input  logic [2:0]          arsize,
  input  logic [1:0]          arburst,
  input  logic                arlock,
  input  logic [3:0]          arcache,
  input  logic [2:0]          arprot,
  input  logic                arvalid,
  output logic                arready,

  output logic [ID_W-1:0]     rid,
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          rresp,
  output logic                rlast,
  output logic                rvalid,
  input  logic                rready
);

  localparam int BUS_BYTES = DATA_W/8;

  //==========================================================================
  // Memory
  //==========================================================================
  logic [7:0] mem [0:MEM_BYTES-1];

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // Absolute address -> memory index. Out-of-range is caught separately and
  // answered with SLVERR; this only has to be safe, not meaningful.
  function automatic int unsigned mem_idx(input logic [ADDR_W-1:0] a);
    return int'(a - BASE_ADDR) % MEM_BYTES;
  endfunction

  function automatic bit in_range(input logic [ADDR_W-1:0] a);
    return (a >= BASE_ADDR) && (a < (BASE_ADDR + ADDR_W'(MEM_BYTES)));
  endfunction

  //==========================================================================
  // Request descriptors
  //==========================================================================
  typedef struct packed {
    logic [ID_W-1:0]   id;
    logic [ADDR_W-1:0] addr;
    logic [7:0]        len;
    logic [2:0]        size;
    logic [1:0]        burst;
    logic              lock;
  } req_t;

  req_t              aw_q   [AW_DEPTH];
  int unsigned       aw_head, aw_tail, aw_cnt;

  req_t              ar_q   [AR_DEPTH];
  int unsigned       ar_head, ar_tail, ar_cnt;

  typedef struct packed {
    logic [ID_W-1:0] id;
    logic [1:0]      resp;
  } bresp_t;

  bresp_t            b_q    [AW_DEPTH];
  int unsigned       b_head, b_tail, b_cnt;

  //==========================================================================
  // Exclusive-access monitor
  //
  // A reservation is per (ID, address range). An exclusive read installs one; a
  // matching exclusive write consumes it and returns EXOKAY; any normal write
  // that overlaps a reservation clears it, which is what makes the classic
  // load-linked / store-conditional idiom fail correctly under contention.
  //==========================================================================
  typedef struct packed {
    logic              valid;
    logic [ID_W-1:0]   id;
    logic [ADDR_W-1:0] addr;   // aligned to the exclusive byte count
    int unsigned       bytes;
  } excl_t;

  excl_t excl [EXCL_SLOTS];

  function automatic int excl_find_id(input logic [ID_W-1:0] id);
    for (int i = 0; i < EXCL_SLOTS; i++)
      if (excl[i].valid && excl[i].id == id) return i;
    return -1;
  endfunction

  function automatic int excl_free_slot();
    for (int i = 0; i < EXCL_SLOTS; i++)
      if (!excl[i].valid) return i;
    return -1;
  endfunction

  // Reservation granule: the exclusive access is tracked at its total-byte
  // alignment, not at the raw address.
  function automatic logic [ADDR_W-1:0] excl_base(input req_t q);
    return q.addr & ~(ADDR_W'(axi_burst_bytes(q.len, q.size) - 1));
  endfunction

  // Does [lo,hi] of a write overlap reservation slot i?
  function automatic bit excl_overlaps(input int i,
                                       input logic [ADDR_W-1:0] lo,
                                       input logic [ADDR_W-1:0] hi);
    logic [ADDR_W-1:0] elo, ehi;
    if (!excl[i].valid) return 1'b0;
    elo = excl[i].addr;
    ehi = excl[i].addr + ADDR_W'(excl[i].bytes - 1);
    return !((hi < elo) || (lo > ehi));
  endfunction

  //==========================================================================
  // Pseudo-random backpressure
  //
  // A single 32-bit LFSR shared across channels, sampled with different shifts
  // so the channels do not stall in lockstep -- correlated backpressure hides
  // exactly the arbitration bugs this is meant to expose.
  //
  // bp_stall() may ONLY gate READY outputs. AXI permits READY to be withdrawn
  // freely, but forbids withdrawing VALID before its READY arrives, so gating a
  // VALID with a free-running LFSR would produce a protocol violation from the
  // DUT itself. Backpressure on the R channel is applied instead by reloading
  // the inter-beat delay counter at a beat boundary -- decided before RVALID
  // asserts, and therefore stable once it has.
  //==========================================================================
  // Backpressure percentage. BP_PERCENT is the compile-time default; a
  // simulation can override it with +SLV_BP=<0..100>, which is how a regression
  // runs the same snapshot with and without slave-side READY jitter. (The spec
  // asks for this to be test-controllable.) The override is simulation-only and
  // compiled out of synthesis.
  integer bp_pct;
  initial begin
    bp_pct = BP_PERCENT;
`ifndef SYNTHESIS
    if ($value$plusargs("SLV_BP=%d", bp_pct)) begin end
`endif
  end

  logic [31:0] lfsr;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) lfsr <= BP_SEED;
    else          lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
  end

`ifdef REPLAY_A6
  // Bug A6 as first written: the decision reads `lfsr` and `bp_pct` from module
  // scope instead of taking them as arguments. See docs/bug_replays.md.
  function automatic bit bp_stall_a6(input int unsigned shift);
    if (bp_pct <= 0) return 1'b0;
    return ((({lfsr, lfsr} >> shift) & 32'h7F) % 100) < bp_pct;
  endfunction
  `define BP_STALL(sh) bp_stall_a6(sh)
`else
  `define BP_STALL(sh) bp_stall(lfsr, bp_pct, sh)
`endif

  // READY-only. See the note above.
  //
  // Everything the decision depends on is an ARGUMENT. That matters because it is
  // called from continuous assignments: a continuous assignment re-evaluates only
  // when one of its operands changes, and variables read inside a called function
  // are not operands. The first version of this function read `lfsr` and `bp_pct`
  // directly, so awready/wready were recomputed only when aw_cnt/b_cnt moved --
  // and a READY that happened to evaluate low then stayed low forever while the
  // LFSR kept running, hanging the bus (bug A6, docs/bug_log.md).
  function automatic bit bp_stall(input logic [31:0]  l,
                                  input integer       pct,
                                  input int unsigned  shift);
    if (pct <= 0) return 1'b0;
    return ((({l, l} >> shift) & 64'h7F) % 100) < pct;
  endfunction

  // Gap to insert before the next R beat, chosen at the previous beat boundary.
  function automatic int unsigned bp_beat_delay();
    if (bp_pct <= 0) return 0;
    return ((lfsr[7:0] % 100) < bp_pct) ? (1 + (lfsr[11:8] % 3)) : 0;
  endfunction

  //==========================================================================
  // Write address channel
  //==========================================================================
  assign awready = (aw_cnt < AW_DEPTH) && !`BP_STALL(0);

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_head <= 0; aw_tail <= 0; aw_cnt <= 0;
    end
    else begin
      // Accept a new write request.
      if (awvalid && awready) begin
        aw_q[aw_tail] <= '{ id: awid, addr: awaddr, len: awlen,
                            size: awsize, burst: awburst, lock: awlock };
        aw_tail <= (aw_tail + 1) % AW_DEPTH;
      end

      // Retire on WLAST (handled in the write-data block below).
      if (wvalid && wready && wlast)
        aw_head <= (aw_head + 1) % AW_DEPTH;

      aw_cnt <= aw_cnt + ((awvalid && awready) ? 1 : 0)
                       - ((wvalid && wready && wlast) ? 1 : 0);
    end
  end

  //==========================================================================
  // Write data channel
  //
  // W beats belong to the oldest outstanding AW from this master. AXI4 removed
  // write interleaving, so head-of-queue association is exact -- there is no
  // WID to match against and none is needed.
  //==========================================================================
  int unsigned w_beat;
  logic        w_excl_pass;   // latched at the first beat of an exclusive write
  logic        w_range_bad;

  assign wready = (aw_cnt != 0) && (b_cnt < AW_DEPTH) && !`BP_STALL(5);

  always_ff @(posedge aclk or negedge aresetn) begin
    int                     slot;
    req_t                   cur;
    logic [ADDR_W-1:0]      beat_addr, bus_base, ex_lo, ex_hi;
    int unsigned            lo, hi, idx;
    logic [1:0]             resp;
    bit                     excl_ok;

    if (!aresetn) begin
      w_beat      <= 0;
      w_excl_pass <= 1'b0;
      w_range_bad <= 1'b0;
      for (int i = 0; i < EXCL_SLOTS; i++) excl[i] <= '0;
      b_head <= 0; b_tail <= 0; b_cnt <= 0;
    end
    else begin
      //----------------------------------------------------------------------
      // Install a reservation on an exclusive read.
      //----------------------------------------------------------------------
      if (arvalid && arready && arlock) begin
        slot = excl_find_id(arid);
        if (slot < 0) slot = excl_free_slot();
        // With no free slot the oldest reservation is simply not installed;
        // the subsequent exclusive write then fails, which is a legal outcome.
        if (slot >= 0) begin
          excl[slot] <= '{ valid: 1'b1,
                           id:    arid,
                           addr:  araddr & ~(ADDR_W'(axi_burst_bytes(arlen, arsize) - 1)),
                           bytes: axi_burst_bytes(arlen, arsize) };
        end
      end

      //----------------------------------------------------------------------
      // Consume a write beat.
      //----------------------------------------------------------------------
      if (wvalid && wready) begin
        cur       = aw_q[aw_head];
        beat_addr = axi_beat_addr(cur.addr, cur.len, cur.size, cur.burst, w_beat);
        bus_base  = beat_addr & ~(ADDR_W'(BUS_BYTES - 1));
        axi_byte_lanes(cur.addr, cur.len, cur.size, cur.burst,
                       w_beat, BUS_BYTES, lo, hi);

        // Evaluate the exclusive check once, at the first beat -- the point at
        // which the write actually begins to take effect. Checking at AW accept
        // would be wrong: an intervening write between AW and W must be able to
        // break the reservation.
        //
        // The decision is computed here and latched so that every beat of the
        // burst AND the final BRESP all use the same answer. A fresh lookup per
        // beat would let a mid-burst reservation change split one transaction
        // across both outcomes -- partially written memory with an EXOKAY, or
        // an untouched memory with an OKAY that the master cannot distinguish
        // from a genuine failure.
        if (w_beat == 0) begin
          slot        = cur.lock ? excl_find_id(cur.id) : -1;
          excl_ok     = cur.lock && (slot >= 0) &&
                        (excl[slot].addr == excl_base(cur));
          w_excl_pass <= excl_ok;
          w_range_bad <= !in_range(cur.addr);
        end
        else begin
          excl_ok = w_excl_pass;
        end

        // Commit bytes. An exclusive write that failed its check must leave
        // memory untouched -- that is the entire point of the mechanism.
        if (in_range(beat_addr) && (!cur.lock || excl_ok)) begin
          for (int i = int'(lo); i <= int'(hi); i++) begin
            if (wstrb[i]) begin
              idx = mem_idx(bus_base + ADDR_W'(i));
              mem[idx] <= wdata[8*i +: 8];
            end
          end
        end

        //--------------------------------------------------------------------
        // Any write that actually changes memory clears overlapping reservations
        // -- a normal write, and also a SUCCESSFUL exclusive write, which is a
        // write like any other as far as everyone else's reservation is concerned
        // (bug A5). A failed exclusive write changes nothing, so it clears
        // nothing.
        //--------------------------------------------------------------------
`ifdef REPLAY_A5
        if (!cur.lock) begin                // original behaviour, kept for replay
`else
        if (!cur.lock || excl_ok) begin
`endif
          ex_lo = bus_base + ADDR_W'(lo);
          ex_hi = bus_base + ADDR_W'(hi);
          for (int i = 0; i < EXCL_SLOTS; i++)
            if (excl_overlaps(i, ex_lo, ex_hi)) excl[i].valid <= 1'b0;
        end

        //--------------------------------------------------------------------
        // Burst end: form the response and retire.
        //--------------------------------------------------------------------
        if (wlast) begin
          if (!in_range(cur.addr))      resp = AXI_RESP_SLVERR;
          else if (cur.lock) begin
            // The same latched decision that gated the memory write above.
            resp = excl_ok ? AXI_RESP_EXOKAY : AXI_RESP_OKAY;
            // A completed exclusive write consumes its reservation either way.
            slot = excl_find_id(cur.id);
            if (slot >= 0) excl[slot].valid <= 1'b0;
          end
          else                          resp = AXI_RESP_OKAY;

          b_q[b_tail] <= '{ id: cur.id, resp: resp };
          b_tail      <= (b_tail + 1) % AW_DEPTH;
          w_beat      <= 0;
        end
        else begin
          w_beat <= w_beat + 1;
        end
      end

      //----------------------------------------------------------------------
      // B queue accounting
      //----------------------------------------------------------------------
      if (bvalid && bready) b_head <= (b_head + 1) % AW_DEPTH;

      b_cnt <= b_cnt + ((wvalid && wready && wlast) ? 1 : 0)
                     - ((bvalid && bready)          ? 1 : 0);
    end
  end

  //==========================================================================
  // Write response channel
  //==========================================================================
  assign bvalid = (b_cnt != 0);
  assign bid    = b_q[b_head].id;
  assign bresp  = b_q[b_head].resp;

  //==========================================================================
  // Read address channel
  //==========================================================================
  assign arready = (ar_cnt < AR_DEPTH) && !`BP_STALL(11);

  //==========================================================================
  // Read data channel
  //==========================================================================
  int unsigned r_beat;
  int unsigned r_delay;
  logic        r_active;

  req_t        r_cur;
  assign       r_cur = ar_q[ar_head];

  // Assemble one beat straight out of the byte array. Bytes outside the active
  // lanes are driven to zero rather than X: the scoreboard masks to the lanes
  // anyway, and X here would trip the checker's no-X-while-RVALID property for
  // no diagnostic gain.
  function automatic logic [DATA_W-1:0] read_beat(input req_t q,
                                                  input int unsigned beat);
    logic [ADDR_W-1:0] beat_addr, bus_base;
    int unsigned       lo, hi;
    logic [DATA_W-1:0] d;

    d         = '0;
    beat_addr = axi_beat_addr(q.addr, q.len, q.size, q.burst, beat);
    bus_base  = beat_addr & ~(ADDR_W'(BUS_BYTES - 1));
    axi_byte_lanes(q.addr, q.len, q.size, q.burst, beat, BUS_BYTES, lo, hi);

    for (int i = int'(lo); i <= int'(hi); i++)
      if (in_range(bus_base + ADDR_W'(i)))
        d[8*i +: 8] = mem[mem_idx(bus_base + ADDR_W'(i))];

    return d;
  endfunction

  assign rvalid = r_active && (r_delay == 0);
  assign rid    = r_cur.id;
  assign rlast  = r_active && (r_beat == int'(r_cur.len));
  assign rdata  = read_beat(r_cur, r_beat);
  assign rresp  = !in_range(r_cur.addr) ? AXI_RESP_SLVERR
                : (r_cur.lock           ? AXI_RESP_EXOKAY   // exclusive reads
                                        : AXI_RESP_OKAY);   // always succeed

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      ar_head <= 0; ar_tail <= 0; ar_cnt <= 0;
      r_beat  <= 0; r_delay <= 0; r_active <= 1'b0;
    end
    else begin
      if (arvalid && arready) begin
        ar_q[ar_tail] <= '{ id: arid, addr: araddr, len: arlen,
                            size: arsize, burst: arburst, lock: arlock };
        ar_tail <= (ar_tail + 1) % AR_DEPTH;
      end

      // Start the next read once the queue is non-empty.
      if (!r_active && (ar_cnt != 0)) begin
        r_active <= 1'b1;
        r_beat   <= 0;
        r_delay  <= RD_LATENCY;
      end
      else if (r_active && (r_delay != 0)) begin
        r_delay <= r_delay - 1;
      end
      else if (rvalid && rready) begin
        if (rlast) begin
          r_active <= 1'b0;
          r_beat   <= 0;
          ar_head  <= (ar_head + 1) % AR_DEPTH;
        end
        else begin
          r_beat  <= r_beat + 1;
          r_delay <= bp_beat_delay();   // decided before the next RVALID rises
        end
      end

      ar_cnt <= ar_cnt + ((arvalid && arready)          ? 1 : 0)
                       - ((rvalid && rready && rlast)   ? 1 : 0);
    end
  end

endmodule : axi4_sram_ctrl

`endif // AXI4_SRAM_CTRL_SV
