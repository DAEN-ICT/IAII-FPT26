module gqav5_attention_overlap_pipeline #(
  parameter int unsigned QK_STEPS     = 128,
  parameter int unsigned OUTPUT_TILES = 8,
  parameter int unsigned STATE_SLOTS  = 4,
  parameter int unsigned TXN_W        = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned OUTPUT_TILE_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    desc_valid_i,
  output logic                    desc_ready_o,
  input  logic [STATE_SLOT_W-1:0] desc_state_slot_i,
  input  logic [31:0]             desc_query_base_i,
  input  logic [31:0]             desc_context_base_i,
  input  logic [4:0]              desc_query_valid_rows_i,
  input  logic [4:0]              desc_context_valid_cols_i,
  input  logic                    desc_causal_i,
  input  logic                    desc_first_context_i,
  input  logic                    desc_last_context_i,
  input  logic [31:0]             attention_scale_fp32_i,
  input  logic [TXN_W-1:0]        desc_txn_id_i,

  input  logic                    qk_step_valid_i,
  output logic                    qk_step_ready_o,
  input  logic [15:0]             q_bf16_i [16],
  input  logic [15:0]             k_bf16_i [16],

  input  logic                    v_step_valid_i,
  output logic                    v_step_ready_o,
  input  logic [15:0]             v_bf16_i [16],

  output logic                    result_valid_o,
  input  logic                    result_ready_i,
  output logic [31:0]             result_fp32_o [16],
  output logic [OUTPUT_TILE_W-1:0] result_output_tile_o,
  output logic [3:0]              result_row_index_o,
  output logic [TXN_W-1:0]        result_txn_id_o,
  output logic                    result_row_valid_o,

  output logic                    busy_o,
  output logic                    done_o,
  output logic                    qk_active_o,
  output logic                    softmax_active_o,
  output logic                    pv_active_o,
  output logic                    update_active_o,
  output logic [63:0]             total_cycles_o,
  output logic [63:0]             qk_accepted_macs_o,
  output logic [63:0]             softmax_accepted_exp_o,
  output logic [63:0]             pv_accepted_macs_o,
  output logic [63:0]             update_accepted_elements_o,
  output logic [63:0]             partial_capture_count_o,
  output logic [63:0]             partial_row_transfer_count_o,
  output logic                    error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic score_row_valid;
  logic score_row_ready;
  logic [31:0] score_row [16];
  logic [3:0] score_row_index;
  logic [STATE_SLOT_W-1:0] score_state_slot;
  logic [31:0] score_query_base;
  logic [31:0] score_context_base;
  logic [4:0] score_query_valid_rows;
  logic [4:0] score_context_valid_cols;
  logic score_causal;
  logic score_first_context;
  logic score_last_context;
  logic [31:0] score_scale;
  logic [TXN_W-1:0] score_txn;
  logic qk_stage_busy;
  logic qk_stage_error;
  logic downstream_busy;
  logic downstream_error;
  logic [15:0] v_partition_legacy [4][16];

  generate
    for (genvar part = 0; part < 4; part++) begin : gen_legacy_v_part
      for (genvar lane = 0; lane < 16; lane++) begin : gen_legacy_v_lane
        assign v_partition_legacy[part][lane] = v_bf16_i[lane];
      end
    end
  endgenerate

  /* verilator lint_off PINCONNECTEMPTY */
  gqav5_qk_score_stage #(
    .QK_STEPS   (QK_STEPS),
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W      (TXN_W)
  ) i_qk_score_stage (
    .clk_i,
    .rst_ni,
    .desc_valid_i,
    .desc_ready_o,
    .desc_state_slot_i,
    .desc_query_base_i,
    .desc_context_base_i,
    .desc_query_valid_rows_i,
    .desc_context_valid_cols_i,
    .desc_causal_i,
    .desc_first_context_i,
    .desc_last_context_i,
    .desc_scale_fp32_i       (attention_scale_fp32_i),
    .desc_txn_id_i,
    .qk_step_valid_i,
    .qk_step_ready_o,
    .q_bf16_i,
    .k_bf16_i,
    .score_row_valid_o       (score_row_valid),
    .score_row_ready_i       (score_row_ready),
    .score_row_fp32_o        (score_row),
    .score_row_index_o       (score_row_index),
    .score_state_slot_o      (score_state_slot),
    .score_query_base_o      (score_query_base),
    .score_context_base_o    (score_context_base),
    .score_query_valid_rows_o(score_query_valid_rows),
    .score_context_valid_cols_o(score_context_valid_cols),
    .score_causal_o          (score_causal),
    .score_first_context_o   (score_first_context),
    .score_last_context_o    (score_last_context),
    .score_scale_fp32_o      (score_scale),
    .score_txn_id_o          (score_txn),
    .busy_o                  (qk_stage_busy),
    .qk_active_o,
    .accepted_macs_o         (qk_accepted_macs_o),
    .captured_tiles_o        (),
    .transferred_score_rows_o(),
    .error_o                 (qk_stage_error)
  );

  gqav5_attention_downstream #(
    .OUTPUT_TILES(OUTPUT_TILES),
    .STATE_SLOTS (STATE_SLOTS),
    .TXN_W       (TXN_W)
  ) i_downstream (
    .clk_i,
    .rst_ni,
    .score_row_valid_i       (score_row_valid),
    .score_row_ready_o       (score_row_ready),
    .score_row_fp32_i        (score_row),
    .score_row_index_i       (score_row_index),
    .score_state_slot_i      (score_state_slot),
    .score_query_base_i      (score_query_base),
    .score_context_base_i    (score_context_base),
    .score_query_valid_rows_i(score_query_valid_rows),
    .score_context_valid_cols_i(score_context_valid_cols),
    .score_causal_i          (score_causal),
    .score_first_context_i   (score_first_context),
    .score_last_context_i    (score_last_context),
    .score_scale_fp32_i      (score_scale),
    .score_txn_id_i          (score_txn),
    .pv_skip_enable_i        (1'b0),
    .pv_skip_lambda_fp32_i   (32'd0),
    .v_step_valid_i,
    .v_step_ready_o,
    .v_bf16_i,
    .v_partition_bf16_i      (v_partition_legacy),
    .result_valid_o,
    .result_ready_i,
    .result_fp32_o,
    .result_output_tile_o,
    .result_row_index_o,
    .result_txn_id_o,
    .result_row_valid_o,
    .busy_o                  (downstream_busy),
    .done_o,
    .softmax_active_o,
    .pv_active_o,
    .update_active_o,
    .active_cycles_o         (),
    .softmax_accepted_exp_o,
    .pv_accepted_macs_o,
    .update_accepted_elements_o,
    .partial_capture_count_o,
    .partial_row_transfer_count_o,
    .pv_blocks_total_o       (),
    .pv_blocks_skipped_o     (),
    .pv_skip_decision_valid_o(),
    .pv_skip_decision_o      (),
    .error_o                 (downstream_error)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign busy_o = qk_stage_busy || downstream_busy;
  assign error_o = qk_stage_error || downstream_error;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      total_cycles_o <= '0;
    else if (busy_o)
      total_cycles_o <= total_cycles_o + 64'd1;
  end
endmodule
