//==============================================================================
// axi4_w_router.sv
//
// Routes write data from masters to slaves, preserving AXI4's ordering rules.
//
// AXI4 removed write interleaving and has no WID, so a master's W beats are
// implicitly associated with its own AW order. Two queues capture that:
//
//   mdest[m] : the slaves master m issued AWs to, in issue order
//   sown[s]  : the masters that were granted slave s, in grant order
//
// A beat moves from master m to slave s only when BOTH agree: s is at the head
// of mdest[m] and m is at the head of sown[s]. Requiring both is what keeps a
// master's bursts in its own AW order while also keeping each slave's W port
// owned by one master at a time.
//
// DEADLOCK-FREEDOM. It is not obvious that the two queues cannot disagree
// permanently. They cannot, because both are projections of the same total
// order of AW grants -- a cycle of the form "m waits for s, s waits for m'"
// would require grant timestamps t1 < t2 < ... < t1. This is one of the
// properties targeted at VC Formal in Phase 7 rather than left to argument.
//
// SKID BUFFER (spec decision G2). AXI4 explicitly permits WVALID before
// AWVALID, so beats can arrive before the router knows where to send them.
// Each master gets a small FIFO that accepts data regardless, and WREADY
// depends only on that FIFO having room. Without it the router would have to
// stall W until AW resolved, which works only because our own driver happens to
// send AW first -- a DUT that only behaves because the testbench is polite has
// a latent bug.
//==============================================================================
`ifndef AXI4_W_ROUTER_SV
`define AXI4_W_ROUTER_SV

module axi4_w_router #(
  parameter int N_M    = 3,
  parameter int N_ST   = 4,             // real slaves + default slave
  parameter int DATA_W = 64,
  parameter int STRB_W = DATA_W/8,
  parameter int SKID_D = 4,             // power of two
  parameter int QD     = 8,             // power of two
  parameter int MIDXW  = (N_M  > 1) ? $clog2(N_M)  : 1,
  parameter int SIDXW  = (N_ST > 1) ? $clog2(N_ST) : 1,
  parameter int SKPW   = $clog2(SKID_D),
  parameter int QPW    = $clog2(QD)
) (
  input  logic                          aclk,
  input  logic                          aresetn,

  // One push per slave per cycle, at that slave's AW grant. A master can only
  // have one AW accepted per cycle, so no master is ever pushed twice.
  input  logic [N_ST-1:0]               push_valid,
  input  logic [N_ST-1:0][MIDXW-1:0]    push_master,

  // Master-side W channels
  input  logic [N_M-1:0][DATA_W-1:0]    m_wdata,
  input  logic [N_M-1:0][STRB_W-1:0]    m_wstrb,
  input  logic [N_M-1:0]                m_wlast,
  input  logic [N_M-1:0]                m_wvalid,
  output logic [N_M-1:0]                m_wready,

  // Slave-side W channels
  output logic [N_ST-1:0][DATA_W-1:0]   s_wdata,
  output logic [N_ST-1:0][STRB_W-1:0]   s_wstrb,
  output logic [N_ST-1:0]               s_wlast,
  output logic [N_ST-1:0]               s_wvalid,
  input  logic [N_ST-1:0]               s_wready
);

  //--------------------------------------------------------------------------
  // Per-master skid FIFO
  //--------------------------------------------------------------------------
  logic [DATA_W-1:0] sk_data [N_M][SKID_D];
  logic [STRB_W-1:0] sk_strb [N_M][SKID_D];
  logic              sk_last [N_M][SKID_D];
  logic [SKPW-1:0]   sk_rd   [N_M];
  logic [SKPW-1:0]   sk_wr   [N_M];
  logic [SKPW:0]     sk_cnt  [N_M];

  //--------------------------------------------------------------------------
  // Ordering queues
  //--------------------------------------------------------------------------
  logic [SIDXW-1:0]  mdest    [N_M][QD];
  logic [QPW-1:0]    md_rd    [N_M];
  logic [QPW-1:0]    md_wr    [N_M];
  logic [QPW:0]      md_cnt   [N_M];

  logic [MIDXW-1:0]  sown     [N_ST][QD];
  logic [QPW-1:0]    so_rd    [N_ST];
  logic [QPW-1:0]    so_wr    [N_ST];
  logic [QPW:0]      so_cnt   [N_ST];

  //--------------------------------------------------------------------------
  // Transfer decision
  //--------------------------------------------------------------------------
  logic [MIDXW-1:0] own_m   [N_ST];   // master currently owning slave s
  logic [N_ST-1:0]  s_go;             // slave s may take a beat this cycle
  logic [N_M-1:0]   m_pop;            // master m's FIFO is popped this cycle
  logic [N_M-1:0]   m_pop_last;

  always_comb begin
    for (int s = 0; s < N_ST; s++) begin
      own_m[s]     = sown[s][so_rd[s]];
      s_go[s]      = 1'b0;
      s_wdata[s]   = '0;
      s_wstrb[s]   = '0;
      s_wlast[s]   = 1'b0;
      s_wvalid[s]  = 1'b0;

      if (so_cnt[s] != '0) begin
        // Both queues must agree before a beat may move. See the header note.
        if ((md_cnt[own_m[s]] != '0) &&
            (mdest[own_m[s]][md_rd[own_m[s]]] == SIDXW'(s)) &&
            (sk_cnt[own_m[s]] != '0)) begin
          s_go[s]     = 1'b1;
          s_wvalid[s] = 1'b1;
          s_wdata[s]  = sk_data[own_m[s]][sk_rd[own_m[s]]];
          s_wstrb[s]  = sk_strb[own_m[s]][sk_rd[own_m[s]]];
          s_wlast[s]  = sk_last[own_m[s]][sk_rd[own_m[s]]];
        end
      end
    end

    // At most one slave can be draining a given master, because mdest[m] has a
    // single head. Folding the per-slave decisions into a per-master pop is
    // therefore unambiguous.
    for (int m = 0; m < N_M; m++) begin
      m_pop[m]      = 1'b0;
      m_pop_last[m] = 1'b0;
    end
    for (int s = 0; s < N_ST; s++) begin
      if (s_go[s] && s_wready[s]) begin
        m_pop[own_m[s]]      = 1'b1;
        m_pop_last[own_m[s]] = s_wlast[s];
      end
    end
  end

  // WREADY depends only on skid-FIFO occupancy, never on whether the
  // destination is known yet. That is the whole point of the skid buffer.
  always_comb
    for (int m = 0; m < N_M; m++)
      m_wready[m] = (sk_cnt[m] != (SKPW+1)'(SKID_D));

  //--------------------------------------------------------------------------
  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      for (int m = 0; m < N_M; m++) begin
        sk_rd[m] <= '0; sk_wr[m] <= '0; sk_cnt[m] <= '0;
        md_rd[m] <= '0; md_wr[m] <= '0; md_cnt[m] <= '0;
      end
      for (int s = 0; s < N_ST; s++) begin
        so_rd[s] <= '0; so_wr[s] <= '0; so_cnt[s] <= '0;
      end
    end
    else begin
      //----------------------------------------------------------------------
      // Skid FIFO push / pop
      //----------------------------------------------------------------------
      for (int m = 0; m < N_M; m++) begin
        if (m_wvalid[m] && m_wready[m]) begin
          sk_data[m][sk_wr[m]] <= m_wdata[m];
          sk_strb[m][sk_wr[m]] <= m_wstrb[m];
          sk_last[m][sk_wr[m]] <= m_wlast[m];
          sk_wr[m]             <= sk_wr[m] + SKPW'(1);
        end
        if (m_pop[m]) sk_rd[m] <= sk_rd[m] + SKPW'(1);

        sk_cnt[m] <= sk_cnt[m]
                   + (((m_wvalid[m] && m_wready[m]) ? 1 : 0))
                   - ((m_pop[m] ? 1 : 0));
      end

      //----------------------------------------------------------------------
      // mdest: push the slave this master's AW was granted to
      //----------------------------------------------------------------------
      for (int m = 0; m < N_M; m++) begin
        logic       push_m;
        logic [SIDXW-1:0] push_s;
        push_m = 1'b0;
        push_s = '0;
        for (int s = 0; s < N_ST; s++)
          if (push_valid[s] && (push_master[s] == MIDXW'(m))) begin
            push_m = 1'b1;
            push_s = SIDXW'(s);
          end

        if (push_m) begin
          mdest[m][md_wr[m]] <= push_s;
          md_wr[m]           <= md_wr[m] + QPW'(1);
        end
        // The destination is retired when the burst ends, not per beat.
        if (m_pop[m] && m_pop_last[m]) md_rd[m] <= md_rd[m] + QPW'(1);

        md_cnt[m] <= md_cnt[m] + ((push_m ? 1 : 0))
                                - (((m_pop[m] && m_pop_last[m]) ? 1 : 0));
      end

      //----------------------------------------------------------------------
      // sown: push the master that won this slave
      //----------------------------------------------------------------------
      for (int s = 0; s < N_ST; s++) begin
        logic pop_s;
        pop_s = s_go[s] && s_wready[s] && s_wlast[s];

        if (push_valid[s]) begin
          sown[s][so_wr[s]] <= push_master[s];
          so_wr[s]          <= so_wr[s] + QPW'(1);
        end
        if (pop_s) so_rd[s] <= so_rd[s] + QPW'(1);

        so_cnt[s] <= so_cnt[s] + ((push_valid[s] ? 1 : 0)) - ((pop_s ? 1 : 0));
      end
    end
  end

`ifndef SYNTHESIS
  // Overflowing either ordering queue would silently corrupt W routing rather
  // than stall, so it is worth catching directly. The crossbar's outstanding
  // limit is what keeps them bounded.
  // Precomputed for the same reason as in axi4_id_hazard: XSim mis-samples
  // unpacked-array reads inside a property.
  logic q_overflow;
  always_comb begin
    q_overflow = 1'b0;
    for (int m = 0; m < N_M;  m++) if (md_cnt[m] > (QPW+1)'(QD)) q_overflow = 1'b1;
    for (int s = 0; s < N_ST; s++) if (so_cnt[s] > (QPW+1)'(QD)) q_overflow = 1'b1;
  end

  a_queue_no_overflow : assert property (
      @(posedge aclk) disable iff (!aresetn) !q_overflow)
    else $error("axi4_w_router: ordering queue overflow");
`endif

endmodule : axi4_w_router

`endif // AXI4_W_ROUTER_SV
