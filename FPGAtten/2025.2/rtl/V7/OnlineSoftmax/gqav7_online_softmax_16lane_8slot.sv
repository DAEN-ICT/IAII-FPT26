// V7 semantic wrapper around the proven V5 online-softmax datapath.
// The arithmetic, ROMs and state-store implementation are inherited; V7
// fixes the architectural state-slot count at eight so two four-group waves
// can keep independent running-max/running-sum state.
module gqav7_online_softmax_16lane_8slot #(
  parameter int unsigned TXN_W = 16
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             in_valid_i,
  output logic             in_ready_o,
  input  logic [31:0]      score_fp32_i [16],
  input  logic [15:0]      score_valid_mask_i,
  input  logic [31:0]      block_max_fp32_i,
  input  logic [2:0]       state_slot_i,
  input  logic [3:0]       row_index_i,
  input  logic             first_context_i,
  input  logic             last_context_i,
  input  logic [TXN_W-1:0] txn_id_i,

  output logic             out_valid_o,
  input  logic             out_ready_i,
  output logic [15:0]      probability_bf16_o [16],
  output logic [15:0]      probability_valid_mask_o,
  output logic [31:0]      alpha_fp32_o,
  output logic [31:0]      block_sum_fp32_o,
  output logic [31:0]      running_max_fp32_o,
  output logic [31:0]      running_sum_fp32_o,
  output logic [2:0]       state_slot_o,
  output logic [3:0]       row_index_o,
  output logic             first_context_o,
  output logic             last_context_o,
  output logic [TXN_W-1:0] txn_id_o,

  output logic [4:0]       accepted_exp_cycle_o,
  output logic [63:0]      accepted_exp_total_o,
  output logic [63:0]      score_read_beats_o,
  output logic [63:0]      probability_beats_o,
  output logic [63:0]      state_commit_count_o,
  output logic             rom_sentinel_ok_o,
  output logic             protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic v5_out_valid;
  logic v5_out_ready;
  logic [15:0] v5_probability [16];
  logic [15:0] v5_probability_valid_mask;
  logic [31:0] v5_alpha;
  logic [31:0] v5_block_sum;
  logic [31:0] v5_running_max;
  logic [31:0] v5_running_sum;
  logic [2:0] v5_state_slot;
  logic [3:0] v5_row_index;
  logic v5_first_context;
  logic v5_last_context;
  logic [TXN_W-1:0] v5_txn_id;

  logic [1:0] output_fifo_count_q;
  logic output_fifo_head_q;
  logic output_fifo_tail_q;
  logic [15:0] output_fifo_probability_q [2][16];
  logic [15:0] output_fifo_probability_valid_mask_q [2];
  logic [31:0] output_fifo_alpha_q [2];
  logic [31:0] output_fifo_block_sum_q [2];
  logic [31:0] output_fifo_running_max_q [2];
  logic [31:0] output_fifo_running_sum_q [2];
  logic [2:0] output_fifo_state_slot_q [2];
  logic [3:0] output_fifo_row_index_q [2];
  logic output_fifo_first_context_q [2];
  logic output_fifo_last_context_q [2];
  logic [TXN_W-1:0] output_fifo_txn_id_q [2];
  logic output_fifo_push;
  logic output_fifo_pop;

  // The inherited 38-stage lock-step pipeline must not see PV's long
  // combinational ready chain.  A two-entry registered queue preserves one
  // row/cycle steady-state throughput and absorbs tile-boundary stalls while
  // its count alone controls the arithmetic pipeline.
  assign v5_out_ready = output_fifo_count_q != 2'd2;
  assign output_fifo_push = v5_out_valid && v5_out_ready;
  assign out_valid_o = output_fifo_count_q != 2'd0;
  assign output_fifo_pop = out_valid_o && out_ready_i;

  always_comb begin
    for (int lane = 0; lane < 16; lane++)
      probability_bf16_o[lane] =
          output_fifo_probability_q[output_fifo_head_q][lane];
    probability_valid_mask_o =
        output_fifo_probability_valid_mask_q[output_fifo_head_q];
    alpha_fp32_o = output_fifo_alpha_q[output_fifo_head_q];
    block_sum_fp32_o = output_fifo_block_sum_q[output_fifo_head_q];
    running_max_fp32_o = output_fifo_running_max_q[output_fifo_head_q];
    running_sum_fp32_o = output_fifo_running_sum_q[output_fifo_head_q];
    state_slot_o = output_fifo_state_slot_q[output_fifo_head_q];
    row_index_o = output_fifo_row_index_q[output_fifo_head_q];
    first_context_o = output_fifo_first_context_q[output_fifo_head_q];
    last_context_o = output_fifo_last_context_q[output_fifo_head_q];
    txn_id_o = output_fifo_txn_id_q[output_fifo_head_q];
  end

  // Wide queue payload is owned by count/head/tail and therefore reset-free.
  always_ff @(posedge clk_i) begin
    if (output_fifo_push) begin
      for (int lane = 0; lane < 16; lane++)
        output_fifo_probability_q[output_fifo_tail_q][lane]
            <= v5_probability[lane];
      output_fifo_probability_valid_mask_q[output_fifo_tail_q]
          <= v5_probability_valid_mask;
      output_fifo_alpha_q[output_fifo_tail_q] <= v5_alpha;
      output_fifo_block_sum_q[output_fifo_tail_q] <= v5_block_sum;
      output_fifo_running_max_q[output_fifo_tail_q] <= v5_running_max;
      output_fifo_running_sum_q[output_fifo_tail_q] <= v5_running_sum;
      output_fifo_state_slot_q[output_fifo_tail_q] <= v5_state_slot;
      output_fifo_row_index_q[output_fifo_tail_q] <= v5_row_index;
      output_fifo_first_context_q[output_fifo_tail_q] <=
          v5_first_context;
      output_fifo_last_context_q[output_fifo_tail_q] <= v5_last_context;
      output_fifo_txn_id_q[output_fifo_tail_q] <= v5_txn_id;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      output_fifo_count_q <= '0;
      output_fifo_head_q <= 1'b0;
      output_fifo_tail_q <= 1'b0;
    end else begin
      if (output_fifo_push)
        output_fifo_tail_q <= ~output_fifo_tail_q;
      if (output_fifo_pop)
        output_fifo_head_q <= ~output_fifo_head_q;
      unique case ({output_fifo_push, output_fifo_pop})
        2'b10:
          output_fifo_count_q <= output_fifo_count_q + 2'd1;
        2'b01:
          output_fifo_count_q <= output_fifo_count_q - 2'd1;
        default: begin
        end
      endcase
    end
  end

  gqav5_online_softmax_16lane #(
    .STATE_SLOTS(8),
    .TXN_W      (TXN_W)
  ) i_v5_datapath (
    .clk_i,
    .rst_ni,
    .in_valid_i,
    .in_ready_o,
    .score_fp32_i,
    .score_valid_mask_i,
    .block_max_fp32_i,
    .state_slot_i,
    .row_index_i,
    .first_context_i,
    .last_context_i,
    .txn_id_i,
    .out_valid_o(v5_out_valid),
    .out_ready_i(v5_out_ready),
    .probability_bf16_o(v5_probability),
    .probability_valid_mask_o(v5_probability_valid_mask),
    .alpha_fp32_o(v5_alpha),
    .block_sum_fp32_o(v5_block_sum),
    .running_max_fp32_o(v5_running_max),
    .running_sum_fp32_o(v5_running_sum),
    .state_slot_o(v5_state_slot),
    .row_index_o(v5_row_index),
    .first_context_o(v5_first_context),
    .last_context_o(v5_last_context),
    .txn_id_o(v5_txn_id),
    .accepted_exp_cycle_o,
    .accepted_exp_total_o,
    .score_read_beats_o,
    .probability_beats_o,
    .state_commit_count_o,
    .rom_sentinel_ok_o,
    .protocol_error_o
  );
endmodule
