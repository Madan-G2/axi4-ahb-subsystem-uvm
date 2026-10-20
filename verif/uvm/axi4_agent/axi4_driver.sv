//==============================================================================
// axi4_driver.sv
//
// Pipelined AXI4 master driver.
//
// The five AXI channels are independent, so the driver runs one thread per
// channel plus a dispatcher. A transaction is accepted from the sequencer,
// handed to the relevant channel threads, and item_done() is called
// immediately -- otherwise the sequencer would serialise on each transaction's
// response and the agent could never build up outstanding depth, which is the
// single most important thing this testbench is supposed to exercise.
//
// Two ordering rules the driver must not break:
//
//   1. AXI4 removed write interleaving. W beats from this master must reach the
//      slave in exactly the order the AWs were issued. Guaranteed here by the
//      dispatcher pushing to aw_mbx and w_mbx as one uninterruptible step, so
//      the two mailboxes are always in the same order.
//
//   2. Once VALID is asserted it must stay asserted, with stable payload, until
//      READY. Every drive_* task below holds its payload across the wait loop
//      and only drops VALID after the handshake completes.
//
// Sampling: signals are driven with non-blocking assignments at posedge and
// READY is read in the Active region of the following posedge. At that point
// the DUT's combinational READY has settled from a VALID driven a full cycle
// earlier, so there is no race. This is the standard clocking-block-free BFM
// idiom; see the note in axi4_if.sv about why clocking blocks are avoided.
//==============================================================================
`ifndef AXI4_DRIVER_SV
`define AXI4_DRIVER_SV

class axi4_driver extends uvm_driver #(axi4_seq_item);


  `uvm_component_utils(axi4_driver)

  virtual axi4_if       vif;
  axi4_agent_cfg        cfg;

  // Channel work queues.
  mailbox #(axi4_seq_item) aw_mbx;
  mailbox #(axi4_seq_item) w_mbx;
  mailbox #(axi4_seq_item) ar_mbx;

  // Outstanding transactions awaiting a response, keyed by ID. AXI requires
  // same-ID responses to come back in issue order, so a FIFO per ID is an exact
  // match for the ordering the slave is obliged to provide.
  axi4_seq_item            wr_out [bit [AXI_ID_W-1:0]][$];
  axi4_seq_item            rd_out [bit [AXI_ID_W-1:0]][$];

  semaphore                wr_credits;
  semaphore                rd_credits;

  // Protocol-violation injection (axi_inject_e). One violation per driver per run:
  // a DUT fed repeated violations ends up in states that say nothing more about
  // the checker, and a single one keeps the aftermath small enough to reason about.
  bit                      injected;

  function void note_inject(string what, axi4_seq_item t);
    injected   = 1'b1;
    t.injected = 1'b1;
    `uvm_info("INJECT", $sformatf("m%0d: %s  (%s)", cfg.master_idx, what, t.convert2string()), UVM_LOW)
  endfunction

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axi4_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXI4DRV", "axi4_agent_cfg not found in config DB")
    vif = cfg.vif;
    aw_mbx = new();
    w_mbx  = new();
    ar_mbx = new();
    wr_credits = new(cfg.max_wr_outstanding);
    rd_credits = new(cfg.max_rd_outstanding);
  endfunction

  //--------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    reset_signals();
    @(posedge vif.aresetn);

    fork
      dispatch();
      aw_thread();
      w_thread();
      b_thread();
      ar_thread();
      r_thread();
    join
  endtask

  //--------------------------------------------------------------------------
  task reset_signals();
    vif.awvalid <= 1'b0;
    vif.wvalid  <= 1'b0;
    vif.arvalid <= 1'b0;
    vif.bready  <= 1'b0;
    vif.rready  <= 1'b0;
    vif.awid    <= '0; vif.awaddr <= '0; vif.awlen <= '0; vif.awsize <= '0;
    vif.awburst <= '0; vif.awlock <= '0; vif.awcache <= '0; vif.awprot <= '0;
    vif.awqos   <= '0; vif.awregion <= '0;
    vif.wdata   <= '0; vif.wstrb <= '0; vif.wlast <= 1'b0;
    vif.arid    <= '0; vif.araddr <= '0; vif.arlen <= '0; vif.arsize <= '0;
    vif.arburst <= '0; vif.arlock <= '0; vif.arcache <= '0; vif.arprot <= '0;
    vif.arqos   <= '0; vif.arregion <= '0;
  endtask

  //--------------------------------------------------------------------------
  // Dispatcher. Takes credit before queuing so the outstanding limit is applied
  // at the point of acceptance rather than deep inside a channel thread.
  //--------------------------------------------------------------------------
  task dispatch();
    axi4_seq_item t;
    forever begin
      seq_item_port.get_next_item(t);

      if (t.is_write) begin
        wr_credits.get(1);
        // Both puts happen with no intervening blocking statement, so aw_mbx
        // and w_mbx stay in lockstep. This is what enforces the no-interleave
        // rule; see the header note.
        aw_mbx.put(t);
        w_mbx.put(t);
      end
      else begin
        rd_credits.get(1);
        ar_mbx.put(t);
      end

      seq_item_port.item_done();
    end
  endtask

  //--------------------------------------------------------------------------
  // Write address channel
  //--------------------------------------------------------------------------
  task aw_thread();
    axi4_seq_item t;
    forever begin
      aw_mbx.get(t);
      repeat (t.aw_delay) @(posedge vif.aclk);

      vif.awid     <= t.id;
      vif.awaddr   <= t.addr;
      vif.awlen    <= t.len;
      vif.awsize   <= t.size;
      vif.awburst  <= t.burst;
      vif.awlock   <= t.lock;
      vif.awcache  <= t.cache;
      vif.awprot   <= t.prot;
      vif.awqos    <= t.qos;
      vif.awregion <= t.region;
      vif.awvalid  <= 1'b1;

      forever begin
        @(posedge vif.aclk);
        if (vif.awready) break;
        // Stalled: VALID is up and READY is not, which is the only window in which
        // the hold-VALID / hold-payload rules apply -- so the only one in which
        // they can be broken.
        if (!injected && t.inject inside {INJ_AW_DROP, INJ_AW_PAYLOAD, INJ_AW_X}) begin
          bit hs;
          inject_aw(t, hs);
          if (hs) break;
        end
      end
      vif.awvalid <= 1'b0;

      // Registered at the handshake, so wr_out per ID is in issue order.
      wr_out[t.id].push_back(t);
    end
  endtask

  // `hs` is set if the handshake completed during the injection cycle (the slave
  // raised READY just then), so the caller does not wait for one that has happened.
  task inject_aw(axi4_seq_item t, output bit hs);
    hs = 1'b0;
    case (t.inject)
      INJ_AW_DROP: begin
        note_inject("AWVALID withdrawn before AWREADY", t);
        vif.awvalid <= 1'b0;
        @(posedge vif.aclk);
        vif.awvalid <= 1'b1;              // VALID was low this cycle: no handshake possible
      end
      INJ_AW_PAYLOAD: begin
        note_inject("AWCACHE changed while AWVALID && !AWREADY", t);
        vif.awcache <= ~t.cache;          // a field the DUT ignores: no side effects
        @(posedge vif.aclk);
        hs = vif.awready;
        vif.awcache <= t.cache;
      end
      INJ_AW_X: begin
        note_inject("AWBURST driven X while AWVALID", t);
        vif.awburst <= 2'bxx;
        @(posedge vif.aclk);
        hs = vif.awready;
        vif.awburst <= t.burst;
      end
      default: ;
    endcase
  endtask

  //--------------------------------------------------------------------------
  // Write data channel
  //--------------------------------------------------------------------------
  task inject_w(axi4_seq_item t, bit [AXI_DATA_W-1:0] dat, bit [AXI_STRB_W-1:0] stb,
                output bit hs);
    hs = 1'b0;
    case (t.inject)
      INJ_W_DROP: begin
        note_inject("WVALID withdrawn before WREADY", t);
        vif.wvalid <= 1'b0;
        @(posedge vif.aclk);
        vif.wvalid <= 1'b1;
      end
      INJ_W_PAYLOAD: begin
        note_inject("WDATA changed while WVALID && !WREADY", t);
        vif.wdata <= ~dat;
        @(posedge vif.aclk);
        hs = vif.wready;
        vif.wdata <= dat;
      end
      INJ_W_X: begin
        note_inject("WSTRB driven X while WVALID", t);
        vif.wstrb <= 'x;
        @(posedge vif.aclk);
        hs = vif.wready;
        vif.wstrb <= stb;
      end
      default: ;
    endcase
  endtask

  task w_thread();
    axi4_seq_item          t;
    bit                    early, missing;
    int                    nbeats;
    int unsigned           wd;
    bit [AXI_DATA_W-1:0]   dat;
    bit [AXI_STRB_W-1:0]   stb;

    forever begin
      w_mbx.get(t);

      // WLAST injection is decided once per burst, up front. (No declaration
      // initialisers in this loop: XSim evaluates them once, at time 0.)
      early   = (!injected && t.inject == INJ_WLAST_EARLY && t.len >= 1);
      missing = (!injected && t.inject == INJ_WLAST_MISSING);
      if (early)   note_inject("WLAST asserted one beat early", t);
      if (missing) note_inject("last beat sent without WLAST; an extra beat carries it", t);
      nbeats = int'(t.len) + 1 + (missing ? 1 : 0);

      for (int b = 0; b < nbeats; b++) begin
        wd = (b <= int'(t.len)) ? t.w_delay[b] : 0;
        repeat (wd) begin
          vif.wvalid <= 1'b0;
          @(posedge vif.aclk);
        end

        if (b <= int'(t.len)) begin
          dat = t.data[b];
          stb = t.strb[b];
        end
        else begin                         // the extra beat of WLAST_MISSING
          dat = {$urandom, $urandom};
          stb = '1;
        end
        vif.wdata  <= dat;
        vif.wstrb  <= stb;
        if (early)        vif.wlast <= (b == int'(t.len) - 1);
        else if (missing) vif.wlast <= (b == nbeats - 1);
        else              vif.wlast <= (b == int'(t.len));
        vif.wvalid <= 1'b1;

        forever begin
          @(posedge vif.aclk);
          if (vif.wready) break;
          if (!injected && t.inject inside {INJ_W_DROP, INJ_W_PAYLOAD, INJ_W_X}) begin
            bit hs;
            inject_w(t, dat, stb, hs);
            if (hs) break;
          end
        end
      end

      vif.wvalid <= 1'b0;
      vif.wlast  <= 1'b0;
    end
  endtask

  //--------------------------------------------------------------------------
  // Write response channel
  //--------------------------------------------------------------------------
  task b_thread();
    axi4_seq_item t;
    bit [AXI_ID_W-1:0] bid;
    bit [1:0]          bresp;

    forever begin
      // BREADY is held low for the configured gap, then raised until a response
      // arrives. Withdrawing READY is legal at any time, so no stability rule
      // applies here.
      vif.bready <= 1'b0;
      repeat (cfg.b_ready_gap) @(posedge vif.aclk);
      vif.bready <= 1'b1;

      forever begin
        @(posedge vif.aclk);
        if (vif.bvalid && vif.bready) break;
        // Idle: no response on offer, so READY is free to move.
        if (cfg.ready_toggle_pct != 0 && !vif.bvalid &&
            ($urandom_range(99, 0) < cfg.ready_toggle_pct))
          vif.bready <= ~vif.bready;
        // A response appeared while READY happened to be low: raise it so the
        // transfer completes rather than stalling forever.
        if (vif.bvalid && !vif.bready) vif.bready <= 1'b1;
      end
      bid   = vif.bid;
      bresp = vif.bresp;
      vif.bready <= 1'b0;

      // exists() first: indexing a missing associative-array key to read
      // .size() can create the entry as a side effect, which would mask the
      // very error this branch is trying to report.
      if (!wr_out.exists(bid) || wr_out[bid].size() == 0) begin
        `uvm_error("AXI4DRV",
                   $sformatf("BRESP for id=%0d with nothing outstanding", bid))
      end
      else begin
        t = wr_out[bid].pop_front();
        t.resp      = bresp;
        t.completed = 1'b1;
        t.done_ev.trigger();
        wr_credits.put(1);
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // Read address channel
  //--------------------------------------------------------------------------
  task inject_ar(axi4_seq_item t, output bit hs);
    hs = 1'b0;
    case (t.inject)
      INJ_AR_DROP: begin
        note_inject("ARVALID withdrawn before ARREADY", t);
        vif.arvalid <= 1'b0;
        @(posedge vif.aclk);
        vif.arvalid <= 1'b1;
      end
      INJ_AR_PAYLOAD: begin
        note_inject("ARPROT changed while ARVALID && !ARREADY", t);
        vif.arprot <= ~t.prot;
        @(posedge vif.aclk);
        hs = vif.arready;
        vif.arprot <= t.prot;
      end
      INJ_AR_X: begin
        note_inject("ARBURST driven X while ARVALID", t);
        vif.arburst <= 2'bxx;
        @(posedge vif.aclk);
        hs = vif.arready;
        vif.arburst <= t.burst;
      end
      default: ;
    endcase
  endtask

  task ar_thread();
    axi4_seq_item t;
    forever begin
      ar_mbx.get(t);
      repeat (t.ar_delay) @(posedge vif.aclk);

      vif.arid     <= t.id;
      vif.araddr   <= t.addr;
      vif.arlen    <= t.len;
      vif.arsize   <= t.size;
      vif.arburst  <= t.burst;
      vif.arlock   <= t.lock;
      vif.arcache  <= t.cache;
      vif.arprot   <= t.prot;
      vif.arqos    <= t.qos;
      vif.arregion <= t.region;
      vif.arvalid  <= 1'b1;

      forever begin
        @(posedge vif.aclk);
        if (vif.arready) break;
        if (!injected && t.inject inside {INJ_AR_DROP, INJ_AR_PAYLOAD, INJ_AR_X}) begin
          bit hs;
          inject_ar(t, hs);
          if (hs) break;
        end
      end
      vif.arvalid <= 1'b0;

      rd_out[t.id].push_back(t);
    end
  endtask

  //--------------------------------------------------------------------------
  // Read data channel
  //
  // Beats for different IDs may interleave, so data is accumulated against the
  // head entry of that ID's queue and only retired on RLAST.
  //--------------------------------------------------------------------------
  task r_thread();
    axi4_seq_item t;
    bit [AXI_ID_W-1:0] rid;
    int unsigned       beat [bit [AXI_ID_W-1:0]];

    forever begin
      vif.rready <= 1'b0;
      repeat (cfg.r_ready_gap) @(posedge vif.aclk);
      vif.rready <= 1'b1;

      forever begin
        @(posedge vif.aclk);
        if (vif.rvalid && vif.rready) break;
        if (cfg.ready_toggle_pct != 0 && !vif.rvalid &&
            ($urandom_range(99, 0) < cfg.ready_toggle_pct))
          vif.rready <= ~vif.rready;
        if (vif.rvalid && !vif.rready) vif.rready <= 1'b1;
      end
      rid = vif.rid;

      if (!rd_out.exists(rid) || rd_out[rid].size() == 0) begin
        `uvm_error("AXI4DRV",
                   $sformatf("RDATA for id=%0d with nothing outstanding", rid))
      end
      else begin
        t = rd_out[rid][0];
        if (!beat.exists(rid)) beat[rid] = 0;
        if (t.rdata.size() == 0) begin
          t.rdata = new[t.len + 1];
          t.rresp = new[t.len + 1];
        end
        if (beat[rid] <= int'(t.len)) begin
          t.rdata[beat[rid]] = vif.rdata;
          t.rresp[beat[rid]] = vif.rresp;
        end

        if (vif.rlast) begin
          if (beat[rid] != int'(t.len))
            `uvm_error("AXI4DRV",
                       $sformatf("RLAST at beat %0d, expected %0d (id=%0d)",
                                 beat[rid], t.len, rid))
          t.resp      = vif.rresp;
          t.completed = 1'b1;
          t.done_ev.trigger();
          void'(rd_out[rid].pop_front());
          beat[rid] = 0;
          rd_credits.put(1);
        end
        else begin
          beat[rid] = beat[rid] + 1;
        end
      end
    end
  endtask

endclass : axi4_driver

`endif // AXI4_DRIVER_SV
