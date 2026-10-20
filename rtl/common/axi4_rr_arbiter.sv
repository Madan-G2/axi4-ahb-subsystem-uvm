//==============================================================================
// axi4_rr_arbiter.sv
//
// Round-robin arbiter.
//
// The pointer advances only when a grant is actually consumed, not merely
// offered. An arbiter that rotates on every grant regardless of acceptance
// starves requesters whenever the downstream port is backpressured, and that
// starvation is invisible until a fairness check goes looking for it.
//==============================================================================
`ifndef AXI4_RR_ARBITER_SV
`define AXI4_RR_ARBITER_SV

module axi4_rr_arbiter #(
  parameter int N    = 3,
  parameter int IDXW = (N > 1) ? $clog2(N) : 1,

  // Set for arbiters whose grant must outlive a gap in the request. The R-channel
  // arbiters are the case: the grant is pinned until RLAST is accepted, but a
  // slave may legally drop RVALID between the beats of a burst, so the request
  // disappears while the grant is (correctly) still held.
  parameter bit HOLD_ACROSS_GAPS = 1'b0
) (
  input  logic            clk,
  input  logic            rstn,

  input  logic [N-1:0]    req,
  input  logic            accept,      // grant consumed this cycle

  output logic            gnt_valid,
  output logic [N-1:0]    gnt_onehot,
  output logic [IDXW-1:0] gnt_idx
);

  logic [IDXW-1:0] ptr;
  logic            locked;
  logic [IDXW-1:0] lock_idx;
  logic            scan_valid;
  logic [IDXW-1:0] scan_idx;
  int              k;

  // Scan N slots starting at ptr, take the first requester found.
  always_comb begin
    scan_valid = 1'b0;
    scan_idx   = '0;
    for (int i = 0; i < N; i++) begin
      k = int'(ptr) + i;
      if (k >= N) k = k - N;
      if (!scan_valid && req[k]) begin
        scan_valid = 1'b1;
        scan_idx   = IDXW'(k);
      end
    end
  end

  // GRANT HOLD.
  //
  // Once a grant is issued it is held until it is accepted, rather than being
  // re-decided every cycle. Without this the arbiter switches away from a
  // requester whose VALID is already asserted and still waiting for READY as
  // soon as a nearer-to-pointer requester appears -- which changes the address
  // and control payload in the middle of a handshake and violates AXI's
  // stability rules. It shows up as a_aw_payload_stable firing on the slave
  // side, some distance from the arbiter that caused it.
  always_comb begin
    gnt_valid  = locked ? 1'b1     : scan_valid;
    gnt_idx    = locked ? lock_idx : scan_idx;
    gnt_onehot = '0;
    if (gnt_valid) gnt_onehot[gnt_idx] = 1'b1;
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      ptr      <= '0;
      locked   <= 1'b0;
      lock_idx <= '0;
    end
    else if (gnt_valid && accept) begin
      // Rotate past the requester that was just served.
      ptr    <= (int'(gnt_idx) == N-1) ? '0 : (gnt_idx + IDXW'(1));
      locked <= 1'b0;
    end
`ifdef REPLAY_A1
    // Bug A1 as first written: no grant hold on the AW / AR / B arbiters, so the
    // choice is re-made every cycle. (The R arbiters keep their lock: they are the
    // burst lock, a separate mechanism.) See docs/bug_replays.md.
    else if (gnt_valid && !locked && HOLD_ACROSS_GAPS) begin
`else
    else if (gnt_valid && !locked) begin
`endif
      // Offered but not taken: freeze this choice until it is.
      locked   <= 1'b1;
      lock_idx <= gnt_idx;
    end
  end

`ifndef SYNTHESIS
  // ---------------------------------------------------------------------------
  // Assertions are written over the arbiter's REGISTERS (locked, lock_idx) and its
  // input (req), never over its combinational outputs gnt_valid / gnt_idx.
  // Under XSim a concurrent assertion that reads a module output port driven by
  // always_comb gets X from the preponed sample in some instances, which fails any
  // property that touches it (docs/xsim_notes.md). The register form is equivalent,
  // because gnt_valid = locked ? 1 : scan_valid and gnt_idx = locked ? lock_idx : scan_idx,
  // and the unlocked case is a requester by construction.
  // ---------------------------------------------------------------------------

  // A grant, once offered, does not move until it is accepted. This is the
  // property the grant-hold logic exists to provide (bug A1), and it holds for
  // every arbiter in the design regardless of what the requests do meanwhile:
  // a grant that was offered and not accepted must be locked, on the same index,
  // in the next cycle.
  logic [IDXW-1:0] gnt_idx_q;
  logic            held_q;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      gnt_idx_q <= '0;
      held_q    <= 1'b0;
    end
    else begin
      gnt_idx_q <= gnt_idx;
      held_q    <= gnt_valid && !accept;
    end
  end

  a_gnt_held_until_accept : assert property (
      @(posedge clk) disable iff (!rstn)
      held_q |-> (locked && lock_idx == gnt_idx_q))
    else $error("axi4_rr_arbiter: an unaccepted grant to idx %0d was not held (locked=%b lock_idx=%0d)",
                gnt_idx_q, locked, lock_idx);

  // A held grant must still correspond to a live request. If the requester goes
  // away while the grant is locked, the arbiter is presenting a phantom request
  // downstream -- which for an AXI address channel means offering one master's
  // payload to a slave it was never destined for. Not applicable where the
  // request may legitimately gap (see HOLD_ACROSS_GAPS).
  a_gnt_is_requesting : assert property (
      @(posedge clk) disable iff (!rstn) (locked && !HOLD_ACROSS_GAPS) |-> req[lock_idx])
    else $error("axi4_rr_arbiter: grant held for idx %0d but req=%b", lock_idx, req);
`endif

endmodule : axi4_rr_arbiter

`endif // AXI4_RR_ARBITER_SV
