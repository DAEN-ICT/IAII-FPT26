module gqav5_qk_score_stage #(
  parameter int unsigned QK_STEPS    = 128,
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned QK_STEP_W =
      (QK_STEPS <= 1) ? 1 : $clog2(QK_STEPS)
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
  input  logic [31:0]             desc_scale_fp32_i,
  input  logic [TXN_W-1:0]        desc_txn_id_i,

  input  logic                    qk_step_valid_i,
  output logic                    qk_step_ready_o,
  input  logic [15:0]             q_bf16_i [16],
  input  logic [15:0]             k_bf16_i [16],

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

  output logic                    busy_o,
  output logic                    qk_active_o,
  output logic [63:0]             accepted_macs_o,
  output logic [63:0]             captured_tiles_o,
  output logic [63:0]             transferred_score_rows_o,
  output logic                    error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic desc_active_q;
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
  logic desc_compute_bank_q;
  logic [QK_STEP_W-1:0] qk_step_index_q;
  logic local_protocol_error_q;
  logic [15:0] query_row_mask;
  logic [15:0] context_col_mask;

  logic qk_start;
  logic qk_start_ready;
  logic qk_step_ready;
  logic qk_compute_active;
  logic qk_done;
  logic qk_result_row_valid;
  logic qk_result_row_bank;
  logic qk_next_compute_bank;
  logic [3:0] qk_result_row_index;
  logic [31:0] qk_result_row [16];
  logic qk_error;
  logic [63:0] qk_completed_tiles;

  always_comb begin
    query_row_mask = '0;
    context_col_mask = '0;
    for (int index = 0; index < 16; index++) begin
      query_row_mask[index]
        = 5'(index) < query_valid_rows_q[desc_compute_bank_q];
      context_col_mask[index]
        = 5'(index) < context_valid_cols_q[desc_compute_bank_q];
    end
  end

  assign desc_ready_o = !desc_active_q && qk_start_ready;
  assign qk_start = desc_active_q && (qk_step_index_q == '0) &&
                    qk_step_valid_i && qk_start_ready;
  assign qk_step_ready_o = desc_active_q ? qk_step_ready : 1'b0;
  assign qk_active_o = qk_compute_active;
  assign busy_o = desc_active_q || qk_result_row_valid;
  assign error_o = local_protocol_error_q || qk_error;
  assign score_row_valid_o = qk_result_row_valid;
  assign score_row_index_o = qk_result_row_index;
  assign score_state_slot_o = state_slot_q[qk_result_row_bank];
  assign score_query_base_o = query_base_q[qk_result_row_bank];
  assign score_context_base_o = context_base_q[qk_result_row_bank];
  assign score_query_valid_rows_o
    = query_valid_rows_q[qk_result_row_bank];
  assign score_context_valid_cols_o
    = context_valid_cols_q[qk_result_row_bank];
  assign score_causal_o = causal_q[qk_result_row_bank];
  assign score_first_context_o = first_context_q[qk_result_row_bank];
  assign score_last_context_o = last_context_q[qk_result_row_bank];
  assign score_scale_fp32_o = scale_q[qk_result_row_bank];
  assign score_txn_id_o = txn_q[qk_result_row_bank];
  assign captured_tiles_o = qk_completed_tiles;
  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_score_row
      assign score_row_fp32_o[lane] = qk_result_row[lane];
    end
  endgenerate

  /* verilator lint_off PINCONNECTEMPTY */
  gqav5_qk_outer_product_16x16 #(.K_STEPS(QK_STEPS)) i_qk (
    .clk_i,
    .rst_ni,
    .start_i                (qk_start),
    .start_ready_o          (qk_start_ready),
    .step_valid_i           (desc_active_q && qk_step_valid_i),
    .step_ready_o           (qk_step_ready),
    .a_bf16_i               (q_bf16_i),
    .b_bf16_i               (k_bf16_i),
    .row_valid_i            (query_row_mask),
    .col_valid_i            (context_col_mask),
    .active_o               (qk_compute_active),
    .done_o                 (qk_done),
    .result_row_valid_o     (qk_result_row_valid),
    .result_row_ready_i     (score_row_ready_i),
    .result_row_fp32_o      (qk_result_row),
    .result_row_index_o     (qk_result_row_index),
    .result_row_bank_o      (qk_result_row_bank),
    .result_drained_o       (),
    .next_compute_bank_o    (qk_next_compute_bank),
    .accepted_macs_cycle_o  (),
    .accepted_macs_total_o  (accepted_macs_o),
    .completed_tiles_o      (qk_completed_tiles),
    .protocol_error_o       (qk_error)
  );

  /* verilator lint_on PINCONNECTEMPTY */

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      desc_active_q         <= 1'b0;
      desc_compute_bank_q   <= 1'b0;
      qk_step_index_q       <= '0;
      local_protocol_error_q <= 1'b0;
      transferred_score_rows_o <= '0;
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
      end
    end else begin
      if (desc_valid_i && desc_ready_o) begin
        desc_active_q        <= 1'b1;
        desc_compute_bank_q  <= qk_next_compute_bank;
        state_slot_q[qk_next_compute_bank] <= desc_state_slot_i;
        query_base_q[qk_next_compute_bank] <= desc_query_base_i;
        context_base_q[qk_next_compute_bank] <= desc_context_base_i;
        query_valid_rows_q[qk_next_compute_bank]
          <= desc_query_valid_rows_i;
        context_valid_cols_q[qk_next_compute_bank]
          <= desc_context_valid_cols_i;
        causal_q[qk_next_compute_bank] <= desc_causal_i;
        first_context_q[qk_next_compute_bank]
          <= desc_first_context_i;
        last_context_q[qk_next_compute_bank] <= desc_last_context_i;
        scale_q[qk_next_compute_bank] <= desc_scale_fp32_i;
        txn_q[qk_next_compute_bank] <= desc_txn_id_i;
        qk_step_index_q      <= '0;
        if ((desc_query_valid_rows_i > 5'd16) ||
            (desc_context_valid_cols_i > 5'd16))
          local_protocol_error_q <= 1'b1;
      end

      if (desc_active_q && qk_step_valid_i && qk_step_ready) begin
        if (qk_step_index_q == QK_STEP_W'(QK_STEPS - 1))
          qk_step_index_q <= '0;
        else
          qk_step_index_q <= qk_step_index_q + QK_STEP_W'(1);
      end

      if (qk_result_row_valid && score_row_ready_i)
        transferred_score_rows_o <= transferred_score_rows_o + 64'd1;

      if (qk_done) begin
        desc_active_q <= 1'b0;
        qk_step_index_q <= '0;
      end
    end
  end

  initial begin
    if (QK_STEPS < 1)
      $error("QK score stage QK_STEPS must be positive");
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16) ||
        ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS)))
      $error("QK score stage STATE_SLOTS must be a power of two");
  end
endmodule
