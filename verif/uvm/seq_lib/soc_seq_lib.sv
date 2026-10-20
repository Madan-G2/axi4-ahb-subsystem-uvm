//==============================================================================
// soc_seq_lib.sv
//
// Phase 2 sequence library.
//
// soc_base_seq enforces one rule for every sequence on every master: no two
// transactions with overlapping addresses are ever in flight at the same time,
// across the whole testbench.
//
// AXI provides no ordering guarantee between the read and write channels, and
// none at all between different masters. A read issued after a write to the
// same address may legitimately be serviced first; two masters writing the same
// address may land in either order. All of those outcomes are protocol-legal,
// which means a sequential reference model cannot predict a single correct
// answer. Rather than weaken the scoreboard to accept any of several values --
// and go blind to real data-path bugs -- the hazard is kept off the bus.
//
// In Phase 1 the tracker was per-sequence, which was sufficient with one
// master. It is now STATIC, because the three masters run independent
// sequences and a per-sequence tracker would not see the other two.
//
// No lock is needed around it. The check-then-claim in issue() contains no
// blocking statement, so it is atomic under SystemVerilog's cooperative
// scheduling; adding a semaphore would suggest a hazard that does not exist.
//
// The cost stays explicit: same-address races are not verified. Closing that
// gap needs an ordering-aware scoreboard, not a change to these sequences.
//==============================================================================
`ifndef SOC_SEQ_LIB_SV
`define SOC_SEQ_LIB_SV

typedef enum int {
  TGT_SRAM = 0,   // AXI SRAM, S0
  TGT_AHB  = 1,   // AHB peripheral registers via the bridge -- plain RW
  TGT_CSR  = 2,   // AXI CSR file, S2
  TGT_BAD  = 3,   // decodes to no AXI slave  -> DECERR
  TGT_ROM  = 4,   // AHB boot ROM: reads OK, writes -> SLVERR
  TGT_WAIT = 5,   // AHB wait/error slave: waits from addr[7:4], SLVERR on [9]
  TGT_HOLE = 6,   // inside the 1MB AHB window but no slave there -> SLVERR
  TGT_FW   = 7    // low 32KB of the SRAM: CPU firmware, master 0 only (spec decision G4)
} soc_target_e;

//------------------------------------------------------------------------------
class soc_base_seq extends uvm_sequence #(axi4_seq_item);

  `uvm_object_utils(soc_base_seq)

  // Default window: the shared upper half of SRAM. The low 32 KB is reserved
  // for CPU firmware and is off-limits to non-CPU masters (spec decision G4).
  // Deliberately not rand -- randomizing the window would let seq.randomize()
  // replace these with arbitrary values and quietly send traffic out of range.
  bit [AXI_ADDR_W-1:0] win_lo = SHARED_BASE;
  bit [AXI_ADDR_W-1:0] win_hi = SRAM_BASE + SRAM_SIZE - 1;

  bit                  allow_lock = 1'b0;
  int unsigned         n_txn      = 100;

  // Which regions this sequence is allowed to target.
  bit                  use_sram = 1'b1;
  bit                  use_ahb  = 1'b0;
  bit                  use_csr  = 1'b0;
  bit                  use_bad  = 1'b0;
  bit                  use_rom  = 1'b0;
  bit                  use_wait = 1'b0;
  bit                  use_hole = 1'b0;
  bit                  use_fw   = 1'b0;     // master 0 only: M1/M2 are kept off the firmware region

  typedef struct { bit [AXI_ADDR_W-1:0] lo, hi; } rng_t;

  // Shared across every sequence on every master. See the header note.
  static rng_t         inflight [$];

  protected int unsigned my_cnt;      // this sequence's own outstanding count
  protected time         POLL = 10ns;

  function new(string name = "soc_base_seq");
    super.new(name);
  endfunction

  // Called once per test, before any sequence starts. Static state that
  // survives between tests in the same simulation would be a real trap.
  static function void reset_tracker();
    inflight.delete();
  endfunction

  //--------------------------------------------------------------------------
  static function bit overlaps(bit [AXI_ADDR_W-1:0] lo, bit [AXI_ADDR_W-1:0] hi);
    foreach (inflight[i])
      if (!((hi < inflight[i].lo) || (lo > inflight[i].hi))) return 1'b1;
    return 1'b0;
  endfunction

  static function void drop(bit [AXI_ADDR_W-1:0] lo, bit [AXI_ADDR_W-1:0] hi);
    foreach (inflight[i])
      if (inflight[i].lo == lo && inflight[i].hi == hi) begin
        inflight.delete(i);
        return;
      end
  endfunction

  //--------------------------------------------------------------------------
  function void region_bounds(soc_target_e t,
                              output bit [AXI_ADDR_W-1:0] lo,
                              output bit [AXI_ADDR_W-1:0] hi);
    case (t)
      TGT_SRAM: begin lo = SHARED_BASE; hi = SRAM_BASE + SRAM_SIZE - 1; end
      // The peripheral register block: the one AHB region that behaves as
      // plain read/write memory, so random traffic can use it freely.
      TGT_AHB : begin lo = AHB_REG_BASE;  hi = AHB_REG_BASE  + AHB_REG_SIZE  - 1; end
      TGT_ROM : begin lo = AHB_ROM_BASE;  hi = AHB_ROM_BASE  + AHB_ROM_SIZE  - 1; end
      TGT_WAIT: begin lo = AHB_WAIT_BASE; hi = AHB_WAIT_BASE + AHB_WAIT_SIZE - 1; end
      // 0x1003_0000: past the three AHB slaves, still inside the bridge's window.
      TGT_HOLE: begin lo = AHB_BASE + 32'h3_0000; hi = AHB_BASE + 32'h3_0FFF; end
      TGT_CSR : begin lo = CSR_BASE;    hi = CSR_BASE  + CSR_SIZE  - 1; end
      TGT_FW  : begin lo = FW_BASE;     hi = FW_BASE   + FW_SIZE   - 1; end
      // Decodes to no slave at all, so the crossbar's default slave answers
      // DECERR. Deliberately far from every real window.
      default : begin lo = 32'h3000_0000; hi = 32'h3000_0FFF; end
    endcase
  endfunction

  function soc_target_e pick_target();
    soc_target_e list [$];
    if (use_sram) list.push_back(TGT_SRAM);
    if (use_ahb)  list.push_back(TGT_AHB);
    if (use_csr)  list.push_back(TGT_CSR);
    if (use_bad)  list.push_back(TGT_BAD);
    if (use_rom)  list.push_back(TGT_ROM);
    if (use_wait) list.push_back(TGT_WAIT);
    if (use_hole) list.push_back(TGT_HOLE);
    if (use_fw)   list.push_back(TGT_FW);
    if (list.size() == 0) return TGT_SRAM;
    return list[$urandom_range(list.size()-1, 0)];
  endfunction

  //--------------------------------------------------------------------------
  // Issue one transaction, holding it back until its address range is clear.
  //--------------------------------------------------------------------------
  task issue(axi4_seq_item t);
    bit [AXI_ADDR_W-1:0] lo, hi;

    lo = axi_aligned_addr(t.addr, t.size);
    // FIXED bursts revisit one beat, so this over-estimates their footprint.
    // Over-estimating is safe; under-estimating would let a race through.
    hi = lo + AXI_ADDR_W'(axi_burst_bytes(t.len, t.size) - 1);

    while (overlaps(lo, hi)) #POLL;
    inflight.push_back('{lo, hi});     // atomic with the check above
    my_cnt++;

    start_item(t);
    finish_item(t);

    fork
      begin
        automatic axi4_seq_item        tt = t;
        automatic bit [AXI_ADDR_W-1:0] l = lo, h = hi;
        // Persistent wait: returns immediately if the driver already finished
        // this transaction before this process got scheduled. A plain
        // wait_trigger() loses that race and deadlocks.
        tt.done_ev.wait_ptrigger();
        drop(l, h);
        my_cnt--;
      end
    join_none
  endtask

  // Waits only for this sequence's own transactions, not the shared list --
  // otherwise three concurrent masters would all wait for each other.
  task drain();
    while (my_cnt != 0) #POLL;
  endtask

  //--------------------------------------------------------------------------
  // `directed` clears the shaping distributions. Any sequence that pins len,
  // burst or strb with an inline constraint must set it: XSim resolves a dist
  // before looking at the inline constraint, so the two fight and the randomize
  // fails intermittently. See the long note in axi4_seq_item.sv.
  //--------------------------------------------------------------------------
  function axi4_seq_item make_item(string name = "t", bit directed = 1'b0,
                                   bit use_bounds = 1'b0,
                                   bit [AXI_ADDR_W-1:0] lo = '0,
                                   bit [AXI_ADDR_W-1:0] hi = '0);
    axi4_seq_item t = axi4_seq_item::type_id::create(name);
    t.addr_min   = use_bounds ? lo : win_lo;
    t.addr_max   = use_bounds ? hi : win_hi;
    t.allow_lock = allow_lock;
    // Exclusive access is not wanted here, so take `lock` out of the solve
    // entirely rather than leaving it to a constraint. An AxLOCK that slips
    // through makes the protocol checker fire and sends you hunting a DUT bug
    // that is not there.
    if (!allow_lock) begin
      t.lock = 1'b0;
      void'(t.lock.rand_mode(0));
    end
    if (directed) begin
      t.shape_len   = 1'b0;
      t.shape_burst = 1'b0;
      t.shape_strb  = 1'b0;
    end
    return t;
  endfunction

endclass : soc_base_seq


//------------------------------------------------------------------------------
// Smallest useful sequence: one aligned single-beat write, then read it back.
//------------------------------------------------------------------------------
class soc_smoke_seq extends soc_base_seq;

  `uvm_object_utils(soc_smoke_seq)

  function new(string name = "soc_smoke_seq");
    super.new(name);
  endfunction

  task body();
    axi4_seq_item wr, rd;
    bit [AXI_ADDR_W-1:0] a = win_lo + 32'h100;

    wr = make_item("wr", .directed(1));
    // {AXI_STRB_W{1'b1}}, not '1 -- XSim's solver cannot handle the unsized
    // all-ones literal inside a foreach constraint.
    if (!wr.randomize() with {
      is_write == 1; addr == a; len == 0; size == 2;
      burst == AXI_BURST_INCR;
      foreach (strb[i]) strb[i] == {AXI_STRB_W{1'b1}};
      aw_delay == 0; b_ready_delay == 0;
    }) `uvm_fatal("SMOKE", "write randomize failed")
    issue(wr);
    wr.done_ev.wait_ptrigger();

    rd = make_item("rd", .directed(1));
    if (!rd.randomize() with {
      is_write == 0; addr == a; len == 0; size == 2;
      burst == AXI_BURST_INCR;
      ar_delay == 0; r_ready_delay == 0;
    }) `uvm_fatal("SMOKE", "read randomize failed")
    issue(rd);
    rd.done_ev.wait_ptrigger();

    drain();
  endtask

endclass : soc_smoke_seq


//------------------------------------------------------------------------------
// Constrained-random traffic across whichever regions are enabled.
//
// Writes are biased ahead of reads early on so reads have something meaningful
// to find -- a flat 50/50 mix spends its first hundred transactions reading
// zeros, which checks very little.
//------------------------------------------------------------------------------
class axi4_random_seq extends soc_base_seq;

  `uvm_object_utils(axi4_random_seq)

  function new(string name = "axi4_random_seq");
    super.new(name);
  endfunction

  task body();
    axi4_seq_item t;
    soc_target_e  tgt;
    bit [AXI_ADDR_W-1:0] lo, hi;

    for (int i = 0; i < int'(n_txn); i++) begin
      tgt = pick_target();
      region_bounds(tgt, lo, hi);

      t = make_item($sformatf("t%0d", i), .directed(0),
                    .use_bounds(1), .lo(lo), .hi(hi));
      if (!t.randomize() with {
        is_write dist { 1 :/ (i < 20 ? 90 : 50), 0 :/ (i < 20 ? 10 : 50) };
      }) `uvm_fatal("RANDSEQ", $sformatf("randomize failed at txn %0d", i))
      issue(t);
    end

    drain();
  endtask

endclass : axi4_random_seq


//------------------------------------------------------------------------------
// Every access lands outside every decode window, so the crossbar's default
// slave must answer DECERR -- with the correct beat count and RLAST, which is
// the part a naive default slave gets wrong.
//------------------------------------------------------------------------------
class axi_decerr_seq extends soc_base_seq;

  `uvm_object_utils(axi_decerr_seq)

  function new(string name = "axi_decerr_seq");
    super.new(name);
    use_sram = 1'b0;
    use_bad  = 1'b1;
  endfunction

  task body();
    axi4_seq_item t;
    bit [AXI_ADDR_W-1:0] lo, hi;
    region_bounds(TGT_BAD, lo, hi);

    for (int i = 0; i < int'(n_txn); i++) begin
      t = make_item($sformatf("d%0d", i), .directed(0),
                    .use_bounds(1), .lo(lo), .hi(hi));
      if (!t.randomize()) `uvm_fatal("DECERR", "randomize failed")
      issue(t);
    end
    drain();
  endtask

endclass : axi_decerr_seq


//==============================================================================
// Virtual sequences
//==============================================================================
class soc_vseq_base extends uvm_sequence;

  `uvm_object_utils(soc_vseq_base)
  `uvm_declare_p_sequencer(soc_virtual_sequencer)

  int unsigned n_txn = 200;

  function new(string name = "soc_vseq_base");
    super.new(name);
  endfunction

endclass : soc_vseq_base


//------------------------------------------------------------------------------
// All three masters generating random traffic to all three slaves at once.
// This is the sequence the crossbar exists to survive: concurrent arbitration
// at every slave port, responses returning out of order across slaves, and the
// W router keeping each master's bursts in its own AW order.
//------------------------------------------------------------------------------
class soc_multi_master_vseq extends soc_vseq_base;

  `uvm_object_utils(soc_multi_master_vseq)

  bit use_bad = 1'b0;

  function new(string name = "soc_multi_master_vseq");
    super.new(name);
  endfunction

  task body();
    axi4_random_seq s [SOC_N_M];

    for (int i = 0; i < SOC_N_M; i++) begin
      s[i] = axi4_random_seq::type_id::create($sformatf("rs%0d", i));
      s[i].n_txn    = n_txn;
      s[i].use_sram = 1'b1;
      s[i].use_ahb  = 1'b1;
      s[i].use_csr  = 1'b1;
      s[i].use_bad  = use_bad;
    end

    fork
      s[0].start(p_sequencer.seqr[0]);
      s[1].start(p_sequencer.seqr[1]);
      s[2].start(p_sequencer.seqr[2]);
    join
  endtask

endclass : soc_multi_master_vseq


//------------------------------------------------------------------------------
// All three masters hammering ONE slave, to make the arbiter work. With traffic
// spread across three slaves the arbiters rarely see simultaneous requests, so
// fairness is never really tested.
//------------------------------------------------------------------------------
class soc_arb_stress_vseq extends soc_vseq_base;

  `uvm_object_utils(soc_arb_stress_vseq)

  function new(string name = "soc_arb_stress_vseq");
    super.new(name);
  endfunction

  task body();
    axi4_random_seq s [SOC_N_M];

    for (int i = 0; i < SOC_N_M; i++) begin
      s[i] = axi4_random_seq::type_id::create($sformatf("as%0d", i));
      s[i].n_txn    = n_txn;
      s[i].use_sram = 1'b1;      // everyone targets S0 only
      s[i].use_ahb  = 1'b0;
      s[i].use_csr  = 1'b0;
    end

    fork
      s[0].start(p_sequencer.seqr[0]);
      s[1].start(p_sequencer.seqr[1]);
      s[2].start(p_sequencer.seqr[2]);
    join
  endtask

endclass : soc_arb_stress_vseq

`endif // SOC_SEQ_LIB_SV
