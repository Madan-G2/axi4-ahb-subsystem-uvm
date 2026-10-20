//==============================================================================
// soc_env.sv
//
// Phase 2 environment: three AXI4 master agents into the crossbar subsystem,
// one scoreboard fed by all of them, and a virtual sequencer to coordinate.
//
// All three agents publish into the same scoreboard. That is only sound because
// soc_base_seq's shared address tracker guarantees no two masters have
// overlapping addresses in flight at once -- see the note there.
//==============================================================================
`ifndef SOC_ENV_SV
`define SOC_ENV_SV

class soc_env extends uvm_env;

  `uvm_component_utils(soc_env)

  axi4_agent            m_agent [SOC_N_M];
  axi4_agent_cfg        m_cfg   [SOC_N_M];
  soc_scoreboard        scb;
  soc_txn_cov           txn_cov;
  soc_virtual_sequencer vseqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    for (int i = 0; i < SOC_N_M; i++) begin
      if (!uvm_config_db#(axi4_agent_cfg)::get(this, "",
                                               $sformatf("m_cfg%0d", i), m_cfg[i]))
        `uvm_fatal("SOCENV", $sformatf("m_cfg%0d not found in config DB", i))
      uvm_config_db#(axi4_agent_cfg)::set(this, $sformatf("m_agent%0d", i),
                                          "cfg", m_cfg[i]);
      m_agent[i] = axi4_agent::type_id::create($sformatf("m_agent%0d", i), this);
    end

    scb     = soc_scoreboard::type_id::create("scb", this);
    txn_cov = soc_txn_cov::type_id::create("txn_cov", this);
    vseqr = soc_virtual_sequencer::type_id::create("vseqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    for (int i = 0; i < SOC_N_M; i++) begin
      m_agent[i].ap.connect(scb.axi_imp);
      m_agent[i].ap.connect(txn_cov.analysis_export);
      if (m_cfg[i].is_active == UVM_ACTIVE)
        vseqr.seqr[i] = m_agent[i].seqr;
    end
  endfunction

endclass : soc_env

`endif // SOC_ENV_SV
