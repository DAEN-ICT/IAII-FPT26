module gqav5_buffered_qk_score_stage #(
  parameter int unsigned QK_STEPS    = 128,
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  parameter int unsigned OPERAND_TAG_W = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS)
) (
  input  logic clk_i,
  input  logic rst_ni,

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
  input  logic [31:0]             desc_scale_fp32_i,
  input  logic [TXN_W-1:0]        desc_txn_id_i,

  input  logic q_fill_valid_i,
  output logic q_fill_ready_o,
  input  logic [OPERAND_TAG_W-1:0] q_fill_tag_i,
  output logic q_fill_bank_o,
  input  logic q_fill_row_valid_i,
  output logic q_fill_row_ready_o,
  input  logic [3:0] q_fill_row_addr_i,
  input  logic [255:0] q_fill_row_data_i,
  input  logic q_fill_row_last_i,
  input  logic k_fill_valid_i,
  output logic k_fill_ready_o,
  input  logic [OPERAND_TAG_W-1:0] k_fill_tag_i,
  output logic k_fill_bank_o,
  input  logic k_fill_row_valid_i,
  output logic k_fill_row_ready_o,
  input  logic [3:0] k_fill_row_addr_i,
  input  logic [255:0] k_fill_row_data_i,
  input  logic k_fill_row_last_i,

  output logic                    score_row_valid_o,
  input  logic                    score_row_ready_i,
  output logic [31:0]             score_row_fp32_o [16],
  output logic [3:0]              score_row_index_o,
  output logic [STATE_SLOT_W-1:0] score_state_slot_o,
  output logic [31:0]             score_query_base_o,
  output logic [31:0]             score_context_base_o,
  output logic [4:0]              score_query_valid_rows_o,
  output logic [4:0]              score_context_valid_cols_o,
  output logic                    score_causal_o,
  output logic                    score_first_context_o,
  output logic                    score_last_context_o,
  output logic [31:0]             score_scale_fp32_o,
  output logic [TXN_W-1:0]        score_txn_id_o,

  output gqav5_pkg::gqav5_bank_state_e q_bank_state_o [2],
  output gqav5_pkg::gqav5_bank_state_e k_bank_state_o [2],
  output logic qk_active_o,
  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] operand_bram_pair_reads_o,
  output logic [63:0] prefetch_compute_overlap_cycles_o,
  output logic [63:0] operand_tile_count_o,
  output logic error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic operand_step_valid;
  logic operand_step_ready;
  logic [15:0] operand_q_column [16];
  logic [15:0] operand_k_column [16];
  logic [3:0] operand_step_index;
  logic [OPERAND_TAG_W-1:0] operand_step_tag;
  logic operand_tile_done;
  logic operand_error;
  logic qk_busy;
  logic qk_error;
  logic [63:0] captured_scores;
  logic [63:0] transferred_rows;

  gqav5_qk_operand_pingpong #(.TAG_W(OPERAND_TAG_W)) i_operands (
    .clk_i,
    .rst_ni,
    .q_fill_valid_i,
    .q_fill_ready_o,
    .q_fill_tag_i,
    .q_fill_bank_o,
    .q_fill_row_valid_i,
    .q_fill_row_ready_o,
    .q_fill_row_addr_i,
    .q_fill_row_data_i,
    .q_fill_row_last_i,
    .k_fill_valid_i,
    .k_fill_ready_o,
    .k_fill_tag_i,
    .k_fill_bank_o,
    .k_fill_row_valid_i,
    .k_fill_row_ready_o,
    .k_fill_row_addr_i,
    .k_fill_row_data_i,
    .k_fill_row_last_i,
    .step_valid_o          (operand_step_valid),
    .step_ready_i          (operand_step_ready),
    .q_column_bf16_o       (operand_q_column),
    .k_column_bf16_o       (operand_k_column),
    .step_index_o          (operand_step_index),
    .step_tag_o            (operand_step_tag),
    .tile_done_o           (operand_tile_done),
    .q_bank_state_o,
    .k_bank_state_o,
    .bram_pair_read_count_o(operand_bram_pair_reads_o),
    .prefetch_compute_overlap_cycle_count_o(
        prefetch_compute_overlap_cycles_o),
    .completed_tile_count_o(operand_tile_count_o),
    .protocol_error_o      (operand_error)
  );

  gqav5_qk_score_stage #(
    .QK_STEPS   (QK_STEPS),
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W      (TXN_W)
  ) i_qk_score (
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
    .desc_scale_fp32_i,
    .desc_txn_id_i,
    .qk_step_valid_i       (operand_step_valid),
    .qk_step_ready_o       (operand_step_ready),
    .q_bf16_i              (operand_q_column),
    .k_bf16_i              (operand_k_column),
    .score_row_valid_o,
    .score_row_ready_i,
    .score_row_fp32_o,
    .score_row_index_o,
    .score_state_slot_o,
    .score_query_base_o,
    .score_context_base_o,
    .score_query_valid_rows_o,
    .score_context_valid_cols_o,
    .score_causal_o,
    .score_first_context_o,
    .score_last_context_o,
    .score_scale_fp32_o,
    .score_txn_id_o,
    .busy_o                (qk_busy),
    .qk_active_o,
    .accepted_macs_o       (qk_accepted_macs_o),
    .captured_tiles_o      (captured_scores),
    .transferred_score_rows_o(transferred_rows),
    .error_o               (qk_error)
  );

  assign error_o = operand_error || qk_error;

  logic unused_status;
  assign unused_status = ^{
    operand_step_index, operand_step_tag, operand_tile_done,
    qk_busy, captured_scores, transferred_rows
  };
endmodule
