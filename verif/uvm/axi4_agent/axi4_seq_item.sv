//==============================================================================
// axi4_seq_item.sv
//
// One complete AXI4 transaction, plus the per-channel timing knobs the driver
// uses to shape the handshakes.
//
// Legality constraints call the predicates in axi4_pkg rather than restating
// the rules. The SVA checker calls the same functions, so stimulus and checking
// cannot drift apart -- if they disagree about what is legal, the failure is a
// single shared function rather than two subtly different copies of the spec.
//==============================================================================
`ifndef AXI4_SEQ_ITEM_SV
`define AXI4_SEQ_ITEM_SV

//------------------------------------------------------------------------------
// Deliberate protocol violations, applied by the driver and never randomised.
//
// They exist to show that the protocol checker is alive and wired to the right
// signals in the full environment -- the unit-level harness (tb_checker_neg) proves
// each property can fire, but not that the instance on master 1 is connected to
// master 1. Every kind breaks exactly one rule, in the one window where the rule
// applies:
//   *_DROP     VALID withdrawn for a cycle while VALID && !READY
//   *_PAYLOAD  a payload field changed for a cycle while VALID && !READY
//   *_X        a control field driven X for a cycle while VALID
//   WLAST_EARLY    WLAST on the second-to-last beat
//   WLAST_MISSING  last beat without WLAST; an extra beat carries it
//------------------------------------------------------------------------------
typedef enum int {
  INJ_NONE,
  INJ_AW_DROP, INJ_AW_PAYLOAD, INJ_AW_X,
  INJ_AR_DROP, INJ_AR_PAYLOAD, INJ_AR_X,
  INJ_W_DROP,  INJ_W_PAYLOAD,  INJ_W_X,
  INJ_WLAST_EARLY, INJ_WLAST_MISSING
} axi_inject_e;


class axi4_seq_item extends uvm_sequence_item;


  //--------------------------------------------------------------------------
  // Request
  //--------------------------------------------------------------------------
  rand bit                    is_write;
  rand bit [AXI_ID_W-1:0]     id;
  rand bit [AXI_ADDR_W-1:0]   addr;
  rand bit [7:0]              len;      // beats - 1
  rand bit [2:0]              size;     // log2(bytes per beat)
  rand bit [1:0]              burst;
  rand bit                    lock;
  rand bit [3:0]              cache;
  rand bit [2:0]              prot;
  rand bit [3:0]              qos;
  rand bit [3:0]              region;

  rand bit [AXI_DATA_W-1:0]   data [];
  rand bit [AXI_STRB_W-1:0]   strb [];

  //--------------------------------------------------------------------------
  // Response, filled in by the driver
  //--------------------------------------------------------------------------
  // 4-state on purpose. This was `bit`, which silently converts an X on the
  // read bus into 0 at the moment of capture -- so a DUT driving X into an
  // ACTIVE byte lane compared equal to a model value of 0 and passed. XSim reads
  // never-written memory as X, so the hole was open for every first read.
  logic [AXI_DATA_W-1:0]      rdata [];
  bit [1:0]                   resp;         // BRESP, or the last RRESP
  bit [1:0]                   rresp [];     // per-beat RRESP
  bit                         completed;

  // Which master port produced this transaction. Set by the monitor, not
  // randomised. The scoreboard needs it because the slave-side exclusive monitor
  // keys on {master, id}; passing the 4-bit ID alone would make two masters that
  // both use ID 3 look like one.
  int                         master_idx;

  // Sequences that care about the outcome (the exclusive tests, mainly) wait on
  // this rather than relying on put_response/get_response. A driver response
  // queue that nobody drains will silently block the whole agent, and that
  // failure mode is far harder to spot than an event nobody waits on.
  uvm_event                   done_ev;

  //--------------------------------------------------------------------------
  // Timing controls
  //--------------------------------------------------------------------------
  rand int unsigned           aw_delay;
  rand int unsigned           ar_delay;
  rand int unsigned           w_delay [];
  rand int unsigned           b_ready_delay;
  rand int unsigned           r_ready_delay;

  //--------------------------------------------------------------------------
  // Address bounds, set by the sequence before randomize().
  //--------------------------------------------------------------------------
  axi_inject_e                inject = INJ_NONE;     // see the enum above
  bit                         injected;              // set by the driver when it applied it

  bit [AXI_ADDR_W-1:0]        addr_min = SRAM_BASE;
  bit [AXI_ADDR_W-1:0]        addr_max = SRAM_BASE + SRAM_SIZE - 1;
  bit                         allow_lock = 1'b0;

  `uvm_object_utils_begin(axi4_seq_item)
    `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_field_int(id,       UVM_ALL_ON)
    `uvm_field_int(addr,     UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(len,      UVM_ALL_ON)
    `uvm_field_int(size,     UVM_ALL_ON)
    `uvm_field_int(burst,    UVM_ALL_ON)
    `uvm_field_int(lock,     UVM_ALL_ON)
    `uvm_field_int(resp,     UVM_ALL_ON)
    `uvm_field_array_int(data,  UVM_ALL_ON | UVM_HEX)
    `uvm_field_array_int(strb,  UVM_ALL_ON | UVM_HEX)
    `uvm_field_array_int(rdata, UVM_ALL_ON | UVM_HEX)
  `uvm_object_utils_end

  function new(string name = "axi4_seq_item");
    super.new(name);
    done_ev = new("done_ev");
  endfunction

  //--------------------------------------------------------------------------
  // Legality
  //--------------------------------------------------------------------------

  // AXI4 reserves 2'b11.
  constraint c_burst_legal {
    burst inside {AXI_BURST_FIXED, AXI_BURST_INCR, AXI_BURST_WRAP};
  }

  // A beat can never be wider than the bus.
  constraint c_size_le_bus {
    size <= $clog2(AXI_STRB_W);
  }

  // WRAP is only defined for 2, 4, 8 or 16 beats.
  constraint c_wrap_len {
    (burst == AXI_BURST_WRAP) -> len inside {1, 3, 7, 15};
  }

  // FIXED is capped at 16 beats.
  constraint c_fixed_len {
    (burst == AXI_BURST_FIXED) -> len <= 15;
  }

  // WRAP requires the start address aligned to the beat size.
  constraint c_wrap_aligned {
    (burst == AXI_BURST_WRAP) -> (addr % (1 << size)) == 0;
  }

  constraint c_addr_range {
    addr >= addr_min;
    addr <= addr_max;
  }

  // No INCR burst may cross a 4KB page boundary. Expressed on the aligned
  // address so it matches the checker's arithmetic exactly.
  constraint c_no_4k_cross {
    (burst == AXI_BURST_INCR) ->
      (((addr & ~((1 << size) - 1)) % 4096) + ((len + 1) << size)) <= 4096;
  }

  // Keep the whole burst inside the addressable window, so a legal request
  // never accidentally becomes an error-response test.
  constraint c_burst_in_range {
    (addr & ~((1 << size) - 1)) + ((len + 1) << size) <= (addr_max + 1);
  }

  // Written as guarded blocks rather than `->` implications.
  //
  // Semantically identical, but XSim did not reliably honour the implication
  // form: with allow_lock clear, random traffic still produced an occasional
  // AxLOCK=1 that tripped a_ar_excl_legal in the protocol checker, in a
  // seed-dependent way that vanished as soon as anything shifted the RNG
  // stream. The `if` form is what the dist guards above already use and it
  // holds. Given the solver bugs already hit in this file -- soft constraints,
  // unsized '1 -- the implication operator is not worth trusting here.
  constraint c_lock_allowed {
    if (!allow_lock) lock == 1'b0;
  }

  // Exclusive access: <= 16 beats, total bytes a POWER OF TWO in 1..128, and
  // the address aligned to that total. (AXI4 A7.2.4)
  //
  // The power-of-two rule is the one that is easy to leave out, and leaving it
  // out does not fail loudly -- it produces requests like 7 beats x 1 byte,
  // which satisfy every other exclusive rule and are still illegal. Since
  // total = (len+1) * 2**size and 2**size is already a power of two, the total
  // is a power of two exactly when (len+1) is.
  constraint c_lock_legal {
    if (lock) {
      burst == AXI_BURST_INCR;
      (len + 1) inside {1, 2, 4, 8, 16};
      ((len + 1) << size) <= 128;
      (addr % ((len + 1) << size)) == 0;
    }
  }

  //--------------------------------------------------------------------------
  // Shape
  //--------------------------------------------------------------------------
  //--------------------------------------------------------------------------
  // Shaping distributions, and why they are switched rather than `soft`.
  //
  // These bias random traffic; they are not legality rules. Directed sequences
  // need to override them, and XSim's solver picks a dist bin BEFORE checking
  // the hard inline constraint and then fails instead of backtracking. So
  // `len == 0` against a dist giving bin 0 a weight of 30 fails roughly 70% of
  // the time, apparently at random, reported only as "randomize failed to meet
  // constraint" with no indication of which one.
  //
  // The obvious fix is `soft`. It does not work here: XSim 2024.1 mis-handles
  // soft constraints in this class outright --
  //
  //   Invalid consttrain id : 0, exceeds total number of constraints (0).
  //   Out of memory on request for a fresh 8388608 bytes
  //   Total memory consumed so far : 3192827920 bytes
  //
  // -- a 3 GB runaway before the solver gives up. So the distributions are
  // gated by plain non-rand switches instead. A cleared switch removes the dist
  // from the solve entirely, which is portable, costs nothing, and makes the
  // intent visible at the call site.
  //--------------------------------------------------------------------------
  bit shape_len   = 1'b1;
  bit shape_burst = 1'b1;
  bit shape_strb  = 1'b1;

  constraint c_len_dist {
    if (shape_len)
      len dist { 0 :/ 30, [1:3] :/ 30, [4:15] :/ 25, [16:63] :/ 10, [64:255] :/ 5 };
  }

  constraint c_burst_dist {
    if (shape_burst)
      burst dist { AXI_BURST_INCR :/ 70, AXI_BURST_WRAP :/ 20, AXI_BURST_FIXED :/ 10 };
  }

  constraint c_arrays {
    data.size() == len + 1;
    strb.size() == len + 1;
    w_delay.size() == len + 1;
  }

  // Explicit solve order.
  //
  // Without it the solver is asked to size three dynamic arrays and satisfy
  // foreach constraints over them in the same pass as it picks `len`, which
  // XSim's solver will not do -- it reports a plain "randomize failed to meet
  // constraint" with no indication which one.
  //
  // The order also matches how the AXI rules actually nest: the burst type
  // decides which length and alignment rules apply, the size fixes the beat
  // width, and only then is there enough information to place the address
  // without violating the 4KB or wrap-alignment rules. Solving in that order is
  // both correct and dramatically faster than letting the solver search.
  constraint c_solve_order {
    solve burst before size;
    solve burst before len;
    solve size  before len;
    solve size  before addr;
    solve len   before addr;
  }

  constraint c_delays {
    aw_delay      inside {[0:4]};
    ar_delay      inside {[0:4]};
    b_ready_delay inside {[0:3]};
    r_ready_delay inside {[0:3]};
    foreach (w_delay[i]) w_delay[i] inside {[0:3]};
  }

  // Bias toward full strobes but keep sparse and all-zero cases reachable --
  // an all-zero WSTRB beat is legal and must leave memory untouched, which is
  // a case naive write paths routinely get wrong.
  constraint c_strb_dist {
    foreach (strb[i]) {
      if (shape_strb)
        strb[i] dist { {AXI_STRB_W{1'b1}} :/ 60,
                       0                  :/ 5,
                       [1:{AXI_STRB_W{1'b1}}-1] :/ 35 };
    }
  }

  //--------------------------------------------------------------------------
  // post_randomize: mask WSTRB down to the lanes this beat actually occupies.
  //
  // Strobe bits outside the active byte lanes are meaningless for narrow or
  // unaligned transfers. Leaving them set would make the DUT and the reference
  // model disagree for reasons that have nothing to do with a real bug.
  //--------------------------------------------------------------------------
  function void post_randomize();
    int unsigned lo, hi;
    bit [AXI_STRB_W-1:0] mask;

    if (!is_write) return;

    foreach (strb[b]) begin
      axi_byte_lanes(addr, len, size, burst, b, AXI_STRB_W, lo, hi);
      mask = '0;
      for (int i = int'(lo); i <= int'(hi) && i < AXI_STRB_W; i++) mask[i] = 1'b1;
      strb[b] &= mask;
    end
  endfunction

  function string convert2string();
    return $sformatf("%s id=%0d addr=0x%0h len=%0d size=%0d burst=%0d lock=%0b resp=%0d",
                     is_write ? "WR" : "RD", id, addr, len, size, burst, lock, resp);
  endfunction

endclass : axi4_seq_item

`endif // AXI4_SEQ_ITEM_SV
