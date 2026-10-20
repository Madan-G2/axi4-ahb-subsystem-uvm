//==============================================================================
// axi4_default_slave.sv
//
// Answers every transaction that decodes to no real slave with DECERR.
//
// The temptation is to make this trivial -- assert BVALID and be done. It is
// not trivial, because an error response still has to be protocol-legal: the
// write data burst must be fully consumed before BVALID, and a read must return
// exactly ARLEN+1 beats with RLAST on the last one. A default slave that
// swallows the address and forgets the data burst deadlocks the master, and a
// master hung behind a stray access to an unmapped address is a genuinely
// horrible thing to debug.
//
// Depth-1 for reads and writes. Errors are not a throughput path, and a deeper
// queue here would only add state to get wrong.
//==============================================================================
`ifndef AXI4_DEFAULT_SLAVE_SV
`define AXI4_DEFAULT_SLAVE_SV

module axi4_default_slave
  import axi4_pkg::*;
#(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 64,
  parameter int ID_W   = 6,
  parameter int STRB_W = DATA_W/8
) (
  input  logic                aclk,
  input  logic                aresetn,

  input  logic [ID_W-1:0]     awid,
  input  logic [ADDR_W-1:0]   awaddr,
  input  logic [7:0]          awlen,
  input  logic [2:0]          awsize,
  input  logic [1:0]          awburst,
  input  logic                awlock,
  input  logic [3:0]          awcache,
  input  logic [2:0]          awprot,
  input  logic                awvalid,
  output logic                awready,

  input  logic [DATA_W-1:0]   wdata,
  input  logic [STRB_W-1:0]   wstrb,
  input  logic                wlast,
  input  logic                wvalid,
  output logic                wready,

  output logic [ID_W-1:0]     bid,
  output logic [1:0]          bresp,
  output logic                bvalid,
  input  logic                bready,

  input  logic [ID_W-1:0]     arid,
  input  logic [ADDR_W-1:0]   araddr,
  input  logic [7:0]          arlen,
  input  logic [2:0]          arsize,
  input  logic [1:0]          arburst,
  input  logic                arlock,
  input  logic [3:0]          arcache,
  input  logic [2:0]          arprot,
  input  logic                arvalid,
  output logic                arready,

  output logic [ID_W-1:0]     rid,
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          rresp,
  output logic                rlast,
  output logic                rvalid,
  input  logic                rready
);

  //--------------------------------------------------------------------------
  // Write path: capture AW, swallow the whole W burst, then respond.
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wst_e;
  wst_e            wst;
  logic [ID_W-1:0] w_id;

  assign awready = (wst == W_IDLE);
  assign wready  = (wst == W_DATA);
  assign bvalid  = (wst == W_RESP);
  assign bid     = w_id;
  assign bresp   = AXI_RESP_DECERR;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wst  <= W_IDLE;
      w_id <= '0;
    end
    else begin
      unique case (wst)
        W_IDLE: if (awvalid && awready) begin
                  w_id <= awid;
                  wst  <= W_DATA;
                end
        // Consume every beat. BVALID must not appear before WLAST is accepted.
        W_DATA: if (wvalid && wready && wlast) wst <= W_RESP;
        W_RESP: if (bvalid && bready)          wst <= W_IDLE;
        default: wst <= W_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // Read path: return the full beat count the master asked for.
  //--------------------------------------------------------------------------
  typedef enum logic { R_IDLE, R_DATA } rst_e;
  rst_e            rst_q;
  logic [ID_W-1:0] r_id;
  logic [7:0]      r_len;
  logic [7:0]      r_beat;

  assign arready = (rst_q == R_IDLE);
  assign rvalid  = (rst_q == R_DATA);
  assign rid     = r_id;
  assign rdata   = '0;
  assign rresp   = AXI_RESP_DECERR;
  assign rlast   = (rst_q == R_DATA) && (r_beat == r_len);

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rst_q  <= R_IDLE;
      r_id   <= '0;
      r_len  <= '0;
      r_beat <= '0;
    end
    else begin
      unique case (rst_q)
        R_IDLE: if (arvalid && arready) begin
                  r_id   <= arid;
                  r_len  <= arlen;
                  r_beat <= '0;
                  rst_q  <= R_DATA;
                end
        R_DATA: if (rvalid && rready) begin
                  if (rlast) rst_q  <= R_IDLE;
                  else       r_beat <= r_beat + 8'd1;
                end
        default: rst_q <= R_IDLE;
      endcase
    end
  end

endmodule : axi4_default_slave

`endif // AXI4_DEFAULT_SLAVE_SV
