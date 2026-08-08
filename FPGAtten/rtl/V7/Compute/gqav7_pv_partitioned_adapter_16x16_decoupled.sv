// Throughput-oriented V7 PV adapter with decoupled compute and retirement.
//
// One proven 64-MAC logical engine captures output tiles into four
// storage-only partial-matrix contexts.  A single 16-lane FP32 adder bank
// retires one sealed context into either of two final-result banks.  This
// gives the front end two additional free contexts while merge/drain runs,
// avoiding r25's duplicated 64-DSP compute engine.
module gqav7_pv_partitioned_adapter_16x16_decoupled #(
  parameter int unsigned K_STEPS        = 16,
  parameter int unsigned OUTPUT_TILES   = 8,
  parameter int unsigned ROW_PARTITIONS = 4,
  // Storage-only result contexts.  This does not replicate the PV MAC; it
  // provides two additional sealed matrices so compute is not held hostage
  // by a merge/drain tail.
  parameter int unsigned CAPTURE_CONTEXTS = 4,
  localparam int unsigned OUTPUT_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES),
  localparam int unsigned CAPTURE_CONTEXT_W =
      (CAPTURE_CONTEXTS <= 1) ? 1 : $clog2(CAPTURE_CONTEXTS)
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

  localparam int unsigned ADD_LATENCY = 5;
  localparam int unsigned P_RETIRE_COUNT_W = OUTPUT_W + 1;

  logic p_load_active_q;
  logic [3:0] p_row_index_q;
  logic p_load_bank_q;
  logic p_compute_bank_q;
  logic [1:0] p_bank_valid_q;
  logic p_start_bank;
  logic [15:0] p_tile_q [2][16][16];

  logic [3:0] v_step_index_q;
  logic [15:0] selected_p_column [16];
  logic [1:0] input_fifo_count_q;
  logic input_fifo_head_q;
  logic input_fifo_tail_q;
  logic input_fifo_start_q [2];
  // Retained for waveform compatibility with r25.  The V7.1 single compute
  // engine ignores this old engine-parity tag and dynamically chooses a free
  // capture context at the launch handshake.
  logic input_fifo_engine_q [2];
  logic [OUTPUT_W-1:0] input_fifo_output_tile_q [2];
  logic input_fifo_p_bank_q [2];
  logic [15:0] input_fifo_p_column_q [2][16];
  logic [15:0] input_fifo_v_partition_q [2][ROW_PARTITIONS][16];
  logic [15:0] input_fifo_row_valid_q [2];
  logic [15:0] input_fifo_col_valid_q [2];
  logic input_fifo_valid;
  logic input_fifo_space;
  logic input_fifo_push;
  logic input_fifo_pop;
  // Each FIFO entry contains 1280 payload bits.  Keeping one synthesized
  // write-enable for the complete entry created a chip-spanning 1280-load
  // control net in the routed predecessor.  Split the enables by entry and
  // ask synthesis to replicate their tiny decode cones locally.
  (* max_fanout = 64 *) logic [1:0] input_fifo_write_enable;

  // Keep the r25 hierarchy names: slots 0/1 now denote capture contexts,
  // rather than separately replicated compute engines.  This preserves
  // existing timeout waveform probes while making the new ownership explicit.
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

  logic [OUTPUT_W-1:0] output_tile_index_q;
  logic [OUTPUT_W-1:0] active_output_tile_q [CAPTURE_CONTEXTS];
  logic active_p_bank_q [CAPTURE_CONTEXTS];
  logic input_active_q;
  logic input_engine_q;
  logic start_engine;
  logic p_start_fire;
  logic p_row_fire;
  logic output_start_fire;
  logic v_step_fire;

  // One shared merger services all sealed partial matrices.  The two final
  // banks keep the merger independent from the row drain.
  logic [31:0] merge_operand_a_q [16];
  logic [31:0] merge_operand_b_q [16];
  logic merge_operand_valid_q;
  logic [CAPTURE_CONTEXT_W-1:0] merge_operand_engine_q;
  logic [3:0] merge_operand_row_q;
  logic [31:0] merge_sum [16];
  logic merge_sum_valid [16];
  logic [CAPTURE_CONTEXT_W-1:0] merge_context_pipe_q [ADD_LATENCY];
  logic merge_final_bank_pipe_q [ADD_LATENCY];
  logic [3:0] merge_row_pipe_q [ADD_LATENCY-1];

  logic retire_busy_q;
  logic retire_issue_active_q;
  logic [CAPTURE_CONTEXT_W-1:0] retire_engine_q;
  logic retire_final_bank_q;
  logic [3:0] retire_issue_row_q;
  logic [4:0] retired_rows_q;
  logic [OUTPUT_W-1:0] retire_output_tile_q;
  logic retire_p_bank_q;
  logic retire_eligible [CAPTURE_CONTEXTS];
  logic [CAPTURE_CONTEXT_W-1:0] retire_select_engine;
  logic retire_select_final_bank;
  logic retire_any_eligible;
  logic retire_final_bank_available;
  logic retire_start;
  // The issue pulse clocks 1024 merge-operand payload bits.  Local driver
  // replication is cheaper than routing one enable through both PV engines.
  (* max_fanout = 64 *) logic retire_issue;
  logic [CAPTURE_CONTEXT_W-1:0] retire_source_engine;
  logic [3:0] retire_source_row;

  // Two independently written 16-deep memories per lane preserve the two
  // drain banks without implementing the final matrices as another 16k-FF
  // decoded register file.
  logic [31:0] final_bank_read [2][16];
  logic [1:0] final_bank_full_q;
  logic [3:0] final_row_q [2];
  logic [OUTPUT_W-1:0] final_output_tile_q [2];
  logic final_p_bank_q [2];
  logic drain_engine;
  logic partial_row_fire;
  logic any_inner_active;
  logic p_compute_context_busy;
  logic [P_RETIRE_COUNT_W-1:0] p_retired_tiles_q [2];

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

  assign start_engine = 1'b0;
  assign input_fifo_valid = input_fifo_count_q != 0;
  assign input_fifo_space = input_fifo_count_q != 2;
  assign output_start_ready_o = p_loaded_o && !input_active_q &&
                                input_fifo_space;
  assign inner_start[0] = input_fifo_valid &&
      input_fifo_start_q[input_fifo_head_q] && inner_start_ready[0];
  assign inner_start[1] = 1'b0;
  assign inner_step_valid[0] = input_fifo_valid &&
      (!input_fifo_start_q[input_fifo_head_q] || inner_start_ready[0]);
  assign inner_step_valid[1] = 1'b0;
  // A context is active while it owns a captured matrix or while the one
  // compute array is filling it.  These probes replace r25's two-engine
  // activity signals without changing the external adapter ABI.
  always_comb begin
    any_inner_active = 1'b0;
    p_compute_context_busy = 1'b0;
    for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++) begin
      inner_active[ctx] = inner_capture_valid[ctx] ||
          (inner_compute_active &&
           (inner_capture_context == CAPTURE_CONTEXT_W'(ctx)));
      any_inner_active |= inner_active[ctx];
      if (inner_active[ctx] &&
          (active_p_bank_q[ctx] == p_compute_bank_q))
        p_compute_context_busy = 1'b1;
    end
  end
  assign output_start_fire =
      output_start_i && output_start_ready_o &&
      v_step_valid_i && v_step_ready_o;
  // output_start_i is a valid-independent launch arm in the production
  // downstream.  Keep first-step acceptance qualified by that arm so a row
  // can never enter the FIFO without a matching wave start, while the arm's
  // local ready path remains independent of the V producer's valid signal.
  assign v_step_ready_o = p_loaded_o && input_fifo_space &&
      (input_active_q || (output_start_i && output_start_ready_o));
  assign v_step_fire = v_step_valid_i && v_step_ready_o;
  assign input_fifo_push = v_step_fire;
  assign input_fifo_pop = input_fifo_valid && inner_step_ready[0];
  assign input_fifo_write_enable[0] =
      input_fifo_push && !input_fifo_tail_q;
  assign input_fifo_write_enable[1] =
      input_fifo_push && input_fifo_tail_q;

  // Capture-valid is registered after the final result beat.  Admit that
  // final beat directly into retirement as well: row zero is already stable
  // in the capture RAM, so this removes the otherwise unconditional one
  // cycle bubble per PV output tile.  The registered valid bit continues to
  // own the matrix for all later retirement cycles.
  always_comb begin
    retire_any_eligible = 1'b0;
    retire_select_engine = '0;
    // Completion order is intentionally independent of launch order.  Tile
    // and P-bank tags travel with every context, and P-bank release is based
    // on a completion count rather than assuming tile 7 retires last.
    for (int ctx = CAPTURE_CONTEXTS - 1; ctx >= 0; ctx--) begin
      retire_eligible[ctx] = inner_capture_valid[ctx] ||
          inner_capture_complete[ctx];
      if (retire_eligible[ctx]) begin
        retire_any_eligible = 1'b1;
        retire_select_engine = CAPTURE_CONTEXT_W'(ctx);
      end
    end
    retire_final_bank_available = !final_bank_full_q[0] ||
        !final_bank_full_q[1];
    retire_select_final_bank = final_bank_full_q[0];
  end
  assign retire_start = !retire_busy_q && retire_any_eligible &&
      retire_final_bank_available;
  assign retire_issue = retire_start || retire_issue_active_q;
  assign retire_source_engine =
      retire_start ? retire_select_engine : retire_engine_q;
  assign retire_source_row =
      retire_start ? 4'd0 : retire_issue_row_q;
  always_comb begin
    for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++)
      inner_capture_release[ctx] = 1'b0;
    if (retire_issue && (retire_source_row == 4'd15))
      inner_capture_release[retire_source_engine] = 1'b1;
  end

  assign drain_engine = final_bank_full_q[0] ? 1'b0 : 1'b1;
  assign partial_row_valid_o =
      final_bank_full_q[0] || final_bank_full_q[1];
  assign partial_row_index_o = final_row_q[drain_engine];
  assign partial_row_output_tile_o = final_output_tile_q[drain_engine];
  assign partial_row_bank_o = drain_engine;
  assign partial_row_fire = partial_row_valid_o && partial_row_ready_i;

  assign active_o = input_active_q || input_fifo_valid ||
      any_inner_active || retire_busy_q ||
      final_bank_full_q[0] || final_bank_full_q[1];
  assign output_tile_index_o = output_tile_index_q;
  assign accepted_macs_cycle_o = inner_accepted_macs_cycle;
  assign accepted_macs_total_o = inner_accepted_macs;

  always_comb begin
    for (int row = 0; row < 16; row++)
      selected_p_column[row] =
          p_tile_q[p_compute_bank_q][row][v_step_index_q];
    for (int lane = 0; lane < 16; lane++)
      partial_row_fp32_o[lane] =
          drain_engine
          ? final_bank_read[1][lane]
          : final_bank_read[0][lane];
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
    .retire_context_i(retire_source_engine),
    .retire_row_i(retire_source_row),
    .retire_partial_a_o(inner_partial_a),
    .retire_partial_b_o(inner_partial_b),
    .accepted_macs_cycle_o(inner_accepted_macs_cycle),
    .accepted_macs_total_o(inner_accepted_macs),
    .completed_tiles_o(inner_completed_tiles),
    .protocol_error_o(inner_error)
  );

  // Context one has no independent MAC engine; these retained probes make
  // that explicit to legacy testbench timeout diagnostics.
  assign inner_start_ready[1] = 1'b0;
  assign inner_step_ready[1] = 1'b0;

  for (genvar lane = 0; lane < 16; lane++) begin : gen_shared_merge_lane
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

  // All wide payload storage is reset-free.  Small ownership-valid state
  // qualifies every read after reset and avoids a matrix-wide reset net.
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

    for (int slot = 0; slot < 2; slot++) begin
      if (input_fifo_write_enable[slot]) begin
        input_fifo_start_q[slot] <= output_start_fire;
        input_fifo_engine_q[slot] <=
            output_start_fire ? start_engine : input_engine_q;
        input_fifo_output_tile_q[slot] <= output_tile_index_q;
        input_fifo_p_bank_q[slot] <= p_compute_bank_q;
        input_fifo_row_valid_q[slot] <= row_valid_i;
        input_fifo_col_valid_q[slot] <= col_valid_i;
        for (int row = 0; row < 16; row++)
          input_fifo_p_column_q[slot][row] <= selected_p_column[row];
        for (int partition = 0; partition < ROW_PARTITIONS; partition++)
          for (int lane = 0; lane < 16; lane++)
            input_fifo_v_partition_q[slot][partition][lane] <=
                v_partition_bf16_i[partition][lane];
      end
    end

    if (retire_issue) begin
      for (int lane = 0; lane < 16; lane++) begin
        merge_operand_a_q[lane] <=
            inner_partial_a[lane];
        merge_operand_b_q[lane] <=
            inner_partial_b[lane];
      end
    end

  end

  for (genvar bank = 0; bank < 2; bank++) begin : gen_final_bank
    for (genvar lane = 0; lane < 16; lane++) begin : gen_final_lane_ram
      (* ram_style = "distributed", rw_addr_collision = "no" *)
      logic [31:0] final_ram_q [16];
      // Replicate the final address register beside each memory.  A shared
      // address stage otherwise drives every RAM address bit in both banks
      // and becomes a non-replicable high-fanout route at 240 MHz.
      (* keep = "true" *) logic [3:0] final_write_row_q;

      assign final_bank_read[bank][lane] =
          final_ram_q[final_row_q[bank]];

      always_ff @(posedge clk_i) begin
        final_write_row_q <= merge_row_pipe_q[ADD_LATENCY-2];
        if (merge_sum_valid[0] &&
            (merge_final_bank_pipe_q[ADD_LATENCY-1] == bank[0]))
          final_ram_q[final_write_row_q] <=
              merge_sum[lane];
      end
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
      for (int ctx = 0; ctx < CAPTURE_CONTEXTS; ctx++) begin
        active_output_tile_q[ctx] <= '0;
        active_p_bank_q[ctx] <= 1'b0;
      end
      input_active_q <= 1'b0;
      input_engine_q <= 1'b0;
      input_fifo_count_q <= '0;
      input_fifo_head_q <= 1'b0;
      input_fifo_tail_q <= 1'b0;
      p_retired_tiles_q[0] <= '0;
      p_retired_tiles_q[1] <= '0;
      retire_busy_q <= 1'b0;
      retire_issue_active_q <= 1'b0;
      retire_engine_q <= '0;
      retire_final_bank_q <= 1'b0;
      retire_issue_row_q <= '0;
      retired_rows_q <= '0;
      retire_output_tile_q <= '0;
      retire_p_bank_q <= 1'b0;
      merge_operand_valid_q <= 1'b0;
      merge_operand_engine_q <= '0;
      merge_operand_row_q <= '0;
      final_bank_full_q <= '0;
      final_row_q[0] <= '0;
      final_row_q[1] <= '0;
      final_output_tile_q[0] <= '0;
      final_output_tile_q[1] <= '0;
      final_p_bank_q[0] <= 1'b0;
      final_p_bank_q[1] <= 1'b0;
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
        merge_row_pipe_q[stage] <= '0;
    end else begin
      output_done_o <= 1'b0;
      partial_drained_o <= 1'b0;

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
        p_retired_tiles_q[p_start_bank] <= '0;
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
        active_output_tile_q[inner_capture_context] <=
            input_fifo_output_tile_q[input_fifo_head_q];
        active_p_bank_q[inner_capture_context] <=
            input_fifo_p_bank_q[input_fifo_head_q];
      end

      merge_operand_valid_q <= retire_issue;
      if (retire_issue) begin
        merge_operand_engine_q <= retire_source_engine;
        merge_operand_row_q <= retire_source_row;
      end
      merge_context_pipe_q[0] <= merge_operand_engine_q;
      // Align the destination-bank tag with the registered merge operand,
      // not with retire_start itself.  The operand selected on a start cycle
      // enters the FP32 pipeline on the following cycle.
      merge_final_bank_pipe_q[0] <= retire_final_bank_q;
      merge_row_pipe_q[0] <= merge_operand_row_q;
      for (int stage = 1; stage < ADD_LATENCY; stage++) begin
        merge_context_pipe_q[stage] <= merge_context_pipe_q[stage-1];
        merge_final_bank_pipe_q[stage] <=
            merge_final_bank_pipe_q[stage-1];
      end
      for (int stage = 1; stage < ADD_LATENCY-1; stage++) begin
        merge_row_pipe_q[stage] <= merge_row_pipe_q[stage-1];
      end

      if (retire_start) begin
        retire_busy_q <= 1'b1;
        retire_issue_active_q <= 1'b1;
        retire_engine_q <= retire_select_engine;
        retire_final_bank_q <= retire_select_final_bank;
        retire_issue_row_q <= 4'd1;
        retired_rows_q <= '0;
        retire_output_tile_q <=
            active_output_tile_q[retire_select_engine];
        retire_p_bank_q <= active_p_bank_q[retire_select_engine];
      end else if (retire_issue_active_q) begin
        if (retire_issue_row_q == 4'd15) begin
          retire_issue_active_q <= 1'b0;
          retire_issue_row_q <= '0;
        end else begin
          retire_issue_row_q <= retire_issue_row_q + 4'd1;
        end
      end

      if (merge_sum_valid[0]) begin
        for (int lane = 1; lane < 16; lane++)
          if (merge_sum_valid[lane] != merge_sum_valid[0])
            protocol_error_o <= 1'b1;
        if (retired_rows_q == 5'd15) begin
          retired_rows_q <= '0;
          retire_busy_q <= 1'b0;
          final_bank_full_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] <=
              1'b1;
          final_row_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] <= '0;
          final_output_tile_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] <=
              retire_output_tile_q;
          final_p_bank_q[merge_final_bank_pipe_q[ADD_LATENCY-1]] <=
              retire_p_bank_q;
          output_done_o <= 1'b1;
          v_output_wave_count_o <= v_output_wave_count_o + 64'd1;
          if (p_retired_tiles_q[retire_p_bank_q] ==
              P_RETIRE_COUNT_W'(OUTPUT_TILES - 1)) begin
            p_retired_tiles_q[retire_p_bank_q] <= '0;
            if (retire_p_bank_q == p_compute_bank_q) begin
              p_bank_valid_q[p_compute_bank_q] <= 1'b0;
              p_compute_bank_q <= ~p_compute_bank_q;
            end else begin
              protocol_error_o <= 1'b1;
            end
          end else begin
            p_retired_tiles_q[retire_p_bank_q] <=
                p_retired_tiles_q[retire_p_bank_q] +
                P_RETIRE_COUNT_W'(1);
          end
        end else begin
          retired_rows_q <= retired_rows_q + 5'd1;
        end
      end

      if (partial_row_fire) begin
        if (final_row_q[drain_engine] == 4'd15) begin
          final_bank_full_q[drain_engine] <= 1'b0;
          final_row_q[drain_engine] <= '0;
          partial_drained_o <= 1'b1;
        end else begin
          final_row_q[drain_engine] <=
              final_row_q[drain_engine] + 4'd1;
        end
      end

      if (p_discard_i) begin
        if (!p_loaded_o || input_active_q || input_fifo_valid ||
            p_compute_context_busy ||
            (retire_busy_q &&
             (retire_p_bank_q == p_compute_bank_q)) ||
            (final_bank_full_q[0] &&
             (final_p_bank_q[0] == p_compute_bank_q)) ||
            (final_bank_full_q[1] &&
             (final_p_bank_q[1] == p_compute_bank_q))) begin
          protocol_error_o <= 1'b1;
        end else begin
          p_bank_valid_q[p_compute_bank_q] <= 1'b0;
          p_compute_bank_q <= ~p_compute_bank_q;
          output_tile_index_q <= '0;
        end
      end

      // output_start_i may be held as an idle launch arm until the first V
      // row becomes valid.  output_start_fire above remains the sole start
      // handshake and still requires both valid and ready.
      if (inner_error)
        protocol_error_o <= 1'b1;
      if (merge_sum_valid[0] &&
          final_bank_full_q[merge_final_bank_pipe_q[ADD_LATENCY-1]])
        protocol_error_o <= 1'b1;
    end
  end

  logic unused_inner_status;
  assign unused_inner_status = ^{
    inner_completed_tiles,
    final_p_bank_q[0], final_p_bank_q[1]
  };

  initial begin
    if (K_STEPS != 16)
      $error("V7 decoupled PV adapter requires K_STEPS == 16");
    if (OUTPUT_TILES < 1)
      $error("V7 decoupled PV adapter requires OUTPUT_TILES >= 1");
    if (ROW_PARTITIONS != 4)
      $error("V7 decoupled PV adapter requires four row partitions");
    if (CAPTURE_CONTEXTS < 2 ||
        ((CAPTURE_CONTEXTS & (CAPTURE_CONTEXTS - 1)) != 0))
      $error("V7 decoupled PV adapter CAPTURE_CONTEXTS must be a power of two >= 2");
  end
endmodule
