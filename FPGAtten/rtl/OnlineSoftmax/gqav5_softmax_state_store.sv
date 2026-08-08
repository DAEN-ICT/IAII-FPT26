module gqav5_softmax_state_store #(
  parameter int unsigned STATE_SLOTS = 4,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned DEPTH = STATE_SLOTS * 16,
  localparam int unsigned ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  logic                    clk_i,
  input  logic                    read_enable_i,
  input  logic [STATE_SLOT_W-1:0] read_state_slot_i,
  input  logic [3:0]              read_row_index_i,
  output logic [63:0]             read_payload_o,
  input  logic                    write_enable_i,
  input  logic [STATE_SLOT_W-1:0] write_state_slot_i,
  input  logic [3:0]              write_row_index_i,
  input  logic [63:0]             write_payload_i
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic [ADDR_W-1:0] read_addr_w;
  logic [ADDR_W-1:0] write_addr_w;

  // m/l is payload, not reset state.  A synchronous read plus one linear
  // write port gives the implementation tool an unambiguous block-RAM shape.
  // The caller resets and checks the separate valid/busy metadata.
  (* ram_style = "block" *) logic [63:0] payload_mem_q [DEPTH];

  assign read_addr_w = ADDR_W'({read_state_slot_i, read_row_index_i});
  assign write_addr_w = ADDR_W'({write_state_slot_i, write_row_index_i});

  always_ff @(posedge clk_i) begin
    if (read_enable_i)
      read_payload_o <= payload_mem_q[read_addr_w];
    if (write_enable_i)
      payload_mem_q[write_addr_w] <= write_payload_i;
  end

  initial begin
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16))
      $error("softmax state-store STATE_SLOTS must be in [1,16]");
    if ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS))
      $error("softmax state-store STATE_SLOTS must be a power of two");
  end
endmodule
