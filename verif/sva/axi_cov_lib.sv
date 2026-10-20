//==============================================================================
// axi_cov_lib.sv
//
// Small building blocks for the cover-event machinery.
//==============================================================================
`ifndef AXI_COV_LIB_SV
`define AXI_COV_LIB_SV

//------------------------------------------------------------------------------
// axi_cov_chain
//
// Procedural equivalent of the SVA sequence
//
//     t[0] ##1 t[1] ##1 ... ##1 t[N-1]
//
// `hit` is high in the cycle the final term completes a match. m[i] records "terms
// 0..i-1 matched in the cycles ending last cycle", the standard shift-register
// form of a ##1 chain. N must be >= 2; single-term events are emitted as plain
// wires by the generator.
//
// This exists because Vivado XSim ignores `cover property`. See
// scripts/gen_cover.py for why both renderings come from one table.
//------------------------------------------------------------------------------
module axi_cov_chain #(
  parameter int N = 2
) (
  input  logic         clk,
  input  logic         rstn,
  input  logic [N-1:0] t,
  output logic         hit
);

  logic [N-1:1] m;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      m <= '0;
    end
    else begin
      m[1] <= t[0];
      for (int i = 2; i < N; i++) m[i] <= m[i-1] & t[i-1];
    end
  end

  assign hit = m[N-1] & t[N-1];

endmodule : axi_cov_chain


//------------------------------------------------------------------------------
// axi_ooo_tracker
//
// Tracks outstanding transactions in issue order and reports, for each
// completion, how many OLDER outstanding transactions with a DIFFERENT ID are
// still waiting -- i.e. how far out of order the response came back.
//
//   dist == 0   the oldest outstanding transaction completed (in order)
//   dist  > 0   it overtook `dist` older transactions of other IDs
//
// Same-ID responses must stay in order by AXI rule, so the first match for an ID
// is always the right one to retire.
//
// Outputs are registered, so downstream covergroups and cover events sample them
// a cycle after the completion, race-free.
//------------------------------------------------------------------------------
module axi_ooo_tracker #(
  parameter int ID_W  = 4,
  parameter int DEPTH = 64
) (
  input  logic              clk,
  input  logic              rstn,
  input  logic              push,
  input  logic [ID_W-1:0]   push_id,
  input  logic              pop,
  input  logic [ID_W-1:0]   pop_id,

  output logic              dist_valid,   // a completion was seen last cycle
  output int unsigned       odist,
  output int unsigned       count         // outstanding right now
);

  logic [ID_W-1:0] q [DEPTH];
  int unsigned     n;
  int              p;

  // Blocking assignments to the internal queue are deliberate: it is private
  // state, never read outside this block. The outputs use non-blocking so other
  // blocks sampling them at the same edge see a stable value.
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      n          = 0;
      dist_valid <= 1'b0;
      odist      <= 0;
      count      <= 0;
    end
    else begin
      dist_valid <= 1'b0;

      if (pop) begin
        p = -1;
        for (int k = 0; k < DEPTH; k++)
          if ((k < int'(n)) && (p < 0) && (q[k] == pop_id)) p = k;

        if (p >= 0) begin
          odist      <= p;
          dist_valid <= 1'b1;
          for (int k = 0; k < DEPTH - 1; k++)
            if (k >= p) q[k] = q[k+1];
          n = n - 1;
        end
      end

      if (push && (n < DEPTH)) begin
        q[n] = push_id;
        n    = n + 1;
      end

      count <= n;
    end
  end

endmodule : axi_ooo_tracker

`endif // AXI_COV_LIB_SV
