//==============================================================================
// soc_ref_dpi.svh
//
// SystemVerilog side of the C++ reference-model boundary.
// Must stay in step with verif/ref_model/dpi_shim.cpp.
//
// Scalars only, by design -- see the header comment in dpi_shim.cpp.
//==============================================================================
`ifndef SOC_REF_DPI_SVH
`define SOC_REF_DPI_SVH

import "DPI-C" function void ref_reset();

import "DPI-C" function void ref_set_standalone(input int standalone);

import "DPI-C" function void ref_txn_begin(input int unsigned addr,
                                           input int          len,
                                           input int          size,
                                           input int          burst,
                                           input int          lock,
                                           input int unsigned id,
                                           input int          is_write);

import "DPI-C" function void ref_txn_wdata(input int             beat,
                                           input longint unsigned data,
                                           input int unsigned     strb);

import "DPI-C" function int ref_txn_commit();

import "DPI-C" function longint unsigned ref_txn_rdata(input int beat);

import "DPI-C" function int ref_txn_rmask(input int beat);

import "DPI-C" function int ref_peek(input int unsigned addr);

import "DPI-C" function int ref_selftest();

`endif // SOC_REF_DPI_SVH
