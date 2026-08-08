// Production-facing V7 QK adapter.
//
// The legacy production contract presents one 16x16 outer-product reduction
// step at a time.  The V7 physical engine executes four 8x8 micro-operations
// per step and needs eight independent recurrence contexts.  Consecutive
// reduction steps are therefore striped across logical_wave 0/1.  The two
// partial FP32 matrices are added after both waves retire, restoring the
// original 16-lane score-row interface.
module gqav7_qk_partitioned_adapter_16x16 #(
  parameter int unsigned K_STEPS        = 128,
  parameter int unsigned ROW_PARTITIONS = 4,
  parameter int unsigned MERGE_LANES    = 8,
  localparam int unsigned K_W =
      (K_STEPS <= 1) ? 1 : $clog2(K_STEPS),
  localparam int unsigned MERGE_BEATS = 256 / MERGE_LANES,
  localparam int unsigned MERGE_INDEX_W =
      (MERGE_BEATS <= 1) ? 1 : $clog2(MERGE_BEATS)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_i,
  output logic start_ready_o,
  input  logic step_valid_i,
  output logic step_ready_o,
  output logic continuation_step_ready_o,
  input  logic [15:0] a_bf16_i [16],
  input  logic [15:0] b_partition_bf16_i [ROW_PARTITIONS][16],
  input  logic [15:0] row_valid_i,
  input  logic [15:0] col_valid_i,

  output logic active_o,
  output logic done_o,
  output logic result_row_valid_o,
  input  logic result_row_ready_i,
  output logic [31:0] result_row_fp32_o [16],
  output logic [3:0] result_row_index_o,
  output logic result_row_bank_o,
  output logic result_drained_o,
  output logic next_compute_bank_o,
  output logic [8:0] accepted_macs_cycle_o,
  output logic [63:0] accepted_macs_total_o,
  output logic [63:0] completed_tiles_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned ADD_LATENCY = 5;

  logic busy_q;
  logic input_active_q;
  logic [K_W-1:0] step_index_q;
  logic logical_valid;
  logic logical_ready;
  logic logical_accept;
  logic logical_wave;
  logic logical_first;
  logic logical_last;

  logic engine_result_valid;
  logic engine_result_wave;
  logic [3:0] engine_result_row;
  logic [3:0] engine_result_col_base;
  logic [31:0] engine_result_data [8];
  logic engine_result_last;
  logic [63:0] engine_accepted_macs;
  logic engine_error;

  // Payload memories are intentionally reset-free.  Their ownership is
  // qualified by the reset control below, so stale data is never visible.
  logic [31:0] partial_read [2][16];
  logic [31:0] final_read [2][16];

  logic [6:0] captured_beats_q;
  logic merge_issue_active_q;
  logic [MERGE_INDEX_W-1:0] merge_issue_index_q;
  logic merge_valid;
  logic merge_prefetch_fire;
  logic [3:0] merge_row;
  logic [3:0] merge_col_base;
  (* max_fanout = 32 *) logic [3:0] partial_read_row;
  logic merge_operand_valid_q;
  (* max_fanout = 64 *) logic [3:0] merge_operand_row_q;
  (* max_fanout = 64 *) logic [3:0] merge_operand_col_base_q;
  logic [31:0] merge_operand_a_q [MERGE_LANES];
  logic [31:0] merge_operand_b_q [MERGE_LANES];
  logic [31:0] merge_sum [MERGE_LANES];
  logic merge_sum_valid [MERGE_LANES];
  // The final FP32 matrix is a bank of wide distributed state.  Replicate
  // its delayed row/bank address bits during synthesis instead of allowing
  // the placer to promote a data-select bit onto a BUFG with >1000 loads.
  (* max_fanout = 64 *) logic [3:0] merge_row_pipe_q [ADD_LATENCY-1];
  (* max_fanout = 64 *) logic [3:0] merge_col_base_pipe_q [ADD_LATENCY-1];
  logic [5:0] merged_beats_q;

  // The arithmetic/merge path is single-buffered, but completed matrices use
  // the same proven two-bank retirement contract as the V5 QK engine.  This
  // lets the next group start as soon as merge completes while the previous
  // score rows remain backpressured by Softmax/PV.
  logic compute_bank_q;
  logic [1:0] result_bank_ready_q;
  logic result_bank_q;
  logic result_active_q;
  logic [3:0] result_row_q;
  logic result_fire;
  logic start_fire;
  logic merge_completion;
  logic other_result_bank;
  logic next_result_available;

  assign start_ready_o = !busy_q &&
      ((!result_bank_ready_q[compute_bank_q]) ||
       (result_fire && (result_row_q == 4'd15) &&
        (result_bank_q == compute_bank_q)));
  assign logical_valid =
      step_valid_i && (input_active_q || (start_i && start_ready_o));
  assign step_ready_o =
      (input_active_q || (start_i && start_ready_o)) && logical_ready;
  // Once a reduction tile is active, logical_ready is the complete readiness
  // condition for every continuation step.  Export that local term without
  // the launch/result-bank feedback in start_ready_o so the resident frontend
  // can perform a zero-cycle column-15/next-tag handoff on a short path.
  assign continuation_step_ready_o = input_active_q && logical_ready;
  assign logical_accept = logical_valid && logical_ready;
  assign start_fire = start_i && start_ready_o && logical_accept;

  assign logical_wave = step_index_q[0];
  assign logical_first = step_index_q < K_W'(2);
  assign logical_last =
      (step_index_q == K_W'(K_STEPS - 2)) ||
      (step_index_q == K_W'(K_STEPS - 1));

  assign active_o = busy_q;
  assign result_row_valid_o = result_active_q;
  assign result_row_index_o = result_row_q;
  assign result_row_bank_o = result_bank_q;
  assign next_compute_bank_o = compute_bank_q;
  assign result_fire = result_active_q && result_row_ready_i;
  assign merge_completion = merge_sum_valid[0] &&
      (merged_beats_q == 6'(MERGE_BEATS - 1));
  assign other_result_bank = ~result_bank_q;
  assign next_result_available =
      result_bank_ready_q[other_result_bank] ||
      (merge_completion && (compute_bank_q == other_result_bank));

  always_comb begin
    if (logical_accept)
      accepted_macs_cycle_o =
          9'($countones(row_valid_i) * $countones(col_valid_i));
    else
      accepted_macs_cycle_o = '0;
    for (int col = 0; col < 16; col++)
      result_row_fp32_o[col] = final_read[result_bank_q][col];
  end

  gqav7_qk_logical_16x16_dual_group i_qk (
    .clk_i,
    .rst_ni,
    .logical_valid_i(logical_valid),
    .logical_ready_o(logical_ready),
    .logical_tile_context_i('0),
    .logical_wave_i(logical_wave),
    .logical_first_i(logical_first),
    .logical_last_i(logical_last),
    .logical_row_valid_i(row_valid_i),
    .logical_col_valid_i(col_valid_i),
    .q_bf16_i(a_bf16_i),
    .k_group_bf16_i(b_partition_bf16_i),
    .result_valid_o(engine_result_valid),
    .result_ready_i(1'b1),
    .result_tile_context_o(),
    .result_wave_o(engine_result_wave),
    .result_logical_row_o(engine_result_row),
    .result_logical_col_base_o(engine_result_col_base),
    .result_data_o(engine_result_data),
    .result_last_o(engine_result_last),
    .accepted_macs_o(engine_accepted_macs),
    .protocol_error_o(engine_error)
  );

  assign merge_valid = merge_issue_active_q;
  assign merge_prefetch_fire =
      engine_result_valid && (captured_beats_q == 7'd63);
  assign partial_read_row = merge_prefetch_fire ? 4'd0 : merge_row;
  generate
    if (MERGE_LANES == 16) begin : gen_merge_address_16
      assign merge_row = merge_issue_index_q[3:0];
      assign merge_col_base = '0;
    end else begin : gen_merge_address_8
      assign merge_row = merge_issue_index_q[4:1];
      assign merge_col_base = {merge_issue_index_q[0], 3'b000};
    end
  endgenerate

  generate
    for (genvar wave = 0; wave < 2; wave++) begin : gen_partial_wave
      for (genvar lane = 0; lane < 16; lane++) begin : gen_partial_lane_ram
        localparam int unsigned RESULT_LANE = lane % 8;
        localparam logic [3:0] LANE_BASE = (lane < 8) ? 4'd0 : 4'd8;
        (* ram_style = "distributed", rw_addr_collision = "no" *)
        logic [31:0] partial_ram_q [16];

        assign partial_read[wave][lane] =
            partial_ram_q[partial_read_row];

        always_ff @(posedge clk_i) begin
          if (engine_result_valid &&
              (engine_result_wave == wave[0]) &&
              (engine_result_col_base == LANE_BASE))
            partial_ram_q[engine_result_row] <=
                engine_result_data[RESULT_LANE];
        end
      end
    end

    for (genvar lane = 0; lane < MERGE_LANES; lane++) begin : gen_merge_lane
      gqav7_fp32_add_rne_pipe i_merge_add (
        .clk_i,
        .rst_ni,
        .advance_i(1'b1),
        .valid_i(merge_operand_valid_q),
        .a_fp32_i(merge_operand_a_q[lane]),
        .b_fp32_i(merge_operand_b_q[lane]),
        .valid_o(merge_sum_valid[lane]),
        .sum_fp32_o(merge_sum[lane])
      );
    end

    for (genvar bank = 0; bank < 2; bank++) begin : gen_final_bank
      for (genvar lane = 0; lane < 16; lane++) begin : gen_final_lane_ram
        localparam int unsigned RESULT_LANE = lane % MERGE_LANES;
        localparam logic [3:0] LANE_BASE =
            4'(lane - RESULT_LANE);
        (* ram_style = "distributed", rw_addr_collision = "no" *)
        logic [31:0] final_ram_q [16];
        (* keep = "true" *) logic [3:0] final_write_row_q;
        (* keep = "true" *) logic [3:0] final_write_col_base_q;

        assign final_read[bank][lane] = final_ram_q[result_row_q];

        always_ff @(posedge clk_i) begin
          final_write_row_q <= merge_row_pipe_q[ADD_LATENCY-2];
          final_write_col_base_q <=
              merge_col_base_pipe_q[ADD_LATENCY-2];
          if (merge_sum_valid[0] &&
              (compute_bank_q == bank[0]) &&
              (final_write_col_base_q == LANE_BASE))
            final_ram_q[final_write_row_q] <=
                merge_sum[RESULT_LANE];
        end
      end
    end
  endgenerate

  // Wide arithmetic payload writes are kept separate from resettable
  // ownership state to avoid a matrix-wide reset network.
  always_ff @(posedge clk_i) begin : p_payload
    // Match the proven V5.6 payload/meta pipeline pattern: the wide,
    // reset-free operand register terminates the dynamic partial-matrix
    // selection before the FP32 adder while the small valid/meta state is
    // carried independently.  This preserves one merge beat per cycle.
    if (merge_prefetch_fire) begin
      for (int lane = 0; lane < MERGE_LANES; lane++) begin
        merge_operand_a_q[lane] <= partial_read[0][lane];
        merge_operand_b_q[lane] <= partial_read[1][lane];
        // The final engine beat and the fixed row-zero prefetch can target
        // the same partial entry.  Forward that beat so the prefetch is
        // correct without waiting an extra cycle for the array write.
        if ((engine_result_row == 4'd0) &&
            (lane >= engine_result_col_base) &&
            (lane < (engine_result_col_base + 5'd8))) begin
          if (engine_result_wave)
            merge_operand_b_q[lane] <=
                engine_result_data[lane - engine_result_col_base];
          else
            merge_operand_a_q[lane] <=
                engine_result_data[lane - engine_result_col_base];
        end
      end
    end else if (merge_valid) begin
      for (int lane = 0; lane < MERGE_LANES; lane++) begin
        merge_operand_a_q[lane] <=
            partial_read[0][merge_col_base + lane];
        merge_operand_b_q[lane] <=
            partial_read[1][merge_col_base + lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_control
    if (!rst_ni) begin
      busy_q <= 1'b0;
      input_active_q <= 1'b0;
      step_index_q <= '0;
      captured_beats_q <= '0;
      merge_issue_active_q <= 1'b0;
      merge_issue_index_q <= '0;
      merge_operand_valid_q <= 1'b0;
      merge_operand_row_q <= '0;
      merge_operand_col_base_q <= '0;
      merged_beats_q <= '0;
      compute_bank_q <= 1'b0;
      result_bank_ready_q <= '0;
      result_bank_q <= 1'b0;
      result_active_q <= 1'b0;
      result_row_q <= '0;
      accepted_macs_total_o <= '0;
      completed_tiles_o <= '0;
      done_o <= 1'b0;
      result_drained_o <= 1'b0;
      protocol_error_o <= 1'b0;
      for (int stage = 0; stage < ADD_LATENCY-1; stage++) begin
        merge_row_pipe_q[stage] <= '0;
        merge_col_base_pipe_q[stage] <= '0;
      end
    end else begin
      done_o <= 1'b0;
      result_drained_o <= 1'b0;

      merge_operand_valid_q <= merge_prefetch_fire || merge_valid;
      if (merge_prefetch_fire) begin
        merge_operand_row_q <= '0;
        merge_operand_col_base_q <= '0;
      end else if (merge_valid) begin
        merge_operand_row_q <= merge_row;
        merge_operand_col_base_q <= merge_col_base;
      end

      merge_row_pipe_q[0] <= merge_operand_row_q;
      merge_col_base_pipe_q[0] <= merge_operand_col_base_q;
      for (int stage = 1; stage < ADD_LATENCY-1; stage++) begin
        merge_row_pipe_q[stage] <= merge_row_pipe_q[stage-1];
        merge_col_base_pipe_q[stage] <= merge_col_base_pipe_q[stage-1];
      end

      if (!result_active_q) begin
        if (result_bank_ready_q[result_bank_q] ||
            (merge_completion &&
             (compute_bank_q == result_bank_q))) begin
          result_active_q <= 1'b1;
          result_row_q <= '0;
        end
      end else if (result_fire) begin
        if (result_row_q == 4'd15) begin
          result_bank_ready_q[result_bank_q] <= 1'b0;
          result_row_q <= '0;
          result_drained_o <= 1'b1;
          result_bank_q <= other_result_bank;
          result_active_q <= next_result_available;
        end else begin
          result_row_q <= result_row_q + 4'd1;
        end
      end

      if (start_fire) begin
        busy_q <= 1'b1;
        input_active_q <= K_STEPS > 1;
        step_index_q <= K_W'(1);
        captured_beats_q <= '0;
        merged_beats_q <= '0;
      end else if (logical_accept) begin
        if (step_index_q == K_W'(K_STEPS - 1)) begin
          input_active_q <= 1'b0;
          step_index_q <= '0;
        end else begin
          step_index_q <= step_index_q + K_W'(1);
        end
      end

      if (logical_accept)
        accepted_macs_total_o <= accepted_macs_total_o +
                                64'(accepted_macs_cycle_o);

      if (engine_result_valid) begin
        if (captured_beats_q == 7'd63) begin
          captured_beats_q <= '0;
          merge_issue_active_q <= 1'b1;
          // Beat zero was prefetched in this cycle; start the sequential
          // issue stream at beat one on the following cycle.
          merge_issue_index_q <= MERGE_INDEX_W'(1);
        end else begin
          captured_beats_q <= captured_beats_q + 7'd1;
        end
      end

      if (merge_issue_active_q) begin
        if (merge_issue_index_q == MERGE_INDEX_W'(MERGE_BEATS - 1)) begin
          merge_issue_active_q <= 1'b0;
          merge_issue_index_q <= '0;
        end else begin
          merge_issue_index_q <=
              merge_issue_index_q + MERGE_INDEX_W'(1);
        end
      end

      if (merge_sum_valid[0]) begin
        for (int lane = 1; lane < MERGE_LANES; lane++)
          if (merge_sum_valid[lane] != merge_sum_valid[0])
            protocol_error_o <= 1'b1;
        if (merged_beats_q == 6'(MERGE_BEATS - 1)) begin
          merged_beats_q <= '0;
          busy_q <= 1'b0;
          result_bank_ready_q[compute_bank_q] <= 1'b1;
          compute_bank_q <= ~compute_bank_q;
          completed_tiles_o <= completed_tiles_o + 64'd1;
          done_o <= 1'b1;
        end else begin
          merged_beats_q <= merged_beats_q + 6'd1;
        end
      end

      if (start_i && !start_ready_o)
        protocol_error_o <= 1'b1;
      if (start_i && start_ready_o && !step_valid_i)
        protocol_error_o <= 1'b1;
      if (logical_accept && !busy_q && !start_fire)
        protocol_error_o <= 1'b1;
      if (engine_error)
        protocol_error_o <= 1'b1;
    end
  end

  logic unused_engine_status;
  assign unused_engine_status = ^{engine_result_last, engine_accepted_macs};

  initial begin
    if (K_STEPS < 2 || (K_STEPS % 2) != 0)
      $error("V7 QK adapter requires an even K_STEPS >= 2");
    if (ROW_PARTITIONS != 4)
      $error("V7 QK adapter requires four row partitions");
    if ((MERGE_LANES != 8) && (MERGE_LANES != 16))
      $error("V7 QK adapter MERGE_LANES must be 8 or 16");
  end
endmodule
