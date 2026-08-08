module gqav5_online_softmax_16lane #(
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic [31:0]             score_fp32_i [16],
  input  logic [15:0]             score_valid_mask_i,
  input  logic [31:0]             block_max_fp32_i,
  input  logic [STATE_SLOT_W-1:0] state_slot_i,
  input  logic [3:0]              row_index_i,
  input  logic                    first_context_i,
  input  logic                    last_context_i,
  input  logic [TXN_W-1:0]        txn_id_i,

  output logic                    out_valid_o,
  input  logic                    out_ready_i,
  output logic [15:0]             probability_bf16_o [16],
  output logic [15:0]             probability_valid_mask_o,
  output logic [31:0]             alpha_fp32_o,
  output logic [31:0]             block_sum_fp32_o,
  output logic [31:0]             running_max_fp32_o,
  output logic [31:0]             running_sum_fp32_o,
  output logic [STATE_SLOT_W-1:0] state_slot_o,
  output logic [3:0]              row_index_o,
  output logic                    first_context_o,
  output logic                    last_context_o,
  output logic [TXN_W-1:0]        txn_id_o,

  output logic [4:0]              accepted_exp_cycle_o,
  output logic [63:0]             accepted_exp_total_o,
  output logic [63:0]             score_read_beats_o,
  output logic [63:0]             probability_beats_o,
  output logic [63:0]             state_commit_count_o,
  output logic                    rom_sentinel_ok_o,
  output logic                    protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  localparam int unsigned PIPE_STAGES = 38;
  localparam logic [31:0] FP32_ZERO   = 32'h0000_0000;

  typedef struct packed {
    logic [TXN_W-1:0]        txn_id;
    logic [STATE_SLOT_W-1:0] state_slot;
    logic [3:0]              row_index;
    logic                    first_context;
    logic                    last_context;
    logic [15:0]             lane_mask;
    logic [31:0]             old_max;
    logic [31:0]             old_sum;
    logic [31:0]             new_max;
  } pipe_meta_t;

  typedef struct packed {
    logic [TXN_W-1:0]        txn_id;
    logic [STATE_SLOT_W-1:0] state_slot;
    logic [3:0]              row_index;
    logic                    first_context;
    logic                    last_context;
    logic [15:0]             lane_mask;
    logic [31:0]             block_max;
  } input_meta_t;

  logic        state_valid_q [STATE_SLOTS][16];
  logic        state_busy_q [STATE_SLOTS][16];
  logic [63:0] state_payload_read_q;
  logic        state_write_enable;

  // The synchronous state read is a one-entry input stage.  Only its valid
  // bit resets; metadata, score and RAM payload are stale-data qualified.
  logic        input_stage_valid_q;
  logic        input_state_valid_q;
  input_meta_t input_meta_q;
  logic [31:0] input_score_q [16];

  logic [PIPE_STAGES-1:0] pipe_valid_q;
  pipe_meta_t             meta_q [PIPE_STAGES];

  logic [31:0] score_q [16];
  logic [15:0] probability_q [11:37][16];
  logic [31:0] probability_fp32_q [16];
  logic [31:0] alpha_q [11:37];
  logic [31:0] block_sum_q [32:37];
  logic [31:0] weighted_old_sum_q [15:31];
  logic [31:0] running_sum_q;

  logic [31:0] old_max_w;
  logic [31:0] old_sum_w;
  logic [31:0] new_max_w;
  logic [31:0] neg_new_max_w;
  logic [31:0] difference_w [17];
  logic [31:0] scaled_w [17];
  logic [15:0] exp_bf16_w [17];
  logic [31:0] exp_fp32_w [17];
  logic [31:0] sum_pair_w [8];
  logic [31:0] sum_quad_w [4];
  logic [31:0] sum_oct_w [2];
  logic [31:0] block_sum_w;
  logic [31:0] weighted_old_sum_w;
  logic [31:0] running_sum_w;
  logic [16:0] difference_valid_w;
  logic [16:0] scale_valid_w;
  logic [7:0]  sum_pair_valid_w;
  logic [3:0]  sum_quad_valid_w;
  logic [1:0]  sum_oct_valid_w;
  logic        block_sum_valid_w;
  logic        weighted_old_sum_valid_w;
  logic        running_sum_valid_w;
  logic        advance;
  logic        input_fire;
  logic        output_fire;
  logic        state_hazard;
  logic        advance_meta_local [PIPE_STAGES];
  logic        advance_difference_local [17];
  logic        advance_probability_local [16];
  logic        advance_alpha_local;
  logic        advance_pair_local [8];
  logic        advance_quad_local [4];
  logic        advance_oct_local [2];
  logic        advance_block_local;
  logic        advance_weight_local;
  logic        advance_final_local;
  logic        input_fire_local [16];
  logic        stage0_capture;
  logic        stage0_capture_local [16];

  function automatic logic fp32_is_nan(input logic [30:0] value);
    fp32_is_nan = (value[30:23] == 8'hff) && (value[22:0] != '0);
  endfunction

  function automatic logic [31:0] fp32_max(
    input logic [31:0] lhs,
    input logic [31:0] rhs
  );
    begin
      if (fp32_is_nan(lhs[30:0]) || fp32_is_nan(rhs[30:0])) begin
        fp32_max = 32'h7fc0_0000;
      end else if ((lhs[30:0] == '0) && (rhs[30:0] == '0)) begin
        fp32_max = (lhs[31] && rhs[31]) ? 32'h8000_0000 : FP32_ZERO;
      end else if (lhs[31] != rhs[31]) begin
        fp32_max = lhs[31] ? rhs : lhs;
      end else if (!lhs[31]) begin
        fp32_max = (lhs[30:0] >= rhs[30:0]) ? lhs : rhs;
      end else begin
        fp32_max = (lhs[30:0] <= rhs[30:0]) ? lhs : rhs;
      end
    end
  endfunction

  always_comb begin
    if (input_meta_q.first_context || !input_state_valid_q) begin
      old_max_w = FP32_NEG_INF;
      old_sum_w = FP32_ZERO;
    end else begin
      old_max_w = state_payload_read_q[63:32];
      old_sum_w = state_payload_read_q[31:0];
    end
    new_max_w = fp32_max(old_max_w, input_meta_q.block_max);
  end

  assign state_hazard = state_busy_q[state_slot_i][row_index_i];
  assign advance       = !pipe_valid_q[37] || out_ready_i;
  assign in_ready_o    = advance && !state_hazard;
  assign input_fire    = in_valid_i && in_ready_o;
  assign output_fire   = out_valid_o && out_ready_i;
  assign out_valid_o   = pipe_valid_q[37];
  assign neg_new_max_w = {~meta_q[0].new_max[31], meta_q[0].new_max[30:0]};
  assign state_write_enable = advance && running_sum_valid_w;
  assign stage0_capture = advance && input_stage_valid_q;

  gqav5_softmax_state_store #(
    .STATE_SLOTS(STATE_SLOTS)
  ) i_state_store (
    .clk_i,
    .read_enable_i     (input_fire),
    .read_state_slot_i (state_slot_i),
    .read_row_index_i  (row_index_i),
    .read_payload_o    (state_payload_read_q),
    .write_enable_i    (state_write_enable),
    .write_state_slot_i(meta_q[36].state_slot),
    .write_row_index_i (meta_q[36].row_index),
    .write_payload_i   ({meta_q[36].new_max, running_sum_w})
  );

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_difference
      gqav7_fp32_add_rne_pipe i_difference (
        .clk_i,
        .rst_ni,
        .advance_i(advance_difference_local[lane]),
        .valid_i   (pipe_valid_q[0]),
        .a_fp32_i  (score_q[lane]),
        .b_fp32_i  (neg_new_max_w),
        .valid_o   (difference_valid_w[lane]),
        .sum_fp32_o(difference_w[lane])
      );
    end
    gqav7_fp32_add_rne_pipe i_alpha_difference (
      .clk_i,
      .rst_ni,
      .advance_i(advance_difference_local[16]),
      .valid_i   (pipe_valid_q[0]),
      .a_fp32_i  (meta_q[0].old_max),
      .b_fp32_i  (neg_new_max_w),
      .valid_o   (difference_valid_w[16]),
      .sum_fp32_o(difference_w[16])
    );

    for (genvar lane = 0; lane < 17; lane++) begin : gen_exp2_scale
      gqav7_fp32_mul_rne_pipe i_scale (
        .clk_i,
        .rst_ni,
        .advance_i     (advance_difference_local[lane]),
        .valid_i       (difference_valid_w[lane]),
        .a_fp32_i      (difference_w[lane]),
        .b_fp32_i      (FP32_LOG2_E),
        .valid_o       (scale_valid_w[lane]),
        .product_fp32_o(scaled_w[lane])
      );
    end

    for (genvar lane = 0; lane < 8; lane++) begin : gen_pair_sum
      gqav7_fp32_add_rne_pipe i_pair_sum (
        .clk_i,
        .rst_ni,
        .advance_i(advance_pair_local[lane]),
        .valid_i   (pipe_valid_q[11]),
        .a_fp32_i  (probability_fp32_q[2*lane]),
        .b_fp32_i  (probability_fp32_q[2*lane+1]),
        .valid_o   (sum_pair_valid_w[lane]),
        .sum_fp32_o(sum_pair_w[lane])
      );
    end
    for (genvar lane = 0; lane < 4; lane++) begin : gen_quad_sum
      gqav7_fp32_add_rne_pipe i_quad_sum (
        .clk_i,
        .rst_ni,
        .advance_i(advance_quad_local[lane]),
        .valid_i   (sum_pair_valid_w[2*lane]),
        .a_fp32_i  (sum_pair_w[2*lane]),
        .b_fp32_i  (sum_pair_w[2*lane+1]),
        .valid_o   (sum_quad_valid_w[lane]),
        .sum_fp32_o(sum_quad_w[lane])
      );
    end
    for (genvar lane = 0; lane < 2; lane++) begin : gen_oct_sum
      gqav7_fp32_add_rne_pipe i_oct_sum (
        .clk_i,
        .rst_ni,
        .advance_i(advance_oct_local[lane]),
        .valid_i   (sum_quad_valid_w[2*lane]),
        .a_fp32_i  (sum_quad_w[2*lane]),
        .b_fp32_i  (sum_quad_w[2*lane+1]),
        .valid_o   (sum_oct_valid_w[lane]),
        .sum_fp32_o(sum_oct_w[lane])
      );
    end
  endgenerate

  gqav7_fp32_add_rne_pipe i_block_sum (
    .clk_i,
    .rst_ni,
    .advance_i(advance_block_local),
    .valid_i   (sum_oct_valid_w[0]),
    .a_fp32_i  (sum_oct_w[0]),
    .b_fp32_i  (sum_oct_w[1]),
    .valid_o   (block_sum_valid_w),
    .sum_fp32_o(block_sum_w)
  );

  gqav7_fp32_mul_rne_pipe i_weight_old_sum (
    .clk_i,
    .rst_ni,
    .advance_i     (advance_alpha_local),
    .valid_i       (pipe_valid_q[11]),
    .a_fp32_i      (alpha_q[11]),
    .b_fp32_i      (meta_q[11].old_sum),
    .valid_o       (weighted_old_sum_valid_w),
    .product_fp32_o(weighted_old_sum_w)
  );

  gqav7_fp32_add_rne_pipe i_running_sum (
    .clk_i,
    .rst_ni,
    .advance_i(advance_final_local),
    .valid_i   (block_sum_valid_w),
    .a_fp32_i  (weighted_old_sum_q[31]),
    .b_fp32_i  (block_sum_w),
    .valid_o   (running_sum_valid_w),
    .sum_fp32_o(running_sum_w)
  );

  gqav5_exp2_neg_lut_bank #(.LANES(17)) i_exp2_bank (
    .clk_i,
    .x_fp32_i       (scaled_w),
    .y_bf16_o       (exp_bf16_w),
    .y_fp32_o       (exp_fp32_w),
    .rom_sentinel_ok_o
  );

  always_comb begin
    accepted_exp_cycle_o = input_fire
      ? 5'($countones(score_valid_mask_i)) : 5'd0;
  end

  assign probability_valid_mask_o = meta_q[37].lane_mask;
  assign alpha_fp32_o              = alpha_q[37];
  assign block_sum_fp32_o          = block_sum_q[37];
  assign running_max_fp32_o        = meta_q[37].new_max;
  assign running_sum_fp32_o        = running_sum_q;
  assign state_slot_o              = meta_q[37].state_slot;
  assign row_index_o               = meta_q[37].row_index;
  assign first_context_o           = meta_q[37].first_context;
  assign last_context_o            = meta_q[37].last_context;
  assign txn_id_o                  = meta_q[37].txn_id;

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_probability_output
      assign probability_bf16_o[lane] = probability_q[37][lane];
    end
  endgenerate

  // Keep the inherited V5 lock-step pipeline, but replicate its wide advance
  // enable into physically local LUT1 leaves.  A single unbuffered advance
  // net drives several thousand payload registers and can otherwise be
  // promoted onto a BUFG, which is both semantically wrong and slow.
  generate
    for (genvar stage = 0; stage < PIPE_STAGES; stage++) begin : gen_meta_advance
      gqav5_local_control_buffer i_meta_advance (
        .in_i (advance),
        .out_o(advance_meta_local[stage])
      );
    end
    for (genvar lane = 0; lane < 17; lane++) begin : gen_difference_advance
      gqav5_local_control_buffer i_difference_advance (
        .in_i (advance),
        .out_o(advance_difference_local[lane])
      );
    end
    for (genvar lane = 0; lane < 16; lane++) begin : gen_probability_advance
      gqav5_local_control_buffer i_probability_advance (
        .in_i (advance),
        .out_o(advance_probability_local[lane])
      );
      // These two enables each control one full FP32 lane.  Explicit local
      // leaves prevent their combined LUT outputs from driving more than 500
      // payload flops through the most congested softmax region.
      gqav5_local_control_buffer i_input_fire (
        .in_i (input_fire),
        .out_o(input_fire_local[lane])
      );
      gqav5_local_control_buffer i_stage0_capture (
        .in_i (stage0_capture),
        .out_o(stage0_capture_local[lane])
      );
    end
    gqav5_local_control_buffer i_alpha_advance (
      .in_i (advance),
      .out_o(advance_alpha_local)
    );
    for (genvar lane = 0; lane < 8; lane++) begin : gen_pair_advance
      gqav5_local_control_buffer i_pair_advance (
        .in_i (advance),
        .out_o(advance_pair_local[lane])
      );
    end
    for (genvar lane = 0; lane < 4; lane++) begin : gen_quad_advance
      gqav5_local_control_buffer i_quad_advance (
        .in_i (advance),
        .out_o(advance_quad_local[lane])
      );
    end
    for (genvar lane = 0; lane < 2; lane++) begin : gen_oct_advance
      gqav5_local_control_buffer i_oct_advance (
        .in_i (advance),
        .out_o(advance_oct_local[lane])
      );
    end
    gqav5_local_control_buffer i_block_advance (
      .in_i (advance),
      .out_o(advance_block_local)
    );
    gqav5_local_control_buffer i_weight_advance (
      .in_i (advance),
      .out_o(advance_weight_local)
    );
    gqav5_local_control_buffer i_final_advance (
      .in_i (advance),
      .out_o(advance_final_local)
    );
  endgenerate

  // Capture the request alongside the synchronous m/l RAM read.  The global
  // advance signal moves this stage and the arithmetic pipeline together, so
  // the added BRAM read latency does not reduce the one-row/cycle issue rate.
  always_ff @(posedge clk_i) begin
    if (input_fire) begin
      input_meta_q.txn_id        <= txn_id_i;
      input_meta_q.state_slot    <= state_slot_i;
      input_meta_q.row_index     <= row_index_i;
      input_meta_q.first_context <= first_context_i;
      input_meta_q.last_context  <= last_context_i;
      input_meta_q.lane_mask     <= score_valid_mask_i;
      input_meta_q.block_max     <= block_max_fp32_i;
      input_state_valid_q
        <= state_valid_q[state_slot_i][row_index_i];
    end
    for (int lane = 0; lane < 16; lane++) begin
      if (input_fire_local[lane])
        input_score_q[lane] <= score_fp32_i[lane];
    end
  end

  // All arithmetic/descriptor pipeline payload below is qualified by
  // pipe_valid_q.  It deliberately has no reset network; reset invalidates
  // the pipeline.  Persistent m/l payload lives in the separate state store,
  // while only busy/valid metadata stays in the resettable control process.
  always_ff @(posedge clk_i) begin
    for (int stage = PIPE_STAGES - 1; stage > 0; stage--)
      if (advance_meta_local[stage])
        meta_q[stage] <= meta_q[stage-1];

    if (advance_meta_local[0] && input_stage_valid_q) begin
        meta_q[0].txn_id         <= input_meta_q.txn_id;
        meta_q[0].state_slot     <= input_meta_q.state_slot;
        meta_q[0].row_index      <= input_meta_q.row_index;
        meta_q[0].first_context  <= input_meta_q.first_context;
        meta_q[0].last_context   <= input_meta_q.last_context;
        meta_q[0].lane_mask      <= input_meta_q.lane_mask;
        meta_q[0].old_max        <= old_max_w;
        meta_q[0].old_sum        <= old_sum_w;
        meta_q[0].new_max        <= new_max_w;
    end
    for (int lane = 0; lane < 16; lane++) begin
      if (stage0_capture_local[lane])
        score_q[lane] <= input_score_q[lane];
    end

    for (int lane = 0; lane < 16; lane++) begin
      if (advance_probability_local[lane]) begin
        probability_q[11][lane] <= meta_q[10].lane_mask[lane]
                                    ? exp_bf16_w[lane] : 16'h0000;
        probability_fp32_q[lane] <= meta_q[10].lane_mask[lane]
                                    ? exp_fp32_w[lane] : FP32_ZERO;
        for (int stage = 12; stage <= 37; stage++)
          probability_q[stage][lane] <= probability_q[stage-1][lane];
      end
    end

    if (advance_alpha_local) begin
      alpha_q[11] <= meta_q[10].first_context ? FP32_ZERO : exp_fp32_w[16];
      for (int stage = 12; stage <= 37; stage++)
        alpha_q[stage] <= alpha_q[stage-1];
    end

    if (advance_weight_local) begin
      weighted_old_sum_q[15] <= weighted_old_sum_w;
      for (int stage = 16; stage <= 31; stage++)
        weighted_old_sum_q[stage] <= weighted_old_sum_q[stage-1];
    end

    if (advance_final_local) begin
      block_sum_q[32] <= block_sum_w;
      for (int stage = 33; stage <= 37; stage++)
        block_sum_q[stage] <= block_sum_q[stage-1];
      running_sum_q <= running_sum_w;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      input_stage_valid_q       <= 1'b0;
      pipe_valid_q             <= '0;
      accepted_exp_total_o     <= '0;
      score_read_beats_o       <= '0;
      probability_beats_o      <= '0;
      state_commit_count_o     <= '0;
      protocol_error_o         <= 1'b0;
      for (int slot = 0; slot < STATE_SLOTS; slot++) begin
        for (int row = 0; row < 16; row++) begin
          state_valid_q[slot][row] <= 1'b0;
          state_busy_q[slot][row]  <= 1'b0;
        end
      end
    end else begin
      if (!rom_sentinel_ok_o)
        protocol_error_o <= 1'b1;
      if (input_fire && !first_context_i &&
          !state_valid_q[state_slot_i][row_index_i])
        protocol_error_o <= 1'b1;

      if (output_fire)
        probability_beats_o <= probability_beats_o + 64'd1;

      if (advance) begin
        input_stage_valid_q <= input_fire;
        for (int stage = PIPE_STAGES - 1; stage > 0; stage--) begin
          pipe_valid_q[stage] <= pipe_valid_q[stage-1];
        end
        pipe_valid_q[0] <= input_stage_valid_q;

        if (input_fire) begin
          state_busy_q[state_slot_i][row_index_i] <= 1'b1;
          accepted_exp_total_o <= accepted_exp_total_o +
                                  {{59{1'b0}},
                                   accepted_exp_cycle_o};
          score_read_beats_o <= score_read_beats_o + 64'd1;
        end

        if (running_sum_valid_w) begin
          state_valid_q[meta_q[36].state_slot][meta_q[36].row_index]
            <= 1'b1;
          state_busy_q[meta_q[36].state_slot][meta_q[36].row_index]
            <= 1'b0;
          state_commit_count_o <= state_commit_count_o + 64'd1;
        end
      end
    end
  end

  initial begin
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16))
      $error("online-softmax STATE_SLOTS must be in [1,16]");
    if ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS))
      $error("online-softmax STATE_SLOTS must be a power of two");
    if (TXN_W < 1)
      $error("online-softmax TXN_W must be positive");
  end
endmodule
