//==============================================================================
// soc_ref_model.h
//
// C++ golden model of the SoC subsystem's memory behaviour.
//
// This model is the authority on WHAT a transaction does: byte-level memory
// contents, which addresses map where, which responses come back, and whether
// an exclusive access succeeds. It is deliberately ignorant of WHEN anything
// happens -- no clocks, no latency, no handshakes. Timing is the SVA checkers'
// job, and keeping the two concerns apart is what stops this model from slowly
// turning into a second, worse copy of the RTL.
//
// The AXI address arithmetic here mirrors rtl/common/axi4_pkg.sv. The two are
// cross-checked by ref_selftest(), which the base test calls at time 0 -- a
// silent divergence between them would make every scoreboard comparison
// meaningless, so it is worth failing loudly and early.
//==============================================================================
#ifndef SOC_REF_MODEL_H
#define SOC_REF_MODEL_H

#include <cstdint>
#include <vector>

namespace soc_ref {

// AXI response encodings, matching axi4_pkg::axi_resp_e.
enum Resp { RESP_OKAY = 0, RESP_EXOKAY = 1, RESP_SLVERR = 2, RESP_DECERR = 3 };

// AXI burst types, matching axi4_pkg::axi_burst_e.
enum Burst { BURST_FIXED = 0, BURST_INCR = 1, BURST_WRAP = 2, BURST_RSVD = 3 };

enum Region { RGN_UNMAPPED = -1, RGN_SRAM = 0, RGN_AHB = 1, RGN_CSR = 2 };

// Address map. Windows are sized to the physical resource behind them, so
// nothing aliases (spec decision G3). Must stay in step with axi4_pkg.sv.
static const uint32_t SRAM_BASE = 0x00000000u;
static const uint32_t SRAM_SIZE = 0x00010000u;   //  64 KB
// Phase 3: the AXI2AHB bridge and its AHB slaves. Must stay in step with
// axi4_pkg.sv and ahb_pkg.sv.
static const uint32_t AHB_BASE  = 0x10000000u;
static const uint32_t AHB_SIZE  = 0x00100000u;   //   1 MB

// AHB sub-map. Anything inside the window but outside these reaches the AHB
// default slave and comes back as SLVERR.
static const uint32_t AHB_ROM_BASE  = 0x10000000u;
static const uint32_t AHB_ROM_SIZE  = 0x00004000u;   // 16 KB, read-only
static const uint32_t AHB_REG_BASE  = 0x10010000u;
static const uint32_t AHB_REG_SIZE  = 0x00001000u;   //  4 KB
static const uint32_t AHB_WAIT_BASE = 0x10020000u;
static const uint32_t AHB_WAIT_SIZE = 0x00001000u;   //  4 KB
// The wait/error slave picks its behaviour from the address: bits [7:4] give
// the wait-state count and bit [9] makes it answer ERROR.
//
// Bit 9, not bit 11. AHB bursts may not cross a 1KB boundary, and the bridge
// restarts every burst with a fresh NONSEQ at one. An error boundary on a 1KB
// multiple (0x800 was one) therefore always fell on the FIRST transfer of a burst,
// and an ERROR in the middle of an AHB burst -- the case the bridge's cancel-the-
// next-address logic exists for -- could never be produced. A 512-byte boundary can
// sit inside a burst.
static const uint32_t AHB_WAIT_ERR_BIT = 0x200u;
static const uint32_t CSR_BASE  = 0x20000000u;
static const uint32_t CSR_SIZE  = 0x00001000u;   //   4 KB

static const int BUS_BYTES  = 8;                 // 64-bit AXI data bus
static const int EXCL_SLOTS = 4;                 // per exclusive-capable slave
static const int EXCL_REGIONS = 2;               // SRAM, CSR (the AHB bridge has none)

// Boot ROM contents. The RTL fills the ROM with the same function in an initial
// block, so reads of it are fully predictable. The ROM is the only memory that
// has defined contents before the first write.
inline uint8_t rom_byte(uint32_t off) {
  return static_cast<uint8_t>((off * 37u + (off >> 8) * 5u + 11u) & 0xFFu);
}

//------------------------------------------------------------------------------
// AXI address arithmetic (mirrors axi4_pkg.sv)
//------------------------------------------------------------------------------
uint32_t bytes_per_beat(int size);
uint32_t burst_bytes(int len, int size);
uint32_t aligned_addr(uint32_t addr, int size);
uint32_t beat_addr(uint32_t start, int len, int size, int burst, int beat);
void     byte_lanes(uint32_t start, int len, int size, int burst,
                    int beat, int data_bytes, int *lo, int *hi);
bool     crosses_4k(uint32_t addr, int len, int size, int burst);

Region   decode(uint32_t addr);

//------------------------------------------------------------------------------
// Exclusive-access reservation, mirroring the monitor in axi4_sram_ctrl.sv.
//------------------------------------------------------------------------------
struct Reservation {
  bool     valid;
  uint32_t id;
  uint32_t addr;    // aligned to the exclusive byte count
  uint32_t bytes;
  Reservation() : valid(false), id(0), addr(0), bytes(0) {}
};

//------------------------------------------------------------------------------
// A transaction staged one beat at a time, then committed.
//
// Staging rather than passing arrays across the DPI boundary is a deliberate
// portability choice: svOpenArrayHandle marshalling is the least portable part
// of DPI and the first thing to break under XSim on Windows, which is the exact
// risk spec decision G5 exists to avoid. Every argument here is a scalar.
//------------------------------------------------------------------------------
struct Txn {
  uint32_t addr;
  int      len;      // AxLEN: beats - 1
  int      size;     // AxSIZE: log2(bytes per beat)
  int      burst;
  bool     lock;
  uint32_t id;
  bool     is_write;

  std::vector<uint64_t> wdata;
  std::vector<uint32_t> wstrb;
  std::vector<uint64_t> rdata;
  std::vector<uint32_t> rmask;

  Txn() : addr(0), len(0), size(0), burst(BURST_INCR),
          lock(false), id(0), is_write(false) {}
};

//------------------------------------------------------------------------------
// The model itself.
//------------------------------------------------------------------------------
class RefModel {
public:
  RefModel();

  void reset();

  // Standalone mode changes only what an unmapped address returns.
  //
  // With the crossbar present (Phase 2 onward) an unmapped address never
  // reaches a slave at all -- the default slave answers DECERR. In Phase 1 the
  // agent is wired straight to the SRAM controller, so an out-of-window address
  // does reach a slave, which answers SLVERR. Same stimulus, different correct
  // answer, purely because of what is between the master and the memory.
  //
  // Making that explicit avoids a confusing Phase 2 regression where previously
  // passing tests start reporting the wrong error code.
  void set_standalone(bool s) { standalone_ = s; }

  void txn_begin(uint32_t addr, int len, int size, int burst,
                 bool lock, uint32_t id, bool is_write);
  void txn_wdata(int beat, uint64_t data, uint32_t strb);
  int  txn_commit();                 // returns a Resp
  uint64_t txn_rdata(int beat) const;

  // Byte lanes of read beat `beat` whose value the model actually knows. A
  // never-written RAM byte has undefined contents in the RTL (XSim: X), so the
  // scoreboard must not compare it -- but it MUST compare, and reject X in,
  // every byte this mask marks as defined.
  uint32_t txn_rmask(int beat) const;

  int  peek(uint32_t addr) const;    // one byte, or -1 if unmapped

  static int selftest();             // 0 == pass

private:
  bool     mapped(uint32_t addr) const;
  uint8_t* byte_ptr(uint32_t addr);
  const uint8_t* byte_ptr(uint32_t addr) const;

  // Does an AHB access to this byte fail? Mirrors the slaves in
  // rtl/ahb/ahb_subsystem.sv.
  bool ahb_byte_errors(uint32_t addr, bool is_write) const;

  // Exclusive monitors are per slave, exactly as in the RTL: each
  // axi4_sram_ctrl instance owns its own reservation table. One shared table
  // would let a reservation at the SRAM evict one at the CSR file.
  static int excl_region(uint32_t addr);          // 0 SRAM, 1 CSR, -1 unsupported
  int  excl_find(int r, uint32_t id) const;
  int  excl_free(int r) const;
  // Clear reservations overlapping [lo,hi]. `except_id` keeps one ID's own slot.
  void excl_clear_overlap(int r, uint32_t lo, uint32_t hi, int64_t except_id);
  bool byte_defined(uint32_t addr) const;

  std::vector<uint8_t> sram_, sram_v_;   // contents, and "has been written"
  std::vector<uint8_t> ahb_,  ahb_v_;
  std::vector<uint8_t> csr_,  csr_v_;
  Reservation          excl_[EXCL_REGIONS][EXCL_SLOTS];
  Txn                  cur_;
  bool                 standalone_;
};

RefModel& instance();

} // namespace soc_ref

#endif // SOC_REF_MODEL_H
