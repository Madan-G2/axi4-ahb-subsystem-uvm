//==============================================================================
// ahb_subsystem.sv
//
// AHB-Lite interconnect and slaves sitting behind the AXI2AHB bridge.
//
// Contains ahb_slave_mem (used for the boot ROM, the peripheral registers and
// the wait/error slave), ahb_error_slave, and the decoder/mux. The spec listed
// these as separate files; they are small enough that splitting them would be
// more ceremony than help, and they are only ever instantiated together.
//
// THE MUX PITFALL. HRDATA / HREADYOUT / HRESP must be selected using the
// select that was valid in the ADDRESS phase, registered forward into the data
// phase -- not the current-phase select. Muxing on the live HSEL returns the
// wrong slave's data for the last beat of every burst that is followed by an
// access to a different slave, which is intermittent and looks like a data
// corruption bug rather than a mux bug.
//==============================================================================
`ifndef AHB_SUBSYSTEM_SV
`define AHB_SUBSYSTEM_SV

//------------------------------------------------------------------------------
// Memory-backed AHB-Lite slave.
//
// READ_ONLY  : writes are refused with ERROR (the boot ROM).
// WAITGEN    : behaviour is selected by the address, so a test picks its own
//              wait-state count and error injection purely by choosing where to
//              access. No control registers, which means no ordering problem
//              between configuring the slave and using it, and the C++ model can
//              mirror it exactly.
//                addr[7:4] -> wait states (0..15)
//                addr[9]   -> respond ERROR (512-byte alternating zones; deliberately NOT
//                             on a 1KB boundary, which an AHB burst can never cross --
//                             see AHB_WAIT_ERR_BIT in soc_ref_model.h)
//------------------------------------------------------------------------------
module ahb_slave_mem
  import ahb_pkg::*;
#(
  parameter logic [31:0] BASE      = 32'h0,
  parameter int          SIZE      = 4096,
  parameter bit          READ_ONLY = 1'b0,
  parameter bit          WAITGEN   = 1'b0
) (
  input  logic        hclk,
  input  logic        hresetn,

  input  logic        hsel,
  input  logic [31:0] haddr,
  input  logic [1:0]  htrans,
  input  logic        hwrite,
  input  logic [2:0]  hsize,
  input  logic [2:0]  hburst,
  input  logic [31:0] hwdata,
  input  logic        hready,        // global HREADY from the mux

  output logic [31:0] hrdata,
  output logic        hreadyout,
  output logic        hresp
);

  logic [7:0] mem [0:SIZE-1];

  // The boot ROM comes up with a known pattern; every other memory here is
  // undefined until written, like a real SRAM. The C++ reference model fills its
  // ROM with the same function (soc_ref::rom_byte), so ROM reads are fully
  // predictable. Without this the ROM reads X, which the original scoreboard
  // silently turned into 0 -- see the note on rdata in axi4_seq_item.sv.
  initial begin
    if (READ_ONLY)
      for (int i = 0; i < SIZE; i++)
        mem[i] = 8'((i * 37 + (i >> 8) * 5 + 11) & 255);
  end

  typedef enum logic [1:0] { S_RDY, S_WAIT, S_ERR1, S_ERR2 } st_e;
  st_e         st;

  logic        d_val, d_wr, d_err;
  logic [31:0] d_addr;
  logic [2:0]  d_size;
  logic [3:0]  d_wait;
  // Declared here, not inside the loop below. An `automatic` declaration with
  // an initializer in a procedural block is not re-evaluated by XSim.
  logic [31:0] wr_ba;

  // A transfer is accepted only when the bus is free (hready), this slave is
  // selected, and HTRANS is NONSEQ or SEQ. htrans[1] distinguishes those from
  // IDLE and BUSY in one bit.
  wire acc = hready && hsel && htrans[1];

  function automatic logic [3:0] wait_of(input logic [31:0] a);
    return WAITGEN ? a[7:4] : 4'd0;
  endfunction

  function automatic bit err_of(input logic [31:0] a, input logic wr);
    if (READ_ONLY && wr) return 1'b1;
    if (WAITGEN && a[9]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic int unsigned idx(input logic [31:0] a);
    return int'(a - BASE) % SIZE;
  endfunction

  assign hreadyout = (st == S_RDY) || (st == S_ERR2);
  assign hresp     = (st == S_ERR1) || (st == S_ERR2);

  // Data phase completes on the cycle this slave asserts HREADYOUT with a
  // transfer in flight.
  wire dphase_done = d_val && hreadyout && (st != S_ERR2);

  always_comb begin
    int unsigned nb;
    hrdata = '0;
    if (d_val && !d_wr && !d_err) begin
      nb = 1 << d_size;
      for (int i = 0; i < 4; i++) begin
        // Byte lane i carries the byte at (word address + i).
        if (idx({d_addr[31:2], 2'b00} + 32'(i)) < SIZE)
          hrdata[8*i +: 8] = mem[idx({d_addr[31:2], 2'b00} + 32'(i))];
      end
    end
  end

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) begin
      st     <= S_RDY;
      d_val  <= 1'b0;
      d_wr   <= 1'b0;
      d_err  <= 1'b0;
      d_addr <= '0;
      d_size <= '0;
      d_wait <= '0;
    end
    else begin
      unique case (st)
        S_RDY: begin
          // Commit the write for the data phase that is finishing now.
          if (d_val && d_wr && !d_err) begin
            for (int i = 0; i < (1 << 3); i++) begin
              if (i < (1 << d_size)) begin
                wr_ba = d_addr + 32'(i);
                mem[idx(wr_ba)] <= hwdata[8*((d_addr[1:0] + i) % 4) +: 8];
              end
            end
          end

          d_val  <= acc;
          if (acc) begin
            d_addr <= haddr;
            d_wr   <= hwrite;
            d_size <= hsize;
            d_err  <= err_of(haddr, hwrite);
            d_wait <= wait_of(haddr);
            if (wait_of(haddr) != 4'd0)        st <= S_WAIT;
            else if (err_of(haddr, hwrite))    st <= S_ERR1;
          end
        end

        S_WAIT: begin
          if (d_wait > 4'd1) d_wait <= d_wait - 4'd1;
          else               st     <= d_err ? S_ERR1 : S_RDY;
        end

        // A two-cycle ERROR response: HRESP high with HREADYOUT low, then
        // HRESP high with HREADYOUT high. Collapsing it into one cycle is a
        // common and subtle AHB bug -- the master needs the first cycle to
        // cancel the next address phase.
        S_ERR1: st <= S_ERR2;

        S_ERR2: begin
          st    <= S_RDY;
          d_val <= 1'b0;
        end

        default: st <= S_RDY;
      endcase
    end
  end

endmodule : ahb_slave_mem


//------------------------------------------------------------------------------
// Answers every access with the two-cycle ERROR response. Reached by any
// address inside the AXI window but outside every AHB slave.
//------------------------------------------------------------------------------
module ahb_error_slave (
  input  logic        hclk,
  input  logic        hresetn,
  input  logic        hsel,
  input  logic [31:0] haddr,
  input  logic [1:0]  htrans,
  input  logic        hwrite,
  input  logic [2:0]  hsize,
  input  logic [2:0]  hburst,
  input  logic [31:0] hwdata,
  input  logic        hready,
  output logic [31:0] hrdata,
  output logic        hreadyout,
  output logic        hresp
);

  typedef enum logic [1:0] { E_RDY, E_ERR1, E_ERR2 } est_e;
  est_e st;

  wire acc = hready && hsel && htrans[1];

  assign hrdata    = '0;
  assign hreadyout = (st == E_RDY) || (st == E_ERR2);
  assign hresp     = (st == E_ERR1) || (st == E_ERR2);

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn) st <= E_RDY;
    else unique case (st)
      E_RDY:  if (acc) st <= E_ERR1;
      E_ERR1: st <= E_ERR2;
      E_ERR2: st <= E_RDY;
      default: st <= E_RDY;
    endcase
  end

endmodule : ahb_error_slave


//------------------------------------------------------------------------------
// Decoder, slaves and data-phase mux.
//------------------------------------------------------------------------------
module ahb_subsystem
  import ahb_pkg::*;
(
  input  logic        hclk,
  input  logic        hresetn,

  input  logic [31:0] haddr,
  input  logic [1:0]  htrans,
  input  logic        hwrite,
  input  logic [2:0]  hsize,
  input  logic [2:0]  hburst,
  input  logic [31:0] hwdata,
  output logic [31:0] hrdata,
  output logic        hready,
  output logic        hresp
);

  localparam int N_AHB_S = 4;   // ROM, REGS, WAITGEN, default

  logic [N_AHB_S-1:0]        hsel;
  logic [N_AHB_S-1:0][31:0]  s_hrdata;
  logic [N_AHB_S-1:0]        s_hreadyout;
  logic [N_AHB_S-1:0]        s_hresp;

  //--------------------------------------------------------------------------
  // Address-phase decode
  //--------------------------------------------------------------------------
  always_comb begin
    hsel = '0;
    unique case (ahb_decode(haddr))
      AHB_SEL_ROM : hsel[0] = 1'b1;
      AHB_SEL_REG : hsel[1] = 1'b1;
      AHB_SEL_WAIT: hsel[2] = 1'b1;
      default     : hsel[3] = 1'b1;
    endcase
  end

  //--------------------------------------------------------------------------
  // Data-phase select: the address-phase select, registered forward.
  //
  // Held while HREADY is low, because the address phase is extended for as long
  // as the current data phase is stalled.
  //--------------------------------------------------------------------------
  logic [N_AHB_S-1:0] hsel_d;

  always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn)     hsel_d <= '0;
    else if (hready)  hsel_d <= (htrans[1] ? hsel : '0);
  end

  always_comb begin
    hrdata = '0;
    hresp  = 1'b0;
    for (int i = 0; i < N_AHB_S; i++)
      if (hsel_d[i]) begin
        hrdata = s_hrdata[i];
        hresp  = s_hresp[i];
      end
    // With no data phase in flight the bus is ready by default; otherwise the
    // selected slave decides.
    hready = (hsel_d == '0) ? 1'b1 : 1'b0;
    for (int i = 0; i < N_AHB_S; i++)
      if (hsel_d[i]) hready = s_hreadyout[i];
  end

  //--------------------------------------------------------------------------
  ahb_slave_mem #(.BASE(AHB_ROM_BASE), .SIZE(AHB_ROM_SIZE), .READ_ONLY(1'b1))
    u_rom (
      .hclk, .hresetn, .hsel(hsel[0]), .haddr, .htrans, .hwrite, .hsize,
      .hburst, .hwdata, .hready,
      .hrdata(s_hrdata[0]), .hreadyout(s_hreadyout[0]), .hresp(s_hresp[0]));

  ahb_slave_mem #(.BASE(AHB_REG_BASE), .SIZE(AHB_REG_SIZE))
    u_regs (
      .hclk, .hresetn, .hsel(hsel[1]), .haddr, .htrans, .hwrite, .hsize,
      .hburst, .hwdata, .hready,
      .hrdata(s_hrdata[1]), .hreadyout(s_hreadyout[1]), .hresp(s_hresp[1]));

  ahb_slave_mem #(.BASE(AHB_WAIT_BASE), .SIZE(AHB_WAIT_SIZE), .WAITGEN(1'b1))
    u_wait (
      .hclk, .hresetn, .hsel(hsel[2]), .haddr, .htrans, .hwrite, .hsize,
      .hburst, .hwdata, .hready,
      .hrdata(s_hrdata[2]), .hreadyout(s_hreadyout[2]), .hresp(s_hresp[2]));

  ahb_error_slave u_dflt (
      .hclk, .hresetn, .hsel(hsel[3]), .haddr, .htrans, .hwrite, .hsize,
      .hburst, .hwdata, .hready,
      .hrdata(s_hrdata[3]), .hreadyout(s_hreadyout[3]), .hresp(s_hresp[3]));

endmodule : ahb_subsystem

`endif // AHB_SUBSYSTEM_SV
