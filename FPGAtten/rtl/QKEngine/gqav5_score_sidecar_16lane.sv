module gqav5_score_sidecar_16lane #(
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

  logic [31:0] scaled_product [16];
  logic [31:0] computed_score [16];
  logic [15:0] computed_valid_mask;

  // A rigid five-register elastic pipeline keeps one-row-per-cycle
  // throughput while cutting the former scale-plus-16-way-serial-max path
  // into a scale stage and four balanced compare stages.  Explicitly keep
  // the delayed score payload in FFs: spending a few thousand local FFs is
  // preferable to rebuilding these wide delays as LUT-based SRLs.
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

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_scale
      gqav5_fp32_mul_rne i_scale (
        .a_fp32_i      (score_fp32_i[lane]),
        .b_fp32_i      (scale_fp32_i),
        .product_fp32_o(scaled_product[lane])
      );
    end
  endgenerate

  always_comb begin
    for (int unsigned lane = 0; lane < 16; lane++) begin
      computed_valid_mask[lane] = !((5'(lane) >= context_valid_cols_i) ||
          (causal_i && ((context_base_i + 32'(lane)) > query_index_i)));
      if (!computed_valid_mask[lane])
        computed_score[lane] = 32'hff80_0000;
      else
        computed_score[lane] = scaled_product[lane];
    end
  end

  // Backpressure freezes the whole short pipe.  Once the output can advance,
  // every occupied stage moves together and the input can accept one row.
  assign pipeline_advance = !pipe_valid_q[4] || out_ready_i;
  assign in_ready_o  = pipeline_advance;
  assign out_valid_o = pipe_valid_q[4];
  assign score_valid_mask_o = valid_mask_pipe_q[4];
  assign block_max_o = block_max_q;
  assign row_index_o = row_index_pipe_q[4];
  assign txn_id_o    = txn_pipe_q[4];

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_output
      assign scaled_masked_score_o[lane] = score_pipe_q[4][lane];
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      pipe_valid_q <= '0;
    else if (pipeline_advance) begin
      pipe_valid_q[0] <= in_valid_i;
      for (int unsigned stage = 1; stage < 5; stage++)
        pipe_valid_q[stage] <= pipe_valid_q[stage - 1];
    end
  end

  // All wide payload and tree registers are qualified by pipe_valid_q.
  // Physical contract: keep the wide sidecar datapath off the asynchronous reset tree.
  // Only valid state is reset.  This limits reset fanout and permits dense
  // local FF packing around the arithmetic.
  always_ff @(posedge clk_i) begin
    if (pipeline_advance) begin
      if (in_valid_i) begin
        for (int unsigned lane = 0; lane < 16; lane++)
          score_pipe_q[0][lane] <= computed_score[lane];
        valid_mask_pipe_q[0] <= computed_valid_mask;
        row_index_pipe_q[0] <= row_index_i;
        txn_pipe_q[0] <= txn_id_i;
      end

      if (pipe_valid_q[0]) begin
        for (int unsigned lane = 0; lane < 16; lane++)
          score_pipe_q[1][lane] <= score_pipe_q[0][lane];
        for (int unsigned pair = 0; pair < 8; pair++)
          pair_max_q[pair] <= fp32_max2(score_pipe_q[0][2 * pair],
                                        score_pipe_q[0][2 * pair + 1]);
        valid_mask_pipe_q[1] <= valid_mask_pipe_q[0];
        row_index_pipe_q[1] <= row_index_pipe_q[0];
        txn_pipe_q[1] <= txn_pipe_q[0];
      end

      if (pipe_valid_q[1]) begin
        for (int unsigned lane = 0; lane < 16; lane++)
          score_pipe_q[2][lane] <= score_pipe_q[1][lane];
        for (int unsigned group = 0; group < 4; group++)
          quad_max_q[group] <= fp32_max2(pair_max_q[2 * group],
                                         pair_max_q[2 * group + 1]);
        valid_mask_pipe_q[2] <= valid_mask_pipe_q[1];
        row_index_pipe_q[2] <= row_index_pipe_q[1];
        txn_pipe_q[2] <= txn_pipe_q[1];
      end

      if (pipe_valid_q[2]) begin
        for (int unsigned lane = 0; lane < 16; lane++)
          score_pipe_q[3][lane] <= score_pipe_q[2][lane];
        for (int unsigned group = 0; group < 2; group++)
          oct_max_q[group] <= fp32_max2(quad_max_q[2 * group],
                                        quad_max_q[2 * group + 1]);
        valid_mask_pipe_q[3] <= valid_mask_pipe_q[2];
        row_index_pipe_q[3] <= row_index_pipe_q[2];
        txn_pipe_q[3] <= txn_pipe_q[2];
      end

      if (pipe_valid_q[3]) begin
        for (int unsigned lane = 0; lane < 16; lane++)
          score_pipe_q[4][lane] <= score_pipe_q[3][lane];
        block_max_q <= fp32_max2(oct_max_q[0], oct_max_q[1]);
        valid_mask_pipe_q[4] <= valid_mask_pipe_q[3];
        row_index_pipe_q[4] <= row_index_pipe_q[3];
        txn_pipe_q[4] <= txn_pipe_q[3];
      end
    end
  end
endmodule
