//==============================================================================
// axi4_protocol_checker.sv
//
// AXI4 protocol compliance checker, bound to an AXI interface.
//
// ONE FILE, TWO USES. With FORMAL_ASSUME=0 every property is an assert and this
// is a simulation checker. With FORMAL_ASSUME=1 the master-driven properties
// become assumes, turning the same file into the constraint set for VC Formal
// in Phase 7. Keeping one source means the constraints a proof relies on are
// literally the properties simulation checks -- they cannot drift apart, which
// is the usual way a formal run ends up proving something about a bus that
// could never exist.
//
// Bound rather than instantiated, so the RTL carries no verification code and
// the same checker attaches to any AXI interface in the design.
//
// Coverage of the AXI spec is not yet complete: response-ordering and the full
// exclusive-access rules land in Phase 4 alongside the AHB checker, once the
// crossbar makes them observable. What is here covers everything a single
// master and single slave can violate.
//==============================================================================
`ifndef AXI4_PROTOCOL_CHECKER_SV
`define AXI4_PROTOCOL_CHECKER_SV

module axi4_protocol_checker
  import axi4_pkg::*;
#(
  parameter int    ADDR_W          = 32,
  parameter int    DATA_W          = 64,
  parameter int    ID_W            = 4,
  parameter int    STRB_W          = DATA_W/8,

  // 0 = simulation checker (assert), 1 = formal constraints (assume)
  parameter bit    FORMAL_ASSUME   = 1'b0,

  // Bounded-liveness windows. Unbounded liveness is useless in simulation --
  // it can only fail at end of test, with no useful failure time -- so both
  // flows use a window. Formal may be given a looser bound than simulation.
  parameter int    MAX_WR_LATENCY  = 10000,
  parameter int    MAX_RD_LATENCY  = 10000,

  parameter string IFNAME          = "axi"
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


  //--------------------------------------------------------------------------
  // assert / assume selector.
  //
  // Split by who drives the signal. Master-driven properties become assumes
  // under formal (they constrain the environment); slave-driven properties stay
  // asserts (they are what the proof must establish).
  //--------------------------------------------------------------------------
  `define AXI_MASTER_CHK(nm, prp)                                             \
    generate                                                                  \
      if (FORMAL_ASSUME) begin : g_``nm                                       \
        nm : assume property (prp);                                           \
      end                                                                     \
      else begin : g_``nm                                                     \
        nm : assert property (prp)                                            \
             else $error("%s: %s violated", IFNAME, `"nm`");                  \
      end                                                                     \
    endgenerate

  `define AXI_SLAVE_CHK(nm, prp)                                              \
    nm : assert property (prp)                                                \
         else $error("%s: %s violated", IFNAME, `"nm`");

  //==========================================================================
  // 1. Reset
  //==========================================================================
  // Checked without the global disable, since this is about behaviour during
  // reset itself.
  property p_reset_valids_low;
    @(posedge aclk) (!aresetn) |-> (!awvalid && !wvalid && !bvalid &&
                                    !arvalid && !rvalid);
  endproperty
  // The failure message names the offending channel. A bare "VALID asserted
  // while in reset" tells you nothing about which of five signals to go and
  // look at, and $sampled reports the preponed values the property actually
  // evaluated rather than whatever the signals became at the edge.
  a_reset_valids_low : assert property (p_reset_valids_low)
    else $error("%s: VALID asserted while in reset: aw=%b w=%b b=%b ar=%b r=%b",
                IFNAME, $sampled(awvalid), $sampled(wvalid), $sampled(bvalid),
                $sampled(arvalid), $sampled(rvalid));

  //==========================================================================
  // 2. Handshake: VALID may not be withdrawn before READY.
  //
  // READY is deliberately not checked -- AXI explicitly permits a slave to
  // withdraw READY at any time, and asserting otherwise is a common way to
  // produce false failures against perfectly legal slaves.
  //==========================================================================
  `AXI_MASTER_CHK(a_awvalid_stable,
    @(posedge aclk) disable iff (!aresetn) (awvalid && !awready) |=> awvalid)
  `AXI_MASTER_CHK(a_wvalid_stable,
    @(posedge aclk) disable iff (!aresetn) (wvalid && !wready) |=> wvalid)
  `AXI_MASTER_CHK(a_arvalid_stable,
    @(posedge aclk) disable iff (!aresetn) (arvalid && !arready) |=> arvalid)
  `AXI_SLAVE_CHK(a_bvalid_stable,
    @(posedge aclk) disable iff (!aresetn) (bvalid && !bready) |=> bvalid)
  `AXI_SLAVE_CHK(a_rvalid_stable,
    @(posedge aclk) disable iff (!aresetn) (rvalid && !rready) |=> rvalid)

  //==========================================================================
  // 3. Payload stability while VALID is held
  //==========================================================================
  `AXI_MASTER_CHK(a_aw_payload_stable,
    @(posedge aclk) disable iff (!aresetn) (awvalid && !awready) |=>
      ($stable(awid) && $stable(awaddr) && $stable(awlen) && $stable(awsize) &&
       $stable(awburst) && $stable(awlock) && $stable(awcache) && $stable(awprot)))

  `AXI_MASTER_CHK(a_w_payload_stable,
    @(posedge aclk) disable iff (!aresetn) (wvalid && !wready) |=>
      ($stable(wdata) && $stable(wstrb) && $stable(wlast)))

  `AXI_MASTER_CHK(a_ar_payload_stable,
    @(posedge aclk) disable iff (!aresetn) (arvalid && !arready) |=>
      ($stable(arid) && $stable(araddr) && $stable(arlen) && $stable(arsize) &&
       $stable(arburst) && $stable(arlock) && $stable(arcache) && $stable(arprot)))

  `AXI_SLAVE_CHK(a_b_payload_stable,
    @(posedge aclk) disable iff (!aresetn) (bvalid && !bready) |=> ($stable(bid) && $stable(bresp)))

  `AXI_SLAVE_CHK(a_r_payload_stable,
    @(posedge aclk) disable iff (!aresetn) (rvalid && !rready) |=>
      ($stable(rid) && $stable(rdata) && $stable(rresp) && $stable(rlast)))

  //==========================================================================
  // 4. Burst legality
  //==========================================================================
  `AXI_MASTER_CHK(a_aw_burst_not_reserved,
    @(posedge aclk) disable iff (!aresetn) awvalid |-> (awburst != AXI_BURST_RSVD))
  `AXI_MASTER_CHK(a_ar_burst_not_reserved,
    @(posedge aclk) disable iff (!aresetn) arvalid |-> (arburst != AXI_BURST_RSVD))

  `AXI_MASTER_CHK(a_aw_size_fits_bus,
    @(posedge aclk) disable iff (!aresetn) awvalid |-> ((1 << awsize) <= STRB_W))
  `AXI_MASTER_CHK(a_ar_size_fits_bus,
    @(posedge aclk) disable iff (!aresetn) arvalid |-> ((1 << arsize) <= STRB_W))

  // WRAP is defined only for 2, 4, 8 or 16 beats, at a beat-aligned address.
  `AXI_MASTER_CHK(a_aw_wrap_len,
    @(posedge aclk) disable iff (!aresetn) (awvalid && awburst == AXI_BURST_WRAP) |->
      (awlen inside {8'd1, 8'd3, 8'd7, 8'd15}))
  `AXI_MASTER_CHK(a_ar_wrap_len,
    @(posedge aclk) disable iff (!aresetn) (arvalid && arburst == AXI_BURST_WRAP) |->
      (arlen inside {8'd1, 8'd3, 8'd7, 8'd15}))

  `AXI_MASTER_CHK(a_aw_wrap_aligned,
    @(posedge aclk) disable iff (!aresetn) (awvalid && awburst == AXI_BURST_WRAP) |->
      (awaddr == axi_aligned_addr(awaddr, awsize)))
  `AXI_MASTER_CHK(a_ar_wrap_aligned,
    @(posedge aclk) disable iff (!aresetn) (arvalid && arburst == AXI_BURST_WRAP) |->
      (araddr == axi_aligned_addr(araddr, arsize)))

  // FIXED is capped at 16 beats.
  `AXI_MASTER_CHK(a_aw_fixed_len,
    @(posedge aclk) disable iff (!aresetn) (awvalid && awburst == AXI_BURST_FIXED) |-> (awlen <= 8'd15))
  `AXI_MASTER_CHK(a_ar_fixed_len,
    @(posedge aclk) disable iff (!aresetn) (arvalid && arburst == AXI_BURST_FIXED) |-> (arlen <= 8'd15))

  // The 4KB rule. Calls the same package function the stimulus constraints and
  // the C++ model use, so all three agree on the arithmetic by construction.
  `AXI_MASTER_CHK(a_aw_no_4k_cross,
    @(posedge aclk) disable iff (!aresetn) awvalid |-> !axi_crosses_4k(awaddr, awlen, awsize, awburst))
  `AXI_MASTER_CHK(a_ar_no_4k_cross,
    @(posedge aclk) disable iff (!aresetn) arvalid |-> !axi_crosses_4k(araddr, arlen, arsize, arburst))

  // Exclusive access: <=16 beats, total bytes a power of two up to 128, address
  // aligned to that total.
  `AXI_MASTER_CHK(a_aw_excl_legal,
    @(posedge aclk) disable iff (!aresetn) (awvalid && awlock) |->
      axi_exclusive_legal(awaddr, awlen, awsize))
  `AXI_MASTER_CHK(a_ar_excl_legal,
    @(posedge aclk) disable iff (!aresetn) (arvalid && arlock) |->
      axi_exclusive_legal(araddr, arlen, arsize))

  //==========================================================================
  // 5. Beat counting
  //
  // W beats belong to the oldest un-served AW: AXI4 removed write interleaving
  // and has no WID, so a plain FIFO of expected lengths is exact.
  //
  // Written with scalars and a fixed array, no queue. The earlier version used a
  // SystemVerilog queue inside the property and XSim reports
  //
  //   Unsupported feature in assertion/property/sequence
  //   'Dynamic array inside concurrent assertion'
  //
  // and DROPS the assertion -- both beat-count checks were silently dead until
  // tb_checker_neg.sv fed the checker an illegal burst and nothing happened.
  //
  // AXI4 also allows write data to arrive BEFORE its address. The crossbar's W
  // skid buffer makes that routine, so the pairing below handles it: a W burst
  // that completes with no AW buffered is counted as "early" and the next AW to
  // arrive is consumed by it instead of being queued. (The queue version would
  // have mis-paired every burst after the first early one.)
  //==========================================================================
  localparam int N_IDS = 1 << ID_W;
  localparam int LQ    = 16;                 // AW lengths awaiting their W burst

  wire aw_hs     = awvalid & awready;
  wire w_hs      = wvalid  & wready;
  wire w_last_hs = w_hs & wlast;
  wire b_hs      = bvalid  & bready;
  wire ar_hs     = arvalid & arready;
  wire r_last_hs = rvalid  & rready & rlast;

  logic [7:0] aw_len_buf [LQ];
  logic [3:0] aw_wp, aw_rp;
  integer     aw_cnt;            // AWs buffered, waiting for their W burst
  integer     w_early;           // W bursts that finished before their AW arrived
  logic [7:0] w_count;           // beats of the current W burst accepted so far

  // Lengths of the bursts counted in w_early, oldest first. Without them an
  // early burst is paired with its AW later and never length-checked, which
  // blinds the master-side check exactly when the slave is slow -- W then runs
  // ahead of AW through the crossbar's skid buffer, and that is the normal case
  // under backpressure. (Found by tests/axi_inj_wlast_early_test: the violation
  // was reported on the slave side only.)
  logic [7:0] ew_len_buf [LQ];
  logic [3:0] ew_wp, ew_rp;

  // Both buffered and early can never be non-zero together, so one cycle's
  // events decide the update unambiguously (see the case analysis in the notes).
  wire push_en   = aw_hs && (w_early == 0) && !(w_last_hs && aw_cnt == 0);
  wire pop_en    = w_last_hs && (aw_cnt > 0);
  wire early_inc = w_last_hs && (aw_cnt == 0) && !(aw_hs && w_early == 0);
  wire early_dec = aw_hs && (w_early > 0);

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_wp <= '0; aw_rp <= '0; aw_cnt <= 0; w_early <= 0; w_count <= '0;
      ew_wp <= '0; ew_rp <= '0;
    end
    else begin
      if (push_en && aw_cnt < LQ) begin
        aw_len_buf[aw_wp] <= awlen;
        aw_wp             <= aw_wp + 4'd1;
      end
      if (pop_en) aw_rp <= aw_rp + 4'd1;
      if (early_inc && w_early < LQ) begin
        ew_len_buf[ew_wp] <= w_count;          // index of the last beat == AWLEN it should match
        ew_wp             <= ew_wp + 4'd1;
      end
      if (early_dec) ew_rp <= ew_rp + 4'd1;

      aw_cnt  <= aw_cnt  + ((push_en && aw_cnt < LQ) ? 1 : 0) - (pop_en ? 1 : 0);
      w_early <= w_early + (early_inc ? 1 : 0) - (early_dec ? 1 : 0);

      if (w_hs) w_count <= wlast ? 8'd0 : w_count + 8'd1;
    end
  end

  // The length the oldest buffered AW promised. A scalar, computed outside the
  // property: XSim cannot index an unpacked array from inside one.
  wire [7:0] aw_head_len = aw_len_buf[aw_rp];
  wire [7:0] ew_head_len = ew_len_buf[ew_rp];
  wire       have_aw     = (aw_cnt > 0);

  // WLAST must land on exactly the beat AWLEN implies -- not early, not late.
  // The comparison happens when BOTH halves of the pair are known, which is one of
  // three moments:
  //   (a) the burst ends and its AW was already buffered,
  //   (b) the burst ends in the same cycle its AW is accepted (nothing else pending),
  //   (c) the AW is accepted for a burst that had already ended (early burst).
  // The cases are mutually exclusive (aw_cnt and w_early are never both non-zero),
  // so one property covers them with a selected pair of values.
  wire       len_chk_a   = w_last_hs && have_aw;
  wire       len_chk_b   = w_last_hs && aw_hs && (aw_cnt == 0) && (w_early == 0);
  wire       len_chk_c   = early_dec;
  wire       len_chk     = len_chk_a || len_chk_b || len_chk_c;
  wire [7:0] len_actual   = len_chk_c ? ew_head_len : w_count;
  wire [7:0] len_expected = len_chk_a ? aw_head_len : awlen;

  `AXI_MASTER_CHK(a_wlast_beat_count,
    @(posedge aclk) disable iff (!aresetn) len_chk |-> (len_actual == len_expected))

  `AXI_MASTER_CHK(a_w_not_past_end,
    @(posedge aclk) disable iff (!aresetn) (w_hs && !wlast && have_aw) |->
      (w_count < aw_head_len))

  //==========================================================================
  // 6. Response rules
  //==========================================================================

  // EXOKAY is only ever a response to an exclusive access. A slave returning it
  // for a normal access would make a master believe an exclusive sequence
  // succeeded when none was requested.
  logic ar_excl_seen [N_IDS];
  logic aw_excl_seen [N_IDS];

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      for (int i = 0; i < N_IDS; i++) begin
        ar_excl_seen[i] <= 1'b0;
        aw_excl_seen[i] <= 1'b0;
      end
    end
    else begin
      if (ar_hs) ar_excl_seen[arid] <= arlock;
      if (aw_hs) aw_excl_seen[awid] <= awlock;
    end
  end

  // Scalars, for the same reason as above: the array lookup must not be inside
  // the property.
  wire b_was_excl = aw_excl_seen[bid];
  wire r_was_excl = ar_excl_seen[rid];

  `AXI_SLAVE_CHK(a_bresp_exokay_only_if_excl,
    @(posedge aclk) disable iff (!aresetn) (b_hs && bresp == AXI_RESP_EXOKAY) |-> b_was_excl)

  `AXI_SLAVE_CHK(a_rresp_exokay_only_if_excl,
    @(posedge aclk) disable iff (!aresetn) (rvalid && rready && rresp == AXI_RESP_EXOKAY) |->
      r_was_excl)

  //==========================================================================
  // 7. No X or Z on control while VALID
  //
  // Data is excluded on purpose: byte lanes outside the active range of a
  // narrow transfer are architecturally don't-care and may legitimately be X.
  //
  // Reduction XOR instead of $isunknown(): XSim drops a concurrent assertion
  // that calls $isunknown ("Assertion not supported ... will be ignored"), and
  // all five of these were dead for that reason. XOR-reducing a vector yields X
  // if ANY bit is X or Z, which is exactly the question being asked, and it
  // needs nothing XSim lacks.
  //==========================================================================
  wire aw_ctl_x = ((^{awid, awaddr, awlen, awsize, awburst, awlock}) === 1'bx);
  wire ar_ctl_x = ((^{arid, araddr, arlen, arsize, arburst, arlock}) === 1'bx);
  wire w_ctl_x  = ((^{wstrb, wlast})            === 1'bx);
  wire b_ctl_x  = ((^{bid, bresp})              === 1'bx);
  wire r_ctl_x  = ((^{rid, rresp, rlast})       === 1'bx);

  `AXI_MASTER_CHK(a_aw_no_x, @(posedge aclk) disable iff (!aresetn) awvalid |-> !aw_ctl_x)
  `AXI_MASTER_CHK(a_ar_no_x, @(posedge aclk) disable iff (!aresetn) arvalid |-> !ar_ctl_x)
  `AXI_MASTER_CHK(a_w_no_x,  @(posedge aclk) disable iff (!aresetn) wvalid  |-> !w_ctl_x)
  `AXI_SLAVE_CHK (a_b_no_x,  @(posedge aclk) disable iff (!aresetn) bvalid  |-> !b_ctl_x)
  `AXI_SLAVE_CHK (a_r_no_x,  @(posedge aclk) disable iff (!aresetn) rvalid  |-> !r_ctl_x)

  //==========================================================================
  // 8. Bounded liveness
  //
  // A watchdog counter and a scalar compare, not `|-> ##[1:MAX_LATENCY] resp`.
  // XSim ignores the ranged-delay form here ("Assertion not supported"), and a
  // property that is silently dropped is worse than none -- it reads as proof.
  //
  // "Owed" is deliberately conservative about whose fault a missing response is:
  //   writes: a response is only owed once BOTH the address and the final data
  //           beat have been accepted. A master that withholds its data has not
  //           been failed by the slave.
  //   reads : a response is owed as soon as the address is accepted.
  // The watchdog counts consecutive cycles with a response owed and none given.
  //==========================================================================
  integer aw_tot, wl_tot, b_tot, ar_tot, rl_tot;
  integer wd_w, wd_r;

  wire signed [31:0] wr_owed = ((aw_tot < wl_tot) ? aw_tot : wl_tot) - b_tot;
  wire signed [31:0] rd_owed = ar_tot - rl_tot;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      aw_tot <= 0; wl_tot <= 0; b_tot <= 0; ar_tot <= 0; rl_tot <= 0;
      wd_w <= 0; wd_r <= 0;
    end
    else begin
      aw_tot <= aw_tot + (aw_hs     ? 1 : 0);
      wl_tot <= wl_tot + (w_last_hs ? 1 : 0);
      b_tot  <= b_tot  + (b_hs      ? 1 : 0);
      ar_tot <= ar_tot + (ar_hs     ? 1 : 0);
      rl_tot <= rl_tot + (r_last_hs ? 1 : 0);
      wd_w   <= (wr_owed > 0 && !b_hs)      ? wd_w + 1 : 0;
      wd_r   <= (rd_owed > 0 && !r_last_hs) ? wd_r + 1 : 0;
    end
  end

  `AXI_SLAVE_CHK(a_write_completes,
    @(posedge aclk) disable iff (!aresetn) (wd_w <= MAX_WR_LATENCY))

  `AXI_SLAVE_CHK(a_read_completes,
    @(posedge aclk) disable iff (!aresetn) (wd_r <= MAX_RD_LATENCY))

  `undef AXI_MASTER_CHK
  `undef AXI_SLAVE_CHK

endmodule : axi4_protocol_checker

`endif // AXI4_PROTOCOL_CHECKER_SV
