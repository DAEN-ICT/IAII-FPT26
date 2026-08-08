// V7.2 logical-8x8 PV adapter.
//
// One physical 8x8 MAC array is shared by four storage-only capture contexts.
// A 16-column score block is represented by two independent 16x8 P banks;
// each bank drives an eight-step PV wave.  The physical four-quadrant
// scheduler is unchanged, so every wave still computes four interleaved
// logical 8x8 output tiles.  Retirement and drain are eight lanes wide and
// run concurrently with the next compute wave.
module gqav72_pv_partitioned_adapter_8x8_decoupled #(
  parameter int unsigned OUTPUT_TILES     = 8,
  parameter int unsigned ROW_PARTITIONS  = 4,
  parameter int unsigned CAPTURE_CONTEXTS = 4,
  localparam int unsigned OUTPUT_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES),
  localparam int unsigned LOGICAL_OUTPUT_TILES = OUTPUT_TILES * 2,
  localparam int unsigned LOGICAL_OUTPUT_W =
      (LOGICAL_OUTPUT_TILES <= 1) ? 1 : $clog2(LOGICAL_OUTPUT_TILES),
  localparam int unsigned CAPTURE_CONTEXT_W =
      (CAPTURE_CONTEXTS <= 1) ? 1 : $clog2(CAPTURE_CONTEXTS),
  localparam int unsigned P_RETIRE_COUNT_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic p_pair_valid_i,
  output logic p_pair_ready_o,
  input  logic p_set_i,
  input  logic [3:0] p_row_index_i,
  input  logic [15:0] p_low_bf16_i [8],
  input  logic [15:0] p_high_bf16_i [8],
  output logic p_loaded_o [2][2],
  input  logic p_discard_valid_i,
  input  logic p_discard_set_i,

  input  logic output_start_i,
  output logic output_start_ready_o,
  input  logic output_set_i,
  input  logic output_context_half_i,
  input  logic [OUTPUT_W-1:0] output_tile_i,
  input  logic v_step_valid_i,
  output logic v_step_ready_o,
  input  logic [15:0] v_partition_bf16_i [ROW_PARTITIONS][16],
  input  logic [15:0] row_valid_i,
  input  logic [15:0] col_valid_i,

  output logic active_o,
  output logic output_done_o,
  output logic partial_row_valid_o,
  input  logic partial_row_ready_i,
  output logic [31:0] partial_row_fp32_o [8],
  output logic [3:0] partial_row_index_o,
  output logic [LOGICAL_OUTPUT_W-1:0] partial_row_output_tile_o,
  output logic partial_row_context_half_o,
  output logic partial_row_set_o,
  output logic partial_row_bank_o,
  output logic partial_drained_o,
  output logic [8:0] accepted_macs_cycle_o,
  output logic [63:0] accepted_macs_total_o,
  output logic [63:0] p_load_count_o,
  output logic [63:0] v_output_wave_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned K_STEPS = 16;
  localparam int unsigned ADD_LATENCY = 5;

  logic [15:0] p_tile_q [4][16][8];
  logic [3:0] p_bank_valid_q;
  logic [1:0] p_set_loading_q;
  logic [3:0] p_expected_row_q [2];
  logic [P_RETIRE_COUNT_W-1:0] p_retired_tiles_q [4];
  logic [1:0] p_start_bank;
  logic p_pair_fire;
  logic p_start_bank_busy;

  logic [3:0] v_step_index_q;
  logic input_active_q;
  logic [1:0] active_wave_p_bank_q;
  logic [OUTPUT_W-1:0] active_wave_output_tile_q;
  logic active_wave_set_q;
  logic active_wave_context_half_q;
  logic [15:0] selected_p_column [16];

  logic [1:0] input_fifo_count_q;
  logic input_fifo_head_q;
  logic input_fifo_tail_q;
  logic input_fifo_start_q [2];
  logic input_fifo_engine_q [2];
  logic [1:0] input_fifo_p_bank_q [2];
  logic [OUTPUT_W-1:0] input_fifo_output_tile_q [2];
  logic input_fifo_set_q [2];
  logic input_fifo_context_half_q [2];
  logic [15:0] input_fifo_p_column_q [2][16];
  logic [15:0] input_fifo_v_partition_q [2][ROW_PARTITIONS][16];
  logic [15:0] input_fifo_row_valid_q [2];
  logic [15:0] input_fifo_col_valid_q [2];
  logic input_fifo_valid;
  logic input_fifo_space;
  logic input_fifo_push;
  logic input_fifo_pop;
  (* max_fanout = 64 *) logic [1:0] input_fifo_write_enable;

  logic inner_start [2];
  logic inner_start_ready [2];
  logic inner_step_valid [2];
  logic inner_step_ready [2];
  logic inner_active [CAPTURE_CONTEXTS];
  logic inner_capture_valid [CAPTURE_CONTEXTS];
  logic inner_capture_complete [CAPTURE_CONTEXTS];
  logic inner_capture_release [CAPTURE_CONTEXTS];
  logic inner_compute_active;
  logic [CAPTURE_CONTEXT_W-1:0] inner_capture_context;
  logic [31:0] inner_partial_a [16];
  logic [31:0] inner_partial_b [16];
  logic [8:0] inner_accepted_macs_cycle;
  logic [63:0] inner_accepted_macs;
  logic [63:0] inner_completed_tiles;
  logic inner_error;

  logic [OUTPUT_W-1:0] capture_output_tile_q [CAPTURE_CONTEXTS];
  logic [OUTPUT_W-1:0] active_output_tile_q [CAPTURE_CONTEXTS];
  logic [1:0] capture_p_bank_q [CAPTURE_CONTEXTS];
  logic capture_set_q [CAPTURE_CONTEXTS];
  logic capture_context_half_q [CAPTURE_CONTEXTS];

  logic [31:0] merge_operand_a_q [8];
  logic [31:0] merge_operand_b_q [8];
  logic merge_operand_valid_q;
  logic [CAPTURE_CONTEXT_W-1:0] merge_operand_context_q;
  logic [4:0] merge_operand_address_q;
  logic [31:0] merge_sum [8];
  logic merge_sum_valid [8];
  logic [CAPTURE_CONTEXT_W-1:0] merge_context_pipe_q [ADD_LATENCY];
  logic merge_final_bank_pipe_q [ADD_LATENCY];
  logic [4:0] merge_address_pipe_q [ADD_LATENCY-1];

  logic retire_busy_q;
  logic retire_issue_active_q;
  logic [CAPTURE_CONTEXT_W-1:0] retire_context_q;
  logic retire_final_bank_q;
  logic [4:0] retire_issue_address_q;
  logic [5:0] retired_beats_q;
  logic [OUTPUT_W-1:0] retire_output_tile_q;
  logic [1:0] retire_p_bank_q;
  logic retire_set_q;
  logic retire_context_half_q;
  logic retire_eligible [CAPTURE_CONTEXTS];
  logic [CAPTURE_CONTEXT_W-1:0] retire_select_context;
  logic retire_any_eligible;
  logic retire_final_bank_available;
  logic retire_select_final_bank;
  logic retire_start;
  (* max_fanout = 64 *) logic retire_issue;
  logic [CAPTURE_CONTEXT_W-1:0] retire_source_context;
  logic [4:0] retire_source_address;
  logic [3:0] retire_source_row;
  logic retire_source_col_half;

  logic [31:0] final_bank_read [2][8];
  // A bank becomes owned at retirement start, but it may be drained as soon
  // as its first merged beat is written.  Keeping separate write and read
  // positions removes the former 32-cycle "fill, then drain" bubble while
  // retaining two complete banks for downstream backpressure absorption.
  logic [1:0] final_bank_full_q;
  logic [4:0] final_address_q [2];
  logic [5:0] final_write_count_q [2];
  logic [OUTPUT_W-1:0] final_output_tile_q [2];
  logic final_set_q [2];
  logic final_context_half_q [2];
  logic [1:0] final_p_bank_q [2];
  logic drain_bank;
  logic partial_row_fire;

  logic output_start_fire;
  logic v_step_fire;
  logic any_inner_active;
  logic p_bank_busy [4];
  logic [1:0] selected_wave_p_bank;
  logic [OUTPUT_W-1:0] selected_wave_output_tile;
  logic selected_wave_set;
  logic selected_wave_context_half;
  logic [3:0] selected_wave_step;
  logic [OUTPUT_W-1:0] output_tile_index_q;
  logic [CAPTURE_CONTEXT_W-1:0] retire_select_engine;
  logic [4:0] retired_rows_q;
  logic [3:0] final_row_q [2];
  logic drain_engine;

  assign p_start_bank = {output_set_i, output_context_half_i};
  assign selected_wave_p_bank = input_active_q ? active_wave_p_bank_q
                                                : p_start_bank;
  assign selected_wave_output_tile = input_active_q
      ? active_wave_output_tile_q : output_tile_i;
  assign selected_wave_set = input_active_q ? active_wave_set_q
                                             : output_set_i;
  assign selected_wave_context_half = input_active_q
      ? active_wave_context_half_q : output_context_half_i;
  assign selected_wave_step = input_active_q ? v_step_index_q : 4'd0;

  always_comb begin
    for (int bank = 0; bank < 4; bank++) begin
      p_bank_busy[bank] = 1'b0;
      for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++) begin
        if ((inner_capture_valid[ctx] ||
             (inner_compute_active &&
              (inner_capture_context == CAPTURE_CONTEXT_W'(ctx)))) &&
            (capture_p_bank_q[ctx] == 2'(bank)))
          p_bank_busy[bank] = 1'b1;
      end
      if (input_active_q && (active_wave_p_bank_q == 2'(bank)))
        p_bank_busy[bank] = 1'b1;
      if (retire_busy_q && (retire_p_bank_q == 2'(bank)))
        p_bank_busy[bank] = 1'b1;
      for (int final_bank = 0; final_bank < 2; final_bank++) begin
        if (final_bank_full_q[final_bank] &&
            (final_p_bank_q[final_bank] == 2'(bank)))
          p_bank_busy[bank] = 1'b1;
      end
    end
    p_start_bank_busy = p_bank_busy[p_start_bank];
    for (int set = 0; set < 2; set++)
      for (int half = 0; half < 2; half++)
        p_loaded_o[set][half] = p_bank_valid_q[{set[0], half[0]}];
  end

  assign p_pair_ready_o = p_set_loading_q[p_set_i] ||
      ((!p_bank_valid_q[{p_set_i, 1'b0}]) &&
       (!p_bank_valid_q[{p_set_i, 1'b1}]) &&
       (!p_bank_busy[{p_set_i, 1'b0}]) &&
       (!p_bank_busy[{p_set_i, 1'b1}]));
  assign p_pair_fire = p_pair_valid_i && p_pair_ready_o;

  assign input_fifo_valid = input_fifo_count_q != 0;
  assign input_fifo_space = input_fifo_count_q != 2;
  // P is read-only after load.  Completed compute contexts retain only their
  // captured FP32 matrices, so later output tiles may immediately reuse the
  // same P bank while earlier tiles merge or drain.
  assign output_start_ready_o =
      p_bank_valid_q[{output_set_i, 1'b0}] &&
      p_bank_valid_q[{output_set_i, 1'b1}] &&
      !input_active_q && input_fifo_space;
  assign output_start_fire = output_start_i && output_start_ready_o &&
      v_step_valid_i && v_step_ready_o;
  assign v_step_ready_o = input_fifo_space &&
      (input_active_q || (output_start_i && output_start_ready_o));
  assign v_step_fire = v_step_valid_i && v_step_ready_o;
  assign input_fifo_push = v_step_fire;
  assign input_fifo_pop = input_fifo_valid && inner_step_ready[0];
  assign input_fifo_write_enable[0] = input_fifo_push && !input_fifo_tail_q;
  assign input_fifo_write_enable[1] = input_fifo_push && input_fifo_tail_q;

  assign inner_start[0] = input_fifo_valid &&
      input_fifo_start_q[input_fifo_head_q] && inner_start_ready[0];
  assign inner_step_valid[0] = input_fifo_valid &&
      (!input_fifo_start_q[input_fifo_head_q] || inner_start_ready[0]);
  assign inner_start[1] = 1'b0;
  assign inner_step_valid[1] = 1'b0;
  assign inner_start_ready[1] = 1'b0;
  assign inner_step_ready[1] = 1'b0;
  assign input_fifo_engine_q[0] = 1'b0;
  assign input_fifo_engine_q[1] = 1'b0;
  assign output_tile_index_q = active_wave_output_tile_q;
  assign retire_select_engine = retire_select_context;
  assign retired_rows_q = retired_beats_q[5:1];
  assign final_row_q[0] = final_address_q[0][4:1];
  assign final_row_q[1] = final_address_q[1][4:1];
  assign drain_engine = drain_bank;
  for (genvar compat_ctx = 0; compat_ctx < CAPTURE_CONTEXTS;
       compat_ctx++) begin : gen_compat_tile_probe
    assign active_output_tile_q[compat_ctx] =
        capture_output_tile_q[compat_ctx];
  end

  always_comb begin
    any_inner_active = inner_compute_active;
    for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++) begin
      inner_active[ctx] = inner_capture_valid[ctx] ||
          (inner_compute_active &&
           (inner_capture_context == CAPTURE_CONTEXT_W'(ctx)));
      any_inner_active |= inner_active[ctx];
    end
  end

  always_comb begin
    retire_any_eligible = 1'b0;
    retire_select_context = '0;
    for (int ctx = CAPTURE_CONTEXTS - 1; ctx >= 0; ctx--) begin
      retire_eligible[ctx] = inner_capture_valid[ctx] ||
                             inner_capture_complete[ctx];
      if (retire_eligible[ctx]) begin
        retire_any_eligible = 1'b1;
        retire_select_context = CAPTURE_CONTEXT_W'(ctx);
      end
    end
    retire_final_bank_available = !final_bank_full_q[0] ||
                                  !final_bank_full_q[1];
    retire_select_final_bank = final_bank_full_q[0];
  end
  assign retire_start = !retire_busy_q && retire_any_eligible &&
                        retire_final_bank_available;
  assign retire_issue = retire_start || retire_issue_active_q;
  assign retire_source_context = retire_start ? retire_select_context
                                               : retire_context_q;
  assign retire_source_address = retire_start ? 5'd0
                                               : retire_issue_address_q;
  assign retire_source_row = retire_source_address[4:1];
  assign retire_source_col_half = retire_source_address[0];

  always_comb begin
    for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++)
      inner_capture_release[ctx] = 1'b0;
    if (retire_issue && (retire_source_address == 5'd31))
      inner_capture_release[retire_source_context] = 1'b1;
  end

  assign drain_bank = (final_bank_full_q[0] &&
                       (6'(final_address_q[0]) < final_write_count_q[0]))
      ? 1'b0 : 1'b1;
  assign partial_row_valid_o =
      (final_bank_full_q[0] &&
       (6'(final_address_q[0]) < final_write_count_q[0])) ||
      (final_bank_full_q[1] &&
       (6'(final_address_q[1]) < final_write_count_q[1]));
  assign partial_row_index_o = final_address_q[drain_bank][4:1];
  assign partial_row_output_tile_o =
      {final_output_tile_q[drain_bank], final_address_q[drain_bank][0]};
  assign partial_row_context_half_o = final_context_half_q[drain_bank];
  assign partial_row_set_o = final_set_q[drain_bank];
  assign partial_row_bank_o = drain_bank;
  assign partial_row_fire = partial_row_valid_o && partial_row_ready_i;

  assign active_o = input_active_q || input_fifo_valid || any_inner_active ||
      retire_busy_q || final_bank_full_q[0] || final_bank_full_q[1];
  assign accepted_macs_cycle_o = inner_accepted_macs_cycle;
  assign accepted_macs_total_o = inner_accepted_macs;

  always_comb begin
    for (int row = 0; row < 16; row++)
      selected_p_column[row] =
          p_tile_q[{selected_wave_set, selected_wave_step[3]}]
                  [row][selected_wave_step[2:0]];
    for (int lane = 0; lane < 8; lane++)
      partial_row_fp32_o[lane] = final_bank_read[drain_bank][lane];
  end

  gqav7_pv_compute_capture_engine #(
    .K_STEPS(K_STEPS),
    .ROW_PARTITIONS(ROW_PARTITIONS),
    .TILE_CONTEXTS(CAPTURE_CONTEXTS)
  ) i_compute_capture (
    .clk_i,
    .rst_ni,
    .start_i(inner_start[0]),
    .start_ready_o(inner_start_ready[0]),
    .capture_context_o(inner_capture_context),
    .step_valid_i(inner_step_valid[0]),
    .step_ready_o(inner_step_ready[0]),
    .a_bf16_i(input_fifo_p_column_q[input_fifo_head_q]),
    .b_partition_bf16_i(input_fifo_v_partition_q[input_fifo_head_q]),
    .row_valid_i(input_fifo_row_valid_q[input_fifo_head_q]),
    .col_valid_i(input_fifo_col_valid_q[input_fifo_head_q]),
    .active_o(inner_compute_active),
    .capture_valid_o(inner_capture_valid),
    .capture_complete_o(inner_capture_complete),
    .capture_release_i(inner_capture_release),
    .retire_context_i(retire_source_context),
    .retire_row_i(retire_source_row),
    .retire_partial_a_o(inner_partial_a),
    .retire_partial_b_o(inner_partial_b),
    .accepted_macs_cycle_o(inner_accepted_macs_cycle),
    .accepted_macs_total_o(inner_accepted_macs),
    .completed_tiles_o(inner_completed_tiles),
    .protocol_error_o(inner_error)
  );

  for (genvar lane = 0; lane < 8; lane++) begin : gen_merge_lane
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

  // Wide payload storage remains reset-free and is always qualified by the
  // ownership/valid state in the control process.
  always_ff @(posedge clk_i) begin : p_payload
    if (p_pair_fire) begin
      for (int lane = 0; lane < 8; lane++)
        begin
          p_tile_q[{p_set_i, 1'b0}][p_row_index_i][lane]
              <= p_low_bf16_i[lane];
          p_tile_q[{p_set_i, 1'b1}][p_row_index_i][lane]
              <= p_high_bf16_i[lane];
        end
    end

    for (int slot = 0; slot < 2; slot++) begin
      if (input_fifo_write_enable[slot]) begin
        input_fifo_start_q[slot] <= output_start_fire;
        input_fifo_p_bank_q[slot] <= selected_wave_p_bank;
        input_fifo_output_tile_q[slot] <= selected_wave_output_tile;
        input_fifo_set_q[slot] <= selected_wave_set;
        input_fifo_context_half_q[slot] <= selected_wave_context_half;
        input_fifo_row_valid_q[slot] <= row_valid_i;
        input_fifo_col_valid_q[slot] <= col_valid_i;
        for (int row = 0; row < 16; row++)
          input_fifo_p_column_q[slot][row] <= selected_p_column[row];
        for (int part = 0; part < ROW_PARTITIONS; part++)
          for (int lane = 0; lane < 16; lane++)
            input_fifo_v_partition_q[slot][part][lane] <=
                v_partition_bf16_i[part][lane];
      end
    end

    if (retire_issue) begin
      for (int lane = 0; lane < 8; lane++) begin
        merge_operand_a_q[lane] <=
            inner_partial_a[{retire_source_col_half, 3'(lane)}];
        merge_operand_b_q[lane] <=
            inner_partial_b[{retire_source_col_half, 3'(lane)}];
      end
    end
  end

  for (genvar bank = 0; bank < 2; bank++) begin : gen_final_bank
    for (genvar lane = 0; lane < 8; lane++) begin : gen_final_lane
      (* ram_style = "distributed", rw_addr_collision = "no" *)
      logic [31:0] final_ram_q [32];
      (* keep = "true" *) logic [4:0] final_write_address_q;

      assign final_bank_read[bank][lane] =
          final_ram_q[final_address_q[bank]];

      always_ff @(posedge clk_i) begin
        final_write_address_q <= merge_address_pipe_q[ADD_LATENCY-2];
        if (merge_sum_valid[0] &&
            (merge_final_bank_pipe_q[ADD_LATENCY-1] == bank[0]))
          final_ram_q[final_write_address_q] <= merge_sum[lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_control
    if (!rst_ni) begin
      p_bank_valid_q <= '0;
      p_set_loading_q <= '0;
      for (int set = 0; set < 2; set++)
        p_expected_row_q[set] <= '0;
      for (int bank = 0; bank < 4; bank++) begin
        p_retired_tiles_q[bank] <= '0;
      end
      v_step_index_q <= '0;
      input_active_q <= 1'b0;
      active_wave_p_bank_q <= '0;
      active_wave_output_tile_q <= '0;
      active_wave_set_q <= 1'b0;
      active_wave_context_half_q <= 1'b0;
      input_fifo_count_q <= '0;
      input_fifo_head_q <= 1'b0;
      input_fifo_tail_q <= 1'b0;
      for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++) begin
        capture_output_tile_q[ctx] <= '0;
        capture_p_bank_q[ctx] <= '0;
        capture_set_q[ctx] <= 1'b0;
        capture_context_half_q[ctx] <= 1'b0;
      end
      retire_busy_q <= 1'b0;
      retire_issue_active_q <= 1'b0;
      retire_context_q <= '0;
      retire_final_bank_q <= 1'b0;
      retire_issue_address_q <= '0;
      retired_beats_q <= '0;
      retire_output_tile_q <= '0;
      retire_p_bank_q <= '0;
      retire_set_q <= 1'b0;
      retire_context_half_q <= 1'b0;
      merge_operand_valid_q <= 1'b0;
      merge_operand_context_q <= '0;
      merge_operand_address_q <= '0;
      final_bank_full_q <= '0;
      for (int bank = 0; bank < 2; bank++) begin
        final_address_q[bank] <= '0;
        final_write_count_q[bank] <= '0;
        final_output_tile_q[bank] <= '0;
        final_set_q[bank] <= 1'b0;
        final_context_half_q[bank] <= 1'b0;
        final_p_bank_q[bank] <= '0;
      end
      output_done_o <= 1'b0;
      partial_drained_o <= 1'b0;
      p_load_count_o <= '0;
      v_output_wave_count_o <= '0;
      protocol_error_o <= 1'b0;
      for (int stage = 0; stage < ADD_LATENCY; stage++) begin
        merge_context_pipe_q[stage] <= '0;
        merge_final_bank_pipe_q[stage] <= 1'b0;
      end
      for (int stage = 0; stage < ADD_LATENCY-1; stage++)
        merge_address_pipe_q[stage] <= '0;
    end else begin
      output_done_o <= 1'b0;
      partial_drained_o <= 1'b0;

      if (p_pair_fire) begin
        if (!p_set_loading_q[p_set_i]) begin
          p_set_loading_q[p_set_i] <= 1'b1;
          p_expected_row_q[p_set_i] <= 4'd1;
          p_retired_tiles_q[{p_set_i, 1'b0}] <= '0;
          p_retired_tiles_q[{p_set_i, 1'b1}] <= '0;
          if (p_row_index_i != 4'd0)
            protocol_error_o <= 1'b1;
        end else if (p_row_index_i != p_expected_row_q[p_set_i]) begin
          protocol_error_o <= 1'b1;
        end

        if (p_row_index_i == 4'd15) begin
          p_set_loading_q[p_set_i] <= 1'b0;
          p_bank_valid_q[{p_set_i, 1'b0}] <= 1'b1;
          p_bank_valid_q[{p_set_i, 1'b1}] <= 1'b1;
          p_expected_row_q[p_set_i] <= '0;
          p_load_count_o <= p_load_count_o + 64'd2;
        end else if (p_set_loading_q[p_set_i]) begin
          p_expected_row_q[p_set_i] <= p_row_index_i + 4'd1;
        end
      end

      unique case ({input_fifo_push, input_fifo_pop})
        2'b10: begin
          input_fifo_count_q <= input_fifo_count_q + 2'd1;
          input_fifo_tail_q <= ~input_fifo_tail_q;
        end
        2'b01: begin
          input_fifo_count_q <= input_fifo_count_q - 2'd1;
          input_fifo_head_q <= ~input_fifo_head_q;
        end
        2'b11: begin
          input_fifo_head_q <= ~input_fifo_head_q;
          input_fifo_tail_q <= ~input_fifo_tail_q;
        end
        default: begin end
      endcase

      if (output_start_fire) begin
        input_active_q <= 1'b1;
        v_step_index_q <= 4'd1;
        active_wave_p_bank_q <= {output_set_i, 1'b0};
        active_wave_output_tile_q <= output_tile_i;
        active_wave_set_q <= output_set_i;
        active_wave_context_half_q <= output_context_half_i;
      end else if (v_step_fire) begin
        if (v_step_index_q == 4'd15) begin
          input_active_q <= 1'b0;
          v_step_index_q <= '0;
        end else begin
          v_step_index_q <= v_step_index_q + 4'd1;
        end
      end

      if (input_fifo_pop && input_fifo_start_q[input_fifo_head_q]) begin
        capture_output_tile_q[inner_capture_context] <=
            input_fifo_output_tile_q[input_fifo_head_q];
        capture_p_bank_q[inner_capture_context] <=
            input_fifo_p_bank_q[input_fifo_head_q];
        capture_set_q[inner_capture_context] <=
            input_fifo_set_q[input_fifo_head_q];
        capture_context_half_q[inner_capture_context] <=
            input_fifo_context_half_q[input_fifo_head_q];
      end

      merge_operand_valid_q <= retire_issue;
      if (retire_issue) begin
        merge_operand_context_q <= retire_source_context;
        merge_operand_address_q <= retire_source_address;
      end
      merge_context_pipe_q[0] <= merge_operand_context_q;
      merge_final_bank_pipe_q[0] <= retire_final_bank_q;
      merge_address_pipe_q[0] <= merge_operand_address_q;
      for (int stage = 1; stage < ADD_LATENCY; stage++) begin
        merge_context_pipe_q[stage] <= merge_context_pipe_q[stage-1];
        merge_final_bank_pipe_q[stage] <=
            merge_final_bank_pipe_q[stage-1];
      end
      for (int stage = 1; stage < ADD_LATENCY-1; stage++)
        merge_address_pipe_q[stage] <= merge_address_pipe_q[stage-1];

      if (retire_start) begin
        retire_busy_q <= 1'b1;
        retire_issue_active_q <= 1'b1;
        retire_context_q <= retire_select_context;
        retire_final_bank_q <= retire_select_final_bank;
        retire_issue_address_q <= 5'd1;
        retired_beats_q <= '0;
        retire_output_tile_q <= capture_output_tile_q[retire_select_context];
        retire_p_bank_q <= capture_p_bank_q[retire_select_context];
        retire_set_q <= capture_set_q[retire_select_context];
        retire_context_half_q <=
            capture_context_half_q[retire_select_context];
        final_bank_full_q[retire_select_final_bank] <= 1'b1;
        final_address_q[retire_select_final_bank] <= '0;
        final_write_count_q[retire_select_final_bank] <= '0;
        final_output_tile_q[retire_select_final_bank] <=
            capture_output_tile_q[retire_select_context];
        final_set_q[retire_select_final_bank] <=
            capture_set_q[retire_select_context];
        final_context_half_q[retire_select_final_bank] <=
            capture_context_half_q[retire_select_context];
        final_p_bank_q[retire_select_final_bank] <=
            capture_p_bank_q[retire_select_context];
      end else if (retire_issue_active_q) begin
        if (retire_issue_address_q == 5'd31) begin
          retire_issue_active_q <= 1'b0;
          retire_issue_address_q <= '0;
        end else begin
          retire_issue_address_q <= retire_issue_address_q + 5'd1;
        end
      end

      if (merge_sum_valid[0]) begin
        final_write_count_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] <=
            final_write_count_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] +
            6'd1;
        for (int lane = 1; lane < 8; lane++)
          if (merge_sum_valid[lane] != merge_sum_valid[0])
            protocol_error_o <= 1'b1;
        if (retired_beats_q == 6'd31) begin
          retired_beats_q <= '0;
          retire_busy_q <= 1'b0;
          output_done_o <= 1'b1;
          v_output_wave_count_o <= v_output_wave_count_o + 64'd1;
          if (p_retired_tiles_q[{retire_set_q, 1'b0}] ==
              P_RETIRE_COUNT_W'(OUTPUT_TILES - 1)) begin
            p_retired_tiles_q[{retire_set_q, 1'b0}] <= '0;
            p_retired_tiles_q[{retire_set_q, 1'b1}] <= '0;
            p_bank_valid_q[{retire_set_q, 1'b0}] <= 1'b0;
            p_bank_valid_q[{retire_set_q, 1'b1}] <= 1'b0;
          end else begin
            p_retired_tiles_q[{retire_set_q, 1'b0}] <=
                p_retired_tiles_q[{retire_set_q, 1'b0}] +
                P_RETIRE_COUNT_W'(1);
            p_retired_tiles_q[{retire_set_q, 1'b1}] <=
                p_retired_tiles_q[{retire_set_q, 1'b1}] +
                P_RETIRE_COUNT_W'(1);
          end
        end else begin
          retired_beats_q <= retired_beats_q + 6'd1;
        end
      end

      if (partial_row_fire) begin
        if (final_address_q[drain_bank] == 5'd31) begin
          final_bank_full_q[drain_bank] <= 1'b0;
          final_address_q[drain_bank] <= '0;
          final_write_count_q[drain_bank] <= '0;
          partial_drained_o <= 1'b1;
        end else begin
          final_address_q[drain_bank] <= final_address_q[drain_bank] + 5'd1;
        end
      end

      if (p_discard_valid_i) begin
        for (int half = 0; half < 2; half++) begin
          if (p_bank_valid_q[{p_discard_set_i, half[0]}] &&
              !p_bank_busy[{p_discard_set_i, half[0]}]) begin
            p_bank_valid_q[{p_discard_set_i, half[0]}] <= 1'b0;
            p_retired_tiles_q[{p_discard_set_i, half[0]}] <= '0;
          end else if (p_bank_valid_q[{p_discard_set_i, half[0]}]) begin
            protocol_error_o <= 1'b1;
          end
        end
      end

      if (inner_error)
        protocol_error_o <= 1'b1;
      if (merge_sum_valid[0] &&
          !final_bank_full_q[merge_final_bank_pipe_q[ADD_LATENCY-1]])
        protocol_error_o <= 1'b1;
    end
  end

  logic unused_status;
  assign unused_status = ^{inner_completed_tiles, merge_context_pipe_q[ADD_LATENCY-1]};

  initial begin
    if (OUTPUT_TILES < 1 || OUTPUT_TILES > 8 ||
        ((OUTPUT_TILES > 1) && ((1 << OUTPUT_W) != OUTPUT_TILES)))
      $error("V7.2 PV OUTPUT_TILES must be a power of two in [1,8]");
    if (ROW_PARTITIONS != 4)
      $error("V7.2 PV requires four row partitions");
    if (CAPTURE_CONTEXTS < 2 ||
        ((CAPTURE_CONTEXTS & (CAPTURE_CONTEXTS - 1)) != 0))
      $error("V7.2 PV CAPTURE_CONTEXTS must be a power of two >=2");
  end
endmodule
