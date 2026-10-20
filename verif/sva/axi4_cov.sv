//==============================================================================
// axi4_cov.sv
//
// Cycle-level AXI4 coverage for one interface: cover events (SVA + procedural
// mirror, see scripts/gen_cover.py) and covergroups for handshake timing,
// outstanding depth, response ordering and crossbar arbitration.
//
// Instantiated once per AXI interface by axi4_observer, next to the protocol
// checker, on every master port and every crossbar-to-slave port.
//
// Everything here only OBSERVES. No signal in this module drives anything.
//
// The port list matches axi4_protocol_checker so the two can share one set of
// connections.
//==============================================================================
`ifndef AXI4_COV_SV
`define AXI4_COV_SV

module axi4_cov
  import axi4_pkg::*;
#(
  parameter int    ADDR_W        = 32,
  parameter int    DATA_W        = 64,
  parameter int    ID_W          = 4,
  parameter int    STRB_W        = DATA_W/8,

  // Slave-side instances see the crossbar-widened ID, whose top two bits are the
  // master index. That is what lets them observe which master won which slave.
  parameter bit    IS_SLAVE_SIDE = 1'b0,
  parameter int    SLAVE_IDX     = 0,

  parameter int    MAX_OUT       = 8,
  parameter string IFNAME        = "axi"
) (
  input logic               aclk,
  input logic               aresetn,

  input logic [ID_W-1:0]    awid,
  input logic [ADDR_W-1:0]  awaddr,
  input logic [7:0]         awlen,
  input logic [2:0]         awsize,
  input logic [1:0]         awburst,
  input logic               awlock,
  input logic [3:0]         awcache,
  input logic [2:0]         awprot,
  input logic               awvalid,
  input logic               awready,

  input logic [DATA_W-1:0]  wdata,
  input logic [STRB_W-1:0]  wstrb,
  input logic               wlast,
  input logic               wvalid,
  input logic               wready,

  input logic [ID_W-1:0]    bid,
  input logic [1:0]         bresp,
  input logic               bvalid,
  input logic               bready,

  input logic [ID_W-1:0]    arid,
  input logic [ADDR_W-1:0]  araddr,
  input logic [7:0]         arlen,
  input logic [2:0]         arsize,
  input logic [1:0]         arburst,
  input logic               arlock,
  input logic [3:0]         arcache,
  input logic [2:0]         arprot,
  input logic               arvalid,
  input logic               arready,

  input logic [ID_W-1:0]    rid,
  input logic [DATA_W-1:0]  rdata,
  input logic [1:0]         rresp,
  input logic               rlast,
  input logic               rvalid,
  input logic               rready
);

  //==========================================================================
  // Generated: per-channel handshake terms and handshake covergroups
  //==========================================================================
  `include "axi4_cov_terms.svh"

  //==========================================================================
  // Generated: request-shape terms for the address channels
  //==========================================================================
  `include "axi4_cov_req.svh"

  //==========================================================================
  // Burst-internal and timing terms
  //==========================================================================
  wire w_hs_notlast = w_hs & ~wlast;
  wire r_hs_notlast = r_hs & ~rlast;
  wire w_last_hs    = w_hs & wlast;
  wire r_last_hs    = r_hs & rlast;
  wire bvalid_s     = bvalid;
  wire bvalid_n     = ~bvalid;
  wire rvalid_s     = rvalid;
  wire rvalid_n     = ~rvalid;

  // First beat of a write burst?
  logic w_first;
  always_ff @(posedge aclk or negedge aresetn)
    if (!aresetn)      w_first <= 1'b1;
    else if (w_hs)     w_first <= wlast;
  wire w_single_ev = w_last_hs & w_first;

  //==========================================================================
  // Write-address / write-data balance
  //
  // AXI4 allows WVALID before AWVALID. awbal is AWs accepted minus completed
  // write bursts, so a write beat accepted while awbal (including a same-cycle
  // AW) is not positive arrived ahead of its address.
  //==========================================================================
  integer awbal;
  always_ff @(posedge aclk or negedge aresetn)
    if (!aresetn) awbal <= 0;
    else          awbal <= awbal + (aw_hs ? 1 : 0) - (w_last_hs ? 1 : 0);

  wire w_ahead_ev        = w_hs & ((awbal + (aw_hs ? 1 : 0)) <= 0);
  wire w_stall_no_aw_ev  = wvalid & ~wready & ((awbal + (aw_hs ? 1 : 0)) <= 0);

  //==========================================================================
  // Outstanding depth and ordering
  //==========================================================================
  logic        rd_dist_valid, wr_dist_valid;
  int unsigned rd_dist, wr_dist, ar_out, aw_out;

  axi_ooo_tracker #(.ID_W(ID_W)) u_rd_trk (
    .clk(aclk), .rstn(aresetn),
    .push(ar_hs),       .push_id(arid),
    .pop (r_last_hs),   .pop_id (rid),
    .dist_valid(rd_dist_valid), .odist(rd_dist), .count(ar_out));

  axi_ooo_tracker #(.ID_W(ID_W)) u_wr_trk (
    .clk(aclk), .rstn(aresetn),
    .push(aw_hs),       .push_id(awid),
    .pop (b_hs),        .pop_id (bid),
    .dist_valid(wr_dist_valid), .odist(wr_dist), .count(aw_out));

  wire ooo_r_ev = rd_dist_valid & (rd_dist != 0);
  wire ooo_b_ev = wr_dist_valid & (wr_dist != 0);

  wire aw_out_ge2_s  = (aw_out >= 2);
  wire aw_out_ge4_s  = (aw_out >= 4);
  wire aw_out_full_s = (aw_out >= MAX_OUT);
  wire ar_out_ge2_s  = (ar_out >= 2);
  wire ar_out_ge4_s  = (ar_out >= 4);
  wire ar_out_full_s = (ar_out >= MAX_OUT);

  //==========================================================================
  // Responses
  //==========================================================================
  localparam int N_IDS = 1 << ID_W;
  logic aw_excl_seen [N_IDS];
  always_ff @(posedge aclk or negedge aresetn)
    if (!aresetn) begin
      for (int i = 0; i < N_IDS; i++) aw_excl_seen[i] <= 1'b0;
    end
    else if (aw_hs) aw_excl_seen[awid] <= awlock;

  wire b_was_excl = aw_excl_seen[bid];

  wire b_okay_ev      = b_hs & (bresp == AXI_RESP_OKAY);
  wire b_exokay_ev    = b_hs & (bresp == AXI_RESP_EXOKAY);
  wire b_slverr_ev    = b_hs & (bresp == AXI_RESP_SLVERR);
  wire b_decerr_ev    = b_hs & (bresp == AXI_RESP_DECERR);
  wire b_excl_fail_ev = b_hs & b_was_excl & (bresp == AXI_RESP_OKAY);

  wire r_okay_ev      = r_last_hs & (rresp == AXI_RESP_OKAY);
  wire r_exokay_ev    = r_last_hs & (rresp == AXI_RESP_EXOKAY);
  wire r_slverr_ev    = r_last_hs & (rresp == AXI_RESP_SLVERR);
  wire r_decerr_ev    = r_last_hs & (rresp == AXI_RESP_DECERR);
  wire r_err_mid_ev   = r_hs & ~rlast & rresp[1];

  //==========================================================================
  // Covergroups that need more than the generated handshake terms
  //==========================================================================

  // How many transactions are in flight, sampled at issue.
  covergroup cg_outstanding @(posedge aclk);
    cp_aw : coverpoint aw_out iff (aresetn && aw_hs) {
      bins d1 = {1}; bins d2 = {2}; bins d3 = {3}; bins d4 = {4};
      bins d5_7 = {[5:7]}; bins d8 = {8}; }
    cp_ar : coverpoint ar_out iff (aresetn && ar_hs) {
      bins d1 = {1}; bins d2 = {2}; bins d3 = {3}; bins d4 = {4};
      bins d5_7 = {[5:7]}; bins d8 = {8}; }
  endgroup
  cg_outstanding cg_outstanding_i = new();

  // How far out of order a response returned.
  covergroup cg_order @(posedge aclk);
    cp_rd : coverpoint rd_dist iff (aresetn && rd_dist_valid) {
      bins in_order = {0}; bins ooo_1 = {1}; bins ooo_2 = {2}; bins ooo_3p = {[3:63]}; }
    cp_wr : coverpoint wr_dist iff (aresetn && wr_dist_valid) {
      bins in_order = {0}; bins ooo_1 = {1}; bins ooo_2 = {2}; bins ooo_3p = {[3:63]}; }
  endgroup
  cg_order cg_order_i = new();

  // Arbitration: which master won which slave. Only meaningful where the ID
  // carries the master index, i.e. on the crossbar's slave ports.
  logic [1:0] arb_master;
  logic       arb_rw;
  wire        arb_ev = aw_hs | ar_hs;
  always_comb begin
    arb_rw     = ~aw_hs;
    arb_master = aw_hs ? awid[ID_W-1 -: 2] : arid[ID_W-1 -: 2];
  end

  logic [2:0] slave_i;
  assign slave_i = 3'(SLAVE_IDX);

  covergroup cg_arb @(posedge aclk);
    cp_master : coverpoint arb_master iff (aresetn && arb_ev) {
      bins m0 = {0}; bins m1 = {1}; bins m2 = {2}; illegal_bins m3 = {3}; }
    cp_slave  : coverpoint slave_i iff (aresetn && arb_ev) {
      bins s0 = {0}; bins s1 = {1}; bins s2 = {2}; bins dflt = {3}; }
    cp_rw     : coverpoint arb_rw iff (aresetn && arb_ev) {
      bins write = {0}; bins read = {1}; }
    x_arb : cross cp_master, cp_slave, cp_rw;
  endgroup

  // Only the slave-side instances get an arbitration group. Constructing it
  // conditionally keeps master-side instances (whose IDs carry no master index)
  // from polluting the cross with a meaningless "master 0".
  cg_arb cg_arb_i;
  initial if (IS_SLAVE_SIDE) cg_arb_i = new();

  //==========================================================================
  // Generated: the cover events and the end-of-simulation report
  //==========================================================================
  `include "axi4_cov_events.svh"

endmodule : axi4_cov

`endif // AXI4_COV_SV
