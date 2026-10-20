//==============================================================================
// soc_subsystem_top.sv
//
// Phase 2 subsystem: three AXI4 master ports into a 3x3 crossbar, three slaves
// plus a default slave.
//
//   S0  0x0000_0000  64 KB  SRAM              RD_LATENCY 2
//   S1  0x1000_0000   1 MB  AXI2AHB bridge -> AHB ROM / regs / wait-error slave
//   S2  0x2000_0000   4 KB  CSR register file RD_LATENCY 0
//   S3  everything else     default slave     DECERR
//
// The read latencies differ on purpose. With every slave answering at the same
// rate, responses come back in issue order and the crossbar's out-of-order
// return path is never exercised -- it would look correct simply because it was
// never asked to reorder anything. Staggering them means a master with reads
// outstanding to S2 and S1 gets them back in the opposite order, every time.
//
// All three slaves are instances of axi4_sram_ctrl. It is already a complete
// AXI4 slave with byte-enabled memory, narrow/unaligned handling and an
// exclusive monitor, so a separate register-file module would be the same code
// with a different name. Phase 3 replaces the S1 instance with the AXI2AHB
// bridge, which is the only reason it exists as a distinct port.
//==============================================================================
`ifndef SOC_SUBSYSTEM_TOP_SV
`define SOC_SUBSYSTEM_TOP_SV

module soc_subsystem_top
  import axi4_pkg::*;
#(
  parameter int N_M    = 3,
  parameter int N_S    = 3,
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64,
  parameter int ID_W   = 4,
  parameter int STRB_W = DATA_W/8,
  parameter int OUTSTANDING = 8,

  parameter int N_ST   = N_S + 1,
  parameter int MIDXW  = (N_M > 1) ? $clog2(N_M) : 1,
  parameter int XID_W  = ID_W + MIDXW
) (
  input  logic                        aclk,
  input  logic                        aresetn,

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
  input  logic [N_M-1:0]              m_rready
);

  //--------------------------------------------------------------------------
  // Crossbar <-> slave wiring
  //--------------------------------------------------------------------------
  logic [N_ST-1:0][XID_W-1:0]  s_awid;
  logic [N_ST-1:0][ADDR_W-1:0] s_awaddr;
  logic [N_ST-1:0][7:0]        s_awlen;
  logic [N_ST-1:0][2:0]        s_awsize;
  logic [N_ST-1:0][1:0]        s_awburst;
  logic [N_ST-1:0]             s_awlock;
  logic [N_ST-1:0][3:0]        s_awcache;
  logic [N_ST-1:0][2:0]        s_awprot;
  logic [N_ST-1:0]             s_awvalid, s_awready;

  logic [N_ST-1:0][DATA_W-1:0] s_wdata;
  logic [N_ST-1:0][STRB_W-1:0] s_wstrb;
  logic [N_ST-1:0]             s_wlast, s_wvalid, s_wready;

  logic [N_ST-1:0][XID_W-1:0]  s_bid;
  logic [N_ST-1:0][1:0]        s_bresp;
  logic [N_ST-1:0]             s_bvalid, s_bready;

  logic [N_ST-1:0][XID_W-1:0]  s_arid;
  logic [N_ST-1:0][ADDR_W-1:0] s_araddr;
  logic [N_ST-1:0][7:0]        s_arlen;
  logic [N_ST-1:0][2:0]        s_arsize;
  logic [N_ST-1:0][1:0]        s_arburst;
  logic [N_ST-1:0]             s_arlock;
  logic [N_ST-1:0][3:0]        s_arcache;
  logic [N_ST-1:0][2:0]        s_arprot;
  logic [N_ST-1:0]             s_arvalid, s_arready;

  logic [N_ST-1:0][XID_W-1:0]  s_rid;
  logic [N_ST-1:0][DATA_W-1:0] s_rdata;
  logic [N_ST-1:0][1:0]        s_rresp;
  logic [N_ST-1:0]             s_rlast, s_rvalid, s_rready;

  //--------------------------------------------------------------------------
  axi4_crossbar #(
    .N_M(N_M), .N_S(N_S), .ADDR_W(ADDR_W), .DATA_W(DATA_W),
    .ID_W(ID_W), .STRB_W(STRB_W), .OUTSTANDING(OUTSTANDING)
  ) u_xbar (
    .aclk(aclk), .aresetn(aresetn),
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awlock,
    .m_awcache, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arlock,
    .m_arcache, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready,
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awlock,
    .s_awcache, .s_awprot, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bid, .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arlock,
    .s_arcache, .s_arprot, .s_arvalid, .s_arready,
    .s_rid, .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready
  );

  //--------------------------------------------------------------------------
  // Real slaves
  //--------------------------------------------------------------------------
  // S0 and S2 are memories; S1 is the AXI2AHB bridge and its AHB subsystem.
  // The read latencies differ on purpose -- see the header note.
  generate
    for (genvar s = 0; s < N_S; s++) begin : g_slv
      if (s == 1) begin : g_ahb
        ahb_s1_wrapper #(
          .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(XID_W), .STRB_W(STRB_W)
        ) u_slv (
          .aclk(aclk), .aresetn(aresetn),
          .awid(s_awid[s]), .awaddr(s_awaddr[s]), .awlen(s_awlen[s]),
          .awsize(s_awsize[s]), .awburst(s_awburst[s]), .awlock(s_awlock[s]),
          .awcache(s_awcache[s]), .awprot(s_awprot[s]),
          .awvalid(s_awvalid[s]), .awready(s_awready[s]),
          .wdata(s_wdata[s]), .wstrb(s_wstrb[s]), .wlast(s_wlast[s]),
          .wvalid(s_wvalid[s]), .wready(s_wready[s]),
          .bid(s_bid[s]), .bresp(s_bresp[s]),
          .bvalid(s_bvalid[s]), .bready(s_bready[s]),
          .arid(s_arid[s]), .araddr(s_araddr[s]), .arlen(s_arlen[s]),
          .arsize(s_arsize[s]), .arburst(s_arburst[s]), .arlock(s_arlock[s]),
          .arcache(s_arcache[s]), .arprot(s_arprot[s]),
          .arvalid(s_arvalid[s]), .arready(s_arready[s]),
          .rid(s_rid[s]), .rdata(s_rdata[s]), .rresp(s_rresp[s]),
          .rlast(s_rlast[s]), .rvalid(s_rvalid[s]), .rready(s_rready[s]),
          .m_haddr(), .m_htrans(), .m_hwrite(), .m_hsize(), .m_hburst(),
          .m_hwdata(), .m_hrdata(), .m_hready(), .m_hresp()
        );
      end
      else begin : g_mem
        localparam logic [31:0] BASE = (s == 0) ? SRAM_BASE : CSR_BASE;
        localparam int          SIZE = (s == 0) ? SRAM_SIZE : CSR_SIZE;
        localparam int          RDL  = (s == 0) ? 2 : 0;

        axi4_sram_ctrl #(
          .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(XID_W), .STRB_W(STRB_W),
          .BASE_ADDR(BASE), .MEM_BYTES(SIZE),
          .AW_DEPTH(8), .AR_DEPTH(8), .RD_LATENCY(RDL), .BP_PERCENT(0)
        ) u_slv (
          .aclk(aclk), .aresetn(aresetn),
          .awid(s_awid[s]), .awaddr(s_awaddr[s]), .awlen(s_awlen[s]),
          .awsize(s_awsize[s]), .awburst(s_awburst[s]), .awlock(s_awlock[s]),
          .awcache(s_awcache[s]), .awprot(s_awprot[s]),
          .awvalid(s_awvalid[s]), .awready(s_awready[s]),
          .wdata(s_wdata[s]), .wstrb(s_wstrb[s]), .wlast(s_wlast[s]),
          .wvalid(s_wvalid[s]), .wready(s_wready[s]),
          .bid(s_bid[s]), .bresp(s_bresp[s]),
          .bvalid(s_bvalid[s]), .bready(s_bready[s]),
          .arid(s_arid[s]), .araddr(s_araddr[s]), .arlen(s_arlen[s]),
          .arsize(s_arsize[s]), .arburst(s_arburst[s]), .arlock(s_arlock[s]),
          .arcache(s_arcache[s]), .arprot(s_arprot[s]),
          .arvalid(s_arvalid[s]), .arready(s_arready[s]),
          .rid(s_rid[s]), .rdata(s_rdata[s]), .rresp(s_rresp[s]),
          .rlast(s_rlast[s]), .rvalid(s_rvalid[s]), .rready(s_rready[s])
        );
      end
    end
  endgenerate

  //--------------------------------------------------------------------------
  // Default slave: anything that decodes nowhere
  //--------------------------------------------------------------------------
  axi4_default_slave #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(XID_W), .STRB_W(STRB_W)
  ) u_defslv (
    .aclk(aclk), .aresetn(aresetn),
    .awid(s_awid[N_S]), .awaddr(s_awaddr[N_S]), .awlen(s_awlen[N_S]),
    .awsize(s_awsize[N_S]), .awburst(s_awburst[N_S]), .awlock(s_awlock[N_S]),
    .awcache(s_awcache[N_S]), .awprot(s_awprot[N_S]),
    .awvalid(s_awvalid[N_S]), .awready(s_awready[N_S]),
    .wdata(s_wdata[N_S]), .wstrb(s_wstrb[N_S]), .wlast(s_wlast[N_S]),
    .wvalid(s_wvalid[N_S]), .wready(s_wready[N_S]),
    .bid(s_bid[N_S]), .bresp(s_bresp[N_S]),
    .bvalid(s_bvalid[N_S]), .bready(s_bready[N_S]),
    .arid(s_arid[N_S]), .araddr(s_araddr[N_S]), .arlen(s_arlen[N_S]),
    .arsize(s_arsize[N_S]), .arburst(s_arburst[N_S]), .arlock(s_arlock[N_S]),
    .arcache(s_arcache[N_S]), .arprot(s_arprot[N_S]),
    .arvalid(s_arvalid[N_S]), .arready(s_arready[N_S]),
    .rid(s_rid[N_S]), .rdata(s_rdata[N_S]), .rresp(s_rresp[N_S]),
    .rlast(s_rlast[N_S]), .rvalid(s_rvalid[N_S]), .rready(s_rready[N_S])
  );

endmodule : soc_subsystem_top

`endif // SOC_SUBSYSTEM_TOP_SV
