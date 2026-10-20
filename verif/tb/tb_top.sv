//==============================================================================
// tb_top.sv
//
// Phase 2 testbench top: three AXI4 master interfaces into the crossbar-based
// subsystem.
//==============================================================================
`ifndef TB_TOP_SV
`define TB_TOP_SV

module tb_top;

  import uvm_pkg::*;
  import axi4_pkg::*;
  import soc_env_pkg::*;
  `include "uvm_macros.svh"

  localparam int  N_M     = 3;
  localparam int  ADDR_W  = 32;
  localparam int  DATA_W  = 64;
  localparam int  ID_W    = 4;
  localparam int  STRB_W  = DATA_W/8;
  localparam int  MIDXW   = $clog2(N_M);
  localparam int  XID_W   = ID_W + MIDXW;
  localparam time CLK_PER = 10ns;

  //--------------------------------------------------------------------------
  logic aclk    = 1'b0;
  // Initialised HIGH so the assignment below produces a real negedge.
  //
  // Starting at 0 looks equivalent but is not: with no falling edge, every
  // `always_ff @(posedge clk or negedge aresetn)` never takes its reset branch
  // until the first clock edge, so those flops hold X through the whole reset
  // window. The crossbar then drives X on AWVALID while in reset, which
  // a_reset_valids_low correctly flags. Real hardware asserts reset; the
  // testbench should too.
  logic aresetn = 1'b1;

  always #(CLK_PER/2) aclk = ~aclk;

  initial begin
    #1 aresetn = 1'b0;           // unambiguous negedge, before the first clock edge
    repeat (10) @(posedge aclk);
    aresetn = 1'b1;
  end

  //--------------------------------------------------------------------------
  // Master interfaces
  //--------------------------------------------------------------------------
  axi4_if #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W))
    m_if [N_M] (.aclk(aclk), .aresetn(aresetn));

  //--------------------------------------------------------------------------
  // Flatten the interface array onto the DUT's packed ports.
  //--------------------------------------------------------------------------
  logic [N_M-1:0][ID_W-1:0]   m_awid;
  logic [N_M-1:0][ADDR_W-1:0] m_awaddr;
  logic [N_M-1:0][7:0]        m_awlen;
  logic [N_M-1:0][2:0]        m_awsize;
  logic [N_M-1:0][1:0]        m_awburst;
  logic [N_M-1:0]             m_awlock;
  logic [N_M-1:0][3:0]        m_awcache;
  logic [N_M-1:0][2:0]        m_awprot;
  logic [N_M-1:0]             m_awvalid, m_awready;

  logic [N_M-1:0][DATA_W-1:0] m_wdata;
  logic [N_M-1:0][STRB_W-1:0] m_wstrb;
  logic [N_M-1:0]             m_wlast, m_wvalid, m_wready;

  logic [N_M-1:0][ID_W-1:0]   m_bid;
  logic [N_M-1:0][1:0]        m_bresp;
  logic [N_M-1:0]             m_bvalid, m_bready;

  logic [N_M-1:0][ID_W-1:0]   m_arid;
  logic [N_M-1:0][ADDR_W-1:0] m_araddr;
  logic [N_M-1:0][7:0]        m_arlen;
  logic [N_M-1:0][2:0]        m_arsize;
  logic [N_M-1:0][1:0]        m_arburst;
  logic [N_M-1:0]             m_arlock;
  logic [N_M-1:0][3:0]        m_arcache;
  logic [N_M-1:0][2:0]        m_arprot;
  logic [N_M-1:0]             m_arvalid, m_arready;

  logic [N_M-1:0][ID_W-1:0]   m_rid;
  logic [N_M-1:0][DATA_W-1:0] m_rdata;
  logic [N_M-1:0][1:0]        m_rresp;
  logic [N_M-1:0]             m_rlast, m_rvalid, m_rready;

  generate
    for (genvar i = 0; i < N_M; i++) begin : g_wire
      assign m_awid[i]    = m_if[i].awid;
      assign m_awaddr[i]  = m_if[i].awaddr;
      assign m_awlen[i]   = m_if[i].awlen;
      assign m_awsize[i]  = m_if[i].awsize;
      assign m_awburst[i] = m_if[i].awburst;
      assign m_awlock[i]  = m_if[i].awlock;
      assign m_awcache[i] = m_if[i].awcache;
      assign m_awprot[i]  = m_if[i].awprot;
      assign m_awvalid[i] = m_if[i].awvalid;
      assign m_if[i].awready = m_awready[i];

      assign m_wdata[i]   = m_if[i].wdata;
      assign m_wstrb[i]   = m_if[i].wstrb;
      assign m_wlast[i]   = m_if[i].wlast;
      assign m_wvalid[i]  = m_if[i].wvalid;
      assign m_if[i].wready = m_wready[i];

      assign m_if[i].bid    = m_bid[i];
      assign m_if[i].bresp  = m_bresp[i];
      assign m_if[i].bvalid = m_bvalid[i];
      assign m_bready[i]    = m_if[i].bready;

      assign m_arid[i]    = m_if[i].arid;
      assign m_araddr[i]  = m_if[i].araddr;
      assign m_arlen[i]   = m_if[i].arlen;
      assign m_arsize[i]  = m_if[i].arsize;
      assign m_arburst[i] = m_if[i].arburst;
      assign m_arlock[i]  = m_if[i].arlock;
      assign m_arcache[i] = m_if[i].arcache;
      assign m_arprot[i]  = m_if[i].arprot;
      assign m_arvalid[i] = m_if[i].arvalid;
      assign m_if[i].arready = m_arready[i];

      assign m_if[i].rid    = m_rid[i];
      assign m_if[i].rdata  = m_rdata[i];
      assign m_if[i].rresp  = m_rresp[i];
      assign m_if[i].rlast  = m_rlast[i];
      assign m_if[i].rvalid = m_rvalid[i];
      assign m_rready[i]    = m_if[i].rready;

      // Unused by this DUT but driven by the agent; tie so they are not X.
      assign m_if[i].awqos    = '0;
      assign m_if[i].awregion = '0;
      assign m_if[i].arqos    = '0;
      assign m_if[i].arregion = '0;
    end
  endgenerate

  //--------------------------------------------------------------------------
  // DUT
  //--------------------------------------------------------------------------
  soc_subsystem_top #(
    .N_M(N_M), .N_S(3), .ADDR_W(ADDR_W), .DATA_W(DATA_W),
    .ID_W(ID_W), .STRB_W(STRB_W), .OUTSTANDING(8)
  ) u_dut (
    .aclk(aclk), .aresetn(aresetn),
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awlock,
    .m_awcache, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arlock,
    .m_arcache, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  //--------------------------------------------------------------------------
  // Master-side protocol checkers.
  //
  // Explicitly instantiated rather than bound, because XSim refuses to
  // instantiate a module inside an interface (VRFC 10-3535). The slave-side
  // checkers are handled by the bind at the bottom of this file, which covers
  // every axi4_sram_ctrl instance automatically.
  //--------------------------------------------------------------------------
  generate
    for (genvar i = 0; i < N_M; i++) begin : g_chk
      axi4_observer #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W),
        .FORMAL_ASSUME(1'b0), .IS_SLAVE_SIDE(1'b0), .SLAVE_IDX(0),
        .MAX_OUT(8), .IFNAME($sformatf("m%0d", i))
      ) u_chk (
        .aclk(aclk), .aresetn(aresetn),
        .awid(m_if[i].awid), .awaddr(m_if[i].awaddr), .awlen(m_if[i].awlen),
        .awsize(m_if[i].awsize), .awburst(m_if[i].awburst),
        .awlock(m_if[i].awlock), .awcache(m_if[i].awcache),
        .awprot(m_if[i].awprot), .awvalid(m_if[i].awvalid),
        .awready(m_if[i].awready),
        .wdata(m_if[i].wdata), .wstrb(m_if[i].wstrb), .wlast(m_if[i].wlast),
        .wvalid(m_if[i].wvalid), .wready(m_if[i].wready),
        .bid(m_if[i].bid), .bresp(m_if[i].bresp),
        .bvalid(m_if[i].bvalid), .bready(m_if[i].bready),
        .arid(m_if[i].arid), .araddr(m_if[i].araddr), .arlen(m_if[i].arlen),
        .arsize(m_if[i].arsize), .arburst(m_if[i].arburst),
        .arlock(m_if[i].arlock), .arcache(m_if[i].arcache),
        .arprot(m_if[i].arprot), .arvalid(m_if[i].arvalid),
        .arready(m_if[i].arready),
        .rid(m_if[i].rid), .rdata(m_if[i].rdata), .rresp(m_if[i].rresp),
        .rlast(m_if[i].rlast), .rvalid(m_if[i].rvalid), .rready(m_if[i].rready)
      );
    end
  endgenerate

  //--------------------------------------------------------------------------
  initial begin
    uvm_config_db#(virtual axi4_if)::set(null, "*", "vif0", m_if[0]);
    uvm_config_db#(virtual axi4_if)::set(null, "*", "vif1", m_if[1]);
    uvm_config_db#(virtual axi4_if)::set(null, "*", "vif2", m_if[2]);
    run_test();
  end

  //--------------------------------------------------------------------------
  // Watchdog. A hung handshake otherwise runs to the simulator's own limit with
  // no indication of where it stopped.
  //--------------------------------------------------------------------------
  initial begin
    static int unsigned timeout_ns = 2_000_000;
    if ($value$plusargs("TIMEOUT_NS=%d", timeout_ns)) begin end
    #(timeout_ns * 1ns);
    // Say where everything is stuck. A bare "timeout" tells you nothing; the
    // handshake state of the master port and the slave behind it usually names
    // the culprit immediately.
    $display("WATCHDOG STATE @%0t", $time);
    for (int i = 0; i < N_M; i++)
      $display("  m%0d: AW %b%b W %b%b(last=%b) B %b%b  AR %b%b R %b%b",
               i, m_awvalid[i], m_awready[i], m_wvalid[i], m_wready[i],
               m_wlast[i], m_bvalid[i], m_bready[i],
               m_arvalid[i], m_arready[i], m_rvalid[i], m_rready[i]);
    $display("  S0: AW %b%b W %b%b B %b%b AR %b%b R %b%b | aw_cnt=%0d b_cnt=%0d w_beat=%0d ar_cnt=%0d r_active=%b",
             u_dut.s_awvalid[0], u_dut.s_awready[0], u_dut.s_wvalid[0], u_dut.s_wready[0],
             u_dut.s_bvalid[0],  u_dut.s_bready[0],  u_dut.s_arvalid[0], u_dut.s_arready[0],
             u_dut.s_rvalid[0],  u_dut.s_rready[0],
             u_dut.g_slv[0].g_mem.u_slv.aw_cnt, u_dut.g_slv[0].g_mem.u_slv.b_cnt,
             u_dut.g_slv[0].g_mem.u_slv.w_beat, u_dut.g_slv[0].g_mem.u_slv.ar_cnt,
             u_dut.g_slv[0].g_mem.u_slv.r_active);
    `uvm_fatal("TBTOP",
      $sformatf("global timeout after %0d ns -- likely a stalled handshake", timeout_ns))
  end

  initial begin
    if ($test$plusargs("WAVES")) begin
      // The design and the top-level nets only. Dumping all of tb_top also takes
      // every observer and coverage counter, which more than doubles the file and
      // contains nothing a design-side root-cause needs.
      $dumpfile("waves.vcd");
      $dumpvars(2, tb_top);
      $dumpvars(0, tb_top.u_dut);
    end
  end

  //--------------------------------------------------------------------------
  // Slave-side protocol checkers. See the note below the module.
  //--------------------------------------------------------------------------
  generate
    for (genvar s = 0; s < 4; s++) begin : g_schk
      axi4_observer #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(XID_W), .STRB_W(STRB_W),
        .FORMAL_ASSUME(1'b0), .IS_SLAVE_SIDE(1'b1), .SLAVE_IDX(s),
        .MAX_OUT(24), .IFNAME($sformatf("s%0d", s))
      ) u_chk (
        .aclk(aclk), .aresetn(aresetn),
        .awid(u_dut.s_awid[s]), .awaddr(u_dut.s_awaddr[s]),
        .awlen(u_dut.s_awlen[s]), .awsize(u_dut.s_awsize[s]),
        .awburst(u_dut.s_awburst[s]), .awlock(u_dut.s_awlock[s]),
        .awcache(u_dut.s_awcache[s]), .awprot(u_dut.s_awprot[s]),
        .awvalid(u_dut.s_awvalid[s]), .awready(u_dut.s_awready[s]),
        .wdata(u_dut.s_wdata[s]), .wstrb(u_dut.s_wstrb[s]),
        .wlast(u_dut.s_wlast[s]), .wvalid(u_dut.s_wvalid[s]),
        .wready(u_dut.s_wready[s]),
        .bid(u_dut.s_bid[s]), .bresp(u_dut.s_bresp[s]),
        .bvalid(u_dut.s_bvalid[s]), .bready(u_dut.s_bready[s]),
        .arid(u_dut.s_arid[s]), .araddr(u_dut.s_araddr[s]),
        .arlen(u_dut.s_arlen[s]), .arsize(u_dut.s_arsize[s]),
        .arburst(u_dut.s_arburst[s]), .arlock(u_dut.s_arlock[s]),
        .arcache(u_dut.s_arcache[s]), .arprot(u_dut.s_arprot[s]),
        .arvalid(u_dut.s_arvalid[s]), .arready(u_dut.s_arready[s]),
        .rid(u_dut.s_rid[s]), .rdata(u_dut.s_rdata[s]),
        .rresp(u_dut.s_rresp[s]), .rlast(u_dut.s_rlast[s]),
        .rvalid(u_dut.s_rvalid[s]), .rready(u_dut.s_rready[s])
      );
    end
  endgenerate


  //--------------------------------------------------------------------------
  // AHB-side coverage, tapped off the bridge's AHB port and the AXI request
  // fields arriving at crossbar port S1.
  //--------------------------------------------------------------------------
  ahb_cov u_ahb_cov (
    .hclk(aclk), .hresetn(aresetn),
    .haddr  (u_dut.g_slv[1].g_ahb.u_slv.haddr),
    .htrans (u_dut.g_slv[1].g_ahb.u_slv.htrans),
    .hwrite (u_dut.g_slv[1].g_ahb.u_slv.hwrite),
    .hsize  (u_dut.g_slv[1].g_ahb.u_slv.hsize),
    .hburst (u_dut.g_slv[1].g_ahb.u_slv.hburst),
    .hready (u_dut.g_slv[1].g_ahb.u_slv.hready),
    .hresp  (u_dut.g_slv[1].g_ahb.u_slv.hresp),
    .aw_hs  (u_dut.s_awvalid[1] & u_dut.s_awready[1]),
    .aw_burst(u_dut.s_awburst[1]),
    .aw_size (u_dut.s_awsize[1]),
    .ar_hs  (u_dut.s_arvalid[1] & u_dut.s_arready[1]),
    .ar_burst(u_dut.s_arburst[1]),
    .ar_size (u_dut.s_arsize[1])
  );

endmodule : tb_top

//------------------------------------------------------------------------------
// Slave-side protocol checkers, tapped hierarchically off the DUT's internal
// crossbar-to-slave wires.
//
// These were originally a `bind axi4_sram_ctrl ... (.*)`, which is the tidier
// construct. It does not work here: under XSim a bound instance connected to
// the target module's OUTPUT ports samples those signals as X in the preponed
// region, even when they are driven 0 all along. a_reset_valids_low then fires
// on every cycle of reset while $sampled() reports x for bvalid and rvalid --
// and a $display in the same module at the same instant shows both are 0.
//
// The give-away was that the master-side checkers, explicitly instantiated over
// the same property set, never fired. Tapping the wires directly costs a verbose
// port map and behaves correctly. It also names each slave port individually,
// which a single bind could not do.
//------------------------------------------------------------------------------
`endif // TB_TOP_SV