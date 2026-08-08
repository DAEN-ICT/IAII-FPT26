// Production-facing V7 PV adapter.
//
// P is loaded in the proven V5 row-major format.  During each output tile,
// one P column and four partitioned V vectors form exactly the same logical
// 16x16 outer-product reduction beat used by the V7 QK adapter.  Reusing that
// verified engine replaces the legacy 256-PE combinational PV recurrence with
// a pipelined 64-MAC/cycle implementation while preserving every downstream
// ready/valid and partial-row contract.
module gqav7_pv_partitioned_adapter_16x16 #(
  parameter int unsigned K_STEPS        = 16,
  parameter int unsigned OUTPUT_TILES   = 8,
  parameter int unsigned ROW_PARTITIONS = 4,
  localparam int unsigned OUTPUT_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic p_start_i,
  output logic p_start_ready_o,
  input  logic p_row_valid_i,
  output logic p_row_ready_o,
  input  logic [15:0] p_row_bf16_i [16],
  output logic p_loaded_o,
  output logic p_next_loaded_o,
  input  logic p_discard_i,

  input  logic output_start_i,
  output logic output_start_ready_o,
  input  logic v_step_valid_i,
  output logic v_step_ready_o,
  input  logic [15:0] v_partition_bf16_i [ROW_PARTITIONS][16],
  input  logic [15:0] row_valid_i,
  input  logic [15:0] col_valid_i,

  output logic active_o,
  output logic output_done_o,
  output logic [OUTPUT_W-1:0] output_tile_index_o,
  output logic partial_row_valid_o,
  input  logic partial_row_ready_i,
  output logic [31:0] partial_row_fp32_o [16],
  output logic [3:0] partial_row_index_o,
  output logic [OUTPUT_W-1:0] partial_row_output_tile_o,
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

  logic p_load_active_q;
  logic [3:0] p_row_index_q;
  logic p_load_bank_q;
  logic p_compute_bank_q;
  logic [1:0] p_bank_valid_q;
  logic p_start_bank;
  logic [15:0] p_tile_q [2][16][16];

  logic [3:0] v_step_index_q;
  logic [15:0] selected_p_column [16];
  // Two registered entries break the inner ready path back to the V-buffer
  // BRAM enable and capture the selected P column beside its storage bank.
  // The queue remains full-rate in steady state and can hold a following tile
  // start behind the current tile's final step.
  logic [1:0] input_fifo_count_q;
  logic input_fifo_head_q;
  logic input_fifo_tail_q;
  logic input_fifo_start_q [2];
  logic input_fifo_engine_q [2];
  logic [OUTPUT_W-1:0] input_fifo_output_tile_q [2];
  logic input_fifo_p_bank_q [2];
  logic [15:0] input_fifo_p_column_q [2][16];
  logic [15:0] input_fifo_v_partition_q [2][ROW_PARTITIONS][16];
  logic [15:0] input_fifo_row_valid_q [2];
  logic [15:0] input_fifo_col_valid_q [2];
  logic input_fifo_valid;
  logic input_fifo_space;
  logic input_fifo_engine;
  logic input_fifo_push;
  logic input_fifo_pop;
  // Two copies of the already-verified V7 64-MAC adapter are alternated by
  // output tile.  While one copy merges and drains its completed matrix, the
  // other can accept the next sixteen V steps.  This removes the merge/drain
  // tail from the steady-state PV initiation interval without changing the
  // floating-point operation order inside either tile.
  logic inner_start [2];
  logic inner_start_ready [2];
  logic inner_step_valid [2];
  logic inner_step_ready [2];
  logic inner_continuation_step_ready [2];
  logic inner_active [2];
  logic inner_done [2];
  logic inner_result_valid [2];
  logic inner_result_ready [2];
  logic [31:0] inner_result [2][16];
  logic [3:0] inner_result_row [2];
  logic inner_result_bank [2];
  logic inner_result_drained [2];
  logic inner_next_bank [2];
  logic [8:0] inner_accepted_macs_cycle [2];
  logic [63:0] inner_accepted_macs [2];
  logic [63:0] inner_completed_tiles [2];
  logic inner_error [2];

  logic [OUTPUT_W-1:0] output_tile_index_q;
  // Each inner engine owns two independently retiring result banks.  Keep the
  // output-tile tag beside the bank that receives the matrix; a single
  // per-engine tag is overwritten when the engine starts its next tile while
  // rows from the previous bank are still draining.
  logic [OUTPUT_W-1:0] active_output_tile_q [2][2];
  logic active_p_bank_q [2];
  logic input_active_q;
  logic input_engine_q;
  logic start_engine;
  logic drain_engine;
  logic p_start_fire;
  logic p_row_fire;
  logic output_start_fire;
  logic v_step_fire;

  assign p_start_bank = p_bank_valid_q[p_compute_bank_q]
      ? ~p_compute_bank_q : p_compute_bank_q;
  assign p_start_ready_o = !p_load_active_q &&
                           !(p_bank_valid_q[0] && p_bank_valid_q[1]);
  assign p_row_ready_o =
      p_load_active_q || (p_start_i && p_start_ready_o);
  assign p_start_fire = p_start_i && p_start_ready_o;
  assign p_row_fire = p_row_valid_i && p_row_ready_o;
  assign p_loaded_o = p_bank_valid_q[p_compute_bank_q];
  assign p_next_loaded_o = p_bank_valid_q[~p_compute_bank_q];

  assign start_engine = output_tile_index_q[0];
  assign input_fifo_valid = input_fifo_count_q != 0;
  assign input_fifo_space = input_fifo_count_q != 2;
  assign input_fifo_engine = input_fifo_engine_q[input_fifo_head_q];
  assign output_start_ready_o = p_loaded_o && !input_active_q &&
                                input_fifo_space;
  for (genvar engine = 0; engine < 2; engine++) begin : gen_input_route
    assign inner_start[engine] = input_fifo_valid &&
        input_fifo_start_q[input_fifo_head_q] &&
        (input_fifo_engine == engine[0]) && inner_start_ready[engine];
    assign inner_step_valid[engine] = input_fifo_valid &&
        (input_fifo_engine == engine[0]) &&
        (!input_fifo_start_q[input_fifo_head_q] ||
         inner_start_ready[engine]);
  end
  assign output_start_fire =
      output_start_i && output_start_ready_o &&
      v_step_valid_i && v_step_ready_o;
  assign v_step_ready_o = p_loaded_o && input_fifo_space &&
      (input_active_q || (output_start_i && output_start_ready_o));
  assign v_step_fire = v_step_valid_i && v_step_ready_o;
  assign input_fifo_push = v_step_fire;
  assign input_fifo_pop = input_fifo_valid &&
      inner_step_ready[input_fifo_engine];

  assign active_o = input_fifo_valid || inner_active[0] || inner_active[1];
  assign output_done_o = inner_done[0] || inner_done[1];
  assign output_tile_index_o = output_tile_index_q;
  // A completed engine holds its current result row under backpressure, so a
  // simple fixed-priority arbiter is lossless.  Engine zero can only delay one
  // finite sixteen-row drain from engine one.
  assign drain_engine = inner_result_valid[0] ? 1'b0 : 1'b1;
  assign partial_row_valid_o = inner_result_valid[0] || inner_result_valid[1];
  assign inner_result_ready[0] = partial_row_ready_i &&
                                 inner_result_valid[0];
  assign inner_result_ready[1] = partial_row_ready_i &&
                                 !inner_result_valid[0] &&
                                 inner_result_valid[1];
  assign partial_row_index_o = inner_result_row[drain_engine];
  assign partial_row_output_tile_o =
      active_output_tile_q[drain_engine]
                          [inner_result_bank[drain_engine]];
  assign partial_row_bank_o = drain_engine;
  assign partial_drained_o = inner_result_drained[0] ||
                             inner_result_drained[1];
  assign accepted_macs_cycle_o = inner_accepted_macs_cycle[0] +
                                 inner_accepted_macs_cycle[1];
  assign accepted_macs_total_o = inner_accepted_macs[0] +
                                 inner_accepted_macs[1];

  always_comb begin
    for (int row = 0; row < 16; row++)
      selected_p_column[row] =
          p_tile_q[p_compute_bank_q][row][v_step_index_q];
    for (int lane = 0; lane < 16; lane++)
      partial_row_fp32_o[lane] = inner_result[drain_engine][lane];
  end

  for (genvar engine = 0; engine < 2; engine++) begin : gen_pv_engine
    gqav7_qk_partitioned_adapter_16x16 #(
      .K_STEPS(K_STEPS),
      .ROW_PARTITIONS(ROW_PARTITIONS),
      .MERGE_LANES(16)
    ) i_shared_engine (
      .clk_i,
      .rst_ni,
      .start_i(inner_start[engine]),
      .start_ready_o(inner_start_ready[engine]),
      .step_valid_i(inner_step_valid[engine]),
      .step_ready_o(inner_step_ready[engine]),
      .continuation_step_ready_o(
          inner_continuation_step_ready[engine]),
      .a_bf16_i(input_fifo_p_column_q[input_fifo_head_q]),
      .b_partition_bf16_i(
          input_fifo_v_partition_q[input_fifo_head_q]
      ),
      .row_valid_i(input_fifo_row_valid_q[input_fifo_head_q]),
      .col_valid_i(input_fifo_col_valid_q[input_fifo_head_q]),
      .active_o(inner_active[engine]),
      .done_o(inner_done[engine]),
      .result_row_valid_o(inner_result_valid[engine]),
      .result_row_ready_i(inner_result_ready[engine]),
      .result_row_fp32_o(inner_result[engine]),
      .result_row_index_o(inner_result_row[engine]),
      .result_row_bank_o(inner_result_bank[engine]),
      .result_drained_o(inner_result_drained[engine]),
      .next_compute_bank_o(inner_next_bank[engine]),
      .accepted_macs_cycle_o(inner_accepted_macs_cycle[engine]),
      .accepted_macs_total_o(inner_accepted_macs[engine]),
      .completed_tiles_o(inner_completed_tiles[engine]),
      .protocol_error_o(inner_error[engine])
    );
  end

  always_ff @(posedge clk_i) begin : p_payload
    if (p_row_fire) begin
      for (int col = 0; col < 16; col++) begin
        if (p_start_fire)
          p_tile_q[p_start_bank][0][col] <= p_row_bf16_i[col];
        else
          p_tile_q[p_load_bank_q][p_row_index_q][col] <=
              p_row_bf16_i[col];
      end
    end
    if (input_fifo_push) begin
      input_fifo_start_q[input_fifo_tail_q] <= output_start_fire;
      input_fifo_engine_q[input_fifo_tail_q] <=
          output_start_fire ? start_engine : input_engine_q;
      input_fifo_output_tile_q[input_fifo_tail_q] <= output_tile_index_q;
      input_fifo_p_bank_q[input_fifo_tail_q] <= p_compute_bank_q;
      input_fifo_row_valid_q[input_fifo_tail_q] <= row_valid_i;
      input_fifo_col_valid_q[input_fifo_tail_q] <= col_valid_i;
      for (int row = 0; row < 16; row++)
        input_fifo_p_column_q[input_fifo_tail_q][row] <=
            selected_p_column[row];
      for (int partition = 0; partition < ROW_PARTITIONS; partition++)
        for (int lane = 0; lane < 16; lane++)
          input_fifo_v_partition_q[input_fifo_tail_q][partition][lane] <=
              v_partition_bf16_i[partition][lane];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_control
    if (!rst_ni) begin
      p_load_active_q <= 1'b0;
      p_row_index_q <= '0;
      p_load_bank_q <= 1'b0;
      p_compute_bank_q <= 1'b0;
      p_bank_valid_q <= '0;
      v_step_index_q <= '0;
      output_tile_index_q <= '0;
      active_output_tile_q[0][0] <= '0;
      active_output_tile_q[0][1] <= '0;
      active_output_tile_q[1][0] <= '0;
      active_output_tile_q[1][1] <= '0;
      active_p_bank_q[0] <= 1'b0;
      active_p_bank_q[1] <= 1'b0;
      input_active_q <= 1'b0;
      input_engine_q <= 1'b0;
      input_fifo_count_q <= '0;
      input_fifo_head_q <= 1'b0;
      input_fifo_tail_q <= 1'b0;
      p_load_count_o <= '0;
      v_output_wave_count_o <= '0;
      protocol_error_o <= 1'b0;
    end else begin
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
        default: begin
        end
      endcase

      if (p_start_fire) begin
        p_load_active_q <= 1'b1;
        p_load_bank_q <= p_start_bank;
        p_row_index_q <= p_row_valid_i ? 4'd1 : 4'd0;
        if (!p_row_valid_i)
          protocol_error_o <= 1'b1;
      end else if (p_row_fire) begin
        if (p_row_index_q == 4'd15) begin
          p_load_active_q <= 1'b0;
          p_row_index_q <= '0;
          p_bank_valid_q[p_load_bank_q] <= 1'b1;
          p_load_count_o <= p_load_count_o + 64'd1;
        end else begin
          p_row_index_q <= p_row_index_q + 4'd1;
        end
      end

      if (output_start_fire) begin
        v_step_index_q <= 4'd1;
        input_active_q <= K_STEPS > 1;
        input_engine_q <= start_engine;
        if (output_tile_index_q == OUTPUT_W'(OUTPUT_TILES - 1))
          output_tile_index_q <= '0;
        else
          output_tile_index_q <= output_tile_index_q + OUTPUT_W'(1);
      end else if (v_step_fire) begin
        if (v_step_index_q == 4'd15) begin
          v_step_index_q <= '0;
          input_active_q <= 1'b0;
        end else begin
          v_step_index_q <= v_step_index_q + 4'd1;
        end
      end

      if (input_fifo_pop && input_fifo_start_q[input_fifo_head_q]) begin
        active_output_tile_q[input_fifo_engine]
                            [inner_next_bank[input_fifo_engine]] <=
            input_fifo_output_tile_q[input_fifo_head_q];
        active_p_bank_q[input_fifo_engine] <=
            input_fifo_p_bank_q[input_fifo_head_q];
      end

      if (inner_done[0] || inner_done[1]) begin
        v_output_wave_count_o <= v_output_wave_count_o +
            64'(inner_done[0]) + 64'(inner_done[1]);
        if ((inner_done[0] &&
             (active_output_tile_q[0][~inner_next_bank[0]] ==
              OUTPUT_W'(OUTPUT_TILES - 1)) &&
             (active_p_bank_q[0] == p_compute_bank_q)) ||
            (inner_done[1] &&
             (active_output_tile_q[1][~inner_next_bank[1]] ==
              OUTPUT_W'(OUTPUT_TILES - 1)) &&
             (active_p_bank_q[1] == p_compute_bank_q))) begin
          p_bank_valid_q[p_compute_bank_q] <= 1'b0;
          p_compute_bank_q <= ~p_compute_bank_q;
        end
      end

      if (p_discard_i) begin
        if (!p_loaded_o || input_active_q || input_fifo_valid ||
            (inner_active[0] &&
             (active_p_bank_q[0] == p_compute_bank_q)) ||
            (inner_active[1] &&
             (active_p_bank_q[1] == p_compute_bank_q))) begin
          protocol_error_o <= 1'b1;
        end else begin
          p_bank_valid_q[p_compute_bank_q] <= 1'b0;
          p_compute_bank_q <= ~p_compute_bank_q;
          output_tile_index_q <= '0;
        end
      end

      if (output_start_i && output_start_ready_o && !v_step_valid_i)
        protocol_error_o <= 1'b1;
      if (inner_error[0] || inner_error[1])
        protocol_error_o <= 1'b1;
    end
  end

  logic unused_inner_status;
  assign unused_inner_status = ^{
    inner_result_bank[0], inner_result_bank[1],
    inner_next_bank[0], inner_next_bank[1],
    inner_completed_tiles[0], inner_completed_tiles[1],
    inner_continuation_step_ready[0],
    inner_continuation_step_ready[1]
  };

  initial begin
    if (K_STEPS != 16)
      $error("V7 PV production adapter requires K_STEPS == 16");
    if (OUTPUT_TILES < 1)
      $error("V7 PV production adapter requires OUTPUT_TILES >= 1");
    if (ROW_PARTITIONS != 4)
      $error("V7 PV production adapter requires four row partitions");
  end
endmodule
