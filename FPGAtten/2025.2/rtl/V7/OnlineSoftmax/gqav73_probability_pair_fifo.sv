// V7.3 registered-ready boundary between probability-pair rescale and PV.
//
// A four-entry shift FIFO deliberately does not expose downstream ready on
// its input-ready path.  This cuts the routed PV-bank/context ownership cone
// that previously propagated through Pair Rescale into every Softmax CE.
// Payload registers are reset-free; count is the sole validity qualifier.
module gqav73_probability_pair_fifo #(
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  parameter int unsigned DEPTH       = 4,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned COUNT_W = $clog2(DEPTH + 1)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic                    in_set_i,
  input  logic [15:0]             in_low_probability_bf16_i [8],
  input  logic [15:0]             in_high_probability_bf16_i [8],
  input  logic [31:0]             in_combined_alpha_fp32_i,
  input  logic [31:0]             in_running_sum_fp32_i,
  input  logic [STATE_SLOT_W-1:0] in_state_slot_i,
  input  logic [3:0]              in_row_index_i,
  input  logic                    in_first_context_i,
  input  logic                    in_last_context_i,
  input  logic [TXN_W-1:0]        in_txn_id_i,

  output logic                    out_valid_o,
  input  logic                    out_ready_i,
  output logic                    out_set_o,
  output logic [15:0]             out_low_probability_bf16_o [8],
  output logic [15:0]             out_high_probability_bf16_o [8],
  output logic [31:0]             out_combined_alpha_fp32_o,
  output logic [31:0]             out_running_sum_fp32_o,
  output logic [STATE_SLOT_W-1:0] out_state_slot_o,
  output logic [3:0]              out_row_index_o,
  output logic                    out_first_context_o,
  output logic                    out_last_context_o,
  output logic [TXN_W-1:0]        out_txn_id_o,

  output logic [63:0]             stall_cycles_o,
  output logic                    protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef struct packed {
    logic [7:0][15:0]          low_probability;
    logic [7:0][15:0]          high_probability;
    logic [31:0]               combined_alpha;
    logic [31:0]               running_sum;
    logic [TXN_W-1:0]          txn_id;
    logic [STATE_SLOT_W-1:0]   state_slot;
    logic [3:0]                row_index;
    logic                      set;
    logic                      first_context;
    logic                      last_context;
  } payload_t;

  payload_t data_q [DEPTH];
  payload_t input_payload;
  logic [COUNT_W-1:0] count_q;
  logic push;
  logic pop;

  always_comb begin
    for (int lane = 0; lane < 8; lane++) begin
      input_payload.low_probability[lane] =
          in_low_probability_bf16_i[lane];
      input_payload.high_probability[lane] =
          in_high_probability_bf16_i[lane];
      out_low_probability_bf16_o[lane] =
          data_q[0].low_probability[lane];
      out_high_probability_bf16_o[lane] =
          data_q[0].high_probability[lane];
    end
    input_payload.combined_alpha = in_combined_alpha_fp32_i;
    input_payload.running_sum = in_running_sum_fp32_i;
    input_payload.txn_id = in_txn_id_i;
    input_payload.state_slot = in_state_slot_i;
    input_payload.row_index = in_row_index_i;
    input_payload.set = in_set_i;
    input_payload.first_context = in_first_context_i;
    input_payload.last_context = in_last_context_i;
  end

  assign in_ready_o = count_q < COUNT_W'(DEPTH);
  assign out_valid_o = count_q != '0;
  assign push = in_valid_i && in_ready_o;
  assign pop = out_valid_o && out_ready_i;

  assign out_combined_alpha_fp32_o = data_q[0].combined_alpha;
  assign out_running_sum_fp32_o = data_q[0].running_sum;
  assign out_txn_id_o = data_q[0].txn_id;
  assign out_state_slot_o = data_q[0].state_slot;
  assign out_row_index_o = data_q[0].row_index;
  assign out_set_o = data_q[0].set;
  assign out_first_context_o = data_q[0].first_context;
  assign out_last_context_o = data_q[0].last_context;

  always_ff @(posedge clk_i) begin
    if (pop) begin
      for (int entry = 0; entry < DEPTH - 1; entry++) begin
        if (COUNT_W'(entry + 1) < count_q)
          data_q[entry] <= data_q[entry + 1];
      end
      if (push)
        data_q[count_q - 1'b1] <= input_payload;
    end else if (push) begin
      data_q[count_q] <= input_payload;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_q <= '0;
      stall_cycles_o <= '0;
      protocol_error_o <= 1'b0;
    end else begin
      unique case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
      if (in_valid_i && !in_ready_o)
        stall_cycles_o <= stall_cycles_o + 64'd1;
      if (count_q > COUNT_W'(DEPTH))
        protocol_error_o <= 1'b1;
    end
  end

  initial begin
    if ((DEPTH < 2) || (DEPTH > 8))
      $error("V7.3 probability-pair FIFO depth must be in [2,8]");
  end
endmodule
