module gqav5_attention_downstream #(
  parameter int unsigned OUTPUT_TILES = 8,
  parameter int unsigned STATE_SLOTS  = 4,
  parameter int unsigned TXN_W        = 16,
  parameter bit          PARTITIONED_PV = 1'b0,
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
  input  logic [31:0]             score_row_fp32_i [16],
  input  logic [3:0]              score_row_index_i,
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
  input  logic [15:0]             v_bf16_i [16],
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
  timeunit 1ns;
  timeprecision 1ps;

  localparam int unsigned TOTAL_OUTPUT_ROWS = OUTPUT_TILES * 16;
  localparam int unsigned OUTPUT_ROW_COUNT_W =
      $clog2(TOTAL_OUTPUT_ROWS + 1);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_SCORE_PLOAD,
    ST_PV_UPDATE,
    ST_DRAIN_UPDATE,
    ST_NORMALIZE
  } state_t;

  state_t state_q;
  logic active_bank_q;
  logic score_bank_q;
  logic next_bank_occupied_q;
  logic next_bank_ready_q;
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
  logic score_input_done_q;
  logic [3:0] expected_score_row_q;
  logic metadata_error_q;

  logic [4:0] pv_v_step_index_q;
  logic [OUTPUT_ROW_COUNT_W-1:0] update_rows_completed_q;
  logic [OUTPUT_ROW_COUNT_W-1:0] normalize_rows_issued_q;
  logic [OUTPUT_ROW_COUNT_W-1:0] normalize_rows_completed_q;
  logic [OUTPUT_TILE_W:0] pv_waves_started_q;
  logic [OUTPUT_TILE_W:0] pv_waves_completed_q;
  logic [15:0] query_row_mask;

  logic score_row_fire;
  logic sidecar_in_valid;
  logic sidecar_in_ready;
  logic sidecar_out_valid;
  logic sidecar_out_ready;
  logic [31:0] sidecar_score [16];
  logic [15:0] sidecar_score_mask;
  logic [31:0] sidecar_block_max;
  logic [3:0] sidecar_row_index;
  logic [TXN_W-1:0] sidecar_txn;

  logic softmax_in_ready;
  logic softmax_out_valid;
  logic softmax_out_ready;
  logic [15:0] softmax_probability [16];
  logic [31:0] softmax_alpha;
  logic [31:0] softmax_block_max;
  logic [31:0] softmax_running_max;
  logic [31:0] softmax_running_sum;
  logic [STATE_SLOT_W-1:0] softmax_state_slot;
  logic [3:0] softmax_row_index;
  logic softmax_first_context;
  logic softmax_last_context;
  logic [TXN_W-1:0] softmax_txn;
  logic softmax_rom_ok;
  logic softmax_error;
  logic diagnostic_error;
  // Preserve a registered diagnostic boundary at the downstream output.
  // Every leaf error is sticky (or is qualified by a full-cycle valid), so
  // this adds only one cycle of reporting latency.  Without the boundary,
  // Vivado folds the leaf sticky registers into the core sticky register and
  // builds a 12-level, cross-floorplan error-reduction path through QK,
  // softmax, PV, update, and normalize.
  (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *)
  logic diagnostic_error_q;
  // These single-read/single-write, sixteen-entry sidecars are too shallow
  // for dedicated BRAM but should use LUTRAM rather than 1,536 routed FFs.
  (* ram_style = "distributed" *) logic [31:0]
      block_max_by_row_q [2][16];
  (* ram_style = "distributed" *) logic [31:0]
      alpha_by_row_q [2][16];
  (* ram_style = "distributed" *) logic [31:0]
      running_sum_by_row_q [2][16];

  logic pv_p_start;
  logic pv_p_start_ready;
  logic pv_p_row_ready;
  logic pv_p_loaded;
  logic pv_p_next_loaded;
  logic pv_p_discard;
  logic pv_output_start;
  logic pv_output_start_ready;
  logic pv_v_step_ready;
  logic pv_output_done;
  logic pv_partial_row_valid;
  logic pv_partial_row_ready;
  logic [31:0] pv_partial_row [16];
  logic [15:0] pv_selected_v [ROW_PARTITIONS][16];
  logic [3:0] pv_partial_row_index;
  logic [OUTPUT_TILE_W-1:0] pv_partial_output_tile;
  logic pv_error;
  logic pv_wave_start_fire;
  logic pv_v_step_fire;
  logic skip_candidate_q [2];
  logic skip_current_q [2];
  logic [31:0] skip_delta;
  logic skip_delta_valid;
  logic [3:0] skip_row_pipe_q [5];
  logic skip_eval_requires_pv;
  logic skip_eval_complete_q [2];
  logic [OUTPUT_ROW_COUNT_W-1:0] skip_row_count_q;

  logic partial_row_valid;
  logic partial_row_ready;
  logic [31:0] partial_row [16];
  logic [31:0] partial_row_alpha;
  logic [31:0] partial_row_running_sum;
  logic [STATE_SLOT_W-1:0] partial_row_state_slot;
  logic [3:0] partial_row_index;
  logic [OUTPUT_TILE_W-1:0] partial_row_output_tile;
  logic partial_row_first_context;
  logic partial_row_last_context;
  logic [TXN_W-1:0] partial_row_txn;

  logic update_in_ready;
  logic update_out_valid;
  logic update_out_ready;
  logic [31:0] update_out [16];
  logic [31:0] update_running_sum;
  logic [STATE_SLOT_W-1:0] update_state_slot;
  logic [3:0] update_row_index;
  logic [OUTPUT_TILE_W-1:0] update_output_tile;
  logic update_first_context;
  logic update_last_context;
  logic [TXN_W-1:0] update_txn;
  logic update_error;
  logic update_out_fire;

  logic final_write_valid;
  logic final_write_ready;
  logic final_read_valid;
  logic final_read_ready;
  logic final_row_valid;
  logic final_row_ready;
  logic [OUTPUT_TILE_W-1:0] final_output_tile;
  logic [3:0] final_row_index;
  logic [31:0] final_row [16];

  logic normalize_in_ready;
  logic normalize_out_valid;
  logic normalize_out_ready;
  logic [31:0] normalize_out [16];
  logic [STATE_SLOT_W-1:0] normalize_state_slot;
  logic [3:0] normalize_row_index;
  logic [OUTPUT_TILE_W-1:0] normalize_output_tile;
  logic [TXN_W-1:0] normalize_txn;
  logic normalize_rom_ok;
  logic normalize_error;
  logic normalize_result_fire;
  logic score_accept_window;
  logic active_context_complete;

  function automatic logic fp32_is_nan(input logic [30:0] value);
    fp32_is_nan = (value[30:23] == 8'hff) && (value[22:0] != '0);
  endfunction

  function automatic logic fp32_less(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    begin
      if (fp32_is_nan(lhs[30:0]) || fp32_is_nan(rhs[30:0]))
        fp32_less = 1'b0;
      else if ((lhs[30:0] == '0) && (rhs[30:0] == '0))
        fp32_less = 1'b0;
      else if (lhs[31] != rhs[31])
        fp32_less = lhs[31];
      else if (!lhs[31])
        fp32_less = lhs[30:0] < rhs[30:0];
      else
        fp32_less = lhs[30:0] > rhs[30:0];
    end
  endfunction

  always_comb begin
    query_row_mask = '0;
    for (int row = 0; row < 16; row++)
      query_row_mask[row] =
          5'(row) < query_valid_rows_q[active_bank_q];
  end

  assign busy_o = state_q != ST_IDLE;
  assign score_accept_window =
      ((state_q == ST_IDLE) || (state_q == ST_SCORE_PLOAD)) ||
      (((state_q == ST_PV_UPDATE) ||
        (state_q == ST_DRAIN_UPDATE) ||
        (state_q == ST_NORMALIZE)) &&
       (!next_bank_occupied_q ||
        (score_bank_q == ~active_bank_q)));
  assign sidecar_in_valid = score_row_valid_i && !score_input_done_q &&
      score_accept_window;
  assign score_row_ready_o = sidecar_in_ready && !score_input_done_q &&
      score_accept_window;
  assign score_row_fire = score_row_valid_i && score_row_ready_o;
  assign sidecar_out_ready = softmax_in_ready;

`ifdef GQAV7_SCORE_SIDECAR_PRODUCTION
  gqav7_score_sidecar_16lane #(.TXN_W(TXN_W)) i_score_sidecar (
`else
  gqav5_score_sidecar_16lane #(.TXN_W(TXN_W)) i_score_sidecar (
`endif
    .clk_i,
    .rst_ni,
    .in_valid_i             (sidecar_in_valid),
    .in_ready_o             (sidecar_in_ready),
    .score_fp32_i           (score_row_fp32_i),
    .scale_fp32_i           (score_scale_fp32_i),
    .query_index_i          (score_query_base_i + 32'(score_row_index_i)),
    .context_base_i         (score_context_base_i),
    .context_valid_cols_i   (score_context_valid_cols_i),
    .causal_i               (score_causal_i),
    .row_index_i            (score_row_index_i),
    .txn_id_i               (score_txn_id_i),
    .out_valid_o            (sidecar_out_valid),
    .out_ready_i            (sidecar_out_ready),
    .scaled_masked_score_o  (sidecar_score),
    .score_valid_mask_o     (sidecar_score_mask),
    .block_max_o            (sidecar_block_max),
    .row_index_o            (sidecar_row_index),
    .txn_id_o               (sidecar_txn)
  );

  /* verilator lint_off PINCONNECTEMPTY */
  gqav5_online_softmax_16lane #(
    .STATE_SLOTS(STATE_SLOTS),
    .TXN_W      (TXN_W)
  ) i_softmax (
    .clk_i,
    .rst_ni,
    .in_valid_i              (sidecar_out_valid),
    .in_ready_o              (softmax_in_ready),
    .score_fp32_i            (sidecar_score),
    .score_valid_mask_i      ((5'(sidecar_row_index) <
                               query_valid_rows_q[score_bank_q])
                               ? sidecar_score_mask : 16'h0000),
    .block_max_fp32_i        (sidecar_block_max),
    .state_slot_i            (state_slot_q[score_bank_q]),
    .row_index_i             (sidecar_row_index),
    .first_context_i         (first_context_q[score_bank_q]),
    .last_context_i          (last_context_q[score_bank_q]),
    .txn_id_i                (txn_q[score_bank_q]),
    .out_valid_o             (softmax_out_valid),
    .out_ready_i             (softmax_out_ready),
    .probability_bf16_o      (softmax_probability),
    .probability_valid_mask_o(),
    .alpha_fp32_o            (softmax_alpha),
    .block_sum_fp32_o        (),
    .running_max_fp32_o      (softmax_running_max),
    .running_sum_fp32_o      (softmax_running_sum),
    .state_slot_o            (softmax_state_slot),
    .row_index_o             (softmax_row_index),
    .first_context_o         (softmax_first_context),
    .last_context_o          (softmax_last_context),
    .txn_id_o                (softmax_txn),
    .accepted_exp_cycle_o    (),
    .accepted_exp_total_o    (softmax_accepted_exp_o),
    .score_read_beats_o      (),
    .probability_beats_o     (),
    .state_commit_count_o    (),
    .rom_sentinel_ok_o       (softmax_rom_ok),
    .protocol_error_o        (softmax_error)
  );

  assign softmax_block_max =
      block_max_by_row_q[score_bank_q][softmax_row_index];
  gqav7_fp32_add_rne_pipe i_skip_delta (
    .clk_i,
    .rst_ni,
    .advance_i (1'b1),
    .valid_i   (softmax_out_valid && softmax_out_ready),
    .a_fp32_i  (softmax_block_max),
    .b_fp32_i  ({~softmax_running_max[31], softmax_running_max[30:0]}),
    .valid_o   (skip_delta_valid),
    .sum_fp32_o(skip_delta)
  );
  assign skip_eval_requires_pv =
      (5'(skip_row_pipe_q[4]) < query_valid_rows_q[score_bank_q]) &&
      (!fp32_less(skip_delta, pv_skip_lambda_fp32_i) ||
       fp32_is_nan(skip_delta[30:0]) ||
       fp32_is_nan(pv_skip_lambda_fp32_i[30:0]));

  assign pv_p_start = softmax_out_valid && (softmax_row_index == 4'd0) &&
                      pv_p_start_ready;
  assign softmax_out_ready = pv_p_row_ready;

  // PARTITIONED_PV is an elaboration-time choice. Legacy single-KV waves
  // replicate one V vector into the four local regions; 16Q/4KV waves retain
  // four independent V vectors. No run-time wide mux remains after synthesis.
  generate
    for (genvar part = 0; part < ROW_PARTITIONS; part++) begin : gen_pv_v_part
      for (genvar lane = 0; lane < 16; lane++) begin : gen_pv_v_lane
        assign pv_selected_v[part][lane] = PARTITIONED_PV
            ? v_partition_bf16_i[part][lane] : v_bf16_i[lane];
      end
    end
  endgenerate

`ifdef GQAV7_PV_PRODUCTION
  gqav7_pv_partitioned_adapter_16x16_decoupled #(
    .K_STEPS     (16),
    .OUTPUT_TILES(OUTPUT_TILES),
    .ROW_PARTITIONS(ROW_PARTITIONS),
    // One physical PV 8x8 array, four lightweight capture/result contexts.
    .CAPTURE_CONTEXTS(4)
  ) i_pv (
    .clk_i,
    .rst_ni,
    .p_start_i              (pv_p_start),
    .p_start_ready_o        (pv_p_start_ready),
    .p_row_valid_i          (softmax_out_valid),
    .p_row_ready_o          (pv_p_row_ready),
    .p_row_bf16_i           (softmax_probability),
    .p_loaded_o             (pv_p_loaded),
    .p_next_loaded_o        (pv_p_next_loaded),
    .p_discard_i            (pv_p_discard),
    .output_start_i         (pv_output_start),
    .output_start_ready_o   (pv_output_start_ready),
    .v_step_valid_i         ((state_q == ST_PV_UPDATE) && v_step_valid_i),
    .v_step_ready_o         (pv_v_step_ready),
    .v_partition_bf16_i     (pv_selected_v),
    .row_valid_i            (query_row_mask),
    .col_valid_i            (16'hffff),
    .active_o               (pv_active_o),
    .output_done_o          (pv_output_done),
    .output_tile_index_o    (),
    .partial_row_valid_o    (pv_partial_row_valid),
    .partial_row_ready_i    (pv_partial_row_ready),
    .partial_row_fp32_o     (pv_partial_row),
    .partial_row_index_o    (pv_partial_row_index),
    .partial_row_output_tile_o(pv_partial_output_tile),
    .partial_row_bank_o     (),
    .partial_drained_o      (),
    .accepted_macs_cycle_o  (),
    .accepted_macs_total_o  (pv_accepted_macs_o),
    .p_load_count_o         (),
    .v_output_wave_count_o  (),
    .protocol_error_o       (pv_error)
  );
`else
  gqav5_pv_partitioned_p_stationary_16x16 #(
    .K_STEPS     (16),
    .OUTPUT_TILES(OUTPUT_TILES),
    .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_pv (
    .clk_i,
    .rst_ni,
    .p_start_i              (pv_p_start),
    .p_start_ready_o        (pv_p_start_ready),
    .p_row_valid_i          (softmax_out_valid),
    .p_row_ready_o          (pv_p_row_ready),
    .p_row_bf16_i           (softmax_probability),
    .p_loaded_o             (pv_p_loaded),
    .p_discard_i            (pv_p_discard),
    .output_start_i         (pv_output_start),
    .output_start_ready_o   (pv_output_start_ready),
    .v_step_valid_i         ((state_q == ST_PV_UPDATE) && v_step_valid_i),
    .v_step_ready_o         (pv_v_step_ready),
    .v_partition_bf16_i     (pv_selected_v),
    .row_valid_i            (query_row_mask),
    .col_valid_i            (16'hffff),
    .active_o               (pv_active_o),
    .output_done_o          (pv_output_done),
    .output_tile_index_o    (),
    .partial_row_valid_o    (pv_partial_row_valid),
    .partial_row_ready_i    (pv_partial_row_ready),
    .partial_row_fp32_o     (pv_partial_row),
    .partial_row_index_o    (pv_partial_row_index),
    .partial_row_output_tile_o(pv_partial_output_tile),
    .partial_row_bank_o     (),
    .partial_drained_o      (),
    .accepted_macs_cycle_o  (),
    .accepted_macs_total_o  (pv_accepted_macs_o),
    .p_load_count_o         (),
    .v_output_wave_count_o  (),
    .protocol_error_o       (pv_error)
  );
`endif

  assign pv_p_discard = pv_p_loaded &&
      skip_current_q[active_bank_q] &&
      ((state_q == ST_SCORE_PLOAD) ||
       ((state_q == ST_PV_UPDATE) && (pv_waves_started_q == 0)));
  // The decision is held as a level throughout PV/update processing.  A
  // resident scheduler may therefore defer V traffic without adding a
  // timing-sensitive pulse synchronizer or a broad combinational feedback.
  assign pv_skip_decision_valid_o = pv_skip_enable_i &&
      ((state_q == ST_PV_UPDATE) || next_bank_ready_q);
  assign pv_skip_decision_o = next_bank_ready_q
      ? skip_current_q[~active_bank_q] : skip_current_q[active_bank_q];
`ifdef GQAV7_PV_PRODUCTION
  // Arm the next PV wave from registered downstream state, independently of
  // the V producer's valid.  The actual fire below still requires the first
  // V row, which breaks the V-valid -> PV-ready -> resident replay loop
  // without allowing an unstarted row into the decoupled adapter FIFO.
  assign pv_output_start = !skip_current_q[active_bank_q] &&
      (state_q == ST_PV_UPDATE) && (pv_v_step_index_q == 0) &&
      (pv_waves_started_q < (OUTPUT_TILE_W + 1)'(OUTPUT_TILES));
`else
  assign pv_output_start = !skip_current_q[active_bank_q] &&
      (state_q == ST_PV_UPDATE) &&
      v_step_valid_i && (pv_v_step_index_q == 0) &&
      (pv_waves_started_q < (OUTPUT_TILE_W + 1)'(OUTPUT_TILES));
`endif
  assign v_step_ready_o = !skip_current_q[active_bank_q] &&
      (state_q == ST_PV_UPDATE) && pv_v_step_ready &&
      ((pv_v_step_index_q != 0) ||
       (pv_output_start_ready &&
        (pv_waves_started_q < (OUTPUT_TILE_W + 1)'(OUTPUT_TILES))));
`ifdef GQAV7_PV_PRODUCTION
  assign pv_wave_start_fire = pv_output_start && pv_output_start_ready &&
      v_step_valid_i && pv_v_step_ready;
`else
  assign pv_wave_start_fire = pv_output_start && pv_output_start_ready;
`endif
  assign pv_v_step_fire = v_step_valid_i && v_step_ready_o;
  assign partial_row_valid = skip_current_q[active_bank_q]
      ? ((state_q == ST_PV_UPDATE) &&
         (skip_row_count_q < OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS)))
      : pv_partial_row_valid;
  assign pv_partial_row_ready = skip_current_q[active_bank_q]
      ? 1'b0 : partial_row_ready;
  assign partial_row_alpha =
      alpha_by_row_q[active_bank_q][partial_row_index];
  assign partial_row_running_sum
    = running_sum_by_row_q[active_bank_q][partial_row_index];
  assign partial_row_state_slot = state_slot_q[active_bank_q];
  assign partial_row_index = skip_current_q[active_bank_q]
      ? skip_row_count_q[3:0] : pv_partial_row_index;
  assign partial_row_output_tile = skip_current_q[active_bank_q]
      ? skip_row_count_q[4 +: OUTPUT_TILE_W] : pv_partial_output_tile;
  assign partial_row_first_context = first_context_q[active_bank_q];
  assign partial_row_last_context = last_context_q[active_bank_q];
  assign partial_row_txn = txn_q[active_bank_q];
  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_partial_row_relay
      assign partial_row[lane] = skip_current_q[active_bank_q]
          ? 32'd0 : pv_partial_row[lane];
    end
  endgenerate
  assign partial_row_ready = update_in_ready;
`ifdef GQAV7_OUTPUT_UPDATE_PRODUCTION
  gqav7_output_update_16lane #(
`else
  gqav5_output_update_16lane #(
`endif
    .STATE_SLOTS (STATE_SLOTS),
    .OUTPUT_TILES(OUTPUT_TILES),
    .TXN_W       (TXN_W)
  ) i_output_update (
    .clk_i,
    .rst_ni,
    .clear_i                    (1'b0),
    .in_valid_i                 (partial_row_valid),
    .in_ready_o                 (update_in_ready),
    .partial_fp32_i             (partial_row),
    .alpha_fp32_i               (partial_row_alpha),
    .running_sum_fp32_i         (partial_row_running_sum),
    .state_slot_i               (partial_row_state_slot),
    .row_index_i                (partial_row_index),
    .output_tile_i              (partial_row_output_tile),
    .first_context_i            (partial_row_first_context),
    .last_context_i             (partial_row_last_context),
    .txn_id_i                   (partial_row_txn),
    .out_valid_o                (update_out_valid),
    .out_ready_i                (update_out_ready),
    .updated_fp32_o             (update_out),
    .running_sum_fp32_o         (update_running_sum),
    .state_slot_o               (update_state_slot),
    .row_index_o                (update_row_index),
    .output_tile_o              (update_output_tile),
    .first_context_o            (update_first_context),
    .last_context_o             (update_last_context),
    .txn_id_o                   (update_txn),
    .accepted_updates_cycle_o   (),
    .accepted_updates_total_o   (update_accepted_elements_o),
    .state_write_count_o        (),
    .forwarding_count_o         (),
    .hazard_stall_cycles_o      (),
    .protocol_error_o           (update_error)
  );

  assign update_out_ready = update_last_context ? final_write_ready : 1'b1;
  assign update_out_fire = update_out_valid && update_out_ready;
  assign final_write_valid = update_out_valid && update_last_context;

  gqav5_output_row_buffer #(.OUTPUT_TILES(OUTPUT_TILES)) i_final_buffer (
    .clk_i,
    .rst_ni,
    .write_valid_i       (final_write_valid),
    .write_ready_o       (final_write_ready),
    .write_output_tile_i (update_output_tile),
    .write_row_index_i   (update_row_index),
    .write_data_fp32_i   (update_out),
    .read_valid_i        (final_read_valid),
    .read_ready_o        (final_read_ready),
    .read_output_tile_i  (normalize_rows_issued_q[4 +: OUTPUT_TILE_W]),
    .read_row_index_i    (normalize_rows_issued_q[3:0]),
    .out_valid_o         (final_row_valid),
    .out_ready_i         (final_row_ready),
    .out_output_tile_o   (final_output_tile),
    .out_row_index_o     (final_row_index),
    .out_data_fp32_o     (final_row),
    .write_count_o       (),
    .read_count_o        ()
  );

  assign final_read_valid = (state_q == ST_NORMALIZE) &&
      (normalize_rows_issued_q < OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS));
  assign final_row_ready = normalize_in_ready;

`ifdef GQAV7_OUTPUT_NORMALIZE_PRODUCTION
  gqav7_output_normalize_16lane #(
`else
  gqav5_output_normalize_16lane #(
`endif
    .STATE_SLOT_W (STATE_SLOT_W),
    .OUTPUT_TILE_W(OUTPUT_TILE_W),
    .TXN_W        (TXN_W)
  ) i_normalize (
    .clk_i,
    .rst_ni,
    .in_valid_i              (final_row_valid),
    .in_ready_o              (normalize_in_ready),
    .row_valid_i             (5'(final_row_index) <
                               query_valid_rows_q[active_bank_q]),
    .updated_fp32_i          (final_row),
    .running_sum_fp32_i      (
        running_sum_by_row_q[active_bank_q][final_row_index]),
    .state_slot_i            (state_slot_q[active_bank_q]),
    .row_index_i             (final_row_index),
    .output_tile_i           (final_output_tile),
    .txn_id_i                (txn_q[active_bank_q]),
    .out_valid_o             (normalize_out_valid),
    .out_ready_i             (normalize_out_ready),
    .normalized_fp32_o       (normalize_out),
    .reciprocal_fp32_o       (),
    .state_slot_o            (normalize_state_slot),
    .row_index_o             (normalize_row_index),
    .output_tile_o           (normalize_output_tile),
    .txn_id_o                (normalize_txn),
    .normalized_rows_o       (),
    .reciprocal_busy_cycles_o(),
    .rom_sentinel_ok_o       (normalize_rom_ok),
    .protocol_error_o        (normalize_error)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  assign normalize_out_ready = result_ready_i;
  assign result_valid_o = normalize_out_valid;
  assign result_output_tile_o = normalize_output_tile;
  assign result_row_index_o = normalize_row_index;
  assign result_txn_id_o = normalize_txn;
  assign result_row_valid_o = 5'(normalize_row_index) <
                              query_valid_rows_q[active_bank_q];
  assign normalize_result_fire = normalize_out_valid && result_ready_i;
  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_result
      assign result_fp32_o[lane] = normalize_out[lane];
    end
  endgenerate

  assign softmax_active_o = (state_q == ST_SCORE_PLOAD) ||
                            sidecar_out_valid || softmax_out_valid;
  assign update_active_o = partial_row_valid || update_out_valid;
  assign diagnostic_error =
      metadata_error_q || softmax_error || pv_error ||
      update_error || normalize_error ||
      !softmax_rom_ok || !normalize_rom_ok ||
      (sidecar_out_valid &&
       (sidecar_txn != txn_q[score_bank_q])) ||
      (softmax_out_valid &&
       ((softmax_state_slot != state_slot_q[score_bank_q]) ||
        (softmax_txn != txn_q[score_bank_q]) ||
        (softmax_first_context != first_context_q[score_bank_q]) ||
        (softmax_last_context != last_context_q[score_bank_q]))) ||
      (update_out_valid &&
       ((update_state_slot != state_slot_q[active_bank_q]) ||
        (update_running_sum !=
         running_sum_by_row_q[active_bank_q][update_row_index]) ||
        (update_first_context != first_context_q[active_bank_q]) ||
        (update_txn != txn_q[active_bank_q]))) ||
      (normalize_out_valid &&
       (normalize_state_slot != state_slot_q[active_bank_q]));
  assign error_o = diagnostic_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      diagnostic_error_q <= 1'b0;
    else
      diagnostic_error_q <= diagnostic_error_q || diagnostic_error;
  end

  // Per-row sidecar payload is fully qualified by the downstream FSM and the
  // producer handshakes.  Keep these 1,536 data bits off the asynchronous
  // reset tree; every descriptor overwrites all sixteen row entries before
  // PV/update/normalize consumes them.
  always_ff @(posedge clk_i) begin
    if (sidecar_out_valid && sidecar_out_ready)
      block_max_by_row_q[score_bank_q][sidecar_row_index]
          <= sidecar_block_max;

    if (softmax_out_valid && softmax_out_ready) begin
      alpha_by_row_q[score_bank_q][softmax_row_index] <= softmax_alpha;
      running_sum_by_row_q[score_bank_q][softmax_row_index]
          <= softmax_running_sum;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                    <= ST_IDLE;
      active_bank_q              <= 1'b0;
      score_bank_q               <= 1'b0;
      next_bank_occupied_q       <= 1'b0;
      next_bank_ready_q          <= 1'b0;
      for (int bank = 0; bank < 2; bank++) begin
        state_slot_q[bank]         <= '0;
        query_base_q[bank]         <= '0;
        context_base_q[bank]       <= '0;
        query_valid_rows_q[bank]   <= '0;
        context_valid_cols_q[bank] <= '0;
        causal_q[bank]             <= 1'b0;
        first_context_q[bank]      <= 1'b0;
        last_context_q[bank]       <= 1'b0;
        scale_q[bank]              <= '0;
        txn_q[bank]                <= '0;
        skip_candidate_q[bank]     <= 1'b0;
        skip_current_q[bank]       <= 1'b0;
        skip_eval_complete_q[bank] <= 1'b0;
      end
      score_input_done_q         <= 1'b0;
      expected_score_row_q       <= '0;
      metadata_error_q           <= 1'b0;
      pv_v_step_index_q          <= '0;
      pv_waves_started_q         <= '0;
      pv_waves_completed_q       <= '0;
      update_rows_completed_q    <= '0;
      normalize_rows_issued_q    <= '0;
      normalize_rows_completed_q <= '0;
      active_cycles_o            <= '0;
      partial_capture_count_o    <= '0;
      partial_row_transfer_count_o <= '0;
      pv_blocks_total_o          <= '0;
      pv_blocks_skipped_o        <= '0;
      skip_row_count_q           <= '0;
      for (int skip_stage = 0; skip_stage < 5; skip_stage++)
        skip_row_pipe_q[skip_stage] <= '0;
      done_o                     <= 1'b0;
    end else begin
      done_o <= 1'b0;
      skip_row_pipe_q[0] <= softmax_row_index;
      for (int skip_stage = 1; skip_stage < 5; skip_stage++)
        skip_row_pipe_q[skip_stage] <= skip_row_pipe_q[skip_stage - 1];
      if (busy_o)
        active_cycles_o <= active_cycles_o + 64'd1;

      if (score_row_fire) begin
        if (state_q == ST_IDLE) begin
          score_bank_q <= active_bank_q;
          state_slot_q[active_bank_q] <= score_state_slot_i;
          query_base_q[active_bank_q] <= score_query_base_i;
          context_base_q[active_bank_q] <= score_context_base_i;
          query_valid_rows_q[active_bank_q] <=
              score_query_valid_rows_i;
          context_valid_cols_q[active_bank_q] <=
              score_context_valid_cols_i;
          causal_q[active_bank_q] <= score_causal_i;
          first_context_q[active_bank_q] <= score_first_context_i;
          last_context_q[active_bank_q] <= score_last_context_i;
          scale_q[active_bank_q] <= score_scale_fp32_i;
          txn_q[active_bank_q] <= score_txn_id_i;
          score_input_done_q   <= 1'b0;
          expected_score_row_q <= 4'd0;
          pv_v_step_index_q    <= '0;
          pv_waves_started_q   <= '0;
          pv_waves_completed_q <= '0;
          update_rows_completed_q <= '0;
          normalize_rows_issued_q <= '0;
          normalize_rows_completed_q <= '0;
          skip_candidate_q[active_bank_q] <= pv_skip_enable_i;
          skip_current_q[active_bank_q] <= 1'b0;
          skip_eval_complete_q[active_bank_q] <= 1'b0;
          skip_row_count_q      <= '0;
          state_q <= ST_SCORE_PLOAD;
        end else if ((state_q != ST_SCORE_PLOAD) &&
                     (expected_score_row_q == 0)) begin
          score_bank_q <= ~active_bank_q;
          next_bank_occupied_q <= 1'b1;
          next_bank_ready_q <= 1'b0;
          state_slot_q[~active_bank_q] <= score_state_slot_i;
          query_base_q[~active_bank_q] <= score_query_base_i;
          context_base_q[~active_bank_q] <= score_context_base_i;
          query_valid_rows_q[~active_bank_q] <=
              score_query_valid_rows_i;
          context_valid_cols_q[~active_bank_q] <=
              score_context_valid_cols_i;
          causal_q[~active_bank_q] <= score_causal_i;
          first_context_q[~active_bank_q] <= score_first_context_i;
          last_context_q[~active_bank_q] <= score_last_context_i;
          scale_q[~active_bank_q] <= score_scale_fp32_i;
          txn_q[~active_bank_q] <= score_txn_id_i;
          skip_candidate_q[~active_bank_q] <= pv_skip_enable_i;
          skip_current_q[~active_bank_q] <= 1'b0;
          skip_eval_complete_q[~active_bank_q] <= 1'b0;
        end else if ((score_state_slot_i != state_slot_q[score_bank_q]) ||
                     (score_query_base_i != query_base_q[score_bank_q]) ||
                     (score_context_base_i !=
                      context_base_q[score_bank_q]) ||
                     (score_query_valid_rows_i !=
                      query_valid_rows_q[score_bank_q]) ||
                     (score_context_valid_cols_i !=
                      context_valid_cols_q[score_bank_q]) ||
                     (score_causal_i != causal_q[score_bank_q]) ||
                     (score_first_context_i !=
                      first_context_q[score_bank_q]) ||
                     (score_last_context_i !=
                      last_context_q[score_bank_q]) ||
                     (score_scale_fp32_i != scale_q[score_bank_q]) ||
                     (score_txn_id_i != txn_q[score_bank_q])) begin
          metadata_error_q <= 1'b1;
        end

        if (score_row_index_i != expected_score_row_q)
          metadata_error_q <= 1'b1;
        if (score_row_index_i == 4'd15) begin
          score_input_done_q <= 1'b1;
          expected_score_row_q <= '0;
        end else begin
          expected_score_row_q <= score_row_index_i + 4'd1;
        end
      end

      if (skip_delta_valid) begin
        if (skip_eval_requires_pv)
          skip_candidate_q[score_bank_q] <= 1'b0;
        if (skip_row_pipe_q[4] == 4'd15) begin
          skip_current_q[score_bank_q] <= pv_skip_enable_i &&
              skip_candidate_q[score_bank_q] && !skip_eval_requires_pv;
          skip_eval_complete_q[score_bank_q] <= 1'b1;
        end
      end

      if (next_bank_occupied_q && pv_p_next_loaded &&
          skip_eval_complete_q[~active_bank_q])
        next_bank_ready_q <= 1'b1;

      if ((state_q == ST_SCORE_PLOAD) && pv_p_loaded &&
          skip_eval_complete_q[active_bank_q]) begin
        pv_v_step_index_q <= '0;
        score_input_done_q <= 1'b0;
        expected_score_row_q <= '0;
        pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
        if (skip_current_q[active_bank_q])
          pv_blocks_skipped_o <= pv_blocks_skipped_o + 64'd1;
        state_q <= ST_PV_UPDATE;
      end

      if (pv_wave_start_fire) begin
        pv_waves_started_q <= pv_waves_started_q + 1'b1;
      end
      if (pv_v_step_fire) begin
        if (pv_v_step_index_q == 5'd15)
          pv_v_step_index_q <= '0;
        else
          pv_v_step_index_q <= pv_v_step_index_q + 5'd1;
      end
      if (skip_current_q[active_bank_q] &&
          partial_row_valid && partial_row_ready) begin
        if (skip_row_count_q ==
            OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS - 1)) begin
          skip_row_count_q <= OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS);
          state_q <= ST_DRAIN_UPDATE;
        end else begin
          skip_row_count_q <= skip_row_count_q + 1'b1;
        end
      end
      if (pv_output_done) begin
        partial_capture_count_o <= partial_capture_count_o + 64'd1;
        pv_waves_completed_q <= pv_waves_completed_q + 1'b1;
        if (pv_waves_completed_q ==
            (OUTPUT_TILE_W + 1)'(OUTPUT_TILES - 1))
          state_q <= ST_DRAIN_UPDATE;
      end

      if (partial_row_valid && partial_row_ready)
        partial_row_transfer_count_o
          <= partial_row_transfer_count_o + 64'd1;

      if (update_out_fire) begin
        if (update_rows_completed_q ==
            OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS - 1)) begin
          update_rows_completed_q <= OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS);
          if (last_context_q[active_bank_q]) begin
            normalize_rows_issued_q <= '0;
            normalize_rows_completed_q <= '0;
            state_q <= ST_NORMALIZE;
          end else if (next_bank_occupied_q) begin
            done_o <= 1'b1;
            active_bank_q <= ~active_bank_q;
            next_bank_occupied_q <= 1'b0;
            next_bank_ready_q <= 1'b0;
            pv_v_step_index_q <= '0;
            pv_waves_started_q <= '0;
            pv_waves_completed_q <= '0;
            update_rows_completed_q <= '0;
            skip_row_count_q <= '0;
            if (next_bank_ready_q) begin
              score_input_done_q <= 1'b0;
              expected_score_row_q <= '0;
              pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
              if (skip_current_q[~active_bank_q])
                pv_blocks_skipped_o <= pv_blocks_skipped_o + 64'd1;
              state_q <= ST_PV_UPDATE;
            end else begin
              state_q <= ST_SCORE_PLOAD;
            end
          end else begin
            done_o <= 1'b1;
            score_input_done_q <= 1'b0;
            expected_score_row_q <= '0;
            state_q <= ST_IDLE;
          end
        end else begin
          update_rows_completed_q <= update_rows_completed_q + 1'b1;
        end
      end

      if (final_read_valid && final_read_ready)
        normalize_rows_issued_q <= normalize_rows_issued_q + 1'b1;

      if (normalize_result_fire) begin
        if (normalize_rows_completed_q ==
            OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS - 1)) begin
          normalize_rows_completed_q <= OUTPUT_ROW_COUNT_W'(TOTAL_OUTPUT_ROWS);
          done_o <= 1'b1;
          if (next_bank_occupied_q) begin
            active_bank_q <= ~active_bank_q;
            next_bank_occupied_q <= 1'b0;
            next_bank_ready_q <= 1'b0;
            pv_v_step_index_q <= '0;
            pv_waves_started_q <= '0;
            pv_waves_completed_q <= '0;
            update_rows_completed_q <= '0;
            normalize_rows_issued_q <= '0;
            normalize_rows_completed_q <= '0;
            skip_row_count_q <= '0;
            if (next_bank_ready_q) begin
              score_input_done_q <= 1'b0;
              expected_score_row_q <= '0;
              pv_blocks_total_o <= pv_blocks_total_o + 64'd1;
              if (skip_current_q[~active_bank_q])
                pv_blocks_skipped_o <= pv_blocks_skipped_o + 64'd1;
              state_q <= ST_PV_UPDATE;
            end else begin
              state_q <= ST_SCORE_PLOAD;
            end
          end else begin
            score_input_done_q <= 1'b0;
            expected_score_row_q <= '0;
            state_q <= ST_IDLE;
          end
        end else begin
          normalize_rows_completed_q <= normalize_rows_completed_q + 1'b1;
        end
      end
    end
  end

  initial begin
    if ((OUTPUT_TILES < 1) || (OUTPUT_TILES > 8) ||
        ((OUTPUT_TILES > 1) && ((1 << OUTPUT_TILE_W) != OUTPUT_TILES)))
      $error("attention downstream OUTPUT_TILES must be 1/2/4/8");
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16) ||
        ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS)))
      $error("attention downstream STATE_SLOTS must be a power of two");
    if (ROW_PARTITIONS != 4)
      $error("attention downstream partitioned PV requires four regions");
  end
endmodule
