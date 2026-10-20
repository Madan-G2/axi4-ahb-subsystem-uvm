//==============================================================================
// axi4_crossbar.sv
//
// N_M x N_S AXI4 crossbar, plus a default slave for unmapped addresses.
//
// Structure:
//   AW / AR   per-master address decode, per-master hazard and outstanding
//             checks, then one round-robin arbiter per slave port.
//   W         handed to axi4_w_router, which owns the ordering rules.
//   B / R     routed by the master index carried in the upper ID bits, with one
//             round-robin arbiter per master port.
//
// ID REMAPPING. Every request leaves with {master_index, original_id}. This
// makes response routing a bit-slice rather than a lookup, and guarantees that
// IDs are unique across masters at every slave -- without it, two masters both
// using ID 0 would be indistinguishable to a slave that reorders.
//
// READ INTERLEAVING. AXI4 permits read data for different IDs to interleave.
// This crossbar does not: once a master's R arbiter picks a slave it holds that
// grant until RLAST. Not interleaving is always legal, and the alternative
// needs per-ID reassembly buffers for a throughput gain that nothing here is
// bottlenecked on.
//
// OUTSTANDING LIMIT. The spec listed this as a separate axi4_outstanding_tracker
// module; it is ten lines of counter and lives inline below. It bounds the
// per-master total, which the per-ID table in axi4_id_hazard deliberately does
// not -- eight IDs each allowed eight outstanding would let one master put 64
// entries into an ordering queue sized for eight.
//==============================================================================
`ifndef AXI4_CROSSBAR_SV
`define AXI4_CROSSBAR_SV

module axi4_crossbar
  import axi4_pkg::*;
#(
  parameter int N_M         = 3,
  parameter int N_S         = 3,
  parameter int ADDR_W      = 32,
  parameter int DATA_W      = 64,
  parameter int ID_W        = 4,
  parameter int STRB_W      = DATA_W/8,
  parameter int OUTSTANDING = 8,

  parameter int N_ST        = N_S + 1,                      // + default slave
  parameter int MIDXW       = (N_M  > 1) ? $clog2(N_M)  : 1,
  parameter int SIDXW       = (N_ST > 1) ? $clog2(N_ST) : 1,
  parameter int XID_W       = ID_W + MIDXW
) (
  input  logic                        aclk,
  input  logic                        aresetn,

  //-------------------------------------------------------------------------
  // Master side
  //-------------------------------------------------------------------------
  input  logic [N_M-1:0][ID_W-1:0]    m_awid,
  input  logic [N_M-1:0][ADDR_W-1:0]  m_awaddr,
  input  logic [N_M-1:0][7:0]         m_awlen,
  input  logic [N_M-1:0][2:0]         m_awsize,
  input  logic [N_M-1:0][1:0]         m_awburst,
  input  logic [N_M-1:0]              m_awlock,
  input  logic [N_M-1:0][3:0]         m_awcache,
  input  logic [N_M-1:0][2:0]         m_awprot,
  input  logic [N_M-1:0]              m_awvalid,
  output logic [N_M-1:0]              m_awready,

  input  logic [N_M-1:0][DATA_W-1:0]  m_wdata,
  input  logic [N_M-1:0][STRB_W-1:0]  m_wstrb,
  input  logic [N_M-1:0]              m_wlast,
  input  logic [N_M-1:0]              m_wvalid,
  output logic [N_M-1:0]              m_wready,

  output logic [N_M-1:0][ID_W-1:0]    m_bid,
  output logic [N_M-1:0][1:0]         m_bresp,
  output logic [N_M-1:0]              m_bvalid,
  input  logic [N_M-1:0]              m_bready,

  input  logic [N_M-1:0][ID_W-1:0]    m_arid,
  input  logic [N_M-1:0][ADDR_W-1:0]  m_araddr,
  input  logic [N_M-1:0][7:0]         m_arlen,
  input  logic [N_M-1:0][2:0]         m_arsize,
  input  logic [N_M-1:0][1:0]         m_arburst,
  input  logic [N_M-1:0]              m_arlock,
  input  logic [N_M-1:0][3:0]         m_arcache,
  input  logic [N_M-1:0][2:0]         m_arprot,
  input  logic [N_M-1:0]              m_arvalid,
  output logic [N_M-1:0]              m_arready,

  output logic [N_M-1:0][ID_W-1:0]    m_rid,
  output logic [N_M-1:0][DATA_W-1:0]  m_rdata,
  output logic [N_M-1:0][1:0]         m_rresp,
  output logic [N_M-1:0]              m_rlast,
  output logic [N_M-1:0]              m_rvalid,
  input  logic [N_M-1:0]              m_rready,

  //-------------------------------------------------------------------------
  // Slave side (index N_S is the default slave)
  //-------------------------------------------------------------------------
  output logic [N_ST-1:0][XID_W-1:0]  s_awid,
  output logic [N_ST-1:0][ADDR_W-1:0] s_awaddr,
  output logic [N_ST-1:0][7:0]        s_awlen,
  output logic [N_ST-1:0][2:0]        s_awsize,
  output logic [N_ST-1:0][1:0]        s_awburst,
  output logic [N_ST-1:0]             s_awlock,
  output logic [N_ST-1:0][3:0]        s_awcache,
  output logic [N_ST-1:0][2:0]        s_awprot,
  output logic [N_ST-1:0]             s_awvalid,
  input  logic [N_ST-1:0]             s_awready,

  output logic [N_ST-1:0][DATA_W-1:0] s_wdata,
  output logic [N_ST-1:0][STRB_W-1:0] s_wstrb,
  output logic [N_ST-1:0]             s_wlast,
  output logic [N_ST-1:0]             s_wvalid,
  input  logic [N_ST-1:0]             s_wready,

  input  logic [N_ST-1:0][XID_W-1:0]  s_bid,
  input  logic [N_ST-1:0][1:0]        s_bresp,
  input  logic [N_ST-1:0]             s_bvalid,
  output logic [N_ST-1:0]             s_bready,

  output logic [N_ST-1:0][XID_W-1:0]  s_arid,
  output logic [N_ST-1:0][ADDR_W-1:0] s_araddr,
  output logic [N_ST-1:0][7:0]        s_arlen,
  output logic [N_ST-1:0][2:0]        s_arsize,
  output logic [N_ST-1:0][1:0]        s_arburst,
  output logic [N_ST-1:0]             s_arlock,
  output logic [N_ST-1:0][3:0]        s_arcache,
  output logic [N_ST-1:0][2:0]        s_arprot,
  output logic [N_ST-1:0]             s_arvalid,
  input  logic [N_ST-1:0]             s_arready,

  input  logic [N_ST-1:0][XID_W-1:0]  s_rid,
  input  logic [N_ST-1:0][DATA_W-1:0] s_rdata,
  input  logic [N_ST-1:0][1:0]        s_rresp,
  input  logic [N_ST-1:0]             s_rlast,
  input  logic [N_ST-1:0]             s_rvalid,
  output logic [N_ST-1:0]             s_rready
);

  localparam int CNTW = $clog2(OUTSTANDING + 1);

  //==========================================================================
  // Address decode
  //==========================================================================
  logic [N_M-1:0][SIDXW-1:0] aw_sel, ar_sel;

  generate
    for (genvar m = 0; m < N_M; m++) begin : g_dec
      axi4_addr_decoder #(.ADDR_W(ADDR_W), .N_S(N_S), .SIDXW(SIDXW))
        u_awd (.addr(m_awaddr[m]), .sel(aw_sel[m]), .decerr());
      axi4_addr_decoder #(.ADDR_W(ADDR_W), .N_S(N_S), .SIDXW(SIDXW))
        u_ard (.addr(m_araddr[m]), .sel(ar_sel[m]), .decerr());
    end
  endgenerate

  //==========================================================================
  // Per-master outstanding counters and ID hazard (spec decision G1)
  //==========================================================================
  logic [N_M-1:0] aw_hz, ar_hz;
  logic [N_M-1:0] aw_stall, ar_stall;
  logic [CNTW-1:0] aw_out [N_M];
  logic [CNTW-1:0] ar_out [N_M];

  logic [N_M-1:0] aw_hs, ar_hs;     // request accepted this cycle
  logic [N_M-1:0] b_hs,  r_hs;      // response retired this cycle

  generate
    for (genvar m = 0; m < N_M; m++) begin : g_hz
      axi4_id_hazard #(.ID_W(ID_W), .SIDXW(SIDXW), .MAX_OUT(OUTSTANDING))
        u_awhz (
          .clk(aclk), .rstn(aresetn),
          .issue_valid (aw_hs[m]),
          .issue_id    (m_awid[m]),
          .issue_slave (aw_sel[m]),
          .retire_valid(b_hs[m]),
          .retire_id   (m_bid[m]),
          .probe_id    (m_awid[m]),
          .probe_slave (aw_sel[m]),
          .stall       (aw_hz[m])
        );
      axi4_id_hazard #(.ID_W(ID_W), .SIDXW(SIDXW), .MAX_OUT(OUTSTANDING))
        u_arhz (
          .clk(aclk), .rstn(aresetn),
          .issue_valid (ar_hs[m]),
          .issue_id    (m_arid[m]),
          .issue_slave (ar_sel[m]),
          .retire_valid(r_hs[m]),
          .retire_id   (m_rid[m]),
          .probe_id    (m_arid[m]),
          .probe_slave (ar_sel[m]),
          .stall       (ar_hz[m])
        );
    end
  endgenerate

  always_comb
    for (int m = 0; m < N_M; m++) begin
      aw_stall[m] = aw_hz[m] || (aw_out[m] == CNTW'(OUTSTANDING));
      ar_stall[m] = ar_hz[m] || (ar_out[m] == CNTW'(OUTSTANDING));
    end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      for (int m = 0; m < N_M; m++) begin
        aw_out[m] <= '0;
        ar_out[m] <= '0;
      end
    end
    else begin
      for (int m = 0; m < N_M; m++) begin
        aw_out[m] <= aw_out[m] + ((aw_hs[m] ? 1 : 0)) - ((b_hs[m] ? 1 : 0));
        ar_out[m] <= ar_out[m] + ((ar_hs[m] ? 1 : 0)) - ((r_hs[m] ? 1 : 0));
      end
    end
  end

  //==========================================================================
  // AW arbitration: one arbiter per slave port
  //==========================================================================
  logic [N_ST-1:0][N_M-1:0] aw_req;
  logic [N_ST-1:0]          aw_gv;
  logic [N_ST-1:0][MIDXW-1:0] aw_gi;

  always_comb
    for (int s = 0; s < N_ST; s++)
      for (int m = 0; m < N_M; m++)
        aw_req[s][m] = m_awvalid[m] && (aw_sel[m] == SIDXW'(s)) && !aw_stall[m];

  generate
    for (genvar s = 0; s < N_ST; s++) begin : g_awarb
      axi4_rr_arbiter #(.N(N_M), .IDXW(MIDXW)) u_arb (
        .clk(aclk), .rstn(aresetn),
        .req(aw_req[s]),
        .accept(s_awvalid[s] && s_awready[s]),
        .gnt_valid(aw_gv[s]), .gnt_onehot(), .gnt_idx(aw_gi[s])
      );
    end
  endgenerate

  always_comb begin
    for (int s = 0; s < N_ST; s++) begin
      s_awvalid[s] = aw_gv[s];
      s_awid[s]    = {aw_gi[s], m_awid[aw_gi[s]]};   // ID remap
      s_awaddr[s]  = m_awaddr [aw_gi[s]];
      s_awlen[s]   = m_awlen  [aw_gi[s]];
      s_awsize[s]  = m_awsize [aw_gi[s]];
      s_awburst[s] = m_awburst[aw_gi[s]];
      s_awlock[s]  = m_awlock [aw_gi[s]];
      s_awcache[s] = m_awcache[aw_gi[s]];
      s_awprot[s]  = m_awprot [aw_gi[s]];
    end
    for (int m = 0; m < N_M; m++) begin
      m_awready[m] = aw_gv[aw_sel[m]] && (aw_gi[aw_sel[m]] == MIDXW'(m)) &&
                     s_awready[aw_sel[m]];
      aw_hs[m]     = m_awvalid[m] && m_awready[m];
    end
  end

  //==========================================================================
  // W routing (spec decisions G1/G2 live in the router)
  //==========================================================================
  logic [N_ST-1:0]            w_push;
  logic [N_ST-1:0][MIDXW-1:0] w_push_m;

  always_comb
    for (int s = 0; s < N_ST; s++) begin
      w_push[s]   = s_awvalid[s] && s_awready[s];
      w_push_m[s] = aw_gi[s];
    end

  axi4_w_router #(
    .N_M(N_M), .N_ST(N_ST), .DATA_W(DATA_W), .STRB_W(STRB_W),
    .SKID_D(4), .QD(OUTSTANDING), .MIDXW(MIDXW), .SIDXW(SIDXW)
  ) u_wrouter (
    .aclk(aclk), .aresetn(aresetn),
    .push_valid(w_push), .push_master(w_push_m),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
    .m_wvalid(m_wvalid), .m_wready(m_wready),
    .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
    .s_wvalid(s_wvalid), .s_wready(s_wready)
  );

  //==========================================================================
  // B routing: one arbiter per master, selecting among slaves
  //==========================================================================
  logic [N_M-1:0][N_ST-1:0]   b_req;
  logic [N_M-1:0]             b_gv;
  logic [N_M-1:0][SIDXW-1:0]  b_gi;

  always_comb
    for (int m = 0; m < N_M; m++)
      for (int s = 0; s < N_ST; s++)
        b_req[m][s] = s_bvalid[s] && (s_bid[s][XID_W-1:ID_W] == MIDXW'(m));

  generate
    for (genvar m = 0; m < N_M; m++) begin : g_barb
      axi4_rr_arbiter #(.N(N_ST), .IDXW(SIDXW)) u_arb (
        .clk(aclk), .rstn(aresetn),
        .req(b_req[m]),
        .accept(m_bvalid[m] && m_bready[m]),
        .gnt_valid(b_gv[m]), .gnt_onehot(), .gnt_idx(b_gi[m])
      );
    end
  endgenerate

  always_comb begin
    for (int m = 0; m < N_M; m++) begin
      m_bvalid[m] = b_gv[m];
      m_bid[m]    = s_bid[b_gi[m]][ID_W-1:0];      // strip the master index
      m_bresp[m]  = s_bresp[b_gi[m]];
      b_hs[m]     = m_bvalid[m] && m_bready[m];
    end
    for (int s = 0; s < N_ST; s++) begin
      s_bready[s] = 1'b0;
      for (int m = 0; m < N_M; m++)
        if (b_gv[m] && (b_gi[m] == SIDXW'(s))) s_bready[s] = m_bready[m];
    end
  end

  //==========================================================================
  // AR arbitration
  //==========================================================================
  logic [N_ST-1:0][N_M-1:0]   ar_req;
  logic [N_ST-1:0]            ar_gv;
  logic [N_ST-1:0][MIDXW-1:0] ar_gi;

  always_comb
    for (int s = 0; s < N_ST; s++)
      for (int m = 0; m < N_M; m++)
        ar_req[s][m] = m_arvalid[m] && (ar_sel[m] == SIDXW'(s)) && !ar_stall[m];

  generate
    for (genvar s = 0; s < N_ST; s++) begin : g_ararb
      axi4_rr_arbiter #(.N(N_M), .IDXW(MIDXW)) u_arb (
        .clk(aclk), .rstn(aresetn),
        .req(ar_req[s]),
        .accept(s_arvalid[s] && s_arready[s]),
        .gnt_valid(ar_gv[s]), .gnt_onehot(), .gnt_idx(ar_gi[s])
      );
    end
  endgenerate

  always_comb begin
    for (int s = 0; s < N_ST; s++) begin
      s_arvalid[s] = ar_gv[s];
      s_arid[s]    = {ar_gi[s], m_arid[ar_gi[s]]};
      s_araddr[s]  = m_araddr [ar_gi[s]];
      s_arlen[s]   = m_arlen  [ar_gi[s]];
      s_arsize[s]  = m_arsize [ar_gi[s]];
      s_arburst[s] = m_arburst[ar_gi[s]];
      s_arlock[s]  = m_arlock [ar_gi[s]];
      s_arcache[s] = m_arcache[ar_gi[s]];
      s_arprot[s]  = m_arprot [ar_gi[s]];
    end
    for (int m = 0; m < N_M; m++) begin
      m_arready[m] = ar_gv[ar_sel[m]] && (ar_gi[ar_sel[m]] == MIDXW'(m)) &&
                     s_arready[ar_sel[m]];
      ar_hs[m]     = m_arvalid[m] && m_arready[m];
    end
  end

  //==========================================================================
  // R routing, with the grant locked for the duration of a burst
  //==========================================================================
  logic [N_M-1:0][N_ST-1:0]   r_req;
  logic [N_M-1:0]             r_gv;
  logic [N_M-1:0][SIDXW-1:0]  r_gi;

  // No separate burst lock here. The arbiter holds its grant until `accept`,
  // and accept is only asserted at RLAST, so the grant is already pinned for
  // the whole burst. A second lock on top of that would be two mechanisms
  // maintaining the same invariant, which is one more than can be kept right.
  always_comb
    for (int m = 0; m < N_M; m++)
      for (int s = 0; s < N_ST; s++)
        r_req[m][s] = s_rvalid[s] && (s_rid[s][XID_W-1:ID_W] == MIDXW'(m));

  generate
    for (genvar m = 0; m < N_M; m++) begin : g_rarb
      axi4_rr_arbiter #(.N(N_ST), .IDXW(SIDXW), .HOLD_ACROSS_GAPS(1'b1)) u_arb (
        .clk(aclk), .rstn(aresetn),
        .req(r_req[m]),
        // Rotate only when a burst completes, so the arbiter cannot move on
        // mid-burst and split a read across two slaves.
        .accept(m_rvalid[m] && m_rready[m] && m_rlast[m]),
        .gnt_valid(r_gv[m]), .gnt_onehot(), .gnt_idx(r_gi[m])
      );
    end
  endgenerate

  always_comb begin
    for (int m = 0; m < N_M; m++) begin
      m_rvalid[m] = r_gv[m] && s_rvalid[r_gi[m]];
      m_rid[m]    = s_rid  [r_gi[m]][ID_W-1:0];
      m_rdata[m]  = s_rdata[r_gi[m]];
      m_rresp[m]  = s_rresp[r_gi[m]];
      m_rlast[m]  = s_rlast[r_gi[m]];
      r_hs[m]     = m_rvalid[m] && m_rready[m] && m_rlast[m];
    end
    for (int s = 0; s < N_ST; s++) begin
      s_rready[s] = 1'b0;
      for (int m = 0; m < N_M; m++)
        if (r_gv[m] && (r_gi[m] == SIDXW'(s))) s_rready[s] = m_rready[m];
    end
  end

endmodule : axi4_crossbar

`endif // AXI4_CROSSBAR_SV
