module gqav5_partitioned_buffered_attention_pipeline #(
  parameter int unsigned QK_STEPS       = 128,
  parameter int unsigned OUTPUT_TILES   = 8,
  parameter int unsigned STATE_SLOTS    = 4,
  parameter int unsigned TXN_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4,
  // Production builds use the packed column feeder.  Keep the V4.1 row
  // interface as an explicit opt-in so OOC/integrated synthesis does not
  // silently retain the duplicate compatibility cache and broadcast path.
  parameter bit ENABLE_ROW_COMPAT       = 1'b0,
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
  input  logic k_fill_broadcast_i,
  input  logic [1:0] k_fill_partition_i,
  input  logic [15:0] k_fill_tag_i,
  output logic k_fill_bank_o,
  input  logic k_fill_row_valid_i,
  output logic k_fill_row_ready_o,
  input  logic [3:0] k_fill_row_addr_i,
  input  logic [255:0] k_fill_row_data_i,
  input  logic k_fill_row_last_i,

  input  logic qk_stream_start_valid_i,
  output logic qk_stream_start_ready_o,
  input  logic [15:0] qk_stream_start_tag_i,
  input  logic qk_stream_row_valid_i,
  output logic qk_stream_row_ready_o,
  input  logic [3:0] qk_stream_row_index_i,
  input  logic [255:0] qk_stream_q_row_bf16_i,
  input  logic [255:0]
      qk_stream_k_partition_row_bf16_i [ROW_PARTITIONS],
  input  logic qk_stream_row_last_i,

  input  logic qk_column_start_valid_i,
  output logic qk_column_start_ready_o,
  input  logic [15:0] qk_column_start_tag_i,
  input  logic qk_column_valid_i,
  output logic qk_column_ready_o,
  input  logic [3:0] qk_column_index_i,
  input  logic [255:0] qk_column_q_word_bf16_i,
  input  logic [255:0]
      qk_column_k_partition_word_bf16_i [ROW_PARTITIONS],
  input  logic qk_column_last_i,

  input  logic v_fill_valid_i,
  output logic v_fill_ready_o,
  input  logic v_fill_broadcast_i,
  input  logic [1:0] v_fill_partition_i,
  input  logic [15:0] v_fill_tag_i,
  output logic v_fill_bank_o,
  input  logic v_fill_row_valid_i,
  output logic v_fill_row_ready_o,
  input  logic [3:0] v_fill_row_addr_i,
  input  logic [255:0] v_fill_row_data_i,
  input  logic v_fill_row_last_i,

  input  logic pv_stream_start_valid_i,
  output logic pv_stream_start_ready_o,
  input  logic [15:0] pv_stream_start_tag_i,
  input  logic pv_stream_row_valid_i,
  output logic pv_stream_row_ready_o,
  input  logic [3:0] pv_stream_row_index_i,
  input  logic [255:0]
      pv_stream_v_partition_row_bf16_i [ROW_PARTITIONS],
  input  logic pv_stream_row_last_i,

  output logic                     result_valid_o,
  input  logic                     result_ready_i,
  output logic [31:0]              result_fp32_o [16],
  output logic [OUTPUT_TILE_W-1:0] result_output_tile_o,
  output logic [3:0]               result_row_index_o,
  output logic [TXN_W-1:0]         result_txn_id_o,
  output logic                     result_row_valid_o,

  output logic qk_active_o,
  output logic softmax_active_o,
  output logic pv_active_o,
  output logic update_active_o,
  output logic done_o,
  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] pv_accepted_macs_o,
  output logic [63:0] qk_operand_bram_reads_o,
  output logic [63:0] v_operand_bram_reads_o,
  output logic [63:0] operand_prefetch_overlap_cycles_o,
  output logic [63:0] v_prefetch_overlap_cycles_o,
  output logic [63:0] completed_result_rows_o,
  output logic [63:0] pv_blocks_total_o,
  output logic [63:0] pv_blocks_skipped_o,
  output logic pv_skip_decision_valid_o,
  output logic pv_skip_decision_o,
  output logic issue_done_o,
  output logic error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  logic score_row_valid, score_row_ready;
  logic [31:0] score_row [16];
  logic [3:0] score_row_index;
  logic [STATE_SLOT_W-1:0] score_state_slot;
  logic [31:0] score_query_base, score_context_base, score_scale;
  logic [4:0] score_query_valid_rows, score_context_valid_cols;
  logic score_causal, score_first_context, score_last_context;
  logic [TXN_W-1:0] score_txn;
  logic v72_score_valid, v72_score_ready;
  logic [31:0] v72_score [8];
  logic [3:0] v72_score_row;
  logic v72_score_half;
  logic [STATE_SLOT_W-1:0] v72_score_state_slot;
  logic [31:0] v72_score_query_base, v72_score_context_base;
  logic [4:0] v72_score_query_valid_rows, v72_score_context_valid_cols;
  logic v72_score_causal, v72_score_first_context, v72_score_last_context;
  logic [31:0] v72_score_scale;
  logic [TXN_W-1:0] v72_score_txn;
  logic v72_splitter_error;
  gqav5_bank_state_e q_bank_state [2];
  gqav5_bank_state_e k_bank_state [ROW_PARTITIONS][2];
  logic [63:0] qk_operand_tiles;
  logic qk_error;

  logic v_row_valid, v_row_ready;
  logic [15:0] v_partition_row [ROW_PARTITIONS][16];
  logic [3:0] v_row_index;
  logic [15:0] v_tile_tag;
  logic v_row_last, v_tile_done;
  gqav5_bank_state_e v_bank_state [ROW_PARTITIONS][2];
  logic [63:0] v_tiles;
  logic v_error;

  logic downstream_busy, downstream_error;
  logic [63:0] downstream_active_cycles, softmax_exp, update_elements;
  logic [63:0] partial_captures, partial_rows;
  logic [TXN_W-1:0] active_txn_q;
  logic [TXN_W-1:0] txn_fifo_q [2];
  logic txn_write_ptr_q;
  logic txn_read_ptr_q;
  logic [1:0] txn_count_q;
  logic qk_desc_ready;
  logic [OUTPUT_TILE_W-1:0] expected_v_tile_q;
  logic [3:0] expected_v_row_q;
  logic v_tag_error_q;
  logic desc_fire, v_row_fire, v_descriptor_done;
  logic [15:0] expected_v_tag;

  assign desc_ready_o = qk_desc_ready && (txn_count_q < 2);
  assign desc_fire = desc_valid_i && desc_ready_o;
  assign v_row_fire = v_row_valid && v_row_ready;
  assign v_descriptor_done = v_row_fire && v_row_last &&
      (expected_v_tile_q == OUTPUT_TILE_W'(OUTPUT_TILES - 1));
  assign issue_done_o = v_descriptor_done;
  assign active_txn_q = txn_fifo_q[txn_read_ptr_q];
  assign expected_v_tag = {active_txn_q[12:0], 3'(expected_v_tile_q)};

  gqav5_partitioned_buffered_qk_score_stage #(
    .QK_STEPS(QK_STEPS), .STATE_SLOTS(STATE_SLOTS), .TXN_W(TXN_W),
    .ROW_PARTITIONS(ROW_PARTITIONS),
    .ENABLE_ROW_COMPAT(ENABLE_ROW_COMPAT)
  ) i_qk (
    .clk_i, .rst_ni,
    .desc_valid_i(desc_valid_i && (txn_count_q < 2)),
    .desc_ready_o(qk_desc_ready), .desc_state_slot_i,
    .desc_query_base_i, .desc_context_base_i, .desc_query_valid_rows_i,
    .desc_context_valid_cols_i, .desc_causal_i, .desc_first_context_i,
    .desc_last_context_i, .desc_scale_fp32_i(attention_scale_fp32_i),
    .desc_txn_id_i, .q_fill_valid_i, .q_fill_ready_o, .q_fill_tag_i,
    .q_fill_bank_o, .q_fill_row_valid_i, .q_fill_row_ready_o,
    .q_fill_row_addr_i, .q_fill_row_data_i, .q_fill_row_last_i,
    .k_fill_valid_i, .k_fill_ready_o, .k_fill_broadcast_i,
    .k_fill_partition_i, .k_fill_tag_i,
    .k_fill_bank_o, .k_fill_row_valid_i, .k_fill_row_ready_o,
    .k_fill_row_addr_i, .k_fill_row_data_i, .k_fill_row_last_i,
    .qk_stream_start_valid_i, .qk_stream_start_ready_o,
    .qk_stream_start_tag_i, .qk_stream_row_valid_i,
    .qk_stream_row_ready_o, .qk_stream_row_index_i,
    .qk_stream_q_row_bf16_i, .qk_stream_k_partition_row_bf16_i,
    .qk_stream_row_last_i,
    .qk_column_start_valid_i, .qk_column_start_ready_o,
    .qk_column_start_tag_i, .qk_column_valid_i,
    .qk_column_ready_o, .qk_column_index_i,
    .qk_column_q_word_bf16_i,
    .qk_column_k_partition_word_bf16_i, .qk_column_last_i,
    .score_row_valid_o(score_row_valid),
    .score_row_ready_i(score_row_ready), .score_row_fp32_o(score_row),
    .score_row_index_o(score_row_index),
    .score_state_slot_o(score_state_slot),
    .score_query_base_o(score_query_base),
    .score_context_base_o(score_context_base),
    .score_query_valid_rows_o(score_query_valid_rows),
    .score_context_valid_cols_o(score_context_valid_cols),
    .score_causal_o(score_causal),
    .score_first_context_o(score_first_context),
    .score_last_context_o(score_last_context),
    .score_scale_fp32_o(score_scale), .score_txn_id_o(score_txn),
    .q_bank_state_o(q_bank_state), .k_bank_state_o(k_bank_state),
    .qk_active_o, .qk_accepted_macs_o,
    .operand_bram_reads_o(qk_operand_bram_reads_o),
    .prefetch_compute_overlap_cycles_o(operand_prefetch_overlap_cycles_o),
    .operand_tile_count_o(qk_operand_tiles), .error_o(qk_error)
  );

  gqav5_partitioned_v_row_pingpong #(
    .TAG_W(16), .PARTITIONS(ROW_PARTITIONS)
  ) i_v_buffer (
    .clk_i, .rst_ni, .fill_valid_i(v_fill_valid_i),
    .fill_ready_o(v_fill_ready_o), .fill_broadcast_i(v_fill_broadcast_i),
    .fill_partition_i(v_fill_partition_i),
    .fill_tag_i(v_fill_tag_i), .fill_bank_o(v_fill_bank_o),
    .fill_row_valid_i(v_fill_row_valid_i),
    .fill_row_ready_o(v_fill_row_ready_o),
    .fill_row_addr_i(v_fill_row_addr_i), .fill_row_data_i(v_fill_row_data_i),
    .fill_row_last_i(v_fill_row_last_i),
    .fast_start_valid_i(pv_stream_start_valid_i),
    .fast_start_ready_o(pv_stream_start_ready_o),
    .fast_start_tag_i(pv_stream_start_tag_i),
    .fast_row_valid_i(pv_stream_row_valid_i),
    .fast_row_ready_o(pv_stream_row_ready_o),
    .fast_row_index_i(pv_stream_row_index_i),
    .fast_v_partition_row_bf16_i(pv_stream_v_partition_row_bf16_i),
    .fast_row_last_i(pv_stream_row_last_i),
    .v_row_valid_o(v_row_valid),
    .v_row_ready_i(v_row_ready),
    .v_partition_row_bf16_o(v_partition_row),
    .v_row_index_o(v_row_index), .v_tile_tag_o(v_tile_tag),
    .v_row_last_o(v_row_last), .tile_done_o(v_tile_done),
    .bank_state_o(v_bank_state),
    .bram_read_count_o(v_operand_bram_reads_o),
    .fill_compute_overlap_cycle_count_o(v_prefetch_overlap_cycles_o),
    .completed_tile_count_o(v_tiles), .protocol_error_o(v_error)
  );

`ifdef GQAV72_LOGICAL_8X8_PRODUCTION
  gqav72_score_tile_splitter_8lane #(
    .STATE_SLOTS(STATE_SLOTS), .TXN_W(TXN_W)
  ) i_v72_score_splitter (
    .clk_i, .rst_ni,
    .in_valid_i(score_row_valid), .in_ready_o(score_row_ready),
    .in_score_fp32_i(score_row), .in_row_index_i(score_row_index),
    .in_state_slot_i(score_state_slot), .in_query_base_i(score_query_base),
    .in_context_base_i(score_context_base),
    .in_query_valid_rows_i(score_query_valid_rows),
    .in_context_valid_cols_i(score_context_valid_cols),
    .in_causal_i(score_causal),
    .in_first_context_i(score_first_context),
    .in_last_context_i(score_last_context),
    .in_scale_fp32_i(score_scale), .in_txn_id_i(score_txn),
    .out_valid_o(v72_score_valid), .out_ready_i(v72_score_ready),
    .out_score_fp32_o(v72_score), .out_row_index_o(v72_score_row),
    .out_context_half_o(v72_score_half),
    .out_state_slot_o(v72_score_state_slot),
    .out_query_base_o(v72_score_query_base),
    .out_context_base_o(v72_score_context_base),
    .out_query_valid_rows_o(v72_score_query_valid_rows),
    .out_context_valid_cols_o(v72_score_context_valid_cols),
    .out_causal_o(v72_score_causal),
    .out_first_context_o(v72_score_first_context),
    .out_last_context_o(v72_score_last_context),
    .out_scale_fp32_o(v72_score_scale), .out_txn_id_o(v72_score_txn),
    .protocol_error_o(v72_splitter_error)
  );

  gqav72_attention_downstream_8x8 #(
    .OUTPUT_TILES(OUTPUT_TILES), .STATE_SLOTS(STATE_SLOTS), .TXN_W(TXN_W),
    .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_downstream (
    .clk_i, .rst_ni, .score_row_valid_i(v72_score_valid),
    .score_row_ready_o(v72_score_ready), .score_row_fp32_i(v72_score),
    .score_row_index_i(v72_score_row),
    .score_context_half_i(v72_score_half),
    .score_state_slot_i(v72_score_state_slot),
    .score_query_base_i(v72_score_query_base),
    .score_context_base_i(v72_score_context_base),
    .score_query_valid_rows_i(v72_score_query_valid_rows),
    .score_context_valid_cols_i(v72_score_context_valid_cols),
    .score_causal_i(v72_score_causal),
    .score_first_context_i(v72_score_first_context),
    .score_last_context_i(v72_score_last_context),
    .score_scale_fp32_i(v72_score_scale), .score_txn_id_i(v72_score_txn),
    .pv_skip_enable_i, .pv_skip_lambda_fp32_i,
    .v_step_valid_i(v_row_valid), .v_step_ready_o(v_row_ready),
    .v_partition_bf16_i(v_partition_row), .result_valid_o,
    .result_ready_i, .result_fp32_o, .result_output_tile_o,
    .result_row_index_o, .result_txn_id_o, .result_row_valid_o,
    .busy_o(downstream_busy), .done_o, .softmax_active_o, .pv_active_o,
    .update_active_o, .active_cycles_o(downstream_active_cycles),
    .softmax_accepted_exp_o(softmax_exp), .pv_accepted_macs_o,
    .update_accepted_elements_o(update_elements),
    .partial_capture_count_o(partial_captures),
    .partial_row_transfer_count_o(partial_rows), .pv_blocks_total_o,
    .pv_blocks_skipped_o, .pv_skip_decision_valid_o,
    .pv_skip_decision_o, .error_o(downstream_error)
  );
`else
  assign v72_splitter_error = 1'b0;
  gqav5_attention_downstream #(
    .OUTPUT_TILES(OUTPUT_TILES), .STATE_SLOTS(STATE_SLOTS), .TXN_W(TXN_W),
    .PARTITIONED_PV(1'b1), .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_downstream (
    .clk_i, .rst_ni, .score_row_valid_i(score_row_valid),
    .score_row_ready_o(score_row_ready), .score_row_fp32_i(score_row),
    .score_row_index_i(score_row_index),
    .score_state_slot_i(score_state_slot),
    .score_query_base_i(score_query_base),
    .score_context_base_i(score_context_base),
    .score_query_valid_rows_i(score_query_valid_rows),
    .score_context_valid_cols_i(score_context_valid_cols),
    .score_causal_i(score_causal),
    .score_first_context_i(score_first_context),
    .score_last_context_i(score_last_context),
    .score_scale_fp32_i(score_scale), .score_txn_id_i(score_txn),
    .pv_skip_enable_i, .pv_skip_lambda_fp32_i,
    .v_step_valid_i(v_row_valid), .v_step_ready_o(v_row_ready),
    .v_bf16_i(v_partition_row[0]),
    .v_partition_bf16_i(v_partition_row), .result_valid_o,
    .result_ready_i, .result_fp32_o, .result_output_tile_o,
    .result_row_index_o, .result_txn_id_o, .result_row_valid_o,
    .busy_o(downstream_busy), .done_o, .softmax_active_o, .pv_active_o,
    .update_active_o, .active_cycles_o(downstream_active_cycles),
    .softmax_accepted_exp_o(softmax_exp), .pv_accepted_macs_o,
    .update_accepted_elements_o(update_elements),
    .partial_capture_count_o(partial_captures),
    .partial_row_transfer_count_o(partial_rows), .pv_blocks_total_o,
    .pv_blocks_skipped_o, .pv_skip_decision_valid_o,
    .pv_skip_decision_o, .error_o(downstream_error)
  );
`endif

  assign error_o = qk_error || v_error || downstream_error ||
                   v72_splitter_error || v_tag_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      txn_fifo_q[0] <= '0;
      txn_fifo_q[1] <= '0;
      txn_write_ptr_q <= 1'b0;
      txn_read_ptr_q <= 1'b0;
      txn_count_q <= '0;
      expected_v_tile_q <= '0;
      expected_v_row_q <= '0;
      v_tag_error_q <= 1'b0;
      completed_result_rows_o <= '0;
    end else begin
      if (desc_fire) begin
        txn_fifo_q[txn_write_ptr_q] <= desc_txn_id_i;
        txn_write_ptr_q <= ~txn_write_ptr_q;
      end
      unique case ({desc_fire, v_descriptor_done})
        2'b10: txn_count_q <= txn_count_q + 2'd1;
        2'b01: txn_count_q <= txn_count_q - 2'd1;
        default: begin end
      endcase
      if (v_row_fire) begin
        if ((txn_count_q == 0) || v_tile_tag != expected_v_tag ||
            v_row_index != expected_v_row_q ||
            v_row_last != (expected_v_row_q == 4'd15))
          v_tag_error_q <= 1'b1;
        if (v_row_last) begin
          expected_v_row_q <= '0;
          if (expected_v_tile_q == OUTPUT_TILE_W'(OUTPUT_TILES - 1)) begin
            expected_v_tile_q <= '0;
            txn_read_ptr_q <= ~txn_read_ptr_q;
          end else begin
            expected_v_tile_q <= expected_v_tile_q + OUTPUT_TILE_W'(1);
          end
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
    q_bank_state[0], k_bank_state[0][0], v_bank_state[0][0],
    qk_operand_tiles, v_tile_done, v_tiles, downstream_busy,
    downstream_active_cycles, softmax_exp, update_elements,
    partial_captures, partial_rows, active_txn_q, txn_count_q
  };

  initial begin
    if (ROW_PARTITIONS != 4)
      $error("partitioned buffered attention requires four KV regions");
    if (TXN_W < 13)
      $error("TXN_W must retain the 13-bit V-tile tag prefix");
    if (OUTPUT_TILES > 8)
      $error("16-bit V tag reserves three bits for output_tile");
  end
endmodule
