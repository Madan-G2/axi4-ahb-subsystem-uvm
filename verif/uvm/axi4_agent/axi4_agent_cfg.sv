//==============================================================================
// axi4_agent_cfg.sv
//
// Per-agent configuration. One instance per AXI port, handed to the agent's
// children through the config DB.
//==============================================================================
`ifndef AXI4_AGENT_CFG_SV
`define AXI4_AGENT_CFG_SV

class axi4_agent_cfg extends uvm_object;

  `uvm_object_utils(axi4_agent_cfg)

  virtual axi4_if           vif;

  uvm_active_passive_enum   is_active = UVM_ACTIVE;

  // Outstanding capacity this master will use. Kept at or below the slave's
  // depth by default; the outstanding test raises it past the slave's capacity
  // deliberately, to prove the backpressure path works.
  int unsigned              max_wr_outstanding = 8;
  int unsigned              max_rd_outstanding = 8;

  // Cycles BREADY / RREADY are held low between responses. Non-zero values
  // exercise the master-side backpressure path, which is the direction slaves
  // most often get wrong.
  int unsigned              b_ready_gap = 0;
  int unsigned              r_ready_gap = 0;

  // Percent chance, each idle cycle, that BREADY / RREADY is flipped while no
  // response is on offer. AXI lets a master raise and drop READY freely until
  // VALID is up; a slave that mishandles READY changing under it is a real bug
  // class, and a driver that parks READY high and leaves it there never finds it.
  int unsigned              ready_toggle_pct = 0;

  bit                       enable_coverage = 1'b1;

  // Used in messages and coverage bins to tell the ports apart.
  string                    port_name = "M0";
  int                       master_idx = 0;

  function new(string name = "axi4_agent_cfg");
    super.new(name);
  endfunction

endclass : axi4_agent_cfg

`endif // AXI4_AGENT_CFG_SV
