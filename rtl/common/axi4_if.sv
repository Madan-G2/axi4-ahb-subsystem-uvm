//==============================================================================
// axi4_if.sv
//
// AXI4 interface carrying the full signal set, including the channel qualifiers
// (CACHE/PROT/QOS/REGION/USER) that a partial implementation usually drops.
// They are carried even where the current slaves ignore them, so that adding a
// QoS-aware arbiter in Phase 2 does not require touching the interface.
//
// Deliberately no clocking blocks. XSim's clocking-block support around
// bidirectional UVM drivers is the sort of thing that produces hard-to-diagnose
// race behaviour, and a plain-signal interface driven on @(posedge aclk) with
// non-blocking assignments is both portable and easy to read in a waveform.
// The driver and monitor own their own sampling discipline instead.
//
// RTL modules take explicit ports rather than an interface port. That keeps
// them straightforwardly synthesizable and, more importantly, keeps them
// tractable for VC Formal in Phase 7 -- formal tools handle a flat port list far
// more predictably than a virtual interface. tb_top does the wiring.
//==============================================================================
`ifndef AXI4_IF_SV
`define AXI4_IF_SV

interface axi4_if #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64,
  parameter int ID_W   = 4,
  parameter int STRB_W = DATA_W/8
) (
  input logic aclk,
  input logic aresetn
);

  //-------------------------------------------------------------------------
  // Write address channel
  //-------------------------------------------------------------------------
  logic [ID_W-1:0]    awid;
  logic [ADDR_W-1:0]  awaddr;
  logic [7:0]         awlen;
  logic [2:0]         awsize;
  logic [1:0]         awburst;
  logic               awlock;
  logic [3:0]         awcache;
  logic [2:0]         awprot;
  logic [3:0]         awqos;
  logic [3:0]         awregion;
  logic               awvalid;
  logic               awready;

  //-------------------------------------------------------------------------
  // Write data channel. No WID: AXI4 removed write interleaving, so write data
  // is implicitly associated with the oldest outstanding AW from that master.
  //-------------------------------------------------------------------------
  logic [DATA_W-1:0]  wdata;
  logic [STRB_W-1:0]  wstrb;
  logic               wlast;
  logic               wvalid;
  logic               wready;

  //-------------------------------------------------------------------------
  // Write response channel
  //-------------------------------------------------------------------------
  logic [ID_W-1:0]    bid;
  logic [1:0]         bresp;
  logic               bvalid;
  logic               bready;

  //-------------------------------------------------------------------------
  // Read address channel
  //-------------------------------------------------------------------------
  logic [ID_W-1:0]    arid;
  logic [ADDR_W-1:0]  araddr;
  logic [7:0]         arlen;
  logic [2:0]         arsize;
  logic [1:0]         arburst;
  logic               arlock;
  logic [3:0]         arcache;
  logic [2:0]         arprot;
  logic [3:0]         arqos;
  logic [3:0]         arregion;
  logic               arvalid;
  logic               arready;

  //-------------------------------------------------------------------------
  // Read data channel
  //-------------------------------------------------------------------------
  logic [ID_W-1:0]    rid;
  logic [DATA_W-1:0]  rdata;
  logic [1:0]         rresp;
  logic               rlast;
  logic               rvalid;
  logic               rready;

  //-------------------------------------------------------------------------
  // Modports
  //-------------------------------------------------------------------------
  modport master (
    input  aclk, aresetn,
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
           awqos, awregion, awvalid,
    input  awready,
    output wdata, wstrb, wlast, wvalid,
    input  wready,
    input  bid, bresp, bvalid,
    output bready,
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot,
           arqos, arregion, arvalid,
    input  arready,
    input  rid, rdata, rresp, rlast, rvalid,
    output rready
  );

  modport slave (
    input  aclk, aresetn,
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
           awqos, awregion, awvalid,
    output awready,
    input  wdata, wstrb, wlast, wvalid,
    output wready,
    output bid, bresp, bvalid,
    input  bready,
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot,
           arqos, arregion, arvalid,
    output arready,
    output rid, rdata, rresp, rlast, rvalid,
    input  rready
  );

  // Everything an input: used by the UVM monitor and by the bound SVA checker.
  modport monitor (
    input aclk, aresetn,
          awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
          awqos, awregion, awvalid, awready,
          wdata, wstrb, wlast, wvalid, wready,
          bid, bresp, bvalid, bready,
          arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot,
          arqos, arregion, arvalid, arready,
          rid, rdata, rresp, rlast, rvalid, rready
  );

endinterface : axi4_if

`endif // AXI4_IF_SV
