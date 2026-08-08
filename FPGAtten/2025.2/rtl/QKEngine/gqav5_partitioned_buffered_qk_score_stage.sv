module gqav5_partitioned_buffered_qk_score_stage #(
  parameter int unsigned QK_STEPS       = 128,
  parameter int unsigned STATE_SLOTS    = 4,
  parameter int unsigned TXN_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4,
  parameter bit ENABLE_ROW_COMPAT       = 1'b0,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned QK_STEP_W =
      (QK_STEPS <= 1) ? 1 : $clog2(QK_STEPS)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic desc_valid_i,
  output logic desc_ready_o,
  input  logic [STATE_SLOT_W-1:0] desc_state_slot_i,
  input  logic [31:0] desc_query_base_i,
  input  logic [31:0] desc_context_base_i,
  input  logic [4:0] desc_query_valid_rows_i,
  input  logic [4:0] desc_context_valid_cols_i,
  input  logic desc_causal_i,
  input  logic desc_first_context_i,
  input  logic desc_last_context_i,
  input  logic [31:0] desc_scale_fp32_i,
  input  logic [TXN_W-1:0] desc_txn_id_i,

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

  output logic score_row_valid_o,
  input  logic score_row_ready_i,
  output logic [31:0] score_row_fp32_o [16],
  output logic [3:0] score_row_index_o,
  output logic [STATE_SLOT_W-1:0] score_state_slot_o,
  output logic [31:0] score_query_base_o,
  output logic [31:0] score_context_base_o,
  output logic [4:0] score_query_valid_rows_o,
  output logic [4:0] score_context_valid_cols_o,
  output logic score_causal_o,
  output logic score_first_context_o,
  output logic score_last_context_o,
  output logic [31:0] score_scale_fp32_o,
  output logic [TXN_W-1:0] score_txn_id_o,

  output gqav5_pkg::gqav5_bank_state_e q_bank_state_o [2],
  output gqav5_pkg::gqav5_bank_state_e
      k_bank_state_o [ROW_PARTITIONS][2],
  output logic qk_active_o,
  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] operand_bram_reads_o,
  output logic [63:0] prefetch_compute_overlap_cycles_o,
  output logic [63:0] operand_tile_count_o,
  output logic error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic operand_step_valid, operand_step_ready;
  // These buses are intentionally absent from the production datapath when
  // ENABLE_ROW_COMPAT=0.  They remain declared so the optional compatibility
  // generate branch can be elaborated by the same source file.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] operand_q_column [16];
  logic [15:0] operand_k_partition [ROW_PARTITIONS][16];
  logic [3:0] operand_step_index;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] operand_step_tag;
  logic operand_tile_done, operand_error;
  logic direct_step_valid, direct_step_ready;
  logic [15:0] direct_q_column [16];
  logic [15:0] direct_k_partition [ROW_PARTITIONS][16];
  logic [3:0] direct_step_index;
  logic [15:0] direct_step_tag;
  logic direct_tile_done, direct_error;
  logic direct_path_active_q;
  logic direct_start_eligible, direct_adapter_start_ready;
  logic direct_start_fire;
  logic [63:0] direct_steps, direct_tiles;
  logic [63:0] row_operand_tiles;
  logic selected_step_valid, selected_step_ready;
  logic [15:0] selected_q_column [16];
  logic [15:0] selected_k_partition [ROW_PARTITIONS][16];
  logic [3:0] selected_step_index;
  logic [15:0] selected_step_tag;

  logic desc_active_q, desc_compute_bank_q;
  logic [QK_STEP_W-1:0] qk_step_index_q;
  logic [STATE_SLOT_W-1:0] state_slot_q [2];
  logic [31:0] query_base_q [2], context_base_q [2], scale_q [2];
  logic [4:0] query_valid_rows_q [2], context_valid_cols_q [2];
  logic causal_q [2], first_context_q [2], last_context_q [2];
  logic [TXN_W-1:0] txn_q [2];
  logic [15:0] query_row_mask, context_col_mask;
  logic qk_start, qk_start_ready, qk_step_ready, qk_done;
  logic qk_continuation_step_ready;
  logic qk_result_valid, qk_result_bank, qk_next_compute_bank;
  // One result-bank bit formerly selected all descriptor sidecars directly
  // (about 150 routed loads).  Ten preserved leaf copies keep each metadata
  // mux local without adding a cycle to the score-row handshake.
  logic [9:0] qk_result_meta_bank_local;
  logic qk_result_drained;
  logic [8:0] qk_accepted_macs_cycle;
  logic [3:0] qk_result_index;
  logic [31:0] qk_result [16];
  logic qk_error, local_error_q;
  logic [63:0] qk_completed_tiles;
  logic desc_fire, operand_step_fire;

  generate
  if (ENABLE_ROW_COMPAT) begin : gen_row_compat_operands
  gqav5_partitioned_qk_operand_pingpong #(
    .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_operands (
    .clk_i, .rst_ni,
    .q_fill_valid_i, .q_fill_ready_o, .q_fill_tag_i, .q_fill_bank_o,
    .q_fill_row_valid_i, .q_fill_row_ready_o, .q_fill_row_addr_i,
    .q_fill_row_data_i, .q_fill_row_last_i,
    .k_fill_valid_i, .k_fill_ready_o, .k_fill_broadcast_i,
    .k_fill_partition_i,
    .k_fill_tag_i, .k_fill_bank_o, .k_fill_row_valid_i,
    .k_fill_row_ready_o, .k_fill_row_addr_i, .k_fill_row_data_i,
    .k_fill_row_last_i,
    .fast_start_valid_i(qk_stream_start_valid_i),
    .fast_start_ready_o(qk_stream_start_ready_o),
    .fast_start_tag_i(qk_stream_start_tag_i),
    .fast_row_valid_i(qk_stream_row_valid_i),
    .fast_row_ready_o(qk_stream_row_ready_o),
    .fast_row_index_i(qk_stream_row_index_i),
    .fast_q_row_bf16_i(qk_stream_q_row_bf16_i),
    .fast_k_partition_row_bf16_i(
        qk_stream_k_partition_row_bf16_i),
    .fast_row_last_i(qk_stream_row_last_i),
    .step_valid_o(operand_step_valid),
    .step_ready_i(operand_step_ready),
    .q_column_bf16_o(operand_q_column),
    .k_partition_column_bf16_o(operand_k_partition),
    .step_index_o(operand_step_index), .step_tag_o(operand_step_tag),
    .tile_done_o(operand_tile_done), .q_bank_state_o, .k_bank_state_o,
    .bram_read_count_o(operand_bram_reads_o),
    .prefetch_compute_overlap_cycle_count_o(
        prefetch_compute_overlap_cycles_o),
    .completed_tile_count_o(row_operand_tiles),
    .protocol_error_o(operand_error)
  );
  end else begin : gen_no_row_compat_operands
    assign q_fill_ready_o = 1'b0;
    assign q_fill_bank_o = 1'b0;
    assign q_fill_row_ready_o = 1'b0;
    assign k_fill_ready_o = 1'b0;
    assign k_fill_bank_o = 1'b0;
    assign k_fill_row_ready_o = 1'b0;
    assign qk_stream_start_ready_o = 1'b0;
    assign qk_stream_row_ready_o = 1'b0;
    assign operand_step_valid = 1'b0;
    for (genvar lane = 0; lane < 16; lane++) begin : gen_zero_q_lane
      assign operand_q_column[lane] = '0;
      for (genvar part = 0; part < ROW_PARTITIONS;
           part++) begin : gen_zero_k_part
        assign operand_k_partition[part][lane] = '0;
      end
    end
    assign operand_step_index = '0;
    assign operand_step_tag = '0;
    assign operand_tile_done = 1'b0;
    assign row_operand_tiles = '0;
    assign operand_bram_reads_o = '0;
    assign prefetch_compute_overlap_cycles_o = '0;
    assign operand_error = 1'b0;
    for (genvar bank = 0; bank < 2; bank++) begin : gen_q_state
      assign q_bank_state_o[bank] = gqav5_pkg::GQAV5_BANK_FREE;
    end
    for (genvar part = 0; part < ROW_PARTITIONS; part++) begin : gen_k_state
      for (genvar bank = 0; bank < 2; bank++) begin : gen_bank
        assign k_bank_state_o[part][bank] = gqav5_pkg::GQAV5_BANK_FREE;
      end
    end
  end
  endgenerate

  assign direct_start_eligible = direct_path_active_q ||
      (!direct_path_active_q && !operand_step_valid);
  assign qk_column_start_ready_o = direct_start_eligible &&
                                   direct_adapter_start_ready;
  assign direct_start_fire = qk_column_start_valid_i &&
                             qk_column_start_ready_o;

  gqav5_partitioned_qk_column_stream_adapter #(
    .TAG_W(16), .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_direct_column_adapter (
    .clk_i, .rst_ni,
    .start_valid_i(qk_column_start_valid_i && direct_start_eligible),
    .start_ready_o(direct_adapter_start_ready),
    .start_tag_i(qk_column_start_tag_i),
    .column_valid_i(qk_column_valid_i),
    .column_ready_o(qk_column_ready_o),
    .column_index_i(qk_column_index_i),
    .q_column_word_bf16_i(qk_column_q_word_bf16_i),
    .k_partition_column_word_bf16_i(
        qk_column_k_partition_word_bf16_i),
    .column_last_i(qk_column_last_i),
    .step_valid_o(direct_step_valid),
    .step_ready_i(direct_step_ready),
    .retire_ready_i(qk_continuation_step_ready),
    .q_column_bf16_o(direct_q_column),
    .k_partition_column_bf16_o(direct_k_partition),
    .step_index_o(direct_step_index),
    .step_tag_o(direct_step_tag),
    .done_o(direct_tile_done),
    .accepted_step_count_o(direct_steps),
    .completed_tile_count_o(direct_tiles),
    .protocol_error_o(direct_error)
  );

  generate
    if (ENABLE_ROW_COMPAT) begin : gen_runtime_operand_select
      assign selected_step_valid = direct_path_active_q
          ? direct_step_valid : operand_step_valid;
      assign operand_step_ready = !direct_path_active_q && selected_step_ready;
      assign direct_step_ready = direct_path_active_q && selected_step_ready;
      assign selected_step_index = direct_path_active_q
          ? direct_step_index : operand_step_index;
      assign selected_step_tag = direct_path_active_q
          ? direct_step_tag : operand_step_tag;
      for (genvar lane = 0; lane < 16; lane++) begin : gen_operand_select
        assign selected_q_column[lane] = direct_path_active_q
            ? direct_q_column[lane] : operand_q_column[lane];
        for (genvar part = 0; part < ROW_PARTITIONS;
             part++) begin : gen_partition
          assign selected_k_partition[part][lane] = direct_path_active_q
              ? direct_k_partition[part][lane] : operand_k_partition[part][lane];
        end
      end
    end else begin : gen_static_direct_operand_select
      // Production has no row-compatible source.  Bind the direct column
      // stream statically so direct_path_active_q cannot become a broad
      // operand-zero/select network across all 256 product registers.
      assign selected_step_valid = direct_step_valid;
      assign operand_step_ready = 1'b0;
      assign direct_step_ready = selected_step_ready;
      assign selected_step_index = direct_step_index;
      assign selected_step_tag = direct_step_tag;
      for (genvar lane = 0; lane < 16; lane++) begin : gen_operand_select
        assign selected_q_column[lane] = direct_q_column[lane];
        for (genvar part = 0; part < ROW_PARTITIONS;
             part++) begin : gen_partition
          assign selected_k_partition[part][lane] =
              direct_k_partition[part][lane];
        end
      end
    end
  endgenerate

  always_comb begin
    query_row_mask = '0;
    context_col_mask = '0;
    for (int index = 0; index < 16; index++) begin
      query_row_mask[index] =
          5'(index) < query_valid_rows_q[desc_compute_bank_q];
      context_col_mask[index] =
          5'(index) < context_valid_cols_q[desc_compute_bank_q];
    end
  end

  assign desc_ready_o = !desc_active_q && qk_start_ready;
  assign desc_fire = desc_valid_i && desc_ready_o;
  assign qk_start = desc_active_q && (qk_step_index_q == '0) &&
                    selected_step_valid && qk_start_ready;
  assign selected_step_ready = desc_active_q ? qk_step_ready : 1'b0;
  assign operand_step_fire = selected_step_valid && selected_step_ready;

`ifdef GQAV7_QK_PRODUCTION
  // GQAv7 keeps the proven V5 descriptor, operand and score-row contracts,
  // but replaces the timing-limited 256-PE recurrence with the pipelined
  // 64-MAC/cycle engine plus its even/odd reduction-wave merger.
  gqav7_qk_partitioned_adapter_16x16 #(
    .K_STEPS(QK_STEPS), .ROW_PARTITIONS(ROW_PARTITIONS), .MERGE_LANES(8)
  ) i_qk (
    .clk_i, .rst_ni, .start_i(qk_start),
    .start_ready_o(qk_start_ready),
    .step_valid_i(desc_active_q && selected_step_valid),
    .step_ready_o(qk_step_ready),
    .continuation_step_ready_o(qk_continuation_step_ready),
    .a_bf16_i(selected_q_column),
    .b_partition_bf16_i(selected_k_partition),
    .row_valid_i(query_row_mask), .col_valid_i(context_col_mask),
    .active_o(qk_active_o), .done_o(qk_done),
    .result_row_valid_o(qk_result_valid),
    .result_row_ready_i(score_row_ready_i),
    .result_row_fp32_o(qk_result),
    .result_row_index_o(qk_result_index),
    .result_row_bank_o(qk_result_bank),
    .result_drained_o(qk_result_drained),
    .next_compute_bank_o(qk_next_compute_bank),
    .accepted_macs_cycle_o(qk_accepted_macs_cycle),
    .accepted_macs_total_o(qk_accepted_macs_o),
    .completed_tiles_o(qk_completed_tiles),
    .protocol_error_o(qk_error)
  );
`else
  assign qk_continuation_step_ready = direct_step_ready;
  gqav5_qk_partitioned_outer_product_16x16 #(
    .K_STEPS(QK_STEPS), .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_qk (
    .clk_i, .rst_ni, .start_i(qk_start),
    .start_ready_o(qk_start_ready),
    .step_valid_i(desc_active_q && selected_step_valid),
    .step_ready_o(qk_step_ready), .a_bf16_i(selected_q_column),
    .b_partition_bf16_i(selected_k_partition),
    .row_valid_i(query_row_mask), .col_valid_i(context_col_mask),
    .active_o(qk_active_o), .done_o(qk_done),
    .result_row_valid_o(qk_result_valid),
    .result_row_ready_i(score_row_ready_i),
    .result_row_fp32_o(qk_result),
    .result_row_index_o(qk_result_index),
    .result_row_bank_o(qk_result_bank),
    .result_drained_o(qk_result_drained),
    .next_compute_bank_o(qk_next_compute_bank),
    .accepted_macs_cycle_o(qk_accepted_macs_cycle),
    .accepted_macs_total_o(qk_accepted_macs_o),
    .completed_tiles_o(qk_completed_tiles),
    .protocol_error_o(qk_error)
  );
`endif

  assign score_row_valid_o = qk_result_valid;
  assign score_row_index_o = qk_result_index;
  generate
    for (genvar meta_field = 0; meta_field < 10;
         meta_field++) begin : gen_result_meta_bank_local
      gqav5_local_control_buffer i_result_meta_bank_buffer (
        .in_i (qk_result_bank),
        .out_o(qk_result_meta_bank_local[meta_field])
      );
    end
  endgenerate
  assign score_state_slot_o =
      state_slot_q[qk_result_meta_bank_local[0]];
  assign score_query_base_o =
      query_base_q[qk_result_meta_bank_local[1]];
  assign score_context_base_o =
      context_base_q[qk_result_meta_bank_local[2]];
  assign score_query_valid_rows_o =
      query_valid_rows_q[qk_result_meta_bank_local[3]];
  assign score_context_valid_cols_o =
      context_valid_cols_q[qk_result_meta_bank_local[4]];
  assign score_causal_o = causal_q[qk_result_meta_bank_local[5]];
  assign score_first_context_o =
      first_context_q[qk_result_meta_bank_local[6]];
  assign score_last_context_o =
      last_context_q[qk_result_meta_bank_local[7]];
  assign score_scale_fp32_o = scale_q[qk_result_meta_bank_local[8]];
  assign score_txn_id_o = txn_q[qk_result_meta_bank_local[9]];
  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_score_lane
      assign score_row_fp32_o[lane] = qk_result[lane];
    end
  endgenerate
  assign operand_tile_count_o = row_operand_tiles + direct_tiles;
  assign error_o = operand_error || direct_error || qk_error ||
                   local_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      desc_active_q <= 1'b0;
      desc_compute_bank_q <= 1'b0;
      direct_path_active_q <= 1'b0;
      qk_step_index_q <= '0;
      local_error_q <= 1'b0;
      for (int bank = 0; bank < 2; bank++) begin
        state_slot_q[bank] <= '0;
        query_base_q[bank] <= '0; context_base_q[bank] <= '0;
        query_valid_rows_q[bank] <= '0;
        context_valid_cols_q[bank] <= '0;
        causal_q[bank] <= 1'b0; first_context_q[bank] <= 1'b0;
        last_context_q[bank] <= 1'b0; scale_q[bank] <= '0;
        txn_q[bank] <= '0;
      end
    end else begin
      if (desc_fire) begin
        desc_active_q <= 1'b1;
        desc_compute_bank_q <= qk_next_compute_bank;
        state_slot_q[qk_next_compute_bank] <= desc_state_slot_i;
        query_base_q[qk_next_compute_bank] <= desc_query_base_i;
        context_base_q[qk_next_compute_bank] <= desc_context_base_i;
        query_valid_rows_q[qk_next_compute_bank] <=
            desc_query_valid_rows_i;
        context_valid_cols_q[qk_next_compute_bank] <=
            desc_context_valid_cols_i;
        causal_q[qk_next_compute_bank] <= desc_causal_i;
        first_context_q[qk_next_compute_bank] <= desc_first_context_i;
        last_context_q[qk_next_compute_bank] <= desc_last_context_i;
        scale_q[qk_next_compute_bank] <= desc_scale_fp32_i;
        txn_q[qk_next_compute_bank] <= desc_txn_id_i;
        qk_step_index_q <= '0;
        if (desc_query_valid_rows_i == 0 ||
            desc_query_valid_rows_i > 5'd16 ||
            desc_context_valid_cols_i == 0 ||
            desc_context_valid_cols_i > 5'd16)
          local_error_q <= 1'b1;
      end
      if (direct_start_fire)
        direct_path_active_q <= 1'b1;
      if (operand_step_fire) begin
        if (selected_step_index != qk_step_index_q[3:0])
          local_error_q <= 1'b1;
        if (qk_step_index_q == QK_STEP_W'(QK_STEPS - 1))
          qk_step_index_q <= '0;
        else
          qk_step_index_q <= qk_step_index_q + QK_STEP_W'(1);
      end
      if (qk_done) begin
        desc_active_q <= 1'b0;
        direct_path_active_q <= 1'b0;
        qk_step_index_q <= '0;
      end
      if (qk_column_start_valid_i && operand_step_valid &&
          !direct_path_active_q)
        local_error_q <= 1'b1;
      if (direct_start_fire && !desc_active_q)
        local_error_q <= 1'b1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    selected_step_tag, operand_step_tag, operand_tile_done,
    qk_completed_tiles, qk_result_drained, qk_accepted_macs_cycle,
    direct_steps, direct_tile_done, operand_step_ready,
    q_fill_valid_i, q_fill_tag_i, q_fill_row_valid_i,
    q_fill_row_addr_i, q_fill_row_data_i, q_fill_row_last_i,
    k_fill_valid_i, k_fill_broadcast_i, k_fill_partition_i,
    k_fill_tag_i, k_fill_row_valid_i, k_fill_row_addr_i,
    k_fill_row_data_i, k_fill_row_last_i,
    qk_stream_start_valid_i, qk_stream_start_tag_i,
    qk_stream_row_valid_i, qk_stream_row_index_i,
    qk_stream_q_row_bf16_i,
    qk_stream_k_partition_row_bf16_i[0],
    qk_stream_k_partition_row_bf16_i[1],
    qk_stream_k_partition_row_bf16_i[2],
    qk_stream_k_partition_row_bf16_i[3],
    qk_stream_row_last_i
  };

  initial begin
    if (QK_STEPS < 1 || (QK_STEPS % 16) != 0)
      $error("partitioned buffered QK requires 16-step operand tiles");
    if (ROW_PARTITIONS != 4)
      $error("partitioned buffered QK requires four row regions");
  end
endmodule
