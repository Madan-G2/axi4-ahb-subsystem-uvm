//==============================================================================
// axi4_agent_pkg.sv
//
// Include order matters: each class must be compiled after everything it
// refers to by type.
//==============================================================================
`ifndef AXI4_AGENT_PKG_SV
`define AXI4_AGENT_PKG_SV

package axi4_agent_pkg;

  import uvm_pkg::*;
  import axi4_pkg::*;
  `include "uvm_macros.svh"

  `include "axi4_seq_item.sv"
  `include "axi4_agent_cfg.sv"
  `include "axi4_driver.sv"
  `include "axi4_monitor.sv"
  `include "axi4_sequencer.sv"
  `include "axi4_agent.sv"

endpackage : axi4_agent_pkg

`endif // AXI4_AGENT_PKG_SV
