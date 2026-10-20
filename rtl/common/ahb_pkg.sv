//==============================================================================
// ahb_pkg.sv
//
// AHB-Lite encodings and the sub-map behind the AXI2AHB bridge.
//
// Reference: ARM IHI 0033 (AMBA 3 AHB-Lite Protocol Specification).
//==============================================================================
`ifndef AHB_PKG_SV
`define AHB_PKG_SV

package ahb_pkg;

  parameter int AHB_ADDR_W = 32;
  parameter int AHB_DATA_W = 32;

  typedef enum logic [1:0] {
    HTRANS_IDLE   = 2'b00,
    HTRANS_BUSY   = 2'b01,
    HTRANS_NONSEQ = 2'b10,
    HTRANS_SEQ    = 2'b11
  } ahb_trans_e;

  typedef enum logic [2:0] {
    HBURST_SINGLE = 3'b000,
    HBURST_INCR   = 3'b001,   // undefined length
    HBURST_WRAP4  = 3'b010,
    HBURST_INCR4  = 3'b011,
    HBURST_WRAP8  = 3'b100,
    HBURST_INCR8  = 3'b101,
    HBURST_WRAP16 = 3'b110,
    HBURST_INCR16 = 3'b111
  } ahb_burst_e;

  typedef enum logic [2:0] {
    HSIZE_BYTE = 3'b000,
    HSIZE_HALF = 3'b001,
    HSIZE_WORD = 3'b010
  } ahb_size_e;

  // AHB-Lite has a one-bit response. RETRY and SPLIT belong to full AHB.
  typedef enum logic {
    HRESP_OKAY  = 1'b0,
    HRESP_ERROR = 1'b1
  } ahb_resp_e;

  //--------------------------------------------------------------------------
  // Sub-map inside the AXI window at 0x1000_0000.
  //
  // Sized to the resources behind them, per spec decision G3. Anything else in
  // the 1 MB window reaches the AHB default slave, which answers ERROR -- and
  // that becomes SLVERR at the AXI side. Distinct from DECERR, which only the
  // AXI default slave produces for an address that decodes to no slave at all.
  //--------------------------------------------------------------------------
  parameter logic [31:0] AHB_ROM_BASE  = 32'h1000_0000;
  parameter int          AHB_ROM_SIZE  = 32'h0000_4000;   // 16 KB, read-only
  parameter logic [31:0] AHB_REG_BASE  = 32'h1001_0000;
  parameter int          AHB_REG_SIZE  = 32'h0000_1000;   //  4 KB
  parameter logic [31:0] AHB_WAIT_BASE = 32'h1002_0000;
  parameter int          AHB_WAIT_SIZE = 32'h0000_1000;   //  4 KB

  typedef enum int {
    AHB_SEL_ROM  = 0,
    AHB_SEL_REG  = 1,
    AHB_SEL_WAIT = 2,
    AHB_SEL_NONE = 3     // default slave -> ERROR
  } ahb_sel_e;

  function automatic ahb_sel_e ahb_decode(input logic [AHB_ADDR_W-1:0] a);
    if (a >= AHB_ROM_BASE  && a < AHB_ROM_BASE  + AHB_ADDR_W'(AHB_ROM_SIZE))
      return AHB_SEL_ROM;
    if (a >= AHB_REG_BASE  && a < AHB_REG_BASE  + AHB_ADDR_W'(AHB_REG_SIZE))
      return AHB_SEL_REG;
    if (a >= AHB_WAIT_BASE && a < AHB_WAIT_BASE + AHB_ADDR_W'(AHB_WAIT_SIZE))
      return AHB_SEL_WAIT;
    return AHB_SEL_NONE;
  endfunction

  // Beats implied by a fixed-length HBURST. Undefined-length INCR returns 0.
  function automatic int unsigned ahb_burst_beats(input logic [2:0] hb);
    case (hb)
      HBURST_WRAP4,  HBURST_INCR4:  return 4;
      HBURST_WRAP8,  HBURST_INCR8:  return 8;
      HBURST_WRAP16, HBURST_INCR16: return 16;
      HBURST_SINGLE:                return 1;
      default:                      return 0;   // INCR, undefined length
    endcase
  endfunction

  function automatic bit ahb_is_wrap(input logic [2:0] hb);
    return (hb == HBURST_WRAP4) || (hb == HBURST_WRAP8) || (hb == HBURST_WRAP16);
  endfunction

endpackage : ahb_pkg

`endif // AHB_PKG_SV
