//==============================================================================
// dpi_shim.cpp
//
// extern "C" entry points bridging SystemVerilog to the C++ golden model.
//
// Every argument and return value here is a plain scalar. There is no
// svOpenArrayHandle, no svLogicVecVal, and no #include <svdpi.h> -- the shim
// depends on nothing but the C ABI.
//
// That is a deliberate portability decision, not a simplification. Open-array
// marshalling is the least portable corner of DPI and the first thing to break
// under XSim on Windows; spec decision G5 exists precisely because the entire
// C++ reference-model claim rests on this boundary working. A transaction is
// therefore staged one beat at a time and then committed, which costs a handful
// of extra DPI calls per transaction and buys a boundary that is very hard to
// get wrong.
//
// SystemVerilog import declarations live in verif/uvm/env/soc_ref_dpi.svh and
// must stay in step with the signatures below.
//==============================================================================
#include "soc_ref_model.h"

extern "C" {

// Clear all memory and drop every outstanding exclusive reservation.
void ref_reset() {
  soc_ref::instance().reset();
}

// Select what an unmapped address returns: 1 = standalone slave (SLVERR),
// 0 = behind the crossbar (DECERR). See RefModel::set_standalone().
void ref_set_standalone(int standalone) {
  soc_ref::instance().set_standalone(standalone != 0);
}

// Begin staging a transaction. Clears any previously staged beat data.
void ref_txn_begin(unsigned int addr, int len, int size, int burst,
                   int lock, unsigned int id, int is_write) {
  soc_ref::instance().txn_begin(addr, len, size, burst,
                                lock != 0, id, is_write != 0);
}

// Stage one beat of write data. `strb` carries WSTRB in its low BUS_BYTES bits.
void ref_txn_wdata(int beat, unsigned long long data, unsigned int strb) {
  soc_ref::instance().txn_wdata(beat, data, strb);
}

// Apply the staged transaction and return the expected AXI response code
// (0 OKAY, 1 EXOKAY, 2 SLVERR, 3 DECERR).
int ref_txn_commit() {
  return soc_ref::instance().txn_commit();
}

// Predicted read data for a beat. Only meaningful after committing a read.
unsigned long long ref_txn_rdata(int beat) {
  return soc_ref::instance().txn_rdata(beat);
}

// Mask of the byte lanes of read beat `beat` whose contents the model knows.
// Bytes outside the mask were never written and are undefined in the RTL.
int ref_txn_rmask(int beat) {
  return static_cast<int>(soc_ref::instance().txn_rmask(beat));
}

// One byte of modelled memory, or -1 if the address is unmapped. Used by the
// end-of-test memory sweep.
int ref_peek(unsigned int addr) {
  return soc_ref::instance().peek(addr);
}

// Cross-check the C++ address arithmetic against its hand-worked vectors.
// Returns the number of failures; 0 means pass.
int ref_selftest() {
  return soc_ref::RefModel::selftest();
}

} // extern "C"
