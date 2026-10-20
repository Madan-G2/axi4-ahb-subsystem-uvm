//==============================================================================
// soc_ref_model.cpp
//
// Implementation of the C++ golden model. See soc_ref_model.h for the contract.
//==============================================================================
#include "soc_ref_model.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace soc_ref {

//==============================================================================
// AXI address arithmetic. Mirrors axi4_pkg.sv; selftest() cross-checks.
//==============================================================================

uint32_t bytes_per_beat(int size) { return 1u << size; }

uint32_t burst_bytes(int len, int size) {
  return static_cast<uint32_t>(len + 1) * bytes_per_beat(size);
}

uint32_t aligned_addr(uint32_t addr, int size) {
  return addr & ~(bytes_per_beat(size) - 1u);
}

uint32_t beat_addr(uint32_t start, int len, int size, int burst, int beat) {
  const uint32_t nb  = bytes_per_beat(size);
  const uint32_t alg = aligned_addr(start, size);

  switch (burst) {
    case BURST_FIXED:
      return start;

    case BURST_INCR:
      // Beat 0 keeps any unaligned offset; every later beat is aligned.
      return (beat == 0) ? start : (alg + static_cast<uint32_t>(beat) * nb);

    case BURST_WRAP: {
      const uint32_t container = burst_bytes(len, size);
      const uint32_t lower     = start & ~(container - 1u);
      uint32_t a = alg + static_cast<uint32_t>(beat) * nb;
      if (a >= lower + container) a -= container;
      return a;
    }

    default:
      return start;
  }
}

// Lower_Byte_Lane / Upper_Byte_Lane from AXI spec A3.4.3. Only beat 0 can be
// partially offset by an unaligned start; every later beat is fully aligned.
void byte_lanes(uint32_t start, int len, int size, int burst,
                int beat, int data_bytes, int *lo, int *hi) {
  const uint32_t nb  = bytes_per_beat(size);
  const uint32_t alg = aligned_addr(start, size);
  const uint32_t dbm = static_cast<uint32_t>(data_bytes) - 1u;

  if (beat == 0) {
    const uint32_t bus_base = start & ~dbm;
    *lo = static_cast<int>(start - bus_base);
    *hi = static_cast<int>((alg + nb - 1u) - bus_base);
  } else {
    const uint32_t an       = beat_addr(start, len, size, burst, beat);
    const uint32_t bus_base = an & ~dbm;
    *lo = static_cast<int>(an - bus_base);
    *hi = *lo + static_cast<int>(nb) - 1;
    // A FIXED burst repeats its (possibly unaligned) start address, so for a beat as
    // wide as the bus the formula above runs past the top lane (start 0x...6, 8-byte
    // beat: lanes 6..13). Those lanes do not exist. The model used to walk them anyway
    // -- shifting a 64-bit word by up to 104 bits and, once the AHB error zone moved,
    // asking whether a byte in the NEXT word errored. Clip to the bus.
    if (*hi > static_cast<int>(dbm)) *hi = static_cast<int>(dbm);
  }
}

bool crosses_4k(uint32_t addr, int len, int size, int burst) {
  if (burst != BURST_INCR) return false;
  const uint32_t nb   = bytes_per_beat(size);
  const uint32_t alg  = aligned_addr(addr, size);
  const uint32_t last = alg + static_cast<uint32_t>(len) * nb + (nb - 1u);
  return (addr >> 12) != (last >> 12);
}

Region decode(uint32_t addr) {
  if (addr >= SRAM_BASE && addr < SRAM_BASE + SRAM_SIZE) return RGN_SRAM;
  if (addr >= AHB_BASE  && addr < AHB_BASE  + AHB_SIZE)  return RGN_AHB;
  if (addr >= CSR_BASE  && addr < CSR_BASE  + CSR_SIZE)  return RGN_CSR;
  return RGN_UNMAPPED;
}

//==============================================================================
// RefModel
//==============================================================================

RefModel::RefModel()
  : sram_(SRAM_SIZE, 0), sram_v_(SRAM_SIZE, 0),
    ahb_(AHB_SIZE, 0),   ahb_v_(AHB_SIZE, 0),
    csr_(CSR_SIZE, 0),   csr_v_(CSR_SIZE, 0),
    standalone_(true) {
  reset();
}

void RefModel::reset() {
  std::fill(sram_.begin(),   sram_.end(),   0);
  std::fill(sram_v_.begin(), sram_v_.end(), 0);
  std::fill(ahb_.begin(),    ahb_.end(),    0);
  std::fill(ahb_v_.begin(),  ahb_v_.end(),  0);
  std::fill(csr_.begin(),    csr_.end(),    0);
  std::fill(csr_v_.begin(),  csr_v_.end(),  0);
  for (int r = 0; r < EXCL_REGIONS; r++)
    for (int i = 0; i < EXCL_SLOTS; i++) excl_[r][i] = Reservation();
  cur_ = Txn();

  // The boot ROM is the one memory with defined contents from time zero. The
  // RTL fills it from the same function in an initial block.
  for (uint32_t off = 0; off < AHB_ROM_SIZE; off++) {
    ahb_[off]   = rom_byte(off);
    ahb_v_[off] = 1;
  }
}

bool RefModel::mapped(uint32_t addr) const {
  const Region r = decode(addr);
  return (r == RGN_SRAM) || (r == RGN_AHB) || (r == RGN_CSR);
}

uint8_t* RefModel::byte_ptr(uint32_t addr) {
  switch (decode(addr)) {
    case RGN_SRAM: return &sram_[addr - SRAM_BASE];
    case RGN_AHB:  return &ahb_[addr - AHB_BASE];
    case RGN_CSR:  return &csr_[addr - CSR_BASE];
    default:       return nullptr;
  }
}

const uint8_t* RefModel::byte_ptr(uint32_t addr) const {
  switch (decode(addr)) {
    case RGN_SRAM: return &sram_[addr - SRAM_BASE];
    case RGN_AHB:  return &ahb_[addr - AHB_BASE];
    case RGN_CSR:  return &csr_[addr - CSR_BASE];
    default:       return nullptr;
  }
}

bool RefModel::byte_defined(uint32_t addr) const {
  switch (decode(addr)) {
    case RGN_SRAM: return sram_v_[addr - SRAM_BASE] != 0;
    case RGN_AHB:  return ahb_v_[addr - AHB_BASE]   != 0;
    case RGN_CSR:  return csr_v_[addr - CSR_BASE]   != 0;
    default:       return false;
  }
}

int RefModel::peek(uint32_t addr) const {
  const uint8_t *p = byte_ptr(addr);
  return (p && byte_defined(addr)) ? static_cast<int>(*p) : -1;
}

//------------------------------------------------------------------------------
// AHB slave behaviour
//
// Mirrors rtl/ahb/ahb_subsystem.sv. The bridge aborts an AHB burst on the first
// ERROR, so the caller walks bytes in the same order the bridge issues them and
// stops at the first failure -- bytes before it are committed, bytes at and
// after it are not.
//------------------------------------------------------------------------------
bool RefModel::ahb_byte_errors(uint32_t addr, bool is_write) const {
  if (addr >= AHB_ROM_BASE && addr < AHB_ROM_BASE + AHB_ROM_SIZE)
    return is_write;                       // boot ROM refuses writes
  if (addr >= AHB_REG_BASE && addr < AHB_REG_BASE + AHB_REG_SIZE)
    return false;
  if (addr >= AHB_WAIT_BASE && addr < AHB_WAIT_BASE + AHB_WAIT_SIZE)
    return (addr & AHB_WAIT_ERR_BIT) != 0; // programmed to fail by address
  return true;                             // inside the window, no slave there
}

//------------------------------------------------------------------------------
// Exclusive monitors, one table per exclusive-capable slave.
//
// The AXI rule being modelled (IHI0022 A7.2): an exclusive write succeeds only
// if NO OTHER MASTER has written the location since the exclusive read. Three
// consequences, all implemented below:
//   * any normal write overlapping a reservation clears it;
//   * a SUCCESSFUL exclusive write is itself a write, so it clears every OTHER
//     ID's overlapping reservation (its own is consumed);
//   * a FAILED exclusive write changes no memory, so it clears nobody else's.
//
// The second point is easy to miss and the first version of this model did miss
// it -- it copied the RTL's simpler "only normal writes clear" behaviour. A
// reference model that copies the design's behaviour cannot find the design's
// bugs; this one is written from the spec.
//------------------------------------------------------------------------------
int RefModel::excl_region(uint32_t addr) {
  switch (decode(addr)) {
    case RGN_SRAM: return 0;
    case RGN_CSR:  return 1;
    default:       return -1;     // AHB space: the bridge cannot do exclusives
  }
}

int RefModel::excl_find(int r, uint32_t id) const {
  for (int i = 0; i < EXCL_SLOTS; i++)
    if (excl_[r][i].valid && excl_[r][i].id == id) return i;
  return -1;
}

int RefModel::excl_free(int r) const {
  for (int i = 0; i < EXCL_SLOTS; i++)
    if (!excl_[r][i].valid) return i;
  return -1;
}

void RefModel::excl_clear_overlap(int r, uint32_t lo, uint32_t hi,
                                  int64_t except_id) {
  for (int i = 0; i < EXCL_SLOTS; i++) {
    Reservation &e = excl_[r][i];
    if (!e.valid) continue;
    if (except_id >= 0 && e.id == static_cast<uint32_t>(except_id)) continue;
    const uint32_t elo = e.addr;
    const uint32_t ehi = e.addr + e.bytes - 1u;
    if (!(hi < elo || lo > ehi)) e.valid = false;
  }
}

//------------------------------------------------------------------------------
// Transaction staging
//------------------------------------------------------------------------------

void RefModel::txn_begin(uint32_t addr, int len, int size, int burst,
                         bool lock, uint32_t id, bool is_write) {
  cur_ = Txn();
  cur_.addr     = addr;
  cur_.len      = len;
  cur_.size     = size;
  cur_.burst    = burst;
  cur_.lock     = lock;
  cur_.id       = id;
  cur_.is_write = is_write;
  cur_.wdata.assign(len + 1, 0);
  cur_.wstrb.assign(len + 1, 0);
  cur_.rdata.assign(len + 1, 0);
  cur_.rmask.assign(len + 1, 0);
}

void RefModel::txn_wdata(int beat, uint64_t data, uint32_t strb) {
  if (beat < 0 || beat >= static_cast<int>(cur_.wdata.size())) return;
  cur_.wdata[beat] = data;
  cur_.wstrb[beat] = strb;
}

uint64_t RefModel::txn_rdata(int beat) const {
  if (beat < 0 || beat >= static_cast<int>(cur_.rdata.size())) return 0;
  return cur_.rdata[beat];
}

uint32_t RefModel::txn_rmask(int beat) const {
  if (beat < 0 || beat >= static_cast<int>(cur_.rmask.size())) return 0;
  return cur_.rmask[beat];
}

int RefModel::txn_commit() {
  const int nbeats = cur_.len + 1;

  // Unmapped: what comes back depends on what sits between master and memory.
  // See the comment on set_standalone().
  if (!mapped(cur_.addr))
    return standalone_ ? RESP_SLVERR : RESP_DECERR;

  const int xr = excl_region(cur_.addr);          // -1 where exclusive is unsupported

  //--------------------------------------------------------------------------
  // Read
  //--------------------------------------------------------------------------
  if (!cur_.is_write) {
    for (int b = 0; b < nbeats; b++) {
      const uint32_t an       = beat_addr(cur_.addr, cur_.len, cur_.size,
                                          cur_.burst, b);
      const uint32_t bus_base = an & ~(static_cast<uint32_t>(BUS_BYTES) - 1u);
      int lo, hi;
      byte_lanes(cur_.addr, cur_.len, cur_.size, cur_.burst,
                 b, BUS_BYTES, &lo, &hi);

      uint64_t d = 0;
      uint32_t m = 0;
      for (int i = lo; i <= hi; i++) {
        const uint32_t ba = bus_base + static_cast<uint32_t>(i);
        if (decode(ba) == RGN_AHB && ahb_byte_errors(ba, false)) {
          // The bridge aborts here; every remaining beat is unread and the
          // whole AXI transaction comes back SLVERR.
          return RESP_SLVERR;
        }
        const uint8_t *p = byte_ptr(ba);
        if (p) d |= static_cast<uint64_t>(*p) << (8 * i);
        if (byte_defined(ba)) m |= (1u << i);
      }
      cur_.rdata[b] = d;
      cur_.rmask[b] = m;
    }

    // An exclusive read installs a reservation and returns EXOKAY -- but only
    // on a slave that supports exclusive access. The AXI2AHB bridge does not
    // (AHB-Lite has no equivalent), so the same request to AHB space returns
    // plain OKAY, which is how a master learns the access was not exclusive.
    if (cur_.lock && xr >= 0) {
      const uint32_t total = burst_bytes(cur_.len, cur_.size);
      int slot = excl_find(xr, cur_.id);
      if (slot < 0) slot = excl_free(xr);
      if (slot >= 0) {
        excl_[xr][slot].valid = true;
        excl_[xr][slot].id    = cur_.id;
        excl_[xr][slot].addr  = cur_.addr & ~(total - 1u);
        excl_[xr][slot].bytes = total;
      }
      return RESP_EXOKAY;
    }
    return RESP_OKAY;
  }

  //--------------------------------------------------------------------------
  // Write
  //--------------------------------------------------------------------------
  const bool excl = cur_.lock && (xr >= 0);       // exclusive semantics apply

  // Decide the exclusive outcome ONCE, before any byte is written. The RTL
  // latches the same decision at the first beat, for the same reason: a
  // transaction must not end up half-committed with a response that does not
  // describe what happened.
  bool excl_ok = false;
  if (excl) {
    const uint32_t total = burst_bytes(cur_.len, cur_.size);
    const int slot = excl_find(xr, cur_.id);
    excl_ok = (slot >= 0) && (excl_[xr][slot].addr == (cur_.addr & ~(total - 1u)));
  }

  const bool commit = !excl || excl_ok;

  for (int b = 0; b < nbeats; b++) {
    const uint32_t an       = beat_addr(cur_.addr, cur_.len, cur_.size,
                                        cur_.burst, b);
    const uint32_t bus_base = an & ~(static_cast<uint32_t>(BUS_BYTES) - 1u);
    int lo, hi;
    byte_lanes(cur_.addr, cur_.len, cur_.size, cur_.burst,
               b, BUS_BYTES, &lo, &hi);

    if (commit) {
      for (int i = lo; i <= hi; i++) {
        if (!(cur_.wstrb[b] & (1u << i))) continue;
        const uint32_t ba = bus_base + static_cast<uint32_t>(i);
        if (decode(ba) == RGN_AHB && ahb_byte_errors(ba, true)) {
          // Bytes already written stay written -- an aborted AHB burst is not
          // rolled back -- but nothing further is committed.
          return RESP_SLVERR;
        }
        uint8_t *p = byte_ptr(ba);
        if (p) {
          *p = static_cast<uint8_t>((cur_.wdata[b] >> (8 * i)) & 0xFFu);
          switch (decode(ba)) {
            case RGN_SRAM: sram_v_[ba - SRAM_BASE] = 1; break;
            case RGN_AHB:  ahb_v_[ba - AHB_BASE]   = 1; break;
            case RGN_CSR:  csr_v_[ba - CSR_BASE]   = 1; break;
            default: break;
          }
        }
      }

      // This beat modified memory, so it breaks reservations on what it wrote.
      // A normal write breaks everyone's; a successful exclusive write breaks
      // everyone's EXCEPT its own, which is consumed below.
      const int br = excl_region(bus_base);
      if (br >= 0) {
        excl_clear_overlap(br, bus_base + static_cast<uint32_t>(lo),
                               bus_base + static_cast<uint32_t>(hi),
                           excl ? static_cast<int64_t>(cur_.id) : -1);
      }
    }
  }

  if (excl) {
    const int slot = excl_find(xr, cur_.id);
    if (slot >= 0) excl_[xr][slot].valid = false;   // consumed either way
    return excl_ok ? RESP_EXOKAY : RESP_OKAY;
  }
  return RESP_OKAY;
}

//==============================================================================
// Self-test
//
// Checks the address arithmetic against hand-worked cases taken from the AXI
// spec's own examples. The SV side runs the same vectors through axi4_pkg and
// compares, so a divergence between the two implementations is caught at time 0
// rather than showing up as an inexplicable data mismatch several thousand
// transactions into a random test.
//==============================================================================
int RefModel::selftest() {
  int fails = 0;

  #define CHK(cond, msg) \
    do { if (!(cond)) { std::printf("ref_selftest FAIL: %s\n", msg); fails++; } } while (0)

  // INCR, aligned, 4 beats of 8 bytes from 0x1000 -> 0x1000,08,10,18
  CHK(beat_addr(0x1000, 3, 3, BURST_INCR, 0) == 0x1000, "incr beat0");
  CHK(beat_addr(0x1000, 3, 3, BURST_INCR, 1) == 0x1008, "incr beat1");
  CHK(beat_addr(0x1000, 3, 3, BURST_INCR, 3) == 0x1018, "incr beat3");

  // INCR, unaligned start: beat 0 keeps the offset, beat 1 realigns.
  CHK(beat_addr(0x1003, 3, 3, BURST_INCR, 0) == 0x1003, "incr unaligned beat0");
  CHK(beat_addr(0x1003, 3, 3, BURST_INCR, 1) == 0x1008, "incr unaligned beat1");

  // WRAP, 4 beats of 4 bytes from 0x34: container 16 aligned at 0x30, so the
  // sequence is 0x34, 0x38, 0x3C, 0x30.
  CHK(beat_addr(0x34, 3, 2, BURST_WRAP, 0) == 0x34, "wrap beat0");
  CHK(beat_addr(0x34, 3, 2, BURST_WRAP, 1) == 0x38, "wrap beat1");
  CHK(beat_addr(0x34, 3, 2, BURST_WRAP, 2) == 0x3C, "wrap beat2");
  CHK(beat_addr(0x34, 3, 2, BURST_WRAP, 3) == 0x30, "wrap wraps");

  // FIXED never advances.
  CHK(beat_addr(0x40, 3, 2, BURST_FIXED, 2) == 0x40, "fixed stays");

  // 4KB boundary: 8 beats x 8 bytes from 0xFC0 ends at 0xFFF -- just inside.
  CHK(!crosses_4k(0xFC0, 7, 3, BURST_INCR), "4k exact fit");
  // One beat further and it crosses.
  CHK(crosses_4k(0xFC8, 7, 3, BURST_INCR), "4k crossing");
  // Non-INCR cannot cross.
  CHK(!crosses_4k(0xFC8, 7, 3, BURST_WRAP), "wrap never crosses");

  // Byte lanes on a 64-bit bus. A 2-byte transfer starting at 0x1005 aligns
  // down to 0x1004, so beat 0 runs from the unaligned start to the aligned end
  // -- lane 5 only, not 5..6.
  {
    int lo, hi;
    byte_lanes(0x1005, 0, 1, BURST_INCR, 0, 8, &lo, &hi);
    CHK(lo == 5 && hi == 5, "narrow unaligned lanes beat0");
  }
  // Aligned full-width beat occupies every lane.
  {
    int lo, hi;
    byte_lanes(0x1000, 0, 3, BURST_INCR, 0, 8, &lo, &hi);
    CHK(lo == 0 && hi == 7, "full width lanes");
  }
  // FIXED, unaligned, bus-width beats: every beat uses the lanes of the first one, and
  // none of them reaches past the bus.
  {
    int lo, hi;
    byte_lanes(0x1006, 3, 3, BURST_FIXED, 0, 8, &lo, &hi);
    CHK(lo == 6 && hi == 7, "fixed unaligned lanes beat0");
    byte_lanes(0x1006, 3, 3, BURST_FIXED, 2, 8, &lo, &hi);
    CHK(lo == 6 && hi == 7, "fixed unaligned lanes later beat, clipped to the bus");
  }

  // Exclusive-access semantics (see the note above excl_region()). These pin
  // the SPEC behaviour, so a future edit that "simplifies" the model back to
  // mirroring a simpler RTL fails here instead of silently agreeing with it.
  {
    RefModel m;
    m.set_standalone(false);
    auto rd = [&](uint32_t a, bool lk, uint32_t id) {
      m.txn_begin(a, 0, 3, BURST_INCR, lk, id, false); return m.txn_commit(); };
    auto wr = [&](uint32_t a, bool lk, uint32_t id, uint64_t d) {
      m.txn_begin(a, 0, 3, BURST_INCR, lk, id, true);
      m.txn_wdata(0, d, 0xFFu); return m.txn_commit(); };

    // Two IDs reserve the same location; the first to store wins, and its store
    // is a write, so the second must now fail.
    CHK(rd(0x8000, true, 1) == RESP_EXOKAY, "excl read id1");
    CHK(rd(0x8000, true, 2) == RESP_EXOKAY, "excl read id2");
    CHK(wr(0x8000, true, 1, 0x11) == RESP_EXOKAY, "excl write id1 passes");
    CHK(wr(0x8000, true, 2, 0x22) == RESP_OKAY,   "excl write id2 fails after id1 wrote");
    CHK(m.peek(0x8000) == 0x11, "failed exclusive write left memory alone");

    // A normal write between the read and the write breaks the reservation.
    CHK(rd(0x8010, true, 3) == RESP_EXOKAY, "excl read id3");
    CHK(wr(0x8010, false, 4, 0x33) == RESP_OKAY, "normal write");
    CHK(wr(0x8010, true, 3, 0x44) == RESP_OKAY, "excl write fails after normal write");

    // Exclusive access to AHB space is unsupported: plain OKAY, no reservation.
    CHK(rd(0x10010000u, true, 5) == RESP_OKAY, "excl read to AHB space is OKAY");
    CHK(wr(0x10010000u, true, 5, 0x55) == RESP_OKAY, "excl write to AHB space is OKAY");
    CHK(m.peek(0x10010000u) == 0x55, "excl write to AHB space still wrote");

    // Per-slave tables: a CSR reservation must not evict an SRAM one.
    CHK(rd(0x8020, true, 6) == RESP_EXOKAY, "excl read sram id6");
    CHK(rd(0x20000000u, true, 6) == RESP_EXOKAY, "excl read csr id6");
    CHK(wr(0x8020, true, 6, 0x66) == RESP_EXOKAY, "sram reservation survived csr one");
  }

  #undef CHK
  return fails;
}

//==============================================================================
RefModel& instance() {
  static RefModel m;
  return m;
}

} // namespace soc_ref
