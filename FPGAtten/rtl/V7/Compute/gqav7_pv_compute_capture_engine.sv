// V7.1 PV single-MAC / multi-context compute-capture engine.
//
// The physical 8x8 MAC array is instantiated exactly once.  Its eight
// recurrence contexts are banked independently of the one MAC array, so
// completed tiles can drain through the shared retirement path while later
// tiles keep progressing.  The tile-context tag is carried all the way
// through the logical scheduler and result stream; external partial matrices
// are therefore capture state, not a substitute for the MAC accumulator
// context.
module gqav7_pv_compute_capture_engine #(
  parameter int unsigned K_STEPS        = 16,
  parameter int unsigned ROW_PARTITIONS = 4,
  // Four capture contexts are deliberately storage-only.  The physical
  // 8x8 MAC remains unique; extra contexts let a sealed result tile wait
  // for merge/drain without consuming the accumulator context needed by
  // the next tile.
  parameter int unsigned TILE_CONTEXTS  = 4,
  localparam int unsigned K_W =
      (K_STEPS <= 1) ? 1 : $clog2(K_STEPS),
  localparam int unsigned TILE_CONTEXT_W =
      (TILE_CONTEXTS <= 1) ? 1 : $clog2(TILE_CONTEXTS)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_i,
  output logic start_ready_o,
  // Meaningful at the start_i/start_ready_o handshake.  The adapter records
  // tile metadata under this same context in the same cycle.
  output logic [TILE_CONTEXT_W-1:0] capture_context_o,
  input  logic step_valid_i,
  output logic step_ready_o,
  input  logic [15:0] a_bf16_i [16],
  input  logic [15:0] b_partition_bf16_i [ROW_PARTITIONS][16],
  input  logic [15:0] row_valid_i,
  input  logic [15:0] col_valid_i,

  output logic active_o,
  output logic capture_valid_o [TILE_CONTEXTS],
  // One-cycle early indication for the final capture beat.  The completed
  // matrix is made valid on the following edge, but row zero was captured
  // long before that final beat and may be safely handed to the shared
  // merger immediately.  This restores the r25 prefetch cadence without
  // adding a second MAC array or a third capture matrix.
  output logic capture_complete_o [TILE_CONTEXTS],
  input  logic capture_release_i [TILE_CONTEXTS],
  input  logic [TILE_CONTEXT_W-1:0] retire_context_i,
  input  logic [3:0] retire_row_i,
  output logic [31:0] retire_partial_a_o [16],
  output logic [31:0] retire_partial_b_o [16],

  output logic [8:0] accepted_macs_cycle_o,
  output logic [63:0] accepted_macs_total_o,
  output logic [63:0] completed_tiles_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic input_active_q;
  logic [TILE_CONTEXT_W-1:0] input_context_q;
  logic [K_W-1:0] step_index_q;
  logic logical_valid;
  logic logical_ready;
  logic logical_accept;
  logic logical_wave;
  logic logical_first;
  logic logical_last;
  logic start_fire;
  logic capture_context_available;
  logic [TILE_CONTEXT_W-1:0] start_context;
  logic [TILE_CONTEXT_W-1:0] logical_tile_context;

  logic engine_result_valid;
  logic [TILE_CONTEXT_W-1:0] engine_result_context;
  logic engine_result_wave;
  logic [3:0] engine_result_row;
  logic [3:0] engine_result_col_base;
  logic [31:0] engine_result_data [8];
  logic engine_result_last;
  logic [63:0] engine_accepted_macs;
  logic engine_error;

  // Ownership begins when a tile starts and ends only when shared retirement
  // has sampled its final row.  It therefore protects both accumulator and
  // captured-result reuse while allowing the other context to compute.
  logic context_owned_q [TILE_CONTEXTS];
  logic [6:0] captured_beats_q [TILE_CONTEXTS];
  logic [31:0] partial_a_context [TILE_CONTEXTS][16];
  logic [31:0] partial_b_context [TILE_CONTEXTS][16];
  logic [31:0] accepted_macs_low_q;
  logic [31:0] accepted_macs_high_q;
  logic accepted_macs_carry_q;
  logic [32:0] accepted_macs_low_sum;
  logic [9:0] protocol_error_q;

  always_comb begin
    capture_context_available = 1'b0;
    start_context = '0;
    // Lowest-free selection is deterministic and keeps the result tags
    // stable for the existing trace tooling.  Ownership includes only the
    // active accumulator/capture lifetime; retirement is independently
    // tracked by capture_valid_o.
    for (int ctx = TILE_CONTEXTS - 1; ctx >= 0; ctx--) begin
      if (!context_owned_q[ctx]) begin
        capture_context_available = 1'b1;
        start_context = TILE_CONTEXT_W'(ctx);
      end
    end
  end
  assign capture_context_o = input_active_q ? input_context_q : start_context;
  assign logical_tile_context =
      input_active_q ? input_context_q : start_context;
  assign start_ready_o = !input_active_q && capture_context_available;
  assign logical_valid =
      step_valid_i && (input_active_q || (start_i && start_ready_o));
  assign step_ready_o =
      (input_active_q || (start_i && start_ready_o)) && logical_ready;
  assign logical_accept = logical_valid && logical_ready;
  assign start_fire = start_i && start_ready_o && logical_accept;

  assign logical_wave = step_index_q[0];
  assign logical_first = step_index_q < K_W'(2);
  assign logical_last =
      (step_index_q == K_W'(K_STEPS - 2)) ||
      (step_index_q == K_W'(K_STEPS - 1));

  always_comb begin
    active_o = input_active_q;
    for (int ctx = 0; ctx < TILE_CONTEXTS; ctx++)
      active_o |= context_owned_q[ctx];
  end
  for (genvar ctx = 0; ctx < TILE_CONTEXTS; ctx++) begin : gen_complete
    assign capture_complete_o[ctx] = engine_result_valid &&
        (engine_result_context == TILE_CONTEXT_W'(ctx)) &&
        (captured_beats_q[ctx] == 7'd63);
  end
  assign accepted_macs_total_o = {
    accepted_macs_high_q, accepted_macs_low_q
  };
  assign accepted_macs_low_sum =
      {1'b0, accepted_macs_low_q} + 33'(accepted_macs_cycle_o);
  assign protocol_error_o = |protocol_error_q;

  always_comb begin
    accepted_macs_cycle_o = '0;
    if (logical_accept)
      accepted_macs_cycle_o =
          9'($countones(row_valid_i) * $countones(col_valid_i));
    for (int lane = 0; lane < 16; lane++) begin
      retire_partial_a_o[lane] = partial_a_context[retire_context_i][lane];
      retire_partial_b_o[lane] = partial_b_context[retire_context_i][lane];
    end
  end

  gqav7_qk_logical_16x16_dual_group #(
    .TILE_CONTEXTS(TILE_CONTEXTS)
  ) i_qk (
    .clk_i,
    .rst_ni,
    .logical_valid_i(logical_valid),
    .logical_ready_o(logical_ready),
    .logical_tile_context_i(logical_tile_context),
    .logical_wave_i(logical_wave),
    .logical_first_i(logical_first),
    .logical_last_i(logical_last),
    .logical_row_valid_i(row_valid_i),
    .logical_col_valid_i(col_valid_i),
    .q_bf16_i(a_bf16_i),
    .k_group_bf16_i(b_partition_bf16_i),
    .result_valid_o(engine_result_valid),
    .result_ready_i(1'b1),
    .result_tile_context_o(engine_result_context),
    .result_wave_o(engine_result_wave),
    .result_logical_row_o(engine_result_row),
    .result_logical_col_base_o(engine_result_col_base),
    .result_data_o(engine_result_data),
    .result_last_o(engine_result_last),
    .accepted_macs_o(engine_accepted_macs),
    .protocol_error_o(engine_error)
  );

  // Payload memories are reset-free.  The owner/valid bits above qualify all
  // visibility, and each context can be read by retirement while the other
  // is being filled by the single physical MAC array.
  for (genvar ctx = 0; ctx < TILE_CONTEXTS; ctx++) begin : gen_context
    for (genvar wave = 0; wave < 2; wave++) begin : gen_partial_wave
      for (genvar lane = 0; lane < 16; lane++) begin : gen_partial_lane_ram
        localparam int unsigned RESULT_LANE = lane % 8;
        localparam logic [3:0] LANE_BASE = (lane < 8) ? 4'd0 : 4'd8;
        (* ram_style = "distributed", rw_addr_collision = "no" *)
        logic [31:0] partial_ram_q [16];

        always_ff @(posedge clk_i) begin
          if (engine_result_valid &&
              (engine_result_context == TILE_CONTEXT_W'(ctx)) &&
              (engine_result_wave == wave[0]) &&
              (engine_result_col_base == LANE_BASE))
            partial_ram_q[engine_result_row] <=
                engine_result_data[RESULT_LANE];
        end

        if (wave == 0) begin : gen_wave_a_read
          assign partial_a_context[ctx][lane] =
              partial_ram_q[retire_row_i];
        end else begin : gen_wave_b_read
          assign partial_b_context[ctx][lane] =
              partial_ram_q[retire_row_i];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      input_active_q        <= 1'b0;
      input_context_q       <= 1'b0;
      step_index_q          <= '0;
      for (int ctx = 0; ctx < TILE_CONTEXTS; ctx++) begin
        context_owned_q[ctx] <= 1'b0;
        capture_valid_o[ctx] <= 1'b0;
        captured_beats_q[ctx] <= '0;
      end
      accepted_macs_low_q   <= '0;
      accepted_macs_high_q  <= '0;
      accepted_macs_carry_q <= 1'b0;
      completed_tiles_o     <= '0;
      protocol_error_q      <= '0;
    end else begin
      if (start_fire) begin
        input_active_q <= K_STEPS > 1;
        input_context_q <= start_context;
        step_index_q <= K_W'(1);
        context_owned_q[start_context] <= 1'b1;
        capture_valid_o[start_context] <= 1'b0;
        captured_beats_q[start_context] <= '0;
      end else if (logical_accept && input_active_q) begin
        if (step_index_q == K_W'(K_STEPS - 1)) begin
          input_active_q <= 1'b0;
          step_index_q <= '0;
        end else begin
          step_index_q <= step_index_q + K_W'(1);
        end
      end

      accepted_macs_carry_q <= 1'b0;
      if (accepted_macs_carry_q)
        accepted_macs_high_q <= accepted_macs_high_q + 32'd1;
      if (logical_accept) begin
        accepted_macs_low_q <= accepted_macs_low_sum[31:0];
        accepted_macs_carry_q <= accepted_macs_low_sum[32];
      end

      for (int ctx = 0; ctx < TILE_CONTEXTS; ctx++) begin
        if (capture_release_i[ctx]) begin
          capture_valid_o[ctx] <= 1'b0;
          context_owned_q[ctx] <= 1'b0;
          captured_beats_q[ctx] <= '0;
        end
      end

      if (engine_result_valid) begin
        if (captured_beats_q[engine_result_context] == 7'd63) begin
          captured_beats_q[engine_result_context] <= '0;
          capture_valid_o[engine_result_context] <= 1'b1;
          completed_tiles_o <= completed_tiles_o + 64'd1;
        end else begin
          captured_beats_q[engine_result_context] <=
              captured_beats_q[engine_result_context] + 7'd1;
        end
      end

      if (start_i && !start_ready_o)
        protocol_error_q[0] <= 1'b1;
      if (start_i && start_ready_o && !step_valid_i)
        protocol_error_q[1] <= 1'b1;
      if (logical_accept && !input_active_q && !start_fire)
        protocol_error_q[2] <= 1'b1;
      for (int ctx = 0; ctx < TILE_CONTEXTS; ctx++) begin
        if (capture_release_i[ctx] && !capture_valid_o[ctx])
          protocol_error_q[3 + ctx] <= 1'b1;
      end
      if (engine_result_valid && !context_owned_q[engine_result_context])
        protocol_error_q[7] <= 1'b1;
      if (engine_result_valid &&
          (captured_beats_q[engine_result_context] == 7'd63) &&
          capture_valid_o[engine_result_context])
        protocol_error_q[8] <= 1'b1;
      if (engine_error)
        protocol_error_q[9] <= 1'b1;
    end
  end

  initial begin
    if (K_STEPS < 2 || (K_STEPS % 2) != 0)
      $error("V7.1 PV compute/capture requires an even K_STEPS >= 2");
    if (TILE_CONTEXTS < 2 ||
        ((TILE_CONTEXTS & (TILE_CONTEXTS - 1)) != 0))
      $error("V7.1 PV compute/capture TILE_CONTEXTS must be a power of two >= 2");
    if (ROW_PARTITIONS != 4)
      $error("V7.1 PV compute/capture requires four row partitions");
  end

  logic unused_engine_status;
  assign unused_engine_status = ^{engine_result_last, engine_accepted_macs};
endmodule
