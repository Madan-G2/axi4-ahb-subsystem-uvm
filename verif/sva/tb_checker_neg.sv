//==============================================================================
// tb_checker_neg.sv
//
// Unit-level NEGATIVE test for axi4_protocol_checker.
//
// A property that never fires is indistinguishable from a property that is
// broken, ignored by the simulator, or simply has a typo -- all three look like
// "no violations". The only way to know a checker works is to feed it an
// illegal bus and watch it object. This harness does that once per property:
// each phase drives exactly one violation into the checker (no DUT involved) and
// the harness records which assertion, if any, reported it.
//
// Run:  python scripts/run.py neg-checker
// Output: one line per property, FIRED or DEAD, and a non-zero exit if any
// property fails to fire on the violation designed to trip it.
//
// Why a harness and not the full testbench: XSim silently drops assertions it
// cannot handle (see docs/xsim_notes.md), and on the full design a dropped
// assertion is invisible -- a clean regression looks the same either way.
//==============================================================================
`timescale 1ns/1ps

module tb_checker_neg;
  import axi4_pkg::*;

  localparam int ADDR_W = 32, DATA_W = 64, ID_W = 4, STRB_W = 8;

  logic aclk = 0;
  logic aresetn = 0;
  always #5 aclk = ~aclk;

  // The checker's view of the bus. Everything is driven from here.
  logic [ID_W-1:0]   awid = 0;   logic [ADDR_W-1:0] awaddr = 0;
  logic [7:0]        awlen = 0;  logic [2:0] awsize = 0;  logic [1:0] awburst = 1;
  logic              awlock = 0; logic [3:0] awcache = 0; logic [2:0] awprot = 0;
  logic              awvalid = 0, awready = 0;
  logic [DATA_W-1:0] wdata = 0;  logic [STRB_W-1:0] wstrb = 0;
  logic              wlast = 0, wvalid = 0, wready = 0;
  logic [ID_W-1:0]   bid = 0;    logic [1:0] bresp = 0;  logic bvalid = 0, bready = 0;
  logic [ID_W-1:0]   arid = 0;   logic [ADDR_W-1:0] araddr = 0;
  logic [7:0]        arlen = 0;  logic [2:0] arsize = 0;  logic [1:0] arburst = 1;
  logic              arlock = 0; logic [3:0] arcache = 0; logic [2:0] arprot = 0;
  logic              arvalid = 0, arready = 0;
  logic [ID_W-1:0]   rid = 0;    logic [DATA_W-1:0] rdata = 0; logic [1:0] rresp = 0;
  logic              rlast = 0, rvalid = 0, rready = 0;

  axi4_protocol_checker #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .STRB_W(STRB_W),
    .FORMAL_ASSUME(1'b0),
    .MAX_WR_LATENCY(12), .MAX_RD_LATENCY(12),    // short, so liveness can fire
    .IFNAME("neg")
  ) dut (.*);

  //--------------------------------------------------------------------------
  // Bookkeeping: the checker reports "neg: <name> violated" via $error. We catch
  // the failure through a bind-free route -- by watching the simulator's report
  // in the log, which the runner parses. The harness itself prints PHASE markers
  // so the runner can attribute each message to the property under test.
  //--------------------------------------------------------------------------
  task automatic quiet();          // idle bus, all defaults
    awvalid = 0; awready = 0; wvalid = 0; wready = 0; bvalid = 0; bready = 0;
    arvalid = 0; arready = 0; rvalid = 0; rready = 0; rlast = 0; wlast = 0;
    awburst = 1; arburst = 1; awlen = 0; arlen = 0; awsize = 0; arsize = 0;
    awlock = 0; arlock = 0; awaddr = 0; araddr = 0; bresp = 0; rresp = 0;
    bid = 0; rid = 0; awid = 0; arid = 0; wdata = 0; wstrb = 0;
  endtask

  task automatic reset_checker();
    quiet();
    aresetn = 0;
    repeat (3) @(posedge aclk);
    #1 aresetn = 1;
    @(posedge aclk); #1;
  endtask

  task automatic phase(input string name);
    $display("PHASE %s", name);
    reset_checker();
  endtask

  task automatic tick(input int n = 1);
    repeat (n) begin @(posedge aclk); #1; end
  endtask

  initial begin
    quiet();
    repeat (4) @(posedge aclk);

    // ---- 1. reset -----------------------------------------------------------
    $display("PHASE a_reset_valids_low");
    quiet(); aresetn = 0; tick(2);
    awvalid = 1; tick(2);                      // VALID while in reset
    awvalid = 0; aresetn = 1; tick(2);

    // ---- 2. VALID withdrawn before READY -------------------------------------
    phase("a_awvalid_stable"); awvalid = 1; awready = 0; tick(); awvalid = 0; tick(2);
    phase("a_wvalid_stable");  wvalid  = 1; wready  = 0; tick(); wvalid  = 0; tick(2);
    phase("a_arvalid_stable"); arvalid = 1; arready = 0; tick(); arvalid = 0; tick(2);
    phase("a_bvalid_stable");  bvalid  = 1; bready  = 0; tick(); bvalid  = 0; tick(2);
    phase("a_rvalid_stable");  rvalid  = 1; rready  = 0; tick(); rvalid  = 0; tick(2);

    // ---- 3. payload changed while VALID is held -------------------------------
    phase("a_aw_payload_stable"); awvalid = 1; awready = 0; awaddr = 32'h100; tick();
                                  awaddr = 32'h200; tick(2);
    phase("a_w_payload_stable");  wvalid = 1; wready = 0; wdata = 64'hA; tick();
                                  wdata = 64'hB; tick(2);
    phase("a_ar_payload_stable"); arvalid = 1; arready = 0; araddr = 32'h100; tick();
                                  araddr = 32'h200; tick(2);
    phase("a_b_payload_stable");  bvalid = 1; bready = 0; bid = 4'h1; tick();
                                  bid = 4'h2; tick(2);
    phase("a_r_payload_stable");  rvalid = 1; rready = 0; rdata = 64'h1; tick();
                                  rdata = 64'h2; tick(2);

    // ---- 4. burst legality (static fields, so one cycle of VALID is enough) ----
    phase("a_aw_burst_not_reserved"); awvalid = 1; awburst = 2'b11; tick(2);
    phase("a_ar_burst_not_reserved"); arvalid = 1; arburst = 2'b11; tick(2);
    phase("a_aw_size_fits_bus");      awvalid = 1; awsize = 3'd4;   tick(2);
    phase("a_ar_size_fits_bus");      arvalid = 1; arsize = 3'd4;   tick(2);
    phase("a_aw_wrap_len");           awvalid = 1; awburst = 2'b10; awlen = 8'd2; tick(2);
    phase("a_ar_wrap_len");           arvalid = 1; arburst = 2'b10; arlen = 8'd2; tick(2);
    phase("a_aw_wrap_aligned");       awvalid = 1; awburst = 2'b10; awlen = 8'd3;
                                      awsize = 3'd2; awaddr = 32'h1;  tick(2);
    phase("a_ar_wrap_aligned");       arvalid = 1; arburst = 2'b10; arlen = 8'd3;
                                      arsize = 3'd2; araddr = 32'h1;  tick(2);
    phase("a_aw_fixed_len");          awvalid = 1; awburst = 2'b00; awlen = 8'd16; tick(2);
    phase("a_ar_fixed_len");          arvalid = 1; arburst = 2'b00; arlen = 8'd16; tick(2);
    phase("a_aw_no_4k_cross");        awvalid = 1; awburst = 2'b01; awlen = 8'd7;
                                      awsize = 3'd3; awaddr = 32'hFF8; tick(2);
    phase("a_ar_no_4k_cross");        arvalid = 1; arburst = 2'b01; arlen = 8'd7;
                                      arsize = 3'd3; araddr = 32'hFF8; tick(2);
    phase("a_aw_excl_legal");         awvalid = 1; awlock = 1; awlen = 8'd2; tick(2);
    phase("a_ar_excl_legal");         arvalid = 1; arlock = 1; arlen = 8'd2; tick(2);

    // ---- 5. write-data beat counting ------------------------------------------
    // AWLEN = 3 means 4 beats; WLAST on the very first beat is three beats early.
    phase("a_wlast_beat_count");
      awvalid = 1; awready = 1; awlen = 8'd3; tick(); awvalid = 0; awready = 0;
      wvalid = 1; wready = 1; wlast = 1; tick(); wvalid = 0; wlast = 0; tick(2);
    // The same rule when the data runs AHEAD of the address -- the normal case behind
    // a crossbar under backpressure. A 2-beat burst ends, then an AW promising 4
    // beats arrives: the mismatch is only visible when the AW lands.
    phase("a_wlast_beat_count@w_before_aw");
      wvalid = 1; wready = 1; wlast = 0; tick(); wlast = 1; tick(); wvalid = 0; wlast = 0; wready = 0;
      tick(2);
      awvalid = 1; awready = 1; awlen = 8'd3; tick(); awvalid = 0; awready = 0; tick(2);
    // ... and when the last data beat and the AW are accepted in the same cycle.
    phase("a_wlast_beat_count@same_cycle");
      awvalid = 1; awready = 1; awlen = 8'd3; wvalid = 1; wready = 1; wlast = 1; tick();
      awvalid = 0; awready = 0; wvalid = 0; wlast = 0; tick(2);
    // AWLEN = 0 is a single beat; a first beat without WLAST runs past the end.
    phase("a_w_not_past_end");
      awvalid = 1; awready = 1; awlen = 8'd0; tick(); awvalid = 0; awready = 0;
      wvalid = 1; wready = 1; wlast = 0; tick(); wvalid = 0; tick(2);

    // ---- 6. response rules ----------------------------------------------------
    phase("a_bresp_exokay_only_if_excl");
      bvalid = 1; bready = 1; bresp = 2'b01; bid = 4'h3; tick(); bvalid = 0; tick(2);
    phase("a_rresp_exokay_only_if_excl");
      rvalid = 1; rready = 1; rresp = 2'b01; rid = 4'h3; rlast = 1; tick(); rvalid = 0; tick(2);

    // ---- 7. X on control while VALID ------------------------------------------
    phase("a_aw_no_x"); awvalid = 1; awid = 4'bx; tick(2);
    phase("a_ar_no_x"); arvalid = 1; arid = 4'bx; tick(2);
    phase("a_w_no_x");  wvalid  = 1; wstrb = 8'bx; tick(2);
    phase("a_b_no_x");  bvalid  = 1; bresp = 2'bx; tick(2);
    phase("a_r_no_x");  rvalid  = 1; rresp = 2'bx; tick(2);

    // ---- 8. bounded liveness ---------------------------------------------------
    // MAX_*_LATENCY is 12 here; wait well past it with no response.
    // A response is only owed once BOTH the address and the final data beat have
    // been accepted, so send the address too.
    phase("a_write_completes");
      awvalid = 1; awready = 1; awlen = 8'd0; tick(); awvalid = 0; awready = 0;
      wvalid = 1; wready = 1; wlast = 1; tick(); wvalid = 0; wlast = 0; tick(30);
    phase("a_read_completes");
      arvalid = 1; arready = 1; tick(); arvalid = 0; arready = 0; tick(30);

    $display("PHASE END");
    $finish;
  end

endmodule : tb_checker_neg
