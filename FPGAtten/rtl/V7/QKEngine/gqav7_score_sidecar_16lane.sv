module gqav7_score_sidecar_16lane #(
  parameter int unsigned TXN_W = 16
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        in_valid_i,
  output logic        in_ready_o,
  input  logic [31:0] score_fp32_i [16],
  input  logic [31:0] scale_fp32_i,
  input  logic [31:0] query_index_i,
  input  logic [31:0] context_base_i,
  input  logic [4:0]  context_valid_cols_i,
  input  logic        causal_i,
  input  logic [3:0]  row_index_i,
  input  logic [TXN_W-1:0] txn_id_i,

  output logic        out_valid_o,
  input  logic        out_ready_i,
  output logic [31:0] scaled_masked_score_o [16],
  output logic [15:0] score_valid_mask_o,
  output logic [31:0] block_max_o,
  output logic [3:0]  row_index_o,
  output logic [TXN_W-1:0] txn_id_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned MUL_STAGES = 3;

  logic        input_valid_q;
  logic [31:0] score_input_q [16];
  logic [31:0] scale_input_q;
  logic [15:0] valid_mask_input_q;
  logic [3:0] row_index_input_q;
  logic [TXN_W-1:0] txn_input_q;
  logic [31:0] scaled_product [16];
  logic        scaled_valid [16];
  logic [15:0] computed_valid_mask;
  logic [MUL_STAGES-1:0] mul_valid_q;
  logic [15:0] mul_valid_mask_q [MUL_STAGES];
  logic [3:0] mul_row_index_q [MUL_STAGES];
  logic [TXN_W-1:0] mul_txn_q [MUL_STAGES];

  logic [4:0] pipe_valid_q;
  (* shreg_extract = "no" *) logic [31:0] score_pipe_q [5][16];
  (* shreg_extract = "no" *) logic [15:0] valid_mask_pipe_q [5];
  (* shreg_extract = "no" *) logic [3:0] row_index_pipe_q [5];
  (* shreg_extract = "no" *) logic [TXN_W-1:0] txn_pipe_q [5];
  logic [31:0] pair_max_q [8];
  logic [31:0] quad_max_q [4];
  logic [31:0] oct_max_q [2];
  logic [31:0] block_max_q;
  logic pipeline_advance;
  logic input_capture_advance_local;
  logic mul_meta_advance_local;
  logic scale_advance_local [16];
  logic payload_advance_local [5];

  function automatic logic fp32_greater(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    logic lhs_nan;
    logic rhs_nan;
    logic lhs_zero;
    logic rhs_zero;
    begin
      lhs_nan  = (lhs[30:23] == 8'hff) && (lhs[22:0] != '0);
      rhs_nan  = (rhs[30:23] == 8'hff) && (rhs[22:0] != '0);
      lhs_zero = (lhs[30:0] == '0);
      rhs_zero = (rhs[30:0] == '0);
      if (lhs_nan)
        fp32_greater = 1'b0;
      else if (rhs_nan)
        fp32_greater = 1'b1;
      else if (lhs_zero && rhs_zero)
        fp32_greater = 1'b0;
      else if (lhs[31] != rhs[31])
        fp32_greater = !lhs[31];
      else if (!lhs[31])
        fp32_greater = lhs[30:0] > rhs[30:0];
      else
        fp32_greater = lhs[30:0] < rhs[30:0];
    end
  endfunction

  function automatic logic [31:0] fp32_max2(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    fp32_max2 = fp32_greater(lhs, rhs) ? lhs : rhs;
  endfunction

  always_comb begin
    for (int unsigned lane = 0; lane < 16; lane++)
      computed_valid_mask[lane] =
          !((5'(lane) >= context_valid_cols_i) ||
            (causal_i &&
             ((context_base_i + 32'(lane)) > query_index_i)));
  end

  assign pipeline_advance = !pipe_valid_q[4] || out_ready_i;
  assign in_ready_o = pipeline_advance;
  assign out_valid_o = pipe_valid_q[4];
  assign score_valid_mask_o = valid_mask_pipe_q[4];
  assign block_max_o = block_max_q;
  assign row_index_o = row_index_pipe_q[4];
  assign txn_id_o = txn_pipe_q[4];

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_scale
      // Keep the global backpressure decision logically common, but buffer
      // it next to each multiplier.  The predecessor routed one advance net
      // through all sixteen arithmetic lanes and the complete score pipe.
      gqav5_local_control_buffer i_scale_advance (
        .in_i (pipeline_advance),
        .out_o(scale_advance_local[lane])
      );
      gqav7_fp32_mul_rne_pipe i_scale (
        .clk_i,
        .rst_ni,
        .advance_i     (scale_advance_local[lane]),
        .valid_i       (input_valid_q),
        .a_fp32_i      (score_input_q[lane]),
        .b_fp32_i      (scale_input_q),
        .valid_o       (scaled_valid[lane]),
        .product_fp32_o(scaled_product[lane])
      );
      assign scaled_masked_score_o[lane] = score_pipe_q[4][lane];
    end
    for (genvar stage = 0; stage < 5; stage++) begin : gen_payload_advance
      gqav5_local_control_buffer i_payload_advance (
        .in_i (pipeline_advance),
        .out_o(payload_advance_local[stage])
      );
    end
  endgenerate

  gqav5_local_control_buffer i_input_capture_advance (
    .in_i (pipeline_advance),
    .out_o(input_capture_advance_local)
  );
  gqav5_local_control_buffer i_mul_meta_advance (
    .in_i (pipeline_advance),
    .out_o(mul_meta_advance_local)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      input_valid_q <= 1'b0;
      mul_valid_q  <= '0;
      pipe_valid_q <= '0;
    end else if (pipeline_advance) begin
      input_valid_q <= in_valid_i;
      mul_valid_q[0] <= input_valid_q;
      for (int stage = 1; stage < MUL_STAGES; stage++)
        mul_valid_q[stage] <= mul_valid_q[stage-1];

      pipe_valid_q[0] <= mul_valid_q[MUL_STAGES-1];
      for (int stage = 1; stage < 5; stage++)
        pipe_valid_q[stage] <= pipe_valid_q[stage-1];
    end
  end

  // Payload is valid-qualified and reset-free, matching the proven V5
  // physical contract while inserting only the missing scale pipeline.
  always_ff @(posedge clk_i) begin
    if (input_capture_advance_local && in_valid_i) begin
      for (int lane = 0; lane < 16; lane++)
        score_input_q[lane] <= score_fp32_i[lane];
      scale_input_q <= scale_fp32_i;
      valid_mask_input_q <= computed_valid_mask;
      row_index_input_q <= row_index_i;
      txn_input_q <= txn_id_i;
    end

    if (mul_meta_advance_local) begin
      if (input_valid_q) begin
        mul_valid_mask_q[0] <= valid_mask_input_q;
        mul_row_index_q[0] <= row_index_input_q;
        mul_txn_q[0] <= txn_input_q;
      end
      for (int stage = 1; stage < MUL_STAGES; stage++) begin
        mul_valid_mask_q[stage] <= mul_valid_mask_q[stage-1];
        mul_row_index_q[stage] <= mul_row_index_q[stage-1];
        mul_txn_q[stage] <= mul_txn_q[stage-1];
      end
    end

    if (payload_advance_local[0] && mul_valid_q[MUL_STAGES-1]) begin
      for (int lane = 0; lane < 16; lane++)
        score_pipe_q[0][lane] <=
            mul_valid_mask_q[MUL_STAGES-1][lane]
                ? scaled_product[lane] : 32'hff80_0000;
      valid_mask_pipe_q[0] <= mul_valid_mask_q[MUL_STAGES-1];
      row_index_pipe_q[0] <= mul_row_index_q[MUL_STAGES-1];
      txn_pipe_q[0] <= mul_txn_q[MUL_STAGES-1];
    end

    if (payload_advance_local[1] && pipe_valid_q[0]) begin
      for (int lane = 0; lane < 16; lane++)
        score_pipe_q[1][lane] <= score_pipe_q[0][lane];
      for (int pair = 0; pair < 8; pair++)
        pair_max_q[pair] <= fp32_max2(score_pipe_q[0][2 * pair],
                                      score_pipe_q[0][2 * pair + 1]);
      valid_mask_pipe_q[1] <= valid_mask_pipe_q[0];
      row_index_pipe_q[1] <= row_index_pipe_q[0];
      txn_pipe_q[1] <= txn_pipe_q[0];
    end

    if (payload_advance_local[2] && pipe_valid_q[1]) begin
      for (int lane = 0; lane < 16; lane++)
        score_pipe_q[2][lane] <= score_pipe_q[1][lane];
      for (int group = 0; group < 4; group++)
        quad_max_q[group] <= fp32_max2(pair_max_q[2 * group],
                                       pair_max_q[2 * group + 1]);
      valid_mask_pipe_q[2] <= valid_mask_pipe_q[1];
      row_index_pipe_q[2] <= row_index_pipe_q[1];
      txn_pipe_q[2] <= txn_pipe_q[1];
    end

    if (payload_advance_local[3] && pipe_valid_q[2]) begin
      for (int lane = 0; lane < 16; lane++)
        score_pipe_q[3][lane] <= score_pipe_q[2][lane];
      for (int group = 0; group < 2; group++)
        oct_max_q[group] <= fp32_max2(quad_max_q[2 * group],
                                      quad_max_q[2 * group + 1]);
      valid_mask_pipe_q[3] <= valid_mask_pipe_q[2];
      row_index_pipe_q[3] <= row_index_pipe_q[2];
      txn_pipe_q[3] <= txn_pipe_q[2];
    end

    if (payload_advance_local[4] && pipe_valid_q[3]) begin
      for (int lane = 0; lane < 16; lane++)
        score_pipe_q[4][lane] <= score_pipe_q[3][lane];
      block_max_q <= fp32_max2(oct_max_q[0], oct_max_q[1]);
      valid_mask_pipe_q[4] <= valid_mask_pipe_q[3];
      row_index_pipe_q[4] <= row_index_pipe_q[3];
      txn_pipe_q[4] <= txn_pipe_q[3];
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && pipeline_advance) begin
      for (int lane = 1; lane < 16; lane++) begin
        if (scaled_valid[lane] != scaled_valid[0])
          $error("V7 score-sidecar multiplier valid lanes diverged");
      end
      if (scaled_valid[0] != mul_valid_q[MUL_STAGES-1])
        $error("V7 score-sidecar scale metadata misaligned");
    end
  end
`endif
endmodule
