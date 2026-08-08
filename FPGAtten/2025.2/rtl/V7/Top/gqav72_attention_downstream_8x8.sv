module gqav72_attention_downstream_8x8 #(
  parameter int unsigned OUTPUT_TILES   = 8,
  parameter int unsigned STATE_SLOTS    = 4,
  parameter int unsigned TXN_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned OUTPUT_TILE_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    score_row_valid_i,
  output logic                    score_row_ready_o,
  input  logic [31:0]             score_row_fp32_i [8],
  input  logic [3:0]              score_row_index_i,
  input  logic                    score_context_half_i,
  input  logic [STATE_SLOT_W-1:0] score_state_slot_i,
  input  logic [31:0]             score_query_base_i,
  input  logic [31:0]             score_context_base_i,
  input  logic [4:0]              score_query_valid_rows_i,
  input  logic [4:0]              score_context_valid_cols_i,
  input  logic                    score_causal_i,
  input  logic                    score_first_context_i,
  input  logic                    score_last_context_i,
  input  logic [31:0]             score_scale_fp32_i,
  input  logic [TXN_W-1:0]        score_txn_id_i,
  input  logic                    pv_skip_enable_i,
  input  logic [31:0]             pv_skip_lambda_fp32_i,

  input  logic                    v_step_valid_i,
  output logic                    v_step_ready_o,
  input  logic [15:0]
      v_partition_bf16_i [ROW_PARTITIONS][16],

  output logic                    result_valid_o,
  input  logic                    result_ready_i,
  output logic [31:0]             result_fp32_o [16],
  output logic [OUTPUT_TILE_W-1:0] result_output_tile_o,
  output logic [3:0]              result_row_index_o,
  output logic [TXN_W-1:0]        result_txn_id_o,
  output logic                    result_row_valid_o,

  output logic                    busy_o,
  output logic                    done_o,
  output logic                    softmax_active_o,
  output logic                    pv_active_o,
  output logic                    update_active_o,
  output logic [63:0]             active_cycles_o,
  output logic [63:0]             softmax_accepted_exp_o,
  output logic [63:0]             pv_accepted_macs_o,
  output logic [63:0]             update_accepted_elements_o,
  output logic [63:0]             partial_capture_count_o,
  output logic [63:0]             partial_row_transfer_count_o,
  output logic [63:0]             pv_blocks_total_o,
  output logic [63:0]             pv_blocks_skipped_o,
  output logic                    pv_skip_decision_valid_o,
  output logic                    pv_skip_decision_o,
  output logic                    error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned LOGICAL_OUTPUT_TILES = OUTPUT_TILES * 2;
  localparam int unsigned LOGICAL_OUTPUT_TILE_W =
      (LOGICAL_OUTPUT_TILES <= 1) ? 1 : $clog2(LOGICAL_OUTPUT_TILES);
  localparam int unsigned TOTAL_LOGICAL_ROWS = LOGICAL_OUTPUT_TILES * 16;
  localparam int unsigned LOGICAL_ROW_COUNT_W =
      $clog2(TOTAL_LOGICAL_ROWS + 1);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_SCORE_LOAD,
    ST_PV_UPDATE,
    ST_DRAIN_UPDATE,
    ST_NORMALIZE
  } state_t;
  state_t state_q;

  logic active_set_q;
  logic next_set_occupied_q;
  logic bank_ready_q [2];
  logic [STATE_SLOT_W-1:0] state_slot_q [2];
  logic [31:0] query_base_q [2];
  logic [31:0] context_base_q [2];
  logic [4:0] query_valid_rows_q [2];
  logic [4:0] context_valid_cols_q [2];
  logic causal_q [2];
  logic first_context_q [2];
  logic last_context_q [2];
  logic [31:0] scale_q [2];
  logic [TXN_W-1:0] txn_q [2];

  logic score_stream_active_q;
  logic score_stream_set_q;
  logic expected_score_half_q;
  logic [3:0] expected_score_row_q;
  logic score_start_allowed;
  logic score_target_set;
  logic score_row_fire;
  logic score_metadata_error_q;

  logic sidecar_in_ready;
  logic sidecar_out_valid;
  logic sidecar_out_ready;
  logic [31:0] sidecar_score [8];
  logic [7:0] sidecar_mask;
  logic [31:0] sidecar_block_max;
  logic [3:0] sidecar_row;
  logic sidecar_set;
  logic sidecar_half;
  logic [TXN_W-1:0] sidecar_txn;
  logic [4:0] score_half_valid_cols;
  logic [31:0] score_half_context_base;
  logic score_half_first;
  logic score_half_last;

  logic softmax_in_ready;
  logic softmax_out_valid;
  logic softmax_out_ready;
  logic [15:0] softmax_probability [8];
  logic [31:0] softmax_alpha;
  logic [31:0] softmax_running_sum;
  logic [STATE_SLOT_W-1:0] softmax_state_slot;
  logic [3:0] softmax_row;
  logic softmax_set;
  logic softmax_half;
  logic softmax_first;
  logic softmax_last;
  logic [TXN_W-1:0] softmax_txn;
  logic softmax_rom_ok;
  logic softmax_error;

  logic pair_out_valid;
  logic pair_in_ready;
  logic p_pair_ready;
  logic pair_out_set;
  logic [15:0] pair_low_probability [8];
  logic [15:0] pair_high_probability [8];
  logic [31:0] pair_combined_alpha;
  logic [31:0] pair_running_sum;
  logic [STATE_SLOT_W-1:0] pair_state_slot;
  logic [3:0] pair_row;
  logic pair_first;
  logic pair_last;
  logic [TXN_W-1:0] pair_txn;
  logic pair_error;
  logic pair_fire;
  logic pair_fifo_in_ready;
  logic pair_fifo_error;
  logic [63:0] pair_fifo_stall_cycles;
  logic pair_raw_valid;
  logic pair_raw_set;
  logic [15:0] pair_raw_low_probability [8];
  logic [15:0] pair_raw_high_probability [8];
  logic [31:0] pair_raw_combined_alpha;
  logic [31:0] pair_raw_running_sum;
  logic [STATE_SLOT_W-1:0] pair_raw_state_slot;
  logic [3:0] pair_raw_row;
  logic pair_raw_first;
  logic pair_raw_last;
  logic [TXN_W-1:0] pair_raw_txn;

  (* ram_style = "distributed" *) logic [31:0]
      combined_alpha_by_row_q [2][16];
  (* ram_style = "distributed" *) logic [31:0]
      running_sum_by_row_q [2][16];

  logic p_loaded [2][2];
  logic pv_output_start;
  logic pv_output_start_ready;
  logic pv_v_step_ready;
  logic pv_output_done;
  logic pv_partial_valid;
  logic pv_partial_ready;
  logic [31:0] pv_partial_row [8];
  logic [3:0] pv_partial_row_index;
  logic [LOGICAL_OUTPUT_TILE_W-1:0] pv_partial_output_tile;
  logic pv_partial_set;
  logic pv_partial_context_half;
  logic pv_error;
  logic pv_wave_start_fire;
  logic pv_v_step_fire;
  logic [4:0] pv_v_step_index_q;
  logic [OUTPUT_TILE_W:0] pv_waves_started_q;
  logic [OUTPUT_TILE_W:0] pv_waves_completed_q;
  logic [15:0] query_row_mask;

  logic update_in_ready;
  logic update_out_valid;
  logic update_out_ready;
  logic [31:0] update_out [8];
  logic [31:0] update_running_sum;
  logic [STATE_SLOT_W-1:0] update_state_slot;
  logic [3:0] update_row;
  logic [LOGICAL_OUTPUT_TILE_W-1:0] update_output_tile;
  logic update_first;
  logic update_last;
  logic [TXN_W-1:0] update_txn;
  logic update_error;
  logic update_out_fire;
  logic [LOGICAL_ROW_COUNT_W-1:0] update_rows_completed_q;

  logic final_write_valid;
  logic final_write_ready;
  logic final_read_valid;
  logic final_read_ready;
  logic final_row_valid;
  logic final_row_ready;
  logic [LOGICAL_OUTPUT_TILE_W-1:0] final_output_tile;
  logic [3:0] final_row_index;
  logic [31:0] final_row [8];
  logic [LOGICAL_ROW_COUNT_W-1:0] normalize_rows_issued_q;
  logic [LOGICAL_ROW_COUNT_W-1:0] normalize_rows_completed_q;

  logic normalize_in_ready;
  logic normalize_out_valid;
  logic normalize_out_ready;
  logic [31:0] normalize_out [8];
  logic [STATE_SLOT_W-1:0] normalize_state_slot;
  logic [3:0] normalize_row;
  logic [LOGICAL_OUTPUT_TILE_W-1:0] normalize_output_tile;
  logic [TXN_W-1:0] normalize_txn;
  logic normalize_rom_ok;
  logic normalize_error;
  logic normalize_fire;
  (* ram_style = "distributed", rw_addr_collision = "no" *)
  logic [255:0] normalized_low_half_q [16];

  logic diagnostic_error;
  (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *) logic diagnostic_error_q;
  // Compatibility probes retained for the existing full-system timeline TB.
  logic active_bank_q;
  logic metadata_error_q;
  logic pv_p_loaded;
  logic pv_partial_row_valid;
  logic pv_partial_row_ready;
  logic normalize_result_fire;

  assign active_bank_q = active_set_q;
  assign metadata_error_q = score_metadata_error_q;
  assign pv_p_loaded = p_loaded[active_set_q][0] &&
                       p_loaded[active_set_q][1];
  assign pv_partial_row_valid = pv_partial_valid;
  assign pv_partial_row_ready = pv_partial_ready;
  assign normalize_result_fire = result_valid_o && result_ready_i;

  always_comb begin
    query_row_mask = '0;
    for (int row = 0; row < 16; row++)
      query_row_mask[row] = 5'(row) < query_valid_rows_q[active_set_q];

    if (score_context_half_i) begin
      score_half_valid_cols = (score_context_valid_cols_i > 5'd8)
          ? score_context_valid_cols_i - 5'd8 : 5'd0;
      score_half_context_base = score_context_base_i + 32'd8;
    end else begin
      score_half_valid_cols = (score_context_valid_cols_i > 5'd8)
          ? 5'd8 : score_context_valid_cols_i;
      score_half_context_base = score_context_base_i;
    end
    score_half_first = score_first_context_i && !score_context_half_i;
    score_half_last = score_last_context_i && score_context_half_i;
  end

  assign busy_o = state_q != ST_IDLE;
  assign score_start_allowed = !score_stream_active_q &&
      ((state_q == ST_IDLE) ||
       (((state_q == ST_PV_UPDATE) ||
         (state_q == ST_DRAIN_UPDATE) ||
         (state_q == ST_NORMALIZE)) && !next_set_occupied_q));
  assign score_target_set = score_stream_active_q ? score_stream_set_q
      : ((state_q == ST_IDLE) ? active_set_q : ~active_set_q);
  assign score_row_ready_o = sidecar_in_ready &&
      (score_stream_active_q || score_start_allowed);
  assign score_row_fire = score_row_valid_i && score_row_ready_o;
  assign sidecar_out_ready = softmax_in_ready;

  gqav72_score_sidecar_8lane #(.TXN_W(TXN_W)) i_sidecar (
    .clk_i,
    .rst_ni,
    .in_valid_i(score_row_valid_i &&
                (score_stream_active_q || score_start_allowed)),
    .in_ready_o(sidecar_in_ready),
    .score_fp32_i(score_row_fp32_i),
    .scale_fp32_i(score_scale_fp32_i),
    .query_index_i(score_query_base_i + 32'(score_row_index_i)),
    .context_base_i(score_half_context_base),
    .context_valid_cols_i(score_half_valid_cols),
    .causal_i(score_causal_i),
    .row_index_i(score_row_index_i),
    .context_set_i(score_target_set),
    .context_half_i(score_context_half_i),
    .txn_id_i(score_txn_id_i),
    .out_valid_o(sidecar_out_valid),
    .out_ready_i(sidecar_out_ready),
    .scaled_masked_score_o(sidecar_score),
    .score_valid_mask_o(sidecar_mask),
    .block_max_o(sidecar_block_max),
    .row_index_o(sidecar_row),
    .context_set_o(sidecar_set),
    .context_half_o(sidecar_half),
    .txn_id_o(sidecar_txn)
  );

  gqav72_online_softmax_8lane #(
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W(TXN_W)
  ) i_softmax (
    .clk_i,
    .rst_ni,
    .in_valid_i(sidecar_out_valid),
    .in_ready_o(softmax_in_ready),
    .score_fp32_i(sidecar_score),
    .score_valid_mask_i((5'(sidecar_row) <
        query_valid_rows_q[sidecar_set]) ? sidecar_mask : 8'h00),
    .block_max_fp32_i(sidecar_block_max),
    .state_slot_i(state_slot_q[sidecar_set]),
    .row_index_i(sidecar_row),
    .context_set_i(sidecar_set),
    .context_half_i(sidecar_half),
    .first_context_i(first_context_q[sidecar_set] && !sidecar_half),
    .last_context_i(last_context_q[sidecar_set] && sidecar_half),
    .txn_id_i(txn_q[sidecar_set]),
    .out_valid_o(softmax_out_valid),
    .out_ready_i(softmax_out_ready),
    .probability_bf16_o(softmax_probability),
    .probability_valid_mask_o(),
    .alpha_fp32_o(softmax_alpha),
    .block_sum_fp32_o(),
    .running_max_fp32_o(),
    .running_sum_fp32_o(softmax_running_sum),
    .state_slot_o(softmax_state_slot),
    .row_index_o(softmax_row),
    .context_set_o(softmax_set),
    .context_half_o(softmax_half),
    .first_context_o(softmax_first),
    .last_context_o(softmax_last),
    .txn_id_o(softmax_txn),
    .accepted_exp_cycle_o(),
    .accepted_exp_total_o(softmax_accepted_exp_o),
    .score_read_beats_o(),
    .probability_beats_o(),
    .state_commit_count_o(),
    .rom_sentinel_ok_o(softmax_rom_ok),
    .protocol_error_o(softmax_error)
  );

  assign softmax_out_ready = pair_in_ready;
  gqav72_probability_pair_rescale_8lane #(
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W(TXN_W)
  ) i_pair_rescale (
    .clk_i,
    .rst_ni,
    .in_valid_i(softmax_out_valid),
    .in_ready_o(pair_in_ready),
    .in_set_i(softmax_set),
    .in_context_half_i(softmax_half),
    .probability_bf16_i(softmax_probability),
    .alpha_fp32_i(softmax_alpha),
    .running_sum_fp32_i(softmax_running_sum),
    .state_slot_i(softmax_state_slot),
    .row_index_i(softmax_row),
    .first_context_i(softmax_first),
    .last_context_i(softmax_last),
    .txn_id_i(softmax_txn),
    .out_valid_o(pair_raw_valid),
    .out_ready_i(pair_fifo_in_ready),
    .out_set_o(pair_raw_set),
    .low_probability_bf16_o(pair_raw_low_probability),
    .high_probability_bf16_o(pair_raw_high_probability),
    .combined_alpha_fp32_o(pair_raw_combined_alpha),
    .running_sum_fp32_o(pair_raw_running_sum),
    .state_slot_o(pair_raw_state_slot),
    .row_index_o(pair_raw_row),
    .first_context_o(pair_raw_first),
    .last_context_o(pair_raw_last),
    .txn_id_o(pair_raw_txn),
    .protocol_error_o(pair_error)
  );

  gqav73_probability_pair_fifo #(
    .STATE_SLOTS(STATE_SLOTS), .TXN_W(TXN_W), .DEPTH(4)
  ) i_pair_fifo (
    .clk_i, .rst_ni,
    .in_valid_i(pair_raw_valid), .in_ready_o(pair_fifo_in_ready),
    .in_set_i(pair_raw_set),
    .in_low_probability_bf16_i(pair_raw_low_probability),
    .in_high_probability_bf16_i(pair_raw_high_probability),
    .in_combined_alpha_fp32_i(pair_raw_combined_alpha),
    .in_running_sum_fp32_i(pair_raw_running_sum),
    .in_state_slot_i(pair_raw_state_slot), .in_row_index_i(pair_raw_row),
    .in_first_context_i(pair_raw_first),
    .in_last_context_i(pair_raw_last), .in_txn_id_i(pair_raw_txn),
    .out_valid_o(pair_out_valid), .out_ready_i(p_pair_ready),
    .out_set_o(pair_out_set),
    .out_low_probability_bf16_o(pair_low_probability),
    .out_high_probability_bf16_o(pair_high_probability),
    .out_combined_alpha_fp32_o(pair_combined_alpha),
    .out_running_sum_fp32_o(pair_running_sum),
    .out_state_slot_o(pair_state_slot), .out_row_index_o(pair_row),
    .out_first_context_o(pair_first), .out_last_context_o(pair_last),
    .out_txn_id_o(pair_txn), .stall_cycles_o(pair_fifo_stall_cycles),
    .protocol_error_o(pair_fifo_error)
  );

  assign pair_fire = pair_out_valid && p_pair_ready;

  gqav72_pv_partitioned_adapter_8x8_decoupled #(
    .OUTPUT_TILES(OUTPUT_TILES),
    .ROW_PARTITIONS(ROW_PARTITIONS),
    .CAPTURE_CONTEXTS(4)
  ) i_pv (
    .clk_i,
    .rst_ni,
    .p_pair_valid_i(pair_out_valid),
    .p_pair_ready_o(p_pair_ready),
    .p_set_i(pair_out_set),
    .p_row_index_i(pair_row),
    .p_low_bf16_i(pair_low_probability),
    .p_high_bf16_i(pair_high_probability),
    .p_loaded_o(p_loaded),
    .p_discard_valid_i(1'b0),
    .p_discard_set_i(1'b0),
    .output_start_i(pv_output_start),
    .output_start_ready_o(pv_output_start_ready),
    .output_set_i(active_set_q),
    .output_context_half_i(1'b1),
    .output_tile_i(pv_waves_started_q[OUTPUT_TILE_W-1:0]),
    .v_step_valid_i((state_q == ST_PV_UPDATE) && v_step_valid_i),
    .v_step_ready_o(pv_v_step_ready),
    .v_partition_bf16_i(v_partition_bf16_i),
    .row_valid_i(query_row_mask),
    .col_valid_i(16'hffff),
    .active_o(pv_active_o),
    .output_done_o(pv_output_done),
    .partial_row_valid_o(pv_partial_valid),
    .partial_row_ready_i(pv_partial_ready),
    .partial_row_fp32_o(pv_partial_row),
    .partial_row_index_o(pv_partial_row_index),
    .partial_row_output_tile_o(pv_partial_output_tile),
    .partial_row_context_half_o(pv_partial_context_half),
    .partial_row_set_o(pv_partial_set),
    .partial_row_bank_o(),
    .partial_drained_o(),
    .accepted_macs_cycle_o(),
    .accepted_macs_total_o(pv_accepted_macs_o),
    .p_load_count_o(),
    .v_output_wave_count_o(),
    .protocol_error_o(pv_error)
  );

  assign pv_output_start = (state_q == ST_PV_UPDATE) &&
      (pv_v_step_index_q == 0) &&
      (pv_waves_started_q < (OUTPUT_TILE_W + 1)'(OUTPUT_TILES));
  assign v_step_ready_o = (state_q == ST_PV_UPDATE) && pv_v_step_ready &&
      ((pv_v_step_index_q != 0) ||
       (pv_output_start_ready &&
        (pv_waves_started_q < (OUTPUT_TILE_W + 1)'(OUTPUT_TILES))));
  assign pv_wave_start_fire = pv_output_start && pv_output_start_ready &&
      v_step_valid_i && pv_v_step_ready;
  assign pv_v_step_fire = v_step_valid_i && v_step_ready_o;

  assign pv_partial_ready = update_in_ready;
  gqav72_output_update_8lane #(
    .STATE_SLOTS(STATE_SLOTS),
    .OUTPUT_TILES(LOGICAL_OUTPUT_TILES),
    .TXN_W(TXN_W)
  ) i_output_update (
    .clk_i,
    .rst_ni,
    .clear_i(1'b0),
    .in_valid_i(pv_partial_valid),
    .in_ready_o(update_in_ready),
    .partial_fp32_i(pv_partial_row),
    .alpha_fp32_i(combined_alpha_by_row_q[active_set_q]
                                              [pv_partial_row_index]),
    .running_sum_fp32_i(running_sum_by_row_q[active_set_q]
                                             [pv_partial_row_index]),
    .state_slot_i(state_slot_q[active_set_q]),
    .row_index_i(pv_partial_row_index),
    .output_tile_i(pv_partial_output_tile),
    .first_context_i(first_context_q[active_set_q]),
    .last_context_i(last_context_q[active_set_q]),
    .txn_id_i(txn_q[active_set_q]),
    .out_valid_o(update_out_valid),
    .out_ready_i(update_out_ready),
    .updated_fp32_o(update_out),
    .running_sum_fp32_o(update_running_sum),
    .state_slot_o(update_state_slot),
    .row_index_o(update_row),
    .output_tile_o(update_output_tile),
    .first_context_o(update_first),
    .last_context_o(update_last),
    .txn_id_o(update_txn),
    .accepted_updates_cycle_o(),
    .accepted_updates_total_o(update_accepted_elements_o),
    .state_write_count_o(),
    .forwarding_count_o(),
    .hazard_stall_cycles_o(),
    .protocol_error_o(update_error)
  );

  assign update_out_ready = update_last ? final_write_ready : 1'b1;
  assign update_out_fire = update_out_valid && update_out_ready;
  assign final_write_valid = update_out_valid && update_last;

  gqav72_output_row_buffer_8lane #(
    .OUTPUT_TILES(LOGICAL_OUTPUT_TILES)
  ) i_final_buffer (
    .clk_i,
    .rst_ni,
    .write_valid_i(final_write_valid),
    .write_ready_o(final_write_ready),
    .write_output_tile_i(update_output_tile),
    .write_row_index_i(update_row),
    .write_data_fp32_i(update_out),
    .read_valid_i(final_read_valid),
    .read_ready_o(final_read_ready),
    .read_output_tile_i(normalize_rows_issued_q[4 +: LOGICAL_OUTPUT_TILE_W]),
    .read_row_index_i(normalize_rows_issued_q[3:0]),
    .out_valid_o(final_row_valid),
    .out_ready_i(final_row_ready),
    .out_output_tile_o(final_output_tile),
    .out_row_index_o(final_row_index),
    .out_data_fp32_o(final_row),
    .write_count_o(),
    .read_count_o()
  );

  assign final_read_valid = (state_q == ST_NORMALIZE) &&
      (normalize_rows_issued_q <
       LOGICAL_ROW_COUNT_W'(TOTAL_LOGICAL_ROWS));
  assign final_row_ready = normalize_in_ready;

  gqav72_output_normalize_8lane #(
    .STATE_SLOT_W(STATE_SLOT_W),
    .OUTPUT_TILE_W(LOGICAL_OUTPUT_TILE_W),
    .TXN_W(TXN_W)
  ) i_normalize (
    .clk_i,
    .rst_ni,
    .in_valid_i(final_row_valid),
    .in_ready_o(normalize_in_ready),
    .row_valid_i(5'(final_row_index) <
                 query_valid_rows_q[active_set_q]),
    .updated_fp32_i(final_row),
    .running_sum_fp32_i(running_sum_by_row_q[active_set_q]
                                             [final_row_index]),
    .state_slot_i(state_slot_q[active_set_q]),
    .row_index_i(final_row_index),
    .output_tile_i(final_output_tile),
    .txn_id_i(txn_q[active_set_q]),
    .out_valid_o(normalize_out_valid),
    .out_ready_i(normalize_out_ready),
    .normalized_fp32_o(normalize_out),
    .reciprocal_fp32_o(),
    .state_slot_o(normalize_state_slot),
    .row_index_o(normalize_row),
    .output_tile_o(normalize_output_tile),
    .txn_id_o(normalize_txn),
    .normalized_rows_o(),
    .reciprocal_busy_cycles_o(),
    .rom_sentinel_ok_o(normalize_rom_ok),
    .protocol_error_o(normalize_error)
  );

  assign normalize_out_ready = !normalize_output_tile[0] || result_ready_i;
  assign normalize_fire = normalize_out_valid && normalize_out_ready;
  assign result_valid_o = normalize_out_valid && normalize_output_tile[0];
  assign result_output_tile_o =
      normalize_output_tile[LOGICAL_OUTPUT_TILE_W-1:1];
  assign result_row_index_o = normalize_row;
  assign result_txn_id_o = normalize_txn;
  assign result_row_valid_o = 5'(normalize_row) <
                              query_valid_rows_q[active_set_q];
  for (genvar lane = 0; lane < 8; lane++) begin : gen_result_lane
    assign result_fp32_o[lane] =
        normalized_low_half_q[normalize_row][lane*32 +: 32];
    assign result_fp32_o[lane+8] = normalize_out[lane];
  end

  assign softmax_active_o = sidecar_out_valid || softmax_out_valid ||
                            pair_out_valid || score_stream_active_q;
  assign update_active_o = pv_partial_valid || update_out_valid;
  assign pv_skip_decision_valid_o = pv_skip_enable_i &&
                                    (state_q == ST_PV_UPDATE);
  assign pv_skip_decision_o = 1'b0;

  assign diagnostic_error = score_metadata_error_q || softmax_error ||
      pair_error || pair_fifo_error || pv_error || update_error ||
      normalize_error ||
      !softmax_rom_ok || !normalize_rom_ok ||
      (sidecar_out_valid && (sidecar_txn != txn_q[sidecar_set])) ||
      (softmax_out_valid && (softmax_txn != txn_q[softmax_set])) ||
      (pair_out_valid &&
       ((pair_state_slot != state_slot_q[pair_out_set]) ||
        (pair_txn != txn_q[pair_out_set]))) ||
      (pv_partial_valid &&
       ((pv_partial_set != active_set_q) || !pv_partial_context_half)) ||
      (update_out_valid &&
       ((update_state_slot != state_slot_q[active_set_q]) ||
        (update_running_sum != running_sum_by_row_q[active_set_q][update_row]) ||
        (update_txn != txn_q[active_set_q]))) ||
      (normalize_out_valid &&
       (normalize_state_slot != state_slot_q[active_set_q]));
  assign error_o = diagnostic_error_q;

  always_ff @(posedge clk_i) begin
    if (pair_fire) begin
      combined_alpha_by_row_q[pair_out_set][pair_row] <= pair_combined_alpha;
      running_sum_by_row_q[pair_out_set][pair_row] <= pair_running_sum;
    end
    if (normalize_fire && !normalize_output_tile[0]) begin
      for (int lane = 0; lane < 8; lane++)
        normalized_low_half_q[normalize_row][lane*32 +: 32]
            <= normalize_out[lane];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_IDLE;
      active_set_q <= 1'b0;
      next_set_occupied_q <= 1'b0;
      bank_ready_q[0] <= 1'b0;
      bank_ready_q[1] <= 1'b0;
      score_stream_active_q <= 1'b0;
      score_stream_set_q <= 1'b0;
      expected_score_half_q <= 1'b0;
      expected_score_row_q <= '0;
      score_metadata_error_q <= 1'b0;
      for (int set = 0; set < 2; set++) begin
        state_slot_q[set] <= '0;
        query_base_q[set] <= '0;
        context_base_q[set] <= '0;
        query_valid_rows_q[set] <= '0;
        context_valid_cols_q[set] <= '0;
        causal_q[set] <= 1'b0;
        first_context_q[set] <= 1'b0;
        last_context_q[set] <= 1'b0;
        scale_q[set] <= '0;
        txn_q[set] <= '0;
      end
      pv_v_step_index_q <= '0;
      pv_waves_started_q <= '0;
      pv_waves_completed_q <= '0;
      update_rows_completed_q <= '0;
      normalize_rows_issued_q <= '0;
      normalize_rows_completed_q <= '0;
      active_cycles_o <= '0;
      partial_capture_count_o <= '0;
      partial_row_transfer_count_o <= '0;
      pv_blocks_total_o <= '0;
      pv_blocks_skipped_o <= '0;
      done_o <= 1'b0;
      diagnostic_error_q <= 1'b0;
    end else begin
      done_o <= 1'b0;
      diagnostic_error_q <= diagnostic_error_q || diagnostic_error;
      if (busy_o)
        active_cycles_o <= active_cycles_o + 64'd1;

      if (score_row_fire) begin
        if (!score_stream_active_q) begin
          score_stream_active_q <= 1'b1;
          score_stream_set_q <= score_target_set;
          expected_score_half_q <= 1'b0;
          expected_score_row_q <= '0;
          bank_ready_q[score_target_set] <= 1'b0;
          state_slot_q[score_target_set] <= score_state_slot_i;
          query_base_q[score_target_set] <= score_query_base_i;
          context_base_q[score_target_set] <= score_context_base_i;
          query_valid_rows_q[score_target_set] <= score_query_valid_rows_i;
          context_valid_cols_q[score_target_set] <= score_context_valid_cols_i;
          causal_q[score_target_set] <= score_causal_i;
          first_context_q[score_target_set] <= score_first_context_i;
          last_context_q[score_target_set] <= score_last_context_i;
          scale_q[score_target_set] <= score_scale_fp32_i;
          txn_q[score_target_set] <= score_txn_id_i;
          if (state_q == ST_IDLE) begin
            state_q <= ST_SCORE_LOAD;
          end else begin
            next_set_occupied_q <= 1'b1;
          end
          if (score_context_half_i || (score_row_index_i != 0))
            score_metadata_error_q <= 1'b1;
        end else begin
          if ((score_context_half_i != expected_score_half_q) ||
              (score_row_index_i != expected_score_row_q) ||
              (score_state_slot_i != state_slot_q[score_stream_set_q]) ||
              (score_query_base_i != query_base_q[score_stream_set_q]) ||
              (score_context_base_i != context_base_q[score_stream_set_q]) ||
              (score_query_valid_rows_i !=
               query_valid_rows_q[score_stream_set_q]) ||
              (score_context_valid_cols_i !=
               context_valid_cols_q[score_stream_set_q]) ||
              (score_causal_i != causal_q[score_stream_set_q]) ||
              (score_first_context_i != first_context_q[score_stream_set_q]) ||
              (score_last_context_i != last_context_q[score_stream_set_q]) ||
              (score_scale_fp32_i != scale_q[score_stream_set_q]) ||
              (score_txn_id_i != txn_q[score_stream_set_q]))
            score_metadata_error_q <= 1'b1;
        end

        if (score_context_half_i && (score_row_index_i == 4'd15)) begin
          score_stream_active_q <= 1'b0;
          expected_score_half_q <= 1'b0;
          expected_score_row_q <= '0;
        end else if (score_row_index_i == 4'd15) begin
          expected_score_half_q <= 1'b1;
          expected_score_row_q <= '0;
        end else begin
          expected_score_row_q <= score_row_index_i + 4'd1;
        end
      end

      if (pair_fire && (pair_row == 4'd15))
        bank_ready_q[pair_out_set] <= 1'b1;

      if ((state_q == ST_SCORE_LOAD) && bank_ready_q[active_set_q] &&
          p_loaded[active_set_q][0] && p_loaded[active_set_q][1]) begin
        pv_v_step_index_q <= '0;
        pv_waves_started_q <= '0;
        pv_waves_completed_q <= '0;
        update_rows_completed_q <= '0;
        pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
        state_q <= ST_PV_UPDATE;
      end

      if (pv_wave_start_fire)
        pv_waves_started_q <= pv_waves_started_q + 1'b1;
      if (pv_v_step_fire) begin
        if (pv_v_step_index_q == 5'd15)
          pv_v_step_index_q <= '0;
        else
          pv_v_step_index_q <= pv_v_step_index_q + 5'd1;
      end
      if (pv_output_done) begin
        partial_capture_count_o <= partial_capture_count_o + 64'd1;
        pv_waves_completed_q <= pv_waves_completed_q + 1'b1;
        if (pv_waves_completed_q ==
            (OUTPUT_TILE_W + 1)'(OUTPUT_TILES - 1))
          state_q <= ST_DRAIN_UPDATE;
      end
      if (pv_partial_valid && pv_partial_ready)
        partial_row_transfer_count_o <=
            partial_row_transfer_count_o + 64'd1;

      if (update_out_fire) begin
        if (update_rows_completed_q ==
            LOGICAL_ROW_COUNT_W'(TOTAL_LOGICAL_ROWS - 1)) begin
          update_rows_completed_q <= LOGICAL_ROW_COUNT_W'(TOTAL_LOGICAL_ROWS);
          if (last_context_q[active_set_q]) begin
            normalize_rows_issued_q <= '0;
            normalize_rows_completed_q <= '0;
            state_q <= ST_NORMALIZE;
          end else begin
            done_o <= 1'b1;
            bank_ready_q[active_set_q] <= 1'b0;
            if (next_set_occupied_q) begin
              active_set_q <= ~active_set_q;
              next_set_occupied_q <= 1'b0;
              pv_v_step_index_q <= '0;
              pv_waves_started_q <= '0;
              pv_waves_completed_q <= '0;
              update_rows_completed_q <= '0;
              if (bank_ready_q[~active_set_q] &&
                  p_loaded[~active_set_q][0] &&
                  p_loaded[~active_set_q][1]) begin
                pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
                state_q <= ST_PV_UPDATE;
              end else begin
                state_q <= ST_SCORE_LOAD;
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end
        end else begin
          update_rows_completed_q <= update_rows_completed_q + 1'b1;
        end
      end

      if (final_read_valid && final_read_ready)
        normalize_rows_issued_q <= normalize_rows_issued_q + 1'b1;
      if (normalize_fire) begin
        if (normalize_rows_completed_q ==
            LOGICAL_ROW_COUNT_W'(TOTAL_LOGICAL_ROWS - 1)) begin
          normalize_rows_completed_q <=
              LOGICAL_ROW_COUNT_W'(TOTAL_LOGICAL_ROWS);
          done_o <= 1'b1;
          bank_ready_q[active_set_q] <= 1'b0;
          if (next_set_occupied_q) begin
            active_set_q <= ~active_set_q;
            next_set_occupied_q <= 1'b0;
            pv_v_step_index_q <= '0;
            pv_waves_started_q <= '0;
            pv_waves_completed_q <= '0;
            update_rows_completed_q <= '0;
            normalize_rows_issued_q <= '0;
            normalize_rows_completed_q <= '0;
            if (bank_ready_q[~active_set_q] &&
                p_loaded[~active_set_q][0] &&
                p_loaded[~active_set_q][1]) begin
              pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
              state_q <= ST_PV_UPDATE;
            end else begin
              state_q <= ST_SCORE_LOAD;
            end
          end else begin
            state_q <= ST_IDLE;
          end
        end else begin
          normalize_rows_completed_q <= normalize_rows_completed_q + 1'b1;
        end
      end
    end
  end

  logic unused_status;
  assign unused_status = ^{pv_skip_lambda_fp32_i, pair_first, pair_last,
      scale_q[0], context_base_q[0], causal_q[0], pv_blocks_skipped_o};

  initial begin
    if (OUTPUT_TILES != 8)
      $error("V7.2 downstream currently requires OUTPUT_TILES=8");
    if (ROW_PARTITIONS != 4)
      $error("V7.2 downstream requires four row partitions");
  end
endmodule
