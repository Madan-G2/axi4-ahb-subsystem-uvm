//==============================================================================
// axi2ahb_bridge.sv
//
// AXI4 slave (64-bit) to AHB-Lite master (32-bit).
//
// The interesting work is turning one AXI transaction into a legal sequence of
// AHB transfers. Two engines do it:
//
//   UNIFORM path  -- full 64-bit beats, aligned, and (for writes) every strobe
//                    set. The AHB sequence is then a clean run of word
//                    transfers, so a real HBURST can be used: WRAP4/8/16 for a
//                    mappable AXI WRAP, INCR4/8/16 for an exact aligned length,
//                    otherwise undefined-length INCR.
//
//   GENERAL path  -- everything else: narrow AxSIZE, unaligned starts, sparse
//                    WSTRB, FIXED bursts, and 16-beat WRAPs. Walks the active
//                    bytes of each beat and emits the largest aligned run that
//                    is entirely enabled, as SINGLE transfers.
//
// WHY THE GENERAL PATH EXISTS AT ALL: AHB-Lite has no write strobes. A partial
// WSTRB cannot be expressed as a word transfer, so it has to be decomposed into
// narrower transfers that write only the enabled bytes. Getting this wrong
// silently corrupts the bytes that should not have been written -- which the
// scoreboard catches, but only if the stimulus produces sparse strobes.
//
// THE 1KB RULE: AHB forbids a burst crossing a 1KB address boundary, where AXI
// only forbids 4KB. An AXI INCR burst that is perfectly legal can therefore
// still need splitting into several AHB bursts. Undefined-length INCR restarts
// with NONSEQ at each 1KB boundary; the fixed-length forms are only selected
// when alignment makes a crossing impossible.
//
// STORE AND FORWARD: write data is fully collected before any AHB transfer
// starts, and read data is fully collected before any R beat is returned. A
// production bridge would stream to save the buffer. Buffering makes the beat
// bookkeeping obviously correct and keeps the FSM small enough to hand to VC
// Formal in Phase 7, which is worth more here than the area.
//==============================================================================
`ifndef AXI2AHB_BRIDGE_SV
`define AXI2AHB_BRIDGE_SV

module axi2ahb_bridge
  import axi4_pkg::*;
  import ahb_pkg::*;
#(
  parameter int ADDR_W    = 32,
  parameter int DATA_W    = 64,
  parameter int ID_W      = 6,
  parameter int STRB_W    = DATA_W/8,
  parameter int MAX_BEATS = 256
) (
  input  logic                aclk,
  input  logic                aresetn,

  // AXI4 slave port
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
  input  logic                rready,

  // AHB-Lite master port
  output logic [31:0]         haddr,
  output logic [1:0]          htrans,
  output logic                hwrite,
  output logic [2:0]          hsize,
  output logic [2:0]          hburst,
  output logic [31:0]         hwdata,
  input  logic [31:0]         hrdata,
  input  logic                hready,
  input  logic                hresp
);

  //==========================================================================
  // Transaction context
  //==========================================================================
  typedef enum logic [2:0] {
    ST_IDLE, ST_WCOLLECT, ST_AHB, ST_ERRWAIT, ST_BRESP, ST_RDRAIN
  } st_e;

  st_e                st;

  logic [ID_W-1:0]    t_id;
  logic [ADDR_W-1:0]  t_addr;
  logic [7:0]         t_len;
  logic [2:0]         t_size;
  logic [1:0]         t_burst;
  logic               t_write;
  logic               t_err;

  logic [DATA_W-1:0]  wbuf [MAX_BEATS];
  logic [STRB_W-1:0]  sbuf [MAX_BEATS];
  logic [DATA_W-1:0]  rbuf [MAX_BEATS];

  logic [8:0]         w_cnt;      // W beats collected
  logic [8:0]         r_cnt;      // R beats emitted

  //==========================================================================
  // Uniform-path detection
  //==========================================================================
  logic               uni;        // this transaction can use real AHB bursts
  logic [9:0]         uni_words;  // AHB word transfers in the sequence
  logic [2:0]         uni_hburst;
  logic [31:0]        uni_lower;  // WRAP container base
  logic [31:0]        uni_cont;   // WRAP container size

  function automatic bit strobes_full(input logic [8:0] n);
    for (int i = 0; i < MAX_BEATS; i++)
      if (i < int'(n) && sbuf[i] != {STRB_W{1'b1}}) return 1'b0;
    return 1'b1;
  endfunction

  //==========================================================================
  // AHB sequence pointers
  //==========================================================================
  logic [9:0]         ah_i;       // uniform: word index
  logic [8:0]         g_beat;     // general: AXI beat index
  logic [3:0]         g_byte;     // general: byte pointer within the 64b bus
  logic               seq_done;   // no more transfers to issue

  // Address phase presented this cycle
  logic [31:0]        ap_addr;
  logic [2:0]         ap_size;
  logic [1:0]         ap_trans;
  logic [2:0]         ap_burst;
  logic [31:0]        ap_wdata;
  logic [3:0]         ap_run;     // bytes moved by this transfer (1, 2 or 4)
  logic [3:0]         ap_step;    // how far the byte pointer advances

  // Data phase in flight
  logic               dp_val;
  logic               dp_read;
  logic [31:0]        dp_wdata;
  logic [8:0]         dp_beat;
  logic [3:0]         dp_lane;    // lane within the 64-bit AXI word
  logic [2:0]         dp_size;
  logic [31:0]        dp_addr;
  logic [3:0]         dp_run;

  //--------------------------------------------------------------------------
  // General path: for AXI beat `b`, which bytes of the 64-bit bus are active,
  // and is byte `p` enabled?
  //--------------------------------------------------------------------------
  function automatic bit byte_enabled(input logic [8:0] b, input int p);
    int unsigned lo, hi;
    axi_byte_lanes(t_addr, t_len, t_size, t_burst, int'(b), STRB_W, lo, hi);
    if (p < int'(lo) || p > int'(hi)) return 1'b0;
    if (t_write) return sbuf[b][p];
    return 1'b1;
  endfunction

  // Largest aligned, fully-enabled run of 4 / 2 / 1 bytes starting at p.
  function automatic int unsigned run_at(input logic [8:0] b, input int p,
                                         input logic [31:0] base);
    bit ok;
    for (int s = 4; s >= 1; s = s >> 1) begin
      if (((base + 32'(p)) % 32'(s)) == 0 && (p + s) <= STRB_W) begin
        ok = 1'b1;
        for (int k = 0; k < s; k++) if (!byte_enabled(b, p + k)) ok = 1'b0;
        if (ok) return s;
      end
    end
    return 0;
  endfunction

  function automatic logic [31:0] bus_base_of(input logic [8:0] b);
    return axi_beat_addr(t_addr, t_len, t_size, t_burst, int'(b)) &
           ~(ADDR_W'(STRB_W - 1));
  endfunction

  //==========================================================================
  // Address-phase generation
  //==========================================================================
  always_comb begin
    logic [31:0] base;
    int unsigned run;

    ap_addr  = '0;
    ap_size  = HSIZE_WORD;
    ap_trans = HTRANS_IDLE;
    ap_burst = HBURST_SINGLE;
    ap_wdata = '0;
    ap_run   = 4'd0;
    ap_step  = 4'd1;

    if ((st == ST_AHB) && !seq_done && !t_err) begin
      if (uni) begin
        //--------------------------------------------------------------------
        // Uniform: one word per transfer, addresses following the AXI burst.
        //--------------------------------------------------------------------
        if (t_burst == AXI_BURST_WRAP)
          ap_addr = uni_lower | ((t_addr + 32'(ah_i) * 32'd4) & (uni_cont - 32'd1));
        else
          ap_addr = t_addr + 32'(ah_i) * 32'd4;

        ap_size  = HSIZE_WORD;
        ap_burst = uni_hburst;

        // NONSEQ for the first transfer, and again after a 1KB boundary when
        // running an undefined-length INCR (AHB forbids a burst crossing 1KB).
        if (ah_i == 0)
          ap_trans = HTRANS_NONSEQ;
        else if ((uni_hburst == HBURST_INCR) && (ap_addr[9:0] == 10'd0))
          ap_trans = HTRANS_NONSEQ;
        else
          ap_trans = HTRANS_SEQ;

        ap_run   = 4'd4;
        ap_step  = 4'd4;
        ap_wdata = ap_addr[2] ? wbuf[ah_i >> 1][63:32] : wbuf[ah_i >> 1][31:0];
      end
      else begin
        //--------------------------------------------------------------------
        // General: walk the active bytes of the current beat.
        //--------------------------------------------------------------------
        base = bus_base_of(g_beat);
        run  = run_at(g_beat, int'(g_byte), base);
        // A disabled byte still advances the pointer by one; it is skipped, not
        // re-examined.
`ifdef REPLAY_A3
        // Bug A3 as first written: a disabled byte skipped the rest of the beat.
        ap_step = (run == 0) ? 4'd8 : 4'(run);
`else
        ap_step = (run == 0) ? 4'd1 : 4'(run);
`endif
        if (run != 0) begin
          ap_addr  = base + 32'(g_byte);
          ap_size  = (run == 4) ? HSIZE_WORD : (run == 2) ? HSIZE_HALF : HSIZE_BYTE;
          ap_trans = HTRANS_NONSEQ;      // always SINGLE on this path
          ap_burst = HBURST_SINGLE;
          ap_run   = 4'(run);
          // Place the bytes on the lanes AHB expects for this address.
          for (int k = 0; k < 4; k++)
            if (k < int'(run))
              ap_wdata[8*((int'(ap_addr[1:0]) + k) % 4) +: 8] =
                  wbuf[g_beat][8*(int'(g_byte) + k) +: 8];
        end
      end
    end
  end

  assign haddr  = ap_addr;
  assign htrans = ap_trans;
  assign hsize  = ap_size;
  assign hburst = ap_burst;
  assign hwrite = t_write;
  assign hwdata = dp_wdata;

  //==========================================================================
  // AXI handshakes
  //==========================================================================
  assign awready = (st == ST_IDLE) && awvalid;
  assign arready = (st == ST_IDLE) && !awvalid && arvalid;
  assign wready  = (st == ST_WCOLLECT);
  assign bvalid  = (st == ST_BRESP);
  assign bid     = t_id;
  assign bresp   = t_err ? AXI_RESP_SLVERR : AXI_RESP_OKAY;

  assign rvalid  = (st == ST_RDRAIN);
  assign rid     = t_id;
  assign rdata   = rbuf[r_cnt];
  assign rresp   = t_err ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
  assign rlast   = (st == ST_RDRAIN) && (r_cnt == {1'b0, t_len});

  // First cycle of the AHB two-cycle ERROR response.
  wire err_p1 = dp_val && !hready && hresp;

  //==========================================================================
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      st       <= ST_IDLE;
      w_cnt    <= '0;
      r_cnt    <= '0;
      ah_i     <= '0;
      g_beat   <= '0;
      g_byte   <= '0;
      dp_val   <= 1'b0;
      t_err    <= 1'b0;
      seq_done <= 1'b0;
    end
    else begin
      unique case (st)
        //--------------------------------------------------------------------
        ST_IDLE: begin
          dp_val   <= 1'b0;
          t_err    <= 1'b0;
          seq_done <= 1'b0;
          ah_i     <= '0;
          g_beat   <= '0;
          g_byte   <= '0;
          r_cnt    <= '0;
          w_cnt    <= '0;

          if (awvalid && awready) begin
            t_id <= awid; t_addr <= awaddr; t_len <= awlen;
            t_size <= awsize; t_burst <= awburst; t_write <= 1'b1;
            st <= ST_WCOLLECT;
          end
          else if (arvalid && arready) begin
            t_id <= arid; t_addr <= araddr; t_len <= arlen;
            t_size <= arsize; t_burst <= arburst; t_write <= 1'b0;
            st <= ST_AHB;
          end
        end

        //--------------------------------------------------------------------
        // Collect the whole write burst before touching AHB.
        //--------------------------------------------------------------------
        ST_WCOLLECT: begin
          if (wvalid && wready) begin
            wbuf[w_cnt] <= wdata;
            sbuf[w_cnt] <= wstrb;
            w_cnt       <= w_cnt + 9'd1;
            if (wlast) st <= ST_AHB;
          end
        end

        //--------------------------------------------------------------------
        ST_AHB: begin
          // Two-cycle ERROR: cancel the next address phase now, then wait for
          // the second cycle before finishing the transaction.
          if (err_p1) begin
            t_err    <= 1'b1;
            seq_done <= 1'b1;
            dp_val   <= 1'b0;
            st       <= ST_ERRWAIT;
          end
          else if (hready) begin
            // Retire the data phase that just completed.
            // Read capture. AHB places a byte on the lane its address selects,
            // so the bytes have to be rotated back to the AXI lanes they belong
            // to -- and only the bytes this transfer actually moved.
            //
            // The previous form wrote a fixed 32 bits at 8*(lane & 7), which
            // both ignored that rotation and ran off the end of the 64-bit word
            // whenever the lane was 5 or above. It showed up as reads returning
            // zeros in the upper lanes.
`ifdef REPLAY_A2
            // Bug A2 as first written: a fixed 32 bits at 8*(lane & 7) -- no byte
            // rotation, and past the end of the 64-bit word for lane >= 5.
            if (dp_val && dp_read)
              rbuf[dp_beat][8*(int'(dp_lane) & 7) +: 32] <= hrdata;
`else
            if (dp_val && dp_read) begin
              for (int k = 0; k < 4; k++)
                if (k < int'(dp_run))
                  rbuf[dp_beat][8*(int'(dp_lane) + k) +: 8] <=
                      hrdata[8*((int'(dp_addr[1:0]) + k) % 4) +: 8];
            end
`endif

            // Launch the address phase presented this cycle.
            dp_val   <= (ap_trans != HTRANS_IDLE);
            dp_read  <= !t_write;
            dp_wdata <= ap_wdata;
            dp_beat  <= uni ? (ah_i >> 1) : g_beat;
            dp_lane  <= uni ? {2'b00, ah_i[0], 2'b00} : g_byte;
            dp_size  <= ap_size;
            dp_addr  <= ap_addr;
            dp_run   <= ap_run;

            //----------------------------------------------------------------
            // Advance the sequence pointer.
            //
            // The general path advances whether or not a transfer was issued.
            // A byte with its strobe clear, or outside the beat's active lanes,
            // is simply stepped over -- the earlier version jumped to the next
            // BEAT instead of the next BYTE, so any beat whose first lane was
            // inactive (every unaligned or narrow beat) was discarded whole.
            //----------------------------------------------------------------
            if (uni) begin
              if (ap_trans != HTRANS_IDLE) begin
                if (ah_i + 10'd1 >= uni_words) seq_done <= 1'b1;
                ah_i <= ah_i + 10'd1;
              end
            end
`ifdef REPLAY_A4
            // Bug A4 as first written: the step was recomputed here into an
            // automatic variable WITH AN INITIALIZER. XSim does not evaluate that
            // initializer on every execution, so the variable goes stale and the
            // pointer advances by the wrong amount for the rest of the beat.
            else if (!seq_done) begin
              automatic int unsigned run_a4  = run_at(g_beat, int'(g_byte), bus_base_of(g_beat));
              automatic logic [3:0]  step_a4 = (run_a4 == 0) ? 4'd1 : 4'(run_a4);
              if ((int'(g_byte) + int'(step_a4)) >= STRB_W) begin
                g_byte <= '0;
                if (g_beat == {1'b0, t_len}) seq_done <= 1'b1;
                else                         g_beat <= g_beat + 9'd1;
              end
              else begin
                g_byte <= g_byte + step_a4;
              end
            end
`else
            else if (!seq_done) begin
              // ap_step comes from the same always_comb evaluation that chose
              // the transfer, so the pointer cannot advance by a different
              // amount than the transfer actually covered.
              //
              // This was previously recomputed here into an `automatic`
              // variable with an initializer. XSim does not re-evaluate such an
              // initializer on each execution of the block -- the variable went
              // stale, so the pointer stepped by the wrong amount. A 2-byte
              // transfer could be followed by a 1-byte transfer over its own
              // second byte, or a byte could be stepped over and never
              // emitted at all.
              if ((int'(g_byte) + int'(ap_step)) >= STRB_W) begin
                g_byte <= '0;
                if (g_beat == {1'b0, t_len}) seq_done <= 1'b1;
                else                         g_beat <= g_beat + 9'd1;
              end
              else begin
                g_byte <= g_byte + ap_step;
              end
            end
`endif

            // Sequence fully issued and the last data phase has drained.
            if (seq_done && (ap_trans == HTRANS_IDLE) && !dp_val)
              st <= t_write ? ST_BRESP : ST_RDRAIN;
          end
        end

        //--------------------------------------------------------------------
        // Second cycle of the AHB ERROR response.
        //--------------------------------------------------------------------
        ST_ERRWAIT: begin
          if (hready) st <= t_write ? ST_BRESP : ST_RDRAIN;
        end

        //--------------------------------------------------------------------
        ST_BRESP: if (bvalid && bready) st <= ST_IDLE;

        //--------------------------------------------------------------------
        // Every R beat the master asked for is returned, even when the AHB
        // burst was aborted part-way. A short read burst hangs the master.
        //--------------------------------------------------------------------
        ST_RDRAIN: if (rvalid && rready) begin
          if (rlast) st    <= ST_IDLE;
          else       r_cnt <= r_cnt + 9'd1;
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

  //==========================================================================
  // Uniform-path decision, evaluated as the AHB sequence starts.
  //==========================================================================
  always_comb begin
    int unsigned words;
    int unsigned cont;

    uni        = 1'b0;
    uni_words  = '0;
    uni_hburst = HBURST_SINGLE;
    uni_lower  = '0;
    uni_cont   = '0;

    words = (int'(t_len) + 1) * 2;

    if ((t_size == 3'd3) && ((t_addr & 32'd7) == 32'd0) &&
        (t_burst != AXI_BURST_FIXED) &&
        (!t_write || strobes_full({1'b0, t_len} + 9'd1))) begin

      if (t_burst == AXI_BURST_WRAP) begin
        cont = (int'(t_len) + 1) * 8;
        // AHB tops out at WRAP16, so a 16-beat 64-bit WRAP (32 words) has no
        // equivalent and falls through to the general path.
        if (words inside {4, 8, 16}) begin
          uni        = 1'b1;
          uni_words  = 10'(words);
          uni_cont   = 32'(cont);
          uni_lower  = t_addr & ~(32'(cont) - 32'd1);
          uni_hburst = (words == 4)  ? HBURST_WRAP4  :
                       (words == 8)  ? HBURST_WRAP8  : HBURST_WRAP16;
        end
      end
      else begin
        uni       = 1'b1;
        uni_words = 10'(words);
        // A fixed-length burst is only safe when alignment guarantees it
        // cannot cross a 1KB boundary; otherwise use undefined-length INCR,
        // which may be broken at the boundary with a fresh NONSEQ.
        if ((words inside {4, 8, 16}) &&
            ((t_addr & (32'(words) * 32'd4 - 32'd1)) == 32'd0))
          uni_hburst = (words == 4)  ? HBURST_INCR4  :
                       (words == 8)  ? HBURST_INCR8  : HBURST_INCR16;
        else                 uni_hburst = HBURST_INCR;   // (words is (len+1)*2: never 1)
      end
    end
  end

endmodule : axi2ahb_bridge

`endif // AXI2AHB_BRIDGE_SV
