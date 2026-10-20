//==============================================================================
// soc_scoreboard.sv
//
// Compares every observed AXI transaction against the C++ golden model.
//
// ORDERING ASSUMPTION -- worth understanding before extending this.
//
// The reference model is sequential: transactions are applied in the order the
// scoreboard receives them. AXI, however, guarantees no ordering at all between
// the read and write channels. A read issued after a write to the same address
// may legitimately be serviced first, because AR and AW are independent
// channels with independent flow control. There is no way for a scoreboard to
// predict a single expected value in that situation -- both answers are
// protocol-legal.
//
// Rather than weaken the check to "either value is fine", which would blind it
// to real data-path bugs, the hazard is removed at the source: soc_base_seq
// never has a read and a write to overlapping addresses in flight at the same
// time. That keeps this comparison exact.
//
// The restriction costs one thing worth naming: it means this testbench does
// not verify read/write races to the same address. That is a deliberate gap,
// not an oversight, and closing it needs an ordering-aware scoreboard rather
// than a tweak here.
//==============================================================================
`ifndef SOC_SCOREBOARD_SV
`define SOC_SCOREBOARD_SV

`uvm_analysis_imp_decl(_axi)

class soc_scoreboard extends uvm_component;


  `uvm_component_utils(soc_scoreboard)

  uvm_analysis_imp_axi #(axi4_seq_item, soc_scoreboard) axi_imp;

  int unsigned n_wr, n_rd, n_resp_err, n_data_err, n_x_err, n_illegal, n_unchecked;

  // Cleared by the protocol-violation tests. Once a master has deliberately broken
  // the protocol, what the DUT does with the corrupted transaction is undefined, so
  // there is nothing to compare it against; the count of skipped transactions is
  // reported so a test that disables the scoreboard cannot hide behind it.
  bit enable = 1'b1;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    axi_imp = new("axi_imp", this);
  endfunction

  //--------------------------------------------------------------------------
  function void write_axi(axi4_seq_item t);
    int exp_resp;
    logic [5:0] mid;

    if (!enable) begin
      n_unchecked++;
      return;
    end

    // Illegal requests are not modelled. They only exist as deliberate master-side
    // error injection (the negative tests), where the thing under test is the
    // protocol checker, not the data path -- and what a slave does with an
    // illegal burst is, by definition, unspecified, so there is nothing to
    // compare against. They are counted so a test that injects nothing, or
    // everything, is visible rather than silently green.
    if (!axi_req_legal(t.addr, t.len, t.size, t.burst, t.lock, AXI_STRB_W)) begin
      n_illegal++;
      return;
    end

    // The slave-side exclusive monitor keys on the crossbar's 6-bit ID, which is
    // {master index, master's own ID}. Feed the model the same identity.
    mid = {t.master_idx[1:0], t.id};

    ref_txn_begin(t.addr, int'(t.len), int'(t.size), int'(t.burst),
                  int'(t.lock), mid, int'(t.is_write));

    if (t.is_write)
      foreach (t.data[b])
        ref_txn_wdata(b, t.data[b], t.strb[b]);

    exp_resp = ref_txn_commit();

    if (t.resp != exp_resp[1:0]) begin
      n_resp_err++;
      `uvm_error("SCB",
        $sformatf("%s resp mismatch: DUT=%0d expected=%0d  (%s)",
                  t.is_write ? "WRITE" : "READ", t.resp, exp_resp,
                  t.convert2string()))
    end

    if (t.is_write) n_wr++;
    else begin
      n_rd++;
      check_read_data(t);
    end
  endfunction

  //--------------------------------------------------------------------------
  // Compare read data byte by byte, but only within the byte lanes the beat
  // actually occupies. Bytes outside those lanes are architecturally
  // don't-care; comparing them would turn a legal narrow transfer into a false
  // failure that depends on whatever the slave happened to drive.
  //--------------------------------------------------------------------------
  function void check_read_data(axi4_seq_item t);
    int unsigned lo, hi;
    logic [AXI_DATA_W-1:0] exp;
    int                    mask;
    logic [7:0]            eb, gb;

    // A transaction that errored has no meaningful data to compare.
    if (t.resp != AXI_RESP_OKAY && t.resp != AXI_RESP_EXOKAY) return;

    foreach (t.rdata[b]) begin
      exp  = ref_txn_rdata(b);
      mask = ref_txn_rmask(b);
      axi_byte_lanes(t.addr, t.len, t.size, t.burst, b, AXI_STRB_W, lo, hi);

      for (int i = int'(lo); i <= int'(hi) && i < AXI_STRB_W; i++) begin
        // The model only vouches for bytes that were actually written (or that
        // are ROM). A never-written RAM byte is undefined in the RTL, so there
        // is nothing to compare it against.
        if (!mask[i]) continue;

        eb = exp[8*i +: 8];
        gb = t.rdata[b][8*i +: 8];

        // X/Z in a byte the model says is defined is a failure in its own right.
        // `!==` below would catch it too, but only by coincidence of the model's
        // value; naming it separately makes an X bus read as what it is.
        if ($isunknown(gb)) begin
          n_x_err++;
          `uvm_error("SCB",
            $sformatf("READ X/Z on defined lane: beat=%0d lane=%0d got=%b  (%s)",
                      b, i, gb, t.convert2string()))
          return;
        end
        if (eb !== gb) begin
          n_data_err++;
          `uvm_error("SCB",
            $sformatf("READ data mismatch beat=%0d lane=%0d: DUT=0x%02h expected=0x%02h  (%s)",
                      b, i, gb, eb, t.convert2string()))
          return;   // one report per transaction is enough to debug from
        end
      end
    end
  endfunction

  //--------------------------------------------------------------------------
  // End-of-test memory sweep. Catches writes that landed at the wrong address:
  // a per-transaction check only ever looks where it expects the data to be, so
  // a byte written one lane over is invisible until something reads it.
  //--------------------------------------------------------------------------
  function void sweep_memory(bit [AXI_ADDR_W-1:0] base, int unsigned nbytes,
                             ref int unsigned mismatches);
    mismatches = 0;
    // Intentionally not implemented as a raw backdoor peek of the RTL array:
    // that would need a hierarchical reference and would break the moment the
    // memory moves inside the hierarchy. Phase 2 adds a backdoor access task on
    // the SRAM controller and this fills in against ref_peek().
  endfunction

  //--------------------------------------------------------------------------
  function void report_phase(uvm_phase phase);
    `uvm_info("SCB",
      $sformatf("checked %0d writes, %0d reads; %0d response errors, %0d data errors, %0d x errors (%0d illegal skipped)%s",
                n_wr, n_rd, n_resp_err, n_data_err, n_x_err, n_illegal,
                enable ? "" : $sformatf("  [scoreboard DISABLED: %0d transactions not checked]", n_unchecked)),
      UVM_LOW)

    if (n_wr == 0 && n_rd == 0 && n_illegal == 0 && n_unchecked == 0)
      `uvm_error("SCB", "scoreboard saw no transactions -- test proved nothing")
  endfunction

endclass : soc_scoreboard

`endif // SOC_SCOREBOARD_SV
