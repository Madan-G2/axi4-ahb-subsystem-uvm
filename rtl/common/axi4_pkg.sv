//==============================================================================
// axi4_pkg.sv
//
// Shared AXI4 types, parameters and address-arithmetic helpers.
//
// The address helpers in this file are the single source of truth for AXI burst
// address generation. They are reused by:
//   - rtl/axi/axi4_sram_ctrl.sv     (to place beats in memory)
//   - verif/sva/axi4_protocol_checker.sv (to check DUT-generated addresses)
//   - verif/uvm/env/soc_scoreboard.sv    (to predict expected beats)
// The C++ reference model mirrors them in soc_ref_model.cpp; any change here
// must be mirrored there, and ref_selftest() cross-checks the two.
//
// Reference: ARM IHI 0022 (AMBA AXI and ACE Protocol Specification), section
// A3.4.1 "Address structure" and the Transfer_Bytes pseudocode in A3.4.3.
//==============================================================================
`ifndef AXI4_PKG_SV
`define AXI4_PKG_SV

package axi4_pkg;

  //--------------------------------------------------------------------------
  // Default bus geometry. Modules parameterise from these so an alternative
  // configuration can be elaborated without editing the package.
  //--------------------------------------------------------------------------
  parameter int AXI_ADDR_W = 32;
  parameter int AXI_DATA_W = 64;
  parameter int AXI_STRB_W = AXI_DATA_W / 8;
  parameter int AXI_ID_W   = 4;
  parameter int AXI_LEN_W  = 8;   // AXI4: up to 256 beats for INCR

  parameter int AXI_4K     = 4096;

  //--------------------------------------------------------------------------
  // Encodings
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] {
    AXI_BURST_FIXED = 2'b00,
    AXI_BURST_INCR  = 2'b01,
    AXI_BURST_WRAP  = 2'b10,
    AXI_BURST_RSVD  = 2'b11
  } axi_burst_e;

  typedef enum logic [1:0] {
    AXI_RESP_OKAY   = 2'b00,
    AXI_RESP_EXOKAY = 2'b01,
    AXI_RESP_SLVERR = 2'b10,
    AXI_RESP_DECERR = 2'b11
  } axi_resp_e;

  // AXI4 reduced AxLOCK to a single bit (AXI3 had two).
  typedef enum logic {
    AXI_LOCK_NORMAL    = 1'b0,
    AXI_LOCK_EXCLUSIVE = 1'b1
  } axi_lock_e;

  //--------------------------------------------------------------------------
  // Address map. Windows are sized to the physical resource behind them, so no
  // address ever aliases (spec decision G3). Anything outside every window is
  // unmapped and answered by the AXI default slave with DECERR.
  //--------------------------------------------------------------------------
  typedef enum int {
    RGN_SRAM    = 0,
    RGN_AHB     = 1,
    RGN_CSR     = 2,
    RGN_UNMAPPED = -1
  } axi_region_e;

  parameter logic [31:0] SRAM_BASE = 32'h0000_0000;
  parameter logic [31:0] SRAM_MASK = 32'hFFFF_0000;   //  64 KB
  parameter int          SRAM_SIZE = 32'h0001_0000;

  // Phase 3: the AXI2AHB bridge and its AHB subsystem sit behind this window.
  // Widened back to 1 MB now that there are real resources inside it (see
  // ahb_pkg for the sub-map). Addresses inside the window but outside every AHB
  // slave reach the AHB default slave and come back as SLVERR -- reached a
  // slave, which refused -- as distinct from DECERR for an address that decodes
  // to no AXI slave at all.
  parameter logic [31:0] AHB_BASE  = 32'h1000_0000;
  parameter logic [31:0] AHB_MASK  = 32'hFFF0_0000;   //   1 MB
  parameter int          AHB_SIZE  = 32'h0010_0000;

  parameter logic [31:0] CSR_BASE  = 32'h2000_0000;
  parameter logic [31:0] CSR_MASK  = 32'hFFFF_F000;   //   4 KB
  parameter int          CSR_SIZE  = 32'h0000_1000;

  // Firmware partition inside SRAM (spec decision G4). The I-cache does not
  // snoop, so M1/M2 must never write the region the CPU fetches from. Enforced
  // as a constraint in soc_base_seq, not merely by convention.
  parameter logic [31:0] FW_BASE   = 32'h0000_0000;
  parameter int          FW_SIZE   = 32'h0000_8000;   //  low 32 KB, CPU only
  parameter logic [31:0] SHARED_BASE = 32'h0000_8000; // high 32 KB, all masters

  function automatic axi_region_e axi_decode(input logic [AXI_ADDR_W-1:0] addr);
    if ((addr & SRAM_MASK) == SRAM_BASE) return RGN_SRAM;
    if ((addr & AHB_MASK)  == AHB_BASE)  return RGN_AHB;
    if ((addr & CSR_MASK)  == CSR_BASE)  return RGN_CSR;
    return RGN_UNMAPPED;
  endfunction

  //--------------------------------------------------------------------------
  // Address arithmetic
  //--------------------------------------------------------------------------

  // Bytes moved per beat = 2**AxSIZE.
  function automatic int unsigned axi_bytes_per_beat(input logic [2:0] size);
    return (1 << size);
  endfunction

  // Total bytes spanned by the burst, ignoring an unaligned start.
  function automatic int unsigned axi_burst_bytes(input logic [7:0] len,
                                                  input logic [2:0] size);
    return (int'(len) + 1) * axi_bytes_per_beat(size);
  endfunction

  // Start address rounded down to the beat size.
  function automatic logic [AXI_ADDR_W-1:0] axi_aligned_addr(
      input logic [AXI_ADDR_W-1:0] addr, input logic [2:0] size);
    int unsigned nb = axi_bytes_per_beat(size);
    return addr & ~(AXI_ADDR_W'(nb - 1));
  endfunction

  // Lower boundary of the WRAP container. Container size is
  // bytes_per_beat * burst_length, which for legal WRAP lengths (2/4/8/16) is
  // always a power of two, so the mask form is exact.
  function automatic logic [AXI_ADDR_W-1:0] axi_wrap_lower(
      input logic [AXI_ADDR_W-1:0] addr, input logic [7:0] len,
      input logic [2:0] size);
    int unsigned container = axi_burst_bytes(len, size);
    return addr & ~(AXI_ADDR_W'(container - 1));
  endfunction

  // Address of beat N (0-based). This is the canonical generator; everything
  // that needs a beat address calls this rather than recomputing it.
  function automatic logic [AXI_ADDR_W-1:0] axi_beat_addr(
      input logic [AXI_ADDR_W-1:0] start_addr,
      input logic [7:0]            len,
      input logic [2:0]            size,
      input logic [1:0]            burst,
      input int unsigned           beat);

    int unsigned              nb      = axi_bytes_per_beat(size);
    logic [AXI_ADDR_W-1:0]    aligned = axi_aligned_addr(start_addr, size);
    logic [AXI_ADDR_W-1:0]    a;
    int unsigned              container;
    logic [AXI_ADDR_W-1:0]    lower;

    case (burst)
      AXI_BURST_FIXED: return start_addr;

      AXI_BURST_INCR: begin
        // Beat 0 keeps any unaligned offset; later beats are aligned.
        return (beat == 0) ? start_addr : (aligned + AXI_ADDR_W'(beat * nb));
      end

      AXI_BURST_WRAP: begin
        // WRAP requires an aligned start, so aligned == start_addr here.
        container = axi_burst_bytes(len, size);
        lower     = axi_wrap_lower(start_addr, len, size);
        a         = aligned + AXI_ADDR_W'(beat * nb);
        if (a >= (lower + AXI_ADDR_W'(container)))
          a = a - AXI_ADDR_W'(container);
        return a;
      end

      default: return start_addr;
    endcase
  endfunction

  // True if an INCR burst would cross a 4KB page boundary, which AXI forbids.
  // FIXED cannot cross by definition; WRAP cannot because its container is
  // power-of-two sized and aligned.
  function automatic bit axi_crosses_4k(input logic [AXI_ADDR_W-1:0] addr,
                                        input logic [7:0]            len,
                                        input logic [2:0]            size,
                                        input logic [1:0]            burst);
    int unsigned           nb;
    logic [AXI_ADDR_W-1:0] aligned, last_byte;

    if (burst != AXI_BURST_INCR) return 1'b0;

    nb        = axi_bytes_per_beat(size);
    aligned   = axi_aligned_addr(addr, size);
    last_byte = aligned + AXI_ADDR_W'(int'(len) * nb) + AXI_ADDR_W'(nb - 1);

    return (addr[AXI_ADDR_W-1:12] != last_byte[AXI_ADDR_W-1:12]);
  endfunction

  // Byte lanes occupied by beat N on a data_bytes-wide bus.
  // Implements the Lower_Byte_Lane / Upper_Byte_Lane pseudocode from A3.4.3.
  // Beat 0 is the only one that can be partially offset by an unaligned start.
  function automatic void axi_byte_lanes(
      input  logic [AXI_ADDR_W-1:0] start_addr,
      input  logic [7:0]            len,
      input  logic [2:0]            size,
      input  logic [1:0]            burst,
      input  int unsigned           beat,
      input  int unsigned           data_bytes,
      output int unsigned           lo,
      output int unsigned           hi);

    int unsigned           nb      = axi_bytes_per_beat(size);
    logic [AXI_ADDR_W-1:0] aligned = axi_aligned_addr(start_addr, size);
    logic [AXI_ADDR_W-1:0] addr_n  = axi_beat_addr(start_addr, len, size, burst, beat);
    logic [AXI_ADDR_W-1:0] bus_aligned;

    if (beat == 0) begin
      bus_aligned = start_addr & ~(AXI_ADDR_W'(data_bytes - 1));
      lo = int'(start_addr - bus_aligned);
      hi = int'((aligned + AXI_ADDR_W'(nb - 1)) - bus_aligned);
    end
    else begin
      bus_aligned = addr_n & ~(AXI_ADDR_W'(data_bytes - 1));
      lo = int'(addr_n - bus_aligned);
      hi = lo + nb - 1;
      // FIXED repeats an unaligned start address, so a bus-wide beat would run past the
      // top lane (start ...6, 8-byte beat: lanes 6..13). There are no such lanes.
      if (hi > int'(data_bytes) - 1) hi = int'(data_bytes) - 1;
    end
  endfunction

  //--------------------------------------------------------------------------
  // Legality predicates. Shared by the SVA checker and the sequence-item
  // constraints so stimulus and checking cannot disagree about what is legal.
  //--------------------------------------------------------------------------

  // Exclusive access: burst length <= 16 beats, total bytes a power of two in
  // 1..128, and the address aligned to the total byte count. (AXI4 A7.2.4)
  function automatic bit axi_exclusive_legal(input logic [AXI_ADDR_W-1:0] addr,
                                             input logic [7:0]            len,
                                             input logic [2:0]            size);
    int unsigned total = axi_burst_bytes(len, size);
    if (len > 8'd15)              return 1'b0;
    if (total > 128)              return 1'b0;
    if ((total & (total-1)) != 0) return 1'b0;   // not a power of two
    if ((addr & AXI_ADDR_W'(total-1)) != '0) return 1'b0;
    return 1'b1;
  endfunction

  // WRAP: length must be 2, 4, 8 or 16 beats and the address beat-aligned.
  function automatic bit axi_wrap_legal(input logic [AXI_ADDR_W-1:0] addr,
                                        input logic [7:0]            len,
                                        input logic [2:0]            size);
    if (!(len inside {8'd1, 8'd3, 8'd7, 8'd15})) return 1'b0;
    if (addr != axi_aligned_addr(addr, size))    return 1'b0;
    return 1'b1;
  endfunction

  // FIXED bursts are limited to 16 beats.
  function automatic bit axi_fixed_legal(input logic [7:0] len);
    return (len <= 8'd15);
  endfunction

  // Full legality check for a request, given the bus width.
  function automatic bit axi_req_legal(input logic [AXI_ADDR_W-1:0] addr,
                                       input logic [7:0]            len,
                                       input logic [2:0]            size,
                                       input logic [1:0]            burst,
                                       input logic                  lock,
                                       input int unsigned           data_bytes);
    if (burst == AXI_BURST_RSVD)                     return 1'b0;
    if (axi_bytes_per_beat(size) > data_bytes)       return 1'b0;
    if (axi_crosses_4k(addr, len, size, burst))      return 1'b0;
    if (burst == AXI_BURST_WRAP  && !axi_wrap_legal(addr, len, size)) return 1'b0;
    if (burst == AXI_BURST_FIXED && !axi_fixed_legal(len))            return 1'b0;
    if (lock && !axi_exclusive_legal(addr, len, size))                return 1'b0;
    return 1'b1;
  endfunction

endpackage : axi4_pkg

`endif // AXI4_PKG_SV
