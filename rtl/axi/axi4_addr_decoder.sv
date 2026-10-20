//==============================================================================
// axi4_addr_decoder.sv
//
// Address decode for the crossbar.
//
// The map itself lives in axi4_pkg::axi_decode(), not here. That function is
// also what the C++ reference model mirrors and what the sequences constrain
// against, so a change to the memory map cannot land in the RTL while the
// scoreboard still believes the old one.
//
// `sel` == N_S selects the default slave, which answers DECERR. Encoding the
// "no slave" case as an ordinary index keeps every downstream mux uniform and
// removes the class of bug where a decode miss quietly selects slave 0.
//==============================================================================
`ifndef AXI4_ADDR_DECODER_SV
`define AXI4_ADDR_DECODER_SV

module axi4_addr_decoder
  import axi4_pkg::*;
#(
  parameter int ADDR_W = 32,
  parameter int N_S    = 3,
  parameter int SIDXW  = $clog2(N_S + 1)
) (
  input  logic [ADDR_W-1:0] addr,
  output logic [SIDXW-1:0]  sel,
  output logic              decerr
);

  always_comb begin
    unique case (axi_decode(addr))
      RGN_SRAM: sel = SIDXW'(0);
      RGN_AHB : sel = SIDXW'(1);
      RGN_CSR : sel = SIDXW'(2);
      default : sel = SIDXW'(N_S);   // default slave
    endcase
    decerr = (sel == SIDXW'(N_S));
  end

endmodule : axi4_addr_decoder

`endif // AXI4_ADDR_DECODER_SV
