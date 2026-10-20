//==============================================================================
// axi4_agent.sv
//
// The monitor is built unconditionally. A passive agent is still a full
// participant in checking -- in Phase 5 the CPU port M0 has no driver at all,
// but its traffic must still reach the scoreboard and coverage.
//==============================================================================
`ifndef AXI4_AGENT_SV
`define AXI4_AGENT_SV

class axi4_agent extends uvm_agent;

  `uvm_component_utils(axi4_agent)

  axi4_agent_cfg                     cfg;
  axi4_driver                        drv;
  axi4_sequencer                     seqr;
  axi4_monitor                       mon;

  uvm_analysis_port #(axi4_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db#(axi4_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXI4AGT", "axi4_agent_cfg not found in config DB")

    // Push the config down so driver and monitor find it at their own level.
    uvm_config_db#(axi4_agent_cfg)::set(this, "*", "cfg", cfg);

    mon = axi4_monitor::type_id::create("mon", this);

    if (cfg.is_active == UVM_ACTIVE) begin
      drv  = axi4_driver::type_id::create("drv", this);
      seqr = axi4_sequencer::type_id::create("seqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.ap.connect(ap);
    if (cfg.is_active == UVM_ACTIVE)
      drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction

endclass : axi4_agent

`endif // AXI4_AGENT_SV
