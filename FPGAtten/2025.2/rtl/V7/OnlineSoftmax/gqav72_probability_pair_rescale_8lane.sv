// Combine two sequential 8-column online-softmax outputs into one 16-column
// PV operand row without restoring a 16-lane Softmax datapath.
//
// Half0 probabilities are relative to m0.  When half1 produces alpha1 and
// probabilities relative to m1, half0 is rescaled by alpha1 so a single
// sixteen-step PV wave computes alpha1*PV0 + PV1.  The output-update alpha is
// alpha0*alpha1, exactly matching the original full-block online recurrence.
module gqav72_probability_pair_rescale_8lane #(
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic                    in_set_i,
  input  logic                    in_context_half_i,
  input  logic [15:0]             probability_bf16_i [8],
  input  logic [31:0]             alpha_fp32_i,
  input  logic [31:0]             running_sum_fp32_i,
  input  logic [STATE_SLOT_W-1:0] state_slot_i,
  input  logic [3:0]              row_index_i,
  input  logic                    first_context_i,
  input  logic                    last_context_i,
  input  logic [TXN_W-1:0]        txn_id_i,

  output logic                    out_valid_o,
  input  logic                    out_ready_i,
  output logic                    out_set_o,
  output logic [15:0]             low_probability_bf16_o [8],
  output logic [15:0]             high_probability_bf16_o [8],
  output logic [31:0]             combined_alpha_fp32_o,
  output logic [31:0]             running_sum_fp32_o,
  output logic [STATE_SLOT_W-1:0] state_slot_o,
  output logic [3:0]              row_index_o,
  output logic                    first_context_o,
  output logic                    last_context_o,
  output logic [TXN_W-1:0]        txn_id_o,
  output logic                    protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned MUL_LATENCY = 3;

  (* ram_style = "distributed", rw_addr_collision = "no" *)
  logic [127:0] half0_probability_q [2][16];
  (* ram_style = "distributed", rw_addr_collision = "no" *)
  logic [31:0] half0_alpha_q [2][16];
  logic half0_first_q [2][16];
  logic half0_valid_q [2][16];

  logic [31:0] low_product_fp32 [8];
  logic low_product_valid [8];
  logic [15:0] low_product_bf16 [8];
  logic [31:0] combined_alpha_product;
  logic combined_alpha_valid;
  logic advance;
  logic input_fire;
  logic half1_fire;

  logic [MUL_LATENCY-1:0] meta_valid_q;
  logic meta_set_q [MUL_LATENCY];
  logic [15:0] high_probability_q [MUL_LATENCY][8];
  logic [31:0] running_sum_q [MUL_LATENCY];
  logic [STATE_SLOT_W-1:0] state_slot_q [MUL_LATENCY];
  logic [3:0] row_index_q [MUL_LATENCY];
  logic first_context_q [MUL_LATENCY];
  logic last_context_q [MUL_LATENCY];
  logic [TXN_W-1:0] txn_q [MUL_LATENCY];

  assign advance = !out_valid_o || out_ready_i;
  assign in_ready_o = !in_context_half_i ||
      (advance && half0_valid_q[in_set_i][row_index_i]);
  assign input_fire = in_valid_i && in_ready_o;
  assign half1_fire = input_fire && in_context_half_i;
  assign out_valid_o = meta_valid_q[MUL_LATENCY-1];
  assign out_set_o = meta_set_q[MUL_LATENCY-1];
  assign combined_alpha_fp32_o = combined_alpha_product;
  assign running_sum_fp32_o = running_sum_q[MUL_LATENCY-1];
  assign state_slot_o = state_slot_q[MUL_LATENCY-1];
  assign row_index_o = row_index_q[MUL_LATENCY-1];
  assign first_context_o = first_context_q[MUL_LATENCY-1];
  assign last_context_o = last_context_q[MUL_LATENCY-1];
  assign txn_id_o = txn_q[MUL_LATENCY-1];

  for (genvar lane = 0; lane < 8; lane++) begin : gen_rescale_lane
    logic [15:0] stored_probability;
    assign stored_probability =
        half0_probability_q[in_set_i][row_index_i][lane*16 +: 16];

    gqav7_fp32_mul_rne_pipe i_rescale (
      .clk_i,
      .rst_ni,
      .advance_i(advance),
      .valid_i(half1_fire),
      .a_fp32_i({stored_probability, 16'h0000}),
      .b_fp32_i(alpha_fp32_i),
      .valid_o(low_product_valid[lane]),
      .product_fp32_o(low_product_fp32[lane])
    );
    gqav5_fp32_to_bf16_rne i_round (
      .fp32_i(low_product_fp32[lane]),
      .bf16_o(low_product_bf16[lane])
    );
    assign low_probability_bf16_o[lane] = low_product_bf16[lane];
    assign high_probability_bf16_o[lane] =
        high_probability_q[MUL_LATENCY-1][lane];
  end

  gqav7_fp32_mul_rne_pipe i_combine_alpha (
    .clk_i,
    .rst_ni,
    .advance_i(advance),
    .valid_i(half1_fire),
    .a_fp32_i(half0_alpha_q[in_set_i][row_index_i]),
    .b_fp32_i(alpha_fp32_i),
    .valid_o(combined_alpha_valid),
    .product_fp32_o(combined_alpha_product)
  );

  always_ff @(posedge clk_i) begin
    if (input_fire && !in_context_half_i) begin
      for (int lane = 0; lane < 8; lane++)
        half0_probability_q[in_set_i][row_index_i][lane*16 +: 16]
            <= probability_bf16_i[lane];
      half0_alpha_q[in_set_i][row_index_i] <= alpha_fp32_i;
    end

    if (advance) begin
      for (int stage = MUL_LATENCY-1; stage > 0; stage--) begin
        meta_set_q[stage] <= meta_set_q[stage-1];
        running_sum_q[stage] <= running_sum_q[stage-1];
        state_slot_q[stage] <= state_slot_q[stage-1];
        row_index_q[stage] <= row_index_q[stage-1];
        first_context_q[stage] <= first_context_q[stage-1];
        last_context_q[stage] <= last_context_q[stage-1];
        txn_q[stage] <= txn_q[stage-1];
        for (int lane = 0; lane < 8; lane++)
          high_probability_q[stage][lane] <=
              high_probability_q[stage-1][lane];
      end
      if (half1_fire) begin
        meta_set_q[0] <= in_set_i;
        running_sum_q[0] <= running_sum_fp32_i;
        state_slot_q[0] <= state_slot_i;
        row_index_q[0] <= row_index_i;
        first_context_q[0] <= half0_first_q[in_set_i][row_index_i];
        last_context_q[0] <= last_context_i;
        txn_q[0] <= txn_id_i;
        for (int lane = 0; lane < 8; lane++)
          high_probability_q[0][lane] <= probability_bf16_i[lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_valid_q <= '0;
      protocol_error_o <= 1'b0;
      for (int set = 0; set < 2; set++)
        for (int row = 0; row < 16; row++) begin
          half0_valid_q[set][row] <= 1'b0;
          half0_first_q[set][row] <= 1'b0;
        end
    end else begin
      if (advance) begin
        for (int stage = MUL_LATENCY-1; stage > 0; stage--)
          meta_valid_q[stage] <= meta_valid_q[stage-1];
        meta_valid_q[0] <= half1_fire;
      end

      if (input_fire && !in_context_half_i) begin
        if (half0_valid_q[in_set_i][row_index_i])
          protocol_error_o <= 1'b1;
        half0_valid_q[in_set_i][row_index_i] <= 1'b1;
        half0_first_q[in_set_i][row_index_i] <= first_context_i;
      end
      if (half1_fire)
        half0_valid_q[in_set_i][row_index_i] <= 1'b0;

      if (in_valid_i && in_context_half_i &&
          !half0_valid_q[in_set_i][row_index_i])
        protocol_error_o <= 1'b1;
      if (out_valid_o) begin
        for (int lane = 1; lane < 8; lane++)
          if (low_product_valid[lane] != low_product_valid[0])
            protocol_error_o <= 1'b1;
        if ((low_product_valid[0] != combined_alpha_valid) ||
            (low_product_valid[0] != out_valid_o))
          protocol_error_o <= 1'b1;
      end
    end
  end

  initial begin
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16) ||
        ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS)))
      $error("V7.2 probability pair rescale STATE_SLOTS invalid");
  end
endmodule
