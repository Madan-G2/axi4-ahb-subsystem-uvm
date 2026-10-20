//==============================================================================
// axi4_monitor.sv
//
// Passive AXI4 monitor. Reconstructs whole transactions from channel handshakes
// and publishes them once the final response beat lands.
//
// The monitor is entirely independent of the driver -- it never looks at what
// was sent, only at what appeared on the wires. That matters: a monitor that
// reuses the driver's bookkeeping cannot catch a driver bug, and in a passive
// instance (M0, watching the CPU in Phase 5) there is no driver to borrow from
// at all.
//
// Association rules, which follow directly from the protocol:
//   * W beats belong to the oldest un-served AW. AXI4 has no WID and forbids
//     write interleaving, so head-of-queue is exact.
//   * B and R responses are matched by ID, in order within that ID. Different
//     IDs may complete in any order, which is why each ID gets its own queue
//     rather than one global list.
//==============================================================================
`ifndef AXI4_MONITOR_SV
`define AXI4_MONITOR_SV

class axi4_monitor extends uvm_monitor;


  `uvm_component_utils(axi4_monitor)

  virtual axi4_if                        vif;
  axi4_agent_cfg                         cfg;

  uvm_analysis_port #(axi4_seq_item)     ap;

  // Writes seen on AW but not yet fully described by W beats.
  axi4_seq_item                          aw_q [$];
  // Writes whose W burst finished, awaiting B. Per ID, in order.
  axi4_seq_item                          b_pend [bit [AXI_ID_W-1:0]][$];
  // Reads seen on AR, awaiting R beats. Per ID, in order.
  axi4_seq_item                          r_pend [bit [AXI_ID_W-1:0]][$];

  int unsigned                           w_beat;
  int unsigned                           r_beat [bit [AXI_ID_W-1:0]];

  // W beats seen before their AW.
  //
  // AXI4 explicitly permits WVALID before AWVALID, and it happens routinely
  // once there is a crossbar in the path: AW can be stalled by arbitration or
  // by the ID-hazard check while the W skid buffer keeps accepting data. A
  // monitor that drops those beats reports WLAST arriving early by exactly the
  // number it dropped, which looks like an RTL burst-length bug and is not one.
  typedef struct {
    logic [AXI_DATA_W-1:0] data;
    logic [AXI_STRB_W-1:0] strb;
    logic                  last;
  } wbeat_t;

  wbeat_t                                w_pend [$];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(axi4_agent_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("AXI4MON", "axi4_agent_cfg not found in config DB")
    vif = cfg.vif;
  endfunction

  //--------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.aclk);
      if (!vif.aresetn) begin
        flush();
        continue;
      end
      sample_aw();
      sample_w();
      sample_b();
      sample_ar();
      sample_r();
    end
  endtask

  function void flush();
    aw_q.delete();
    b_pend.delete();
    r_pend.delete();
    r_beat.delete();
    w_pend.delete();
    w_beat = 0;
  endfunction

  //--------------------------------------------------------------------------
  function void sample_aw();
    axi4_seq_item t;
    if (!(vif.awvalid && vif.awready)) return;

    t = axi4_seq_item::type_id::create("wr");
    t.master_idx = cfg.master_idx;
    t.is_write = 1'b1;
    t.id       = vif.awid;
    t.addr     = vif.awaddr;
    t.len      = vif.awlen;
    t.size     = vif.awsize;
    t.burst    = vif.awburst;
    t.lock     = vif.awlock;
    t.cache    = vif.awcache;
    t.prot     = vif.awprot;
    t.qos      = vif.awqos;
    t.region   = vif.awregion;
    t.data     = new[t.len + 1];
    t.strb     = new[t.len + 1];
    aw_q.push_back(t);
    drain_pending_w();
  endfunction

  //--------------------------------------------------------------------------
  // Attach one beat to the oldest un-served AW. Head-of-queue association is
  // exact: AXI4 has no WID and forbids write interleaving.
  function void consume_w(wbeat_t b);
    axi4_seq_item t = aw_q[0];

    if (w_beat <= int'(t.len)) begin
      t.data[w_beat] = b.data;
      t.strb[w_beat] = b.strb;
    end

    if (b.last) begin
      if (w_beat != int'(t.len))
        `uvm_error("AXI4MON",
                   $sformatf("WLAST at beat %0d, AWLEN implies %0d",
                             w_beat, t.len))
      void'(aw_q.pop_front());
      b_pend[t.id].push_back(t);
      w_beat = 0;
    end
    else begin
      w_beat++;
    end
  endfunction

  // Drain buffered beats into AWs as they arrive.
  function void drain_pending_w();
    while ((w_pend.size() > 0) && (aw_q.size() > 0))
      consume_w(w_pend.pop_front());
  endfunction

  function void sample_w();
    wbeat_t b;
    if (!(vif.wvalid && vif.wready)) return;

    b.data = vif.wdata;
    b.strb = vif.wstrb;
    b.last = vif.wlast;

    // Buffer rather than drop when the address has not arrived yet, and stay
    // behind anything already buffered so ordering is preserved.
    if ((aw_q.size() == 0) || (w_pend.size() > 0)) w_pend.push_back(b);
    else                                           consume_w(b);
  endfunction

  //--------------------------------------------------------------------------
  function void sample_b();
    axi4_seq_item t;
    bit [AXI_ID_W-1:0] id;
    if (!(vif.bvalid && vif.bready)) return;

    id = vif.bid;
    if (!b_pend.exists(id) || b_pend[id].size() == 0) begin
      `uvm_error("AXI4MON",
                 $sformatf("BRESP id=%0d with no matching write outstanding", id))
      return;
    end

    t = b_pend[id].pop_front();
    t.resp      = vif.bresp;
    t.completed = 1'b1;
    ap.write(t);
  endfunction

  //--------------------------------------------------------------------------
  function void sample_ar();
    axi4_seq_item t;
    if (!(vif.arvalid && vif.arready)) return;

    t = axi4_seq_item::type_id::create("rd");
    t.master_idx = cfg.master_idx;
    t.is_write = 1'b0;
    t.id       = vif.arid;
    t.addr     = vif.araddr;
    t.len      = vif.arlen;
    t.size     = vif.arsize;
    t.burst    = vif.arburst;
    t.lock     = vif.arlock;
    t.cache    = vif.arcache;
    t.prot     = vif.arprot;
    t.qos      = vif.arqos;
    t.region   = vif.arregion;
    t.rdata    = new[t.len + 1];
    t.rresp    = new[t.len + 1];
    r_pend[t.id].push_back(t);
  endfunction

  //--------------------------------------------------------------------------
  function void sample_r();
    axi4_seq_item t;
    bit [AXI_ID_W-1:0] id;
    if (!(vif.rvalid && vif.rready)) return;

    id = vif.rid;
    if (!r_pend.exists(id) || r_pend[id].size() == 0) begin
      `uvm_error("AXI4MON",
                 $sformatf("RDATA id=%0d with no matching read outstanding", id))
      return;
    end

    t = r_pend[id][0];
    if (!r_beat.exists(id)) r_beat[id] = 0;

    if (r_beat[id] <= int'(t.len)) begin
      t.rdata[r_beat[id]] = vif.rdata;
      t.rresp[r_beat[id]] = vif.rresp;
    end

    if (vif.rlast) begin
      if (r_beat[id] != int'(t.len))
        `uvm_error("AXI4MON",
                   $sformatf("RLAST at beat %0d, ARLEN implies %0d (id=%0d)",
                             r_beat[id], t.len, id))
      t.resp      = vif.rresp;
      t.completed = 1'b1;
      void'(r_pend[id].pop_front());
      r_beat[id] = 0;
      ap.write(t);
    end
    else begin
      r_beat[id]++;
    end
  endfunction

  //--------------------------------------------------------------------------
  // Nothing should still be in flight when the test ends. A transaction stuck
  // here is usually a lost response rather than a monitor problem.
  //--------------------------------------------------------------------------
  function void check_phase(uvm_phase phase);
    if (w_pend.size() != 0)
      `uvm_error("AXI4MON",
                 $sformatf("%0d W beats never matched an AW at end of test",
                           w_pend.size()))
    if (aw_q.size() != 0)
      `uvm_error("AXI4MON",
                 $sformatf("%0d writes with incomplete W bursts at end of test",
                           aw_q.size()))
    foreach (b_pend[i])
      if (b_pend[i].size() != 0)
        `uvm_error("AXI4MON",
                   $sformatf("id=%0d: %0d writes never got BRESP", i, b_pend[i].size()))
    foreach (r_pend[i])
      if (r_pend[i].size() != 0)
        `uvm_error("AXI4MON",
                   $sformatf("id=%0d: %0d reads never completed", i, r_pend[i].size()))
  endfunction

endclass : axi4_monitor

`endif // AXI4_MONITOR_SV
