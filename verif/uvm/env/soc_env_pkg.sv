//==============================================================================
// soc_env_pkg.sv
//
// Testbench-side package: DPI imports, scoreboard, virtual sequencer,
// environment, sequences and tests. Compiled after axi4_agent_pkg.
//==============================================================================
`ifndef SOC_ENV_PKG_SV
`define SOC_ENV_PKG_SV

package soc_env_pkg;

  import uvm_pkg::*;
  import axi4_pkg::*;
  import ahb_pkg::*;
  import axi4_agent_pkg::*;
  `include "uvm_macros.svh"

  // Number of master ports. Kept here rather than in axi4_pkg because it is a
  // property of this testbench's topology, not of the AXI protocol.
  parameter int SOC_N_M = 3;

  `include "soc_ref_dpi.svh"
  `include "soc_scoreboard.sv"
  `include "soc_txn_cov.sv"
  `include "soc_virtual_sequencer.sv"
  `include "soc_env.sv"
  `include "soc_seq_lib.sv"
  `include "soc_directed_seqs.sv"
  `include "soc_tests.sv"
  `include "soc_directed_tests.sv"

endpackage : soc_env_pkg

`endif // SOC_ENV_PKG_SV
