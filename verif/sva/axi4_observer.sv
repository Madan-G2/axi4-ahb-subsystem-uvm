//==============================================================================
// axi4_observer.sv
//
// Everything that watches one AXI interface, behind one port list: the protocol
// checker (asserts) and the coverage collector (cover events + covergroups).
//
// Exists so the testbench instantiates one thing per interface instead of two
// identical 40-signal port maps, and so a checker and its coverage can never be
// attached to different wires.
//==============================================================================
`ifndef AXI4_OBSERVER_SV
`define AXI4_OBSERVER_SV

module axi4_observer
  import axi4_pkg::*;
#(
  parameter int    ADDR_W         = 32,
  parameter int    DATA_W         = 64,
  parameter int    ID_W           = 4,
  parameter int    STRB_W         = DATA_W/8,

  parameter bit    FORMAL_ASSUME  = 1'b0,
  parameter int    MAX_WR_LATENCY = 10000,
  parameter int    MAX_RD_LATENCY = 10000,

  parameter bit    IS_SLAVE_SIDE  = 1'b0,
  parameter int    SLAVE_IDX      = 0,
  parameter int    MAX_OUT        = 8,
  parameter bit    ENABLE_COV     = 1'b1,

  parameter string IFNAME         = "axi"
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

  axi4_protocol_checker #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W),
    .FORMAL_ASSUME(FORMAL_ASSUME),
    .MAX_WR_LATENCY(MAX_WR_LATENCY), .MAX_RD_LATENCY(MAX_RD_LATENCY),
    .IFNAME(IFNAME)
  ) u_chk (.*);

  if (ENABLE_COV) begin : g_cov
    axi4_cov #(
      .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W),
      .IS_SLAVE_SIDE(IS_SLAVE_SIDE), .SLAVE_IDX(SLAVE_IDX),
      .MAX_OUT(MAX_OUT), .IFNAME(IFNAME)
    ) u_cov (.*);
  end

endmodule : axi4_observer

`endif // AXI4_OBSERVER_SV
