//==============================================================================
// ahb_cov.sv
//
// Functional coverage for the AHB-Lite side of the AXI2AHB bridge: what the
// bridge actually drives on the AHB bus, and how it relates to the AXI request
// that caused it.
//
// Observation only. Sampled on the bridge's AHB master port plus the AXI
// request fields at the crossbar's S1 slave port.
//==============================================================================
`ifndef AHB_COV_SV
`define AHB_COV_SV

module ahb_cov (
  input logic        hclk,
  input logic        hresetn,

  // AHB-Lite bus (the bridge is the only master)
  input logic [31:0] haddr,
  input logic [1:0]  htrans,
  input logic        hwrite,
  input logic [2:0]  hsize,
  input logic [2:0]  hburst,
  input logic        hready,
  input logic        hresp,

  // AXI requests arriving at the bridge
  input logic        aw_hs,
  input logic [1:0]  aw_burst,
  input logic [2:0]  aw_size,
  input logic        ar_hs,
  input logic [1:0]  ar_burst,
  input logic [2:0]  ar_size
);

  //--------------------------------------------------------------------------
  // Data-phase tracking. An address phase accepted on a cycle where HREADY is
  // high becomes the data phase on the next cycle; its length in wait states is
  // the number of consecutive cycles HREADY then stays low.
  //--------------------------------------------------------------------------
  logic       dp_act, dp_wr;
  logic [4:0] wcnt;
  logic [7:0] beat_idx, dp_beat;

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) begin
      dp_act   <= 1'b0;
      dp_wr    <= 1'b0;
      wcnt     <= 5'd0;
      beat_idx <= 8'd0;
      dp_beat  <= 8'd0;
    end
    else begin
      if (hready) begin
        dp_act <= htrans[1];            // NONSEQ or SEQ starts a data phase
        dp_wr  <= hwrite;
        wcnt   <= 5'd0;
        if (htrans == 2'b10)      begin dp_beat <= 8'd0;     beat_idx <= 8'd1; end
        else if (htrans == 2'b11) begin dp_beat <= beat_idx; beat_idx <= beat_idx + 8'd1; end
      end
      else if (dp_act) begin
        wcnt <= (wcnt == 5'd31) ? wcnt : wcnt + 5'd1;
      end
    end
  end

  wire dp_done   = hresetn & hready & dp_act;           // a data phase ends now
  wire addr_acc  = hresetn & hready;                    // an address phase is taken
  wire first_xfr = addr_acc & (htrans == 2'b10);        // NONSEQ accepted

  //--------------------------------------------------------------------------
  // What the bridge drives
  //--------------------------------------------------------------------------
  covergroup cg_ahb_trans @(posedge hclk);
    // BUSY is deliberately absent. The bridge is the only AHB master and never
    // inserts BUSY cycles, so no stimulus can produce one; see
    // docs/coverage_plan.md. It also means the slaves' BUSY handling is untested.
    cp_htrans : coverpoint htrans iff (addr_acc) {
      bins idle = {2'b00}; bins nonseq = {2'b10}; bins seq = {2'b11}; }

    cp_flow : coverpoint htrans iff (addr_acc) {
      bins idle_to_nonseq    = (2'b00 => 2'b10);
      bins nonseq_to_seq     = (2'b10 => 2'b11);
      bins seq_to_seq        = (2'b11 => 2'b11);
      bins seq_to_nonseq     = (2'b11 => 2'b10);   // 1KB restart, or next transaction
      bins nonseq_to_nonseq  = (2'b10 => 2'b10);   // back-to-back SINGLEs
      bins nonseq_to_idle    = (2'b10 => 2'b00);
      bins seq_to_idle       = (2'b11 => 2'b00);
      illegal_bins idle_to_seq = (2'b00 => 2'b11); // SEQ with no preceding NONSEQ
    }
  endgroup
  cg_ahb_trans cg_ahb_trans_i = new();

  covergroup cg_ahb_burst @(posedge hclk);
    cp_hburst : coverpoint hburst iff (first_xfr) {
      bins single = {3'b000}; bins incr   = {3'b001};
      bins wrap4  = {3'b010}; bins incr4  = {3'b011};
      bins wrap8  = {3'b100}; bins incr8  = {3'b101};
      bins wrap16 = {3'b110}; bins incr16 = {3'b111}; }
    cp_hsize  : coverpoint hsize iff (first_xfr) {
      bins byte_ = {3'd0}; bins half = {3'd1}; bins word = {3'd2}; }
    cp_rw     : coverpoint hwrite iff (first_xfr) {
      bins read = {1'b0}; bins write = {1'b1}; }

    // burst form x transfer width x direction, as ONE coverpoint of explicit bins.
    //
    // This used to be a cross with ignore_bins. XSim's report prints the
    // uncovered bins of such a cross in a compressed form that silently drops
    // some of them (it listed 9 of 10), which the report parser's self-check
    // against XSim's own totals caught. Plain bins are listed one by one and
    // cannot be mis-compressed.
    //
    // Only SINGLE can be narrower than a word: the burst forms are built from full
    // 32-bit transfers, and anything narrow goes through the byte-walking path as
    // SINGLEs. Those narrow-burst combinations are impossible, so are not bins.
    cp_form : coverpoint {hburst, hsize[1:0], hwrite} iff (first_xfr) {
      bins single_byte_rd  = {{3'b000, 2'd0, 1'b0}};  bins single_byte_wr  = {{3'b000, 2'd0, 1'b1}};
      bins single_half_rd  = {{3'b000, 2'd1, 1'b0}};  bins single_half_wr  = {{3'b000, 2'd1, 1'b1}};
      bins single_word_rd  = {{3'b000, 2'd2, 1'b0}};  bins single_word_wr  = {{3'b000, 2'd2, 1'b1}};
      bins incr_word_rd    = {{3'b001, 2'd2, 1'b0}};  bins incr_word_wr    = {{3'b001, 2'd2, 1'b1}};
      bins wrap4_word_rd   = {{3'b010, 2'd2, 1'b0}};  bins wrap4_word_wr   = {{3'b010, 2'd2, 1'b1}};
      bins incr4_word_rd   = {{3'b011, 2'd2, 1'b0}};  bins incr4_word_wr   = {{3'b011, 2'd2, 1'b1}};
      bins wrap8_word_rd   = {{3'b100, 2'd2, 1'b0}};  bins wrap8_word_wr   = {{3'b100, 2'd2, 1'b1}};
      bins incr8_word_rd   = {{3'b101, 2'd2, 1'b0}};  bins incr8_word_wr   = {{3'b101, 2'd2, 1'b1}};
      bins wrap16_word_rd  = {{3'b110, 2'd2, 1'b0}};  bins wrap16_word_wr  = {{3'b110, 2'd2, 1'b1}};
      bins incr16_word_rd  = {{3'b111, 2'd2, 1'b0}};  bins incr16_word_wr  = {{3'b111, 2'd2, 1'b1}};
    }
  endgroup
  cg_ahb_burst cg_ahb_burst_i = new();

  covergroup cg_ahb_wait @(posedge hclk);
    cp_wait : coverpoint wcnt iff (dp_done && !hresp) {
      bins w0 = {0}; bins w1 = {1}; bins w2 = {2}; bins w3 = {3};
      bins w4_7 = {[4:7]}; bins w8_15 = {[8:15]};
      // 15 is the most the slave can insert (addr[7:4]), so there is no 16+ bin. A
      // larger count would mean the bridge or the slave is holding HREADY low
      // for a reason other than a programmed wait state: that is a checker's
      // business (a bounded-wait assertion), not a coverage bin.
    }
  endgroup
  cg_ahb_wait cg_ahb_wait_i = new();

  covergroup cg_ahb_resp @(posedge hclk);
    cp_resp : coverpoint hresp iff (dp_done) {
      bins okay = {1'b0}; bins error = {1'b1}; }
    cp_dir  : coverpoint dp_wr iff (dp_done) {
      bins read = {1'b0}; bins write = {1'b1}; }
    // Which transfer of the burst took the ERROR. The error zones are 512 bytes, so a
    // burst that runs into one does so on an 8-byte boundary, i.e. an EVEN word index
    // (2 after the first dword, 4, 6, ...): index 1 cannot be produced, and a bin for
    // it would sit empty forever. Bins are therefore first / near the start / later.
    cp_err_beat : coverpoint dp_beat iff (dp_done && hresp) {
      bins first = {0}; bins near_start = {[1:2]}; bins later = {[3:255]}; }
    x_resp_dir : cross cp_resp, cp_dir;
  endgroup
  cg_ahb_resp cg_ahb_resp_i = new();

  //--------------------------------------------------------------------------
  // AXI request -> AHB burst conversion matrix.
  //
  // The bridge handles one AXI transaction at a time, so a single capture slot
  // is enough: latch the request at the AXI handshake, and sample it against the
  // first NONSEQ the bridge then drives.
  //--------------------------------------------------------------------------
  logic       rq_val, rq_rw;
  logic [1:0] rq_burst;
  logic [2:0] rq_size;

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) begin
      rq_val <= 1'b0; rq_rw <= 1'b0; rq_burst <= 2'b00; rq_size <= 3'd0;
    end
    else begin
      if (aw_hs) begin
        rq_val <= 1'b1; rq_rw <= 1'b1; rq_burst <= aw_burst; rq_size <= aw_size;
      end
      else if (ar_hs) begin
        rq_val <= 1'b1; rq_rw <= 1'b0; rq_burst <= ar_burst; rq_size <= ar_size;
      end
      else if (first_xfr && rq_val) begin
        rq_val <= 1'b0;
      end
    end
  end

  // key = {AXI burst, AXI size, AHB HBURST}. Only the combinations the bridge
  // can legitimately produce are listed; see the table in docs/coverage_plan.md.
  wire [7:0] conv_key = {1'b0, rq_burst, rq_size[1:0], hburst};   // 8 bits wide
  wire       conv_ev  = first_xfr & rq_val;

  covergroup cg_conv @(posedge hclk);
    cp_conv : coverpoint conv_key iff (conv_ev) {
      // FIXED has no AHB equivalent: always split into SINGLE transfers.
      bins fixed_1B_single  = {{1'b0, 2'b00, 2'd0, 3'b000}};
      bins fixed_2B_single  = {{1'b0, 2'b00, 2'd1, 3'b000}};
      bins fixed_4B_single  = {{1'b0, 2'b00, 2'd2, 3'b000}};
      bins fixed_8B_single  = {{1'b0, 2'b00, 2'd3, 3'b000}};
      // INCR: a real burst only for full-width aligned data; otherwise SINGLEs.
      bins incr_1B_single   = {{1'b0, 2'b01, 2'd0, 3'b000}};
      bins incr_2B_single   = {{1'b0, 2'b01, 2'd1, 3'b000}};
      bins incr_4B_single   = {{1'b0, 2'b01, 2'd2, 3'b000}};
      bins incr_8B_single   = {{1'b0, 2'b01, 2'd3, 3'b000}};
      bins incr_8B_incr     = {{1'b0, 2'b01, 2'd3, 3'b001}};
      bins incr_8B_incr4    = {{1'b0, 2'b01, 2'd3, 3'b011}};
      bins incr_8B_incr8    = {{1'b0, 2'b01, 2'd3, 3'b101}};
      bins incr_8B_incr16   = {{1'b0, 2'b01, 2'd3, 3'b111}};
      // WRAP: mapped when the 32-bit word count is 4/8/16; the 16-beat 64-bit
      // wrap (32 words) has no AHB equivalent and falls back to SINGLEs.
      bins wrap_1B_single   = {{1'b0, 2'b10, 2'd0, 3'b000}};
      bins wrap_2B_single   = {{1'b0, 2'b10, 2'd1, 3'b000}};
      bins wrap_4B_single   = {{1'b0, 2'b10, 2'd2, 3'b000}};
      bins wrap_8B_single   = {{1'b0, 2'b10, 2'd3, 3'b000}};
      bins wrap_8B_wrap4    = {{1'b0, 2'b10, 2'd3, 3'b010}};
      bins wrap_8B_wrap8    = {{1'b0, 2'b10, 2'd3, 3'b100}};
      bins wrap_8B_wrap16   = {{1'b0, 2'b10, 2'd3, 3'b110}};
    }
    cp_dir : coverpoint rq_rw iff (conv_ev) { bins read = {1'b0}; bins write = {1'b1}; }
    x_conv_dir : cross cp_conv, cp_dir;
  endgroup
  cg_conv cg_conv_i = new();

endmodule : ahb_cov

`endif // AHB_COV_SV
