//==============================================================================
// ahb_s1_wrapper.sv
//
// Crossbar port S1: the AXI2AHB bridge plus the AHB subsystem behind it.
//
// Exists so soc_subsystem_top instantiates one thing per slave port. The AHB
// signals are also brought out unused-but-visible, so the testbench can tap
// them for the AHB monitor without a hierarchical reference into two levels.
//==============================================================================
`ifndef AHB_S1_WRAPPER_SV
`define AHB_S1_WRAPPER_SV

module ahb_s1_wrapper
  import axi4_pkg::*;
  import ahb_pkg::*;
#(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64,
  parameter int ID_W   = 6,
  parameter int STRB_W = DATA_W/8
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
  input  logic                rready,

  // AHB monitor taps
  output logic [31:0]         m_haddr,
  output logic [1:0]          m_htrans,
  output logic                m_hwrite,
  output logic [2:0]          m_hsize,
  output logic [2:0]          m_hburst,
  output logic [31:0]         m_hwdata,
  output logic [31:0]         m_hrdata,
  output logic                m_hready,
  output logic                m_hresp
);

  logic [31:0] haddr, hwdata, hrdata;
  logic [1:0]  htrans;
  logic        hwrite, hready, hresp;
  logic [2:0]  hsize, hburst;

  axi2ahb_bridge #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W)
  ) u_bridge (
    .aclk, .aresetn,
    .awid, .awaddr, .awlen, .awsize, .awburst, .awlock, .awcache, .awprot,
    .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bid, .bresp, .bvalid, .bready,
    .arid, .araddr, .arlen, .arsize, .arburst, .arlock, .arcache, .arprot,
    .arvalid, .arready,
    .rid, .rdata, .rresp, .rlast, .rvalid, .rready,
    .haddr, .htrans, .hwrite, .hsize, .hburst, .hwdata,
    .hrdata, .hready, .hresp
  );

  ahb_subsystem u_ahb (
    .hclk(aclk), .hresetn(aresetn),
    .haddr, .htrans, .hwrite, .hsize, .hburst, .hwdata,
    .hrdata, .hready, .hresp
  );

  assign m_haddr  = haddr;
  assign m_htrans = htrans;
  assign m_hwrite = hwrite;
  assign m_hsize  = hsize;
  assign m_hburst = hburst;
  assign m_hwdata = hwdata;
  assign m_hrdata = hrdata;
  assign m_hready = hready;
  assign m_hresp  = hresp;

endmodule : ahb_s1_wrapper

`endif // AHB_S1_WRAPPER_SV
