//==============================================================================
// axi4_id_hazard.sv
//
// Spec decision G1: enforce same-ID response ordering across slaves.
//
// AXI requires responses that share an ID to return in the order they were
// issued. Once the same ID is outstanding to two different slaves that respond
// at different rates, the interconnect cannot honour that without either
// reordering responses or preventing the situation. This block prevents it: a
// request whose ID is already outstanding to a DIFFERENT slave is stalled until
// the earlier one drains.
//
// Same ID to the SAME slave is allowed freely -- the slave is obliged to keep
// its own responses in order, so there is nothing to enforce.
//
// Chosen over a per-ID reorder buffer because it is a table and a comparator
// rather than several hundred lines of response storage, and because a master
// that wants parallelism should be using distinct IDs. That is what the ID
// mechanism is for; serialising a master that reuses one ID everywhere is the
// correct outcome, not a performance bug.
//
// One instance per master per direction: AWID and ARID are independent
// namespaces, so a write with ID 3 imposes no ordering on a read with ID 3.
//==============================================================================
`ifndef AXI4_ID_HAZARD_SV
`define AXI4_ID_HAZARD_SV

module axi4_id_hazard #(
  parameter int ID_W    = 4,
  parameter int SIDXW   = 2,
  parameter int MAX_OUT = 8,
  parameter int N_IDS   = 1 << ID_W,
  parameter int CNTW    = $clog2(MAX_OUT + 1)
) (
  input  logic             clk,
  input  logic             rstn,

  // A request being offered to the crossbar this cycle.
  input  logic             issue_valid,     // handshake actually completing
  input  logic [ID_W-1:0]  issue_id,
  input  logic [SIDXW-1:0] issue_slave,

  // The response for that ID coming back.
  input  logic             retire_valid,
  input  logic [ID_W-1:0]  retire_id,

  // Combinational: this ID is busy with a different slave right now.
  input  logic [ID_W-1:0]  probe_id,
  input  logic [SIDXW-1:0] probe_slave,
  output logic             stall
);

  logic [CNTW-1:0]  cnt  [N_IDS];
  logic [SIDXW-1:0] dest [N_IDS];

  // Stall when the probed ID has traffic in flight to somewhere else, or when
  // it has saturated its own outstanding budget.
  always_comb begin
    stall = (cnt[probe_id] != '0) &&
            ((dest[probe_id] != probe_slave) || (cnt[probe_id] == CNTW'(MAX_OUT)));
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      for (int i = 0; i < N_IDS; i++) begin
        cnt[i]  <= '0;
        dest[i] <= '0;
      end
    end
    else begin
      // Issue and retire of the same ID in one cycle cancel out, so the two
      // updates are combined rather than written as independent statements --
      // the second would otherwise silently win.
      if (issue_valid && retire_valid && (issue_id == retire_id)) begin
        dest[issue_id] <= issue_slave;
      end
      else begin
        if (issue_valid) begin
          cnt[issue_id]  <= cnt[issue_id] + CNTW'(1);
          dest[issue_id] <= issue_slave;
        end
        if (retire_valid) begin
          if (cnt[retire_id] != '0)
            cnt[retire_id] <= cnt[retire_id] - CNTW'(1);
        end
      end
    end
  end

`ifndef SYNTHESIS
  // The stall is what makes same-ID ordering hold, so it is worth asserting
  // that it is never bypassed rather than trusting the surrounding logic.
  // The condition is computed here rather than written inside the property.
  //
  // XSim cannot sample an unpacked-array element indexed by a signal from
  // within a property: cnt[issue_id] and dest[issue_id] both read as X, so
  // (cnt == 0) || (dest == slave) evaluates to X and the assertion "fails" on
  // every issue while the data path is provably correct. $sampled() in the
  // action block reports X for the same reason, which makes the failure look
  // like a design bug rather than a tool artifact.
  //
  // Reducing it to a single-bit signal computed in always_comb sidesteps the
  // problem entirely, and reads better besides.
  logic split_violation;
  logic [SIDXW-1:0] dbg_dest;
  logic [CNTW-1:0]  dbg_cnt;

  always_comb begin
    dbg_cnt         = cnt[issue_id];
    dbg_dest        = dest[issue_id];
    split_violation = issue_valid && (dbg_cnt != '0) && (dbg_dest != issue_slave);
  end

  a_no_split_id : assert property (
      @(posedge clk) disable iff (!rstn) !split_violation)
    else $error("axi4_id_hazard: id %0d -> slave %0d while %0d outstanding to %0d",
                issue_id, issue_slave, dbg_cnt, dbg_dest);
`endif

endmodule : axi4_id_hazard

`endif // AXI4_ID_HAZARD_SV
