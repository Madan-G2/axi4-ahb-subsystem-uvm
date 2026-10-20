//==============================================================================
// soc_virtual_sequencer.sv
//
// Holds a handle to each master's sequencer so a virtual sequence can drive all
// three ports at once. Nothing runs on this sequencer itself.
//==============================================================================
`ifndef SOC_VIRTUAL_SEQUENCER_SV
`define SOC_VIRTUAL_SEQUENCER_SV

class soc_virtual_sequencer extends uvm_sequencer;

  `uvm_component_utils(soc_virtual_sequencer)

  axi4_sequencer seqr [SOC_N_M];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass : soc_virtual_sequencer

`endif // SOC_VIRTUAL_SEQUENCER_SV
