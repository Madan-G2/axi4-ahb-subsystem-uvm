//==============================================================================
// soc_directed_tests.sv
//
// Tests built on the directed sequences. Each exists because coverage measurement
// showed a hole the random tests leave (see docs/coverage_plan.md).
//==============================================================================
`ifndef SOC_DIRECTED_TESTS_SV
`define SOC_DIRECTED_TESTS_SV

//------------------------------------------------------------------------------
// A single step on a chosen master, for virtual sequences that need to interleave
// operations from different masters in a controlled order.
//------------------------------------------------------------------------------
class soc_one_shot_seq extends soc_dir_base;
  `uvm_object_utils(soc_one_shot_seq)
  axi4_seq_item item;
  function new(string name = "soc_one_shot_seq");
    super.new(name);
  endfunction
  task body();
    send(item);
  endtask
endclass : soc_one_shot_seq


//------------------------------------------------------------------------------
// Exclusive access across masters. The reservation is keyed by {master, ID}, so
// the interesting cases are all about WHO wrote in between.
//------------------------------------------------------------------------------
class soc_exclusive_mm_vseq extends soc_vseq_base;

  `uvm_object_utils(soc_exclusive_mm_vseq)

  soc_dir_base h;

  function new(string name = "soc_exclusive_mm_vseq");
    super.new(name);
  endfunction

  task step(int m, bit wr, bit [AXI_ADDR_W-1:0] a, int len, int size,
            bit [AXI_ID_W-1:0] id, bit lock);
    soc_one_shot_seq s;
    s = soc_one_shot_seq::type_id::create("s");
    s.item = h.mk(wr, a, len, size, AXI_BURST_INCR, id, lock);
    s.start(p_sequencer.seqr[m]);
  endtask

  task body();
    bit [AXI_ADDR_W-1:0] a;
    h = soc_dir_base::type_id::create("h");

    for (int pass = 0; pass < 2; pass++) begin
      // Same scenarios against the SRAM and against the CSR file; the AHB bridge
      // does not support exclusive access and is covered by axi_exclusive_test.
      a = (pass == 0 ? (SHARED_BASE + 32'h3000) : (CSR_BASE + 32'h200));

      // Seed the location.
      step(0, 1'b1, a, 1, 3, 4'd0, 1'b0);

      // A. Another master writes between M0's read and write: M0 must fail.
      step(0, 1'b0, a + 32'h00, 0, 3, 4'd1, 1'b1);
      step(1, 1'b1, a + 32'h00, 0, 3, 4'd1, 1'b0);
      step(0, 1'b1, a + 32'h00, 0, 3, 4'd1, 1'b1);
      step(0, 1'b0, a + 32'h00, 0, 3, 4'd0, 1'b0);

      // B. Both masters reserve the same location with the SAME ID. The IDs only
      //    look alike -- the crossbar prefixes the master index. M0 stores first
      //    and succeeds; that store is a write, so M1 must now fail.
      step(0, 1'b0, a + 32'h10, 0, 3, 4'd2, 1'b1);
      step(1, 1'b0, a + 32'h10, 0, 3, 4'd2, 1'b1);
      step(0, 1'b1, a + 32'h10, 0, 3, 4'd2, 1'b1);
      step(1, 1'b1, a + 32'h10, 0, 3, 4'd2, 1'b1);
      step(2, 1'b0, a + 32'h10, 0, 3, 4'd0, 1'b0);

      // C. A failed exclusive write changes nothing, so it must not disturb
      //    someone else's reservation.
      step(0, 1'b0, a + 32'h20, 0, 3, 4'd3, 1'b1);
      step(1, 1'b1, a + 32'h20, 0, 3, 4'd3, 1'b1);     // no reservation: fails
      step(0, 1'b1, a + 32'h20, 0, 3, 4'd3, 1'b1);     // M0's survives and passes
      step(2, 1'b0, a + 32'h20, 0, 3, 4'd0, 1'b0);

      // D. Three masters, one location, everyone reserves; only the first wins.
      for (int m = 0; m < 3; m++) step(m, 1'b0, a + 32'h30, 0, 3, 4'd4, 1'b1);
      for (int m = 0; m < 3; m++) step(m, 1'b1, a + 32'h30, 0, 3, 4'd4, 1'b1);
      step(1, 1'b0, a + 32'h30, 0, 3, 4'd0, 1'b0);
    end
  endtask

endclass : soc_exclusive_mm_vseq


//------------------------------------------------------------------------------
// Every master, every kind of target.
//------------------------------------------------------------------------------
class soc_all_targets_vseq extends soc_vseq_base;

  `uvm_object_utils(soc_all_targets_vseq)

  function new(string name = "soc_all_targets_vseq");
    super.new(name);
  endfunction

  task body();
    axi_all_targets_seq s [SOC_N_M];
    for (int i = 0; i < SOC_N_M; i++) begin
      s[i] = axi_all_targets_seq::type_id::create($sformatf("at%0d", i));
      s[i].n_txn = n_txn;
    end
    // The low 32KB of the SRAM belongs to the CPU (spec decision G4): master 0 is
    // the CPU's slot, so it alone may touch it.
    s[0].use_fw = 1'b1;
    fork
      s[0].start(p_sequencer.seqr[0]);
      s[1].start(p_sequencer.seqr[1]);
      s[2].start(p_sequencer.seqr[2]);
    join
  endtask

endclass : soc_all_targets_vseq


//==============================================================================
// Tests
//==============================================================================

// Runs one directed sequence class against a list of targets on master 0.
class soc_dir_test extends soc_base_test;

  `uvm_component_utils(soc_dir_test)

  soc_target_e tgts [$];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_SRAM, TGT_AHB, TGT_CSR};
  endfunction

  // Derived tests create the sequence for one target.
  virtual task run_seq(soc_target_e tgt);
  endtask

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    phase.raise_objection(this, "dir");
    foreach (tgts[i]) run_seq(tgts[i]);
    phase.drop_objection(this, "dir");
  endtask

endclass : soc_dir_test


class axi_incr_edge_test extends soc_dir_test;
  `uvm_component_utils(axi_incr_edge_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq(soc_target_e tgt);
    axi_incr_edge_seq s;
    s = axi_incr_edge_seq::type_id::create("s");
    s.tgt = tgt;
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_incr_edge_test


class axi_wrap_edge_test extends soc_dir_test;
  `uvm_component_utils(axi_wrap_edge_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq(soc_target_e tgt);
    axi_wrap_edge_seq s;
    s = axi_wrap_edge_seq::type_id::create("s");
    s.tgt = tgt;
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_wrap_edge_test


class axi_fixed_edge_test extends soc_dir_test;
  `uvm_component_utils(axi_fixed_edge_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq(soc_target_e tgt);
    axi_fixed_edge_seq s;
    s = axi_fixed_edge_seq::type_id::create("s");
    s.tgt = tgt;
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_fixed_edge_test


class axi_strobe_test extends soc_dir_test;
  `uvm_component_utils(axi_strobe_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_seq(soc_target_e tgt);
    axi_strobe_seq s;
    s = axi_strobe_seq::type_id::create("s");
    s.tgt = tgt;
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_strobe_test


class axi_exclusive_test extends soc_dir_test;
  `uvm_component_utils(axi_exclusive_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    // SRAM and the CSR file support exclusive access; the AHB register block is
    // reached through the bridge, which does not, and must answer plain OKAY.
    tgts = '{TGT_SRAM, TGT_CSR, TGT_AHB};
  endfunction
  task run_seq(soc_target_e tgt);
    axi_exclusive_seq s;
    s = axi_exclusive_seq::type_id::create("s");
    s.tgt = tgt;
    s.start(env.m_agent[0].seqr);
  endtask
  task run_phase(uvm_phase phase);
    soc_exclusive_mm_vseq v;
    super.run_phase(phase);
    phase.raise_objection(this, "excl_mm");
    v = soc_exclusive_mm_vseq::type_id::create("v");
    v.start(env.vseqr);
    phase.drop_objection(this, "excl_mm");
  endtask
endclass : axi_exclusive_test


// A few reads of different shapes through the bridge; see axi_bridge_probe_seq.
class axi_bridge_probe_test extends soc_dir_test;
  `uvm_component_utils(axi_bridge_probe_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_AHB};
  endfunction
  task run_seq(soc_target_e tgt);
    axi_bridge_probe_seq s;
    s = axi_bridge_probe_seq::type_id::create("s");
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_bridge_probe_test


class axi_ahb_forms_test extends soc_dir_test;
  `uvm_component_utils(axi_ahb_forms_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_AHB};
  endfunction
  task run_seq(soc_target_e tgt);
    axi_ahb_forms_seq s;
    s = axi_ahb_forms_seq::type_id::create("s");
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_ahb_forms_test


class axi_wait_error_test extends soc_dir_test;
  `uvm_component_utils(axi_wait_error_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_WAIT};
  endfunction
  task run_seq(soc_target_e tgt);
    axi_wait_error_seq s;
    s = axi_wait_error_seq::type_id::create("s");
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_wait_error_test


// Needs more in flight than the default agent allows.
class axi_outstanding_test extends soc_dir_test;
  `uvm_component_utils(axi_outstanding_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_SRAM};
  endfunction
  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.max_wr_outstanding = 16;
    cfg.max_rd_outstanding = 16;
  endfunction
  task run_seq(soc_target_e tgt);
    axi_outstanding_seq s;
    s = axi_outstanding_seq::type_id::create("s");
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_outstanding_test


// Fills the SRAM slave's three queues in turn. The response-READY gaps are changed
// between phases from here, which is safe: the driver reads them every cycle.
class axi_queue_full_test extends soc_dir_test;
  `uvm_component_utils(axi_queue_full_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_SRAM};
  endfunction
  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.max_wr_outstanding = 8;
    cfg.max_rd_outstanding = 8;
  endfunction
  task run_seq(soc_target_e tgt);
    axi_queue_full_seq s;
    // phase 0: AW queue -- no response gaps, data arrives late (set in the sequence)
    m_cfg[0].b_ready_gap = 0;  m_cfg[0].r_ready_gap = 0;
    s = axi_queue_full_seq::type_id::create("s_aw");
    s.phase_sel = 0;
    s.start(env.m_agent[0].seqr);
    // phase 1: B queue -- BREADY crawls
    m_cfg[0].b_ready_gap = 40;
    s = axi_queue_full_seq::type_id::create("s_b");
    s.phase_sel = 1;
    s.start(env.m_agent[0].seqr);
    // phase 2: AR queue -- RREADY crawls
    m_cfg[0].b_ready_gap = 0;  m_cfg[0].r_ready_gap = 30;
    s = axi_queue_full_seq::type_id::create("s_ar");
    s.phase_sel = 2;
    s.start(env.m_agent[0].seqr);
    m_cfg[0].r_ready_gap = 0;
  endtask
endclass : axi_queue_full_test


class soc_all_targets_test extends soc_base_test;
  `uvm_component_utils(soc_all_targets_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    soc_all_targets_vseq v;
    super.run_phase(phase);
    phase.raise_objection(this, "all_targets");
    v = soc_all_targets_vseq::type_id::create("v");
    v.n_txn = n_txn;
    v.start(env.vseqr);
    phase.drop_objection(this, "all_targets");
  endtask
endclass : soc_all_targets_test


// Long response backpressure: BREADY / RREADY held off for many cycles.
class axi_b_backpressure_test extends soc_all_targets_test;
  `uvm_component_utils(axi_b_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.b_ready_gap = 8 + 5 * idx;       // 8, 13, 18 cycles
    cfg.r_ready_gap = 4 + 6 * idx;
  endfunction
endclass : axi_b_backpressure_test


// READY toggling while idle, on both the master side (driver) and, with
// +SLV_BP, the slave side. Both are legal and both are where handshakes break.
class axi_ready_toggle_test extends soc_all_targets_test;
  `uvm_component_utils(axi_ready_toggle_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.ready_toggle_pct = 35;
    cfg.b_ready_gap      = idx;
    cfg.r_ready_gap      = idx;
  endfunction
endclass : axi_ready_toggle_test


//------------------------------------------------------------------------------
// Protocol-violation tests. Each one breaks exactly one rule and passes only if the
// checker reports exactly that, and nothing unexplained (scripts/run.py, "expect").
// Slave-side READY jitter (+SLV_BP) is what gives the driver a stall window to
// break the hold-VALID / hold-payload rules in.
//------------------------------------------------------------------------------
class axi_inject_test extends soc_dir_test;

  `uvm_component_utils(axi_inject_test)

  axi_inject_e kind = INJ_NONE;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_SRAM};
  endfunction

  // Corrupted traffic has no defined outcome to compare against.
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    env.scb.enable = 1'b0;
  endfunction

  task run_seq(soc_target_e tgt);
    axi_inject_seq s;
    s = axi_inject_seq::type_id::create("s");
    s.kind = kind;
    s.start(env.m_agent[0].seqr);
  endtask

endclass : axi_inject_test

`define AXI_INJ_TEST(NAME, KIND)                                      \
  class NAME extends axi_inject_test;                                 \
    `uvm_component_utils(NAME)                                        \
    function new(string name, uvm_component parent);                  \
      super.new(name, parent);                                        \
      kind = KIND;                                                    \
    endfunction                                                       \
  endclass : NAME

`AXI_INJ_TEST(axi_inj_aw_drop_test,    INJ_AW_DROP)
`AXI_INJ_TEST(axi_inj_aw_payload_test, INJ_AW_PAYLOAD)
`AXI_INJ_TEST(axi_inj_aw_x_test,       INJ_AW_X)
`AXI_INJ_TEST(axi_inj_ar_drop_test,    INJ_AR_DROP)
`AXI_INJ_TEST(axi_inj_ar_payload_test, INJ_AR_PAYLOAD)
`AXI_INJ_TEST(axi_inj_ar_x_test,       INJ_AR_X)
`AXI_INJ_TEST(axi_inj_w_drop_test,     INJ_W_DROP)
`AXI_INJ_TEST(axi_inj_w_payload_test,  INJ_W_PAYLOAD)
`AXI_INJ_TEST(axi_inj_w_x_test,        INJ_W_X)
`AXI_INJ_TEST(axi_inj_wlast_early_test,   INJ_WLAST_EARLY)
`AXI_INJ_TEST(axi_inj_wlast_missing_test, INJ_WLAST_MISSING)


// Illegal burst requests (content, not handshake). The scoreboard stays ON: the
// ordinary traffic around each illegal request is checked as usual.
class axi_inj_illegal_req_test extends soc_dir_test;
  `uvm_component_utils(axi_inj_illegal_req_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    tgts = '{TGT_SRAM};
  endfunction
  task run_seq(soc_target_e tgt);
    axi_illegal_req_seq s;
    s = axi_illegal_req_seq::type_id::create("s");
    s.start(env.m_agent[0].seqr);
  endtask
endclass : axi_inj_illegal_req_test

`endif // SOC_DIRECTED_TESTS_SV
