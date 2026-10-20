//==============================================================================
// soc_tests.sv
//
// Phase 2 test library. Every test derives from soc_base_test, which owns the
// environment build and the reference-model handshake.
//==============================================================================
`ifndef SOC_TESTS_SV
`define SOC_TESTS_SV

//------------------------------------------------------------------------------
class soc_base_test extends uvm_test;

  `uvm_component_utils(soc_base_test)

  soc_env         env;
  axi4_agent_cfg  m_cfg [SOC_N_M];
  int unsigned    n_txn = 200;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    virtual axi4_if vif;
    super.build_phase(phase);

    if ($value$plusargs("N_TXN=%d", n_txn)) begin end

    for (int i = 0; i < SOC_N_M; i++) begin
      if (!uvm_config_db#(virtual axi4_if)::get(this, "",
                                                $sformatf("vif%0d", i), vif))
        `uvm_fatal("TEST", $sformatf("vif%0d not set in config DB (see tb_top)", i))

      m_cfg[i]                    = axi4_agent_cfg::type_id::create(
                                      $sformatf("m_cfg%0d", i));
      m_cfg[i].vif                = vif;
      m_cfg[i].is_active          = UVM_ACTIVE;
      m_cfg[i].port_name          = $sformatf("M%0d", i);
      m_cfg[i].master_idx         = i;
      m_cfg[i].max_wr_outstanding = 8;
      m_cfg[i].max_rd_outstanding = 8;

      configure(i, m_cfg[i]);

      uvm_config_db#(axi4_agent_cfg)::set(this, "env",
                                          $sformatf("m_cfg%0d", i), m_cfg[i]);
    end

    env = soc_env::type_id::create("env", this);
  endfunction

  // Hook for derived tests to adjust an agent before it is built.
  virtual function void configure(int idx, axi4_agent_cfg cfg);
  endfunction

  //--------------------------------------------------------------------------
  // Prove the C++ model agrees with axi4_pkg before trusting a single
  // comparison it makes. A silent divergence in the address arithmetic would
  // turn every scoreboard result into noise, and it would look like an RTL bug.
  //--------------------------------------------------------------------------
  function void start_of_simulation_phase(uvm_phase phase);
    int fails;
    super.start_of_simulation_phase(phase);

    fails = ref_selftest();
    if (fails != 0)
      `uvm_fatal("TEST",
        $sformatf("C++ reference model selftest failed (%0d checks). The model and axi4_pkg disagree about AXI address arithmetic -- fix that before running anything else.", fails))

    // Phase 2 onward there IS a crossbar, so an unmapped address never reaches
    // a slave: the default slave answers DECERR rather than SLVERR.
    ref_set_standalone(0);
    ref_reset();

    // The address tracker is static, so it must be cleared explicitly.
    soc_base_seq::reset_tracker();

    `uvm_info("TEST", "C++ reference model selftest passed", UVM_LOW)
  endfunction

  task run_phase(uvm_phase phase);
    phase.phase_done.set_drain_time(this, 500ns);
  endtask

endclass : soc_base_test


//------------------------------------------------------------------------------
class soc_smoke_test extends soc_base_test;

  `uvm_component_utils(soc_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_smoke_seq seq;
    super.run_phase(phase);
    phase.raise_objection(this, "smoke");
    seq = soc_smoke_seq::type_id::create("seq");
    seq.start(env.m_agent[0].seqr);
    phase.drop_objection(this, "smoke");
  endtask

endclass : soc_smoke_test


//------------------------------------------------------------------------------
// Single master, SRAM only. Kept from Phase 1 so a failure can be attributed:
// if this passes and the multi-master test does not, the bug is in the crossbar
// rather than in the slave or the agent.
//------------------------------------------------------------------------------
class axi_random_test extends soc_base_test;

  `uvm_component_utils(axi_random_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_random_seq seq;
    super.run_phase(phase);
    phase.raise_objection(this, "random");
    seq = axi4_random_seq::type_id::create("seq");
    seq.n_txn = n_txn;
    seq.start(env.m_agent[0].seqr);
    phase.drop_objection(this, "random");
  endtask

endclass : axi_random_test


//------------------------------------------------------------------------------
class axi_backpressure_test extends axi_random_test;

  `uvm_component_utils(axi_backpressure_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.b_ready_gap = 2;
    cfg.r_ready_gap = 3;
  endfunction

endclass : axi_backpressure_test


//------------------------------------------------------------------------------
// The Phase 2 headline test: three masters, three slaves, all at once.
//------------------------------------------------------------------------------
class soc_multi_master_test extends soc_base_test;

  `uvm_component_utils(soc_multi_master_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_multi_master_vseq vseq;
    super.run_phase(phase);
    phase.raise_objection(this, "mm");
    vseq = soc_multi_master_vseq::type_id::create("vseq");
    vseq.n_txn = n_txn;
    vseq.start(env.vseqr);
    phase.drop_objection(this, "mm");
  endtask

endclass : soc_multi_master_test


//------------------------------------------------------------------------------
// The same traffic with the SRAM and CSR slaves randomly withholding AWREADY, WREADY
// and ARREADY (run.py passes +SLV_BP). Master-side backpressure and slave-side
// backpressure are different tests of an arbiter: with the slave stalling, grants
// are held across cycles, queues fill, and write responses from slaves of unequal
// speed overtake one another. Added after bug A6, whose feature this exercises.
//------------------------------------------------------------------------------
class soc_multi_master_slvbp_test extends soc_multi_master_test;
  `uvm_component_utils(soc_multi_master_slvbp_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : soc_multi_master_slvbp_test


//------------------------------------------------------------------------------
// Same, but with response backpressure on every master, so the arbiters have to
// hold grants across stalls.
//------------------------------------------------------------------------------
class soc_multi_master_bp_test extends soc_multi_master_test;

  `uvm_component_utils(soc_multi_master_bp_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void configure(int idx, axi4_agent_cfg cfg);
    cfg.b_ready_gap = idx + 1;
    cfg.r_ready_gap = 3 - idx;
  endfunction

endclass : soc_multi_master_bp_test


//------------------------------------------------------------------------------
// All three masters onto one slave, so every arbiter sees real contention.
//------------------------------------------------------------------------------
class soc_arb_stress_test extends soc_base_test;

  `uvm_component_utils(soc_arb_stress_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    soc_arb_stress_vseq vseq;
    super.run_phase(phase);
    phase.raise_objection(this, "arb");
    vseq = soc_arb_stress_vseq::type_id::create("vseq");
    vseq.n_txn = n_txn;
    vseq.start(env.vseqr);
    phase.drop_objection(this, "arb");
  endtask

endclass : soc_arb_stress_test


//------------------------------------------------------------------------------
// Bridge tests. Single master so a failure is attributable to the bridge rather
// than to crossbar contention.
//------------------------------------------------------------------------------
class axi_bridge_test extends soc_base_test;

  `uvm_component_utils(axi_bridge_test)

  bit t_ahb = 1'b1, t_rom = 1'b0, t_wait = 1'b0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi4_random_seq seq;
    super.run_phase(phase);
    phase.raise_objection(this, "bridge");
    seq = axi4_random_seq::type_id::create("seq");
    seq.n_txn    = n_txn;
    seq.use_sram = 1'b0;
    seq.use_ahb  = t_ahb;
    seq.use_rom  = t_rom;
    seq.use_wait = t_wait;
    seq.start(env.m_agent[0].seqr);
    phase.drop_objection(this, "bridge");
  endtask

endclass : axi_bridge_test


// Reads succeed, writes must come back SLVERR with memory untouched.
class axi_bridge_rom_test extends axi_bridge_test;
  `uvm_component_utils(axi_bridge_rom_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    t_ahb = 1'b0; t_rom = 1'b1;
  endfunction
endclass : axi_bridge_rom_test


// Wait states from addr[7:4] and ERROR from addr[9], so a burst can be aborted
// part-way and the AXI side still has to return every beat it promised.
class axi_bridge_wait_test extends axi_bridge_test;
  `uvm_component_utils(axi_bridge_wait_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
    t_ahb = 1'b0; t_wait = 1'b1;
  endfunction
endclass : axi_bridge_wait_test


//------------------------------------------------------------------------------
// Every access decodes to no slave, so the default slave must answer DECERR
// with the right beat count and RLAST.
//------------------------------------------------------------------------------
class axi_decerr_test extends soc_base_test;

  `uvm_component_utils(axi_decerr_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    axi_decerr_seq seq;
    super.run_phase(phase);
    phase.raise_objection(this, "decerr");
    seq = axi_decerr_seq::type_id::create("seq");
    seq.n_txn = (n_txn > 50) ? 50 : n_txn;
    seq.start(env.m_agent[0].seqr);
    phase.drop_objection(this, "decerr");
  endtask

endclass : axi_decerr_test

`endif // SOC_TESTS_SV
