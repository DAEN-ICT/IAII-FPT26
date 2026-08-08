module gqav5_buffered_attention_pipeline #(
  parameter int unsigned QK_STEPS     = 128,
  parameter int unsigned OUTPUT_TILES = 8,
  parameter int unsigned STATE_SLOTS  = 4,
  parameter int unsigned TXN_W        = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned OUTPUT_TILE_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES)
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
  input  logic [31:0]             attention_scale_fp32_i,
  input  logic [TXN_W-1:0]        desc_txn_id_i,
  input  logic                    pv_skip_enable_i,
  input  logic [31:0]             pv_skip_lambda_fp32_i,

  input  logic q_fill_valid_i,
  output logic q_fill_ready_o,
  input  logic [15:0] q_fill_tag_i,
  output logic q_fill_bank_o,
  input  logic q_fill_row_valid_i,
  output logic q_fill_row_ready_o,
  input  logic [3:0] q_fill_row_addr_i,
  input  logic [255:0] q_fill_row_data_i,
  input  logic q_fill_row_last_i,
  input  logic k_fill_valid_i,
  output logic k_fill_ready_o,
  input  logic [15:0] k_fill_tag_i,
  output logic k_fill_bank_o,
  input  logic k_fill_row_valid_i,
  output logic k_fill_row_ready_o,
  input  logic [3:0] k_fill_row_addr_i,
  input  logic [255:0] k_fill_row_data_i,
  input  logic k_fill_row_last_i,

  input  logic v_fill_valid_i,
  output logic v_fill_ready_o,
  input  logic [15:0] v_fill_tag_i,
  output logic v_fill_bank_o,
  input  logic v_fill_row_valid_i,
  output logic v_fill_row_ready_o,
  input  logic [3:0] v_fill_row_addr_i,
  input  logic [255:0] v_fill_row_data_i,
  input  logic v_fill_row_last_i,

  output logic                    result_valid_o,
  input  logic                    result_ready_i,
  output logic [31:0]             result_fp32_o [16],
  output logic [OUTPUT_TILE_W-1:0] result_output_tile_o,
  output logic [3:0]              result_row_index_o,
  output logic [TXN_W-1:0]        result_txn_id_o,
  output logic                    result_row_valid_o,

  output logic qk_active_o,
  output logic softmax_active_o,
  output logic pv_active_o,
  output logic update_active_o,
  output logic done_o,
  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] pv_accepted_macs_o,
  output logic [63:0] operand_prefetch_overlap_cycles_o,
  output logic [63:0] v_prefetch_overlap_cycles_o,
  output logic [63:0] completed_result_rows_o,
  output logic [63:0] pv_blocks_total_o,
  output logic [63:0] pv_blocks_skipped_o,
  output logic error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

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
  gqav5_bank_state_e q_bank_state [2];
  gqav5_bank_state_e k_bank_state [2];
  logic [63:0] qk_operand_reads;
  logic [63:0] qk_operand_tiles;
  logic qk_error;

  logic v_row_valid;
  logic v_row_ready;
  logic [15:0] v_row [16];
  logic [15:0] v_partition_legacy [4][16];
  logic [3:0] v_row_index;
  logic [15:0] v_tile_tag;
  logic v_row_last;
  logic v_tile_done;
  gqav5_bank_state_e v_bank_state [2];
  logic [63:0] v_bram_reads;
  logic [63:0] v_tiles;
  logic v_error;

  logic downstream_busy;
  logic downstream_error;
  logic unused_pv_skip_decision_valid;
  logic unused_pv_skip_decision;
  logic [63:0] downstream_active_cycles;
  logic [63:0] softmax_exp;
  logic [63:0] update_elements;
  logic [63:0] partial_captures;
  logic [63:0] partial_rows;
  logic [TXN_W-1:0] active_txn_q;
  logic [OUTPUT_TILE_W-1:0] expected_v_tile_q;
  logic [3:0] expected_v_row_q;
  logic v_tag_error_q;
  logic desc_fire;
  logic v_row_fire;
  logic [15:0] expected_v_tag;

  generate
    for (genvar part = 0; part < 4; part++) begin : gen_legacy_v_part
      for (genvar lane = 0; lane < 16; lane++) begin : gen_legacy_v_lane
        assign v_partition_legacy[part][lane] = v_row[lane];
      end
    end
  endgenerate

  assign desc_fire = desc_valid_i && desc_ready_o;
  assign v_row_fire = v_row_valid && v_row_ready;
  assign expected_v_tag = {active_txn_q[12:0], 3'(expected_v_tile_q)};

  gqav5_buffered_qk_score_stage #(
    .QK_STEPS   (QK_STEPS),
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W      (TXN_W)
  ) i_qk (
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
    .q_bank_state_o          (q_bank_state),
    .k_bank_state_o          (k_bank_state),
    .qk_active_o,
    .qk_accepted_macs_o,
    .operand_bram_pair_reads_o(qk_operand_reads),
    .prefetch_compute_overlap_cycles_o(operand_prefetch_overlap_cycles_o),
    .operand_tile_count_o    (qk_operand_tiles),
    .error_o                 (qk_error)
  );

  gqav5_v_row_pingpong i_v_buffer (
    .clk_i,
    .rst_ni,
    .fill_valid_i          (v_fill_valid_i),
    .fill_ready_o          (v_fill_ready_o),
    .fill_tag_i            (v_fill_tag_i),
    .fill_bank_o           (v_fill_bank_o),
    .fill_row_valid_i      (v_fill_row_valid_i),
    .fill_row_ready_o      (v_fill_row_ready_o),
    .fill_row_addr_i       (v_fill_row_addr_i),
    .fill_row_data_i       (v_fill_row_data_i),
    .fill_row_last_i       (v_fill_row_last_i),
    .v_row_valid_o         (v_row_valid),
    .v_row_ready_i         (v_row_ready),
    .v_row_bf16_o          (v_row),
    .v_row_index_o         (v_row_index),
    .v_tile_tag_o          (v_tile_tag),
    .v_row_last_o          (v_row_last),
    .tile_done_o           (v_tile_done),
    .bank_state_o          (v_bank_state),
    .bram_read_count_o     (v_bram_reads),
    .fill_compute_overlap_cycle_count_o(v_prefetch_overlap_cycles_o),
    .completed_tile_count_o(v_tiles),
    .protocol_error_o      (v_error)
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
    .pv_skip_enable_i,
    .pv_skip_lambda_fp32_i,
    .v_step_valid_i          (v_row_valid),
    .v_step_ready_o          (v_row_ready),
    .v_bf16_i                (v_row),
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
    .active_cycles_o         (downstream_active_cycles),
    .softmax_accepted_exp_o  (softmax_exp),
    .pv_accepted_macs_o,
    .update_accepted_elements_o(update_elements),
    .partial_capture_count_o (partial_captures),
    .partial_row_transfer_count_o(partial_rows),
    .pv_blocks_total_o,
    .pv_blocks_skipped_o,
    .pv_skip_decision_valid_o(unused_pv_skip_decision_valid),
    .pv_skip_decision_o     (unused_pv_skip_decision),
    .error_o                 (downstream_error)
  );

  assign error_o = qk_error || v_error || downstream_error || v_tag_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_txn_q             <= '0;
      expected_v_tile_q        <= '0;
      expected_v_row_q         <= '0;
      v_tag_error_q            <= 1'b0;
      completed_result_rows_o  <= '0;
    end else begin
      if (desc_fire) begin
        active_txn_q      <= desc_txn_id_i;
        expected_v_tile_q <= '0;
        expected_v_row_q  <= '0;
      end
      if (v_row_fire) begin
        if (v_tile_tag != expected_v_tag ||
            v_row_index != expected_v_row_q ||
            v_row_last != (expected_v_row_q == 4'd15))
          v_tag_error_q <= 1'b1;
        if (v_row_last) begin
          expected_v_row_q <= '0;
          if (expected_v_tile_q == OUTPUT_TILE_W'(OUTPUT_TILES - 1))
            expected_v_tile_q <= '0;
          else
            expected_v_tile_q <= expected_v_tile_q + OUTPUT_TILE_W'(1);
        end else begin
          expected_v_row_q <= expected_v_row_q + 4'd1;
        end
      end
      if (result_valid_o && result_ready_i)
        completed_result_rows_o <= completed_result_rows_o + 64'd1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    q_bank_state[0], q_bank_state[1], k_bank_state[0], k_bank_state[1],
    v_bank_state[0], v_bank_state[1], qk_operand_reads, qk_operand_tiles,
    v_tile_done, v_bram_reads, v_tiles, downstream_busy,
    downstream_active_cycles, softmax_exp, update_elements,
    partial_captures, partial_rows, active_txn_q,
    unused_pv_skip_decision_valid, unused_pv_skip_decision
  };

  initial begin
    if (TXN_W < 13)
      $error("TXN_W must retain the 13-bit V-tile tag prefix");
    if (OUTPUT_TILES > 8)
      $error("16-bit V tag reserves three bits for output_tile");
  end
endmodule
