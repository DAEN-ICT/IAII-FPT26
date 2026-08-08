module gqav5_packed_k_column_cache #(
  parameter int unsigned TAG_W               = 16,
  parameter int unsigned PARTITIONS          = 4,
  parameter int unsigned REDUCTION_TILES     = 8,
  parameter int unsigned ROWS                = 16,
  parameter int unsigned COLUMNS             = 16,
  localparam int unsigned PART_W =
      (PARTITIONS <= 1) ? 1 : $clog2(PARTITIONS),
  localparam int unsigned TILE_W =
      (REDUCTION_TILES <= 1) ? 1 : $clog2(REDUCTION_TILES),
  localparam int unsigned ROW_W =
      (ROWS <= 1) ? 1 : $clog2(ROWS),
  localparam int unsigned COL_W =
      (COLUMNS <= 1) ? 1 : $clog2(COLUMNS),
  localparam int unsigned DEPTH = REDUCTION_TILES * COLUMNS,
  localparam int unsigned ADDR_W =
      (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  localparam int unsigned STAGE_SLICE_W = 16,
  localparam int unsigned STAGE_SLICES =
      (COLUMNS * 16) / STAGE_SLICE_W,
  localparam int unsigned EMIT_SLICE_W = 4,
  localparam int unsigned EMIT_SLICES = 16 / EMIT_SLICE_W,
  localparam int unsigned RESIDENT_SLICE_W = 64,
  localparam int unsigned RESIDENT_SLICES =
      (COLUMNS * 16) / RESIDENT_SLICE_W
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic invalidate_i,

  // Standard row-major K tiles enter one partition at a time.  Two small
  // reset-free staging banks transpose the tile while the following DMA tile
  // fills, then commit sixteen full-width column words into resident BRAM.
  input  logic fill_start_valid_i,
  output logic fill_start_ready_o,
  input  logic fill_broadcast_i,
  input  logic [PART_W-1:0] fill_partition_i,
  input  logic [TILE_W-1:0] fill_tile_i,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [ROW_W-1:0] fill_row_index_i,
  input  logic [COLUMNS*16-1:0] fill_row_data_i,
  input  logic fill_row_last_i,
  output logic fill_done_o,

  input  logic replay_start_valid_i,
  output logic replay_start_ready_o,
  input  logic [TILE_W-1:0] replay_tile_i,
  input  logic [TAG_W-1:0] replay_tag_i,
  input  logic [TILE_W:0] replay_wave_tiles_i,
  output logic replay_column_valid_o,
  input  logic replay_column_ready_i,
`ifdef YOSYS
  output logic [PARTITIONS*COLUMNS*16-1:0]
      replay_partition_column_word_bf16_o,
`else
  output logic [COLUMNS*16-1:0]
      replay_partition_column_word_bf16_o [PARTITIONS],
`endif
  output logic [COL_W-1:0] replay_column_index_o,
  output logic replay_column_last_o,
  output logic [TAG_W-1:0] replay_tag_o,
  output logic replay_done_o,

  output logic [PARTITIONS*REDUCTION_TILES-1:0] tile_valid_o,
  output logic fill_active_o,
  output logic transpose_active_o,
  output logic replay_active_o,
  output logic [63:0] accepted_fill_row_count_o,
  output logic [63:0] committed_column_count_o,
  output logic [63:0] emitted_column_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // Only two tiles (8 Kbit total) are staged regardless of the four K
  // partitions.  This replaces the former two complete 4-partition working
  // sets (32 Kbit) at the compute boundary.
  logic [COLUMNS*16-1:0] stage_row_q [2][ROWS];
  logic [COL_W-1:0] emit_column_row_local [ROWS];
  logic emit_bank_row_local [ROWS];
  logic [COL_W-1:0] emit_column_local [ROWS][EMIT_SLICES];
  logic emit_bank_local [ROWS][EMIT_SLICES];
  logic [1:0] stage_ready_q;
  logic [PART_W-1:0] stage_partition_q [2];
  logic stage_broadcast_q [2];
  logic [TILE_W-1:0] stage_tile_q [2];
  logic fill_active_q, fill_bank_q;
  logic [ROW_W-1:0] fill_expected_row_q;
  logic emit_active_q, emit_bank_q;
  logic [COL_W-1:0] emit_column_q;
  logic [COLUMNS*16-1:0] emit_column_word;
  logic [1:0] stage_free;
  logic selected_fill_bank, selected_emit_bank;
  logic emit_issue;
  logic [ADDR_W-1:0] emit_address;
  logic emit_commit_valid_q;
  logic [PART_W-1:0] emit_commit_partition_q;
  logic emit_commit_broadcast_q;
  logic [TILE_W-1:0] emit_commit_tile_q;
  logic [ADDR_W-1:0] emit_commit_address_q;
  logic [COLUMNS*16-1:0] emit_commit_column_word_q;
  logic emit_commit_last_q;
  logic [PARTITIONS*REDUCTION_TILES-1:0] tile_valid_q;

  // One row of payload plus a one-hot bank/row write descriptor forms a
  // single-entry input pipeline.  The descriptor is only 32 control FFs;
  // it breaks fill_active/bank/row decode away from the 8-Kbit stage CEs.
  logic [COLUMNS*16-1:0] stage_write_data_q;
  logic [2*ROWS-1:0] stage_write_row_enable_q;
  logic stage_write_pending_q, stage_write_bank_q, stage_write_last_q;

  logic replay_active_q;
  logic [TILE_W-1:0] replay_base_tile_q;
  logic [TILE_W:0] replay_wave_tiles_q;
  logic [TILE_W-1:0] replay_wave_index_q;
  logic [COL_W-1:0] replay_issue_column_q;
  logic [TAG_W-1:0] replay_tag_q;
  logic replay_all_issued_q;
  logic replay_out_valid_q;
  logic replay_read_issue_partition_local [PARTITIONS];
  logic replay_read_issue_slice_local [PARTITIONS][RESIDENT_SLICES];
  logic emit_commit_write_issue [PARTITIONS];
  logic emit_commit_write_issue_local [PARTITIONS][RESIDENT_SLICES];
  logic [RESIDENT_SLICE_W-1:0]
      replay_out_data_slice_q [PARTITIONS][RESIDENT_SLICES];
  logic [COLUMNS*16-1:0] replay_out_data_q [PARTITIONS];
  logic [COL_W-1:0] replay_out_column_q;
  logic replay_out_tile_last_q, replay_out_wave_last_q;
  logic local_error_q;

  logic fill_start_fire, fill_row_fire, stage_write_finishes_tile;
  logic replay_start_fire, replay_column_fire, replay_read_issue;
  logic replay_last_column_issue, replay_last_wave_issue;
  logic replay_request_valid_tiles;
  logic [TILE_W:0] replay_effective_wave_tiles;
  logic [TILE_W:0] replay_last_tile_calc;
  logic [TILE_W-1:0] replay_current_tile;
  logic [ADDR_W-1:0] replay_address;
  logic fill_replaces_active_slot;
  logic fill_offer_can_evict;

  always_comb begin
    for (int bank = 0; bank < 2; bank++) begin
      stage_free[bank] = !stage_ready_q[bank] &&
          !(fill_active_q && fill_bank_q == 1'(bank)) &&
          !(stage_write_pending_q && stage_write_bank_q == 1'(bank)) &&
          !(emit_active_q && emit_bank_q == 1'(bank));
    end
  end
  assign selected_fill_bank = stage_free[0] ? 1'b0 : 1'b1;
  assign selected_emit_bank = stage_ready_q[0] ? 1'b0 : 1'b1;
  // Decode configurations divide the resident store into eight-tile context
  // slots.  A new tile zero clears a complete slot, therefore it must wait if
  // the QK array is still consuming any tile from that slot.  Normal fills,
  // and all 8-tile legacy configurations, retain their original initiation
  // interval.
  always_comb begin
    fill_replaces_active_slot = 1'b0;
    if (REDUCTION_TILES >= 16 &&
        (fill_tile_i & TILE_W'(7)) == '0 &&
        (((replay_active_q || replay_out_valid_q) &&
          (fill_tile_i >> 3) == (replay_base_tile_q >> 3)) ||
         (replay_start_valid_i && replay_start_ready_o &&
          (fill_tile_i >> 3) == (replay_tile_i >> 3))))
      fill_replaces_active_slot = 1'b1;
  end
  assign fill_start_ready_o = !fill_active_q && (|stage_free) &&
                              !fill_replaces_active_slot;
  assign fill_offer_can_evict = fill_start_valid_i &&
                                !fill_replaces_active_slot;
  assign fill_start_fire = fill_start_valid_i && fill_start_ready_o;
  assign fill_row_ready_o = fill_active_q;
  assign fill_row_fire = fill_row_valid_i && fill_row_ready_o;
  assign stage_write_finishes_tile = stage_write_pending_q &&
                                     stage_write_last_q;
  assign fill_active_o = fill_active_q;
  assign transpose_active_o = emit_active_q || emit_commit_valid_q ||
                              stage_write_pending_q || (|stage_ready_q);

  assign emit_issue = emit_active_q;
  assign emit_address = ADDR_W'(stage_tile_q[emit_bank_q]) *
                        ADDR_W'(COLUMNS) + ADDR_W'(emit_column_q);
  always_comb begin
    emit_column_word = '0;
    for (int row = 0; row < ROWS; row++) begin
      for (int emit_slice = 0;
           emit_slice < EMIT_SLICES;
           emit_slice++) begin
        emit_column_word[
            row * 16 + emit_slice * EMIT_SLICE_W +: EMIT_SLICE_W] =
            stage_row_q[emit_bank_local[row][emit_slice]][row][
                emit_column_local[row][emit_slice] * 16 +
                emit_slice * EMIT_SLICE_W +: EMIT_SLICE_W];
      end
    end
  end

  // The 8-Kbit two-bank transpose store is an intentionally register-based
  // bandwidth adapter: it accepts all sixteen elements of one row and emits
  // all sixteen rows of one column every cycle.  A BRAM implementation would
  // need sixteen read ports or replication and would cost substantially more
  // memory.  Keep the small exception physically local instead.  Fixed
  // bank/row/slice writes bound every local clock-enable load to 16 FFs.  A
  // two-level row/slice tree then fans the registered bank/column controls
  // into four-bit emit slices.  Root fanout is sixteen rows, each row node
  // drives four leaves, and each leaf controls fewer than 32 mapped mux loads;
  // this prevents both the original 1,000+ load broadcast and the 65-flat-pin
  // one-load miss seen with direct eight-bit replicas.
  generate
    for (genvar stage_bank = 0; stage_bank < 2; stage_bank++) begin : gen_stage_bank
      for (genvar stage_row = 0; stage_row < ROWS; stage_row++) begin : gen_stage_row
        for (genvar stage_slice = 0;
             stage_slice < STAGE_SLICES;
             stage_slice++) begin : gen_stage_slice
          wire stage_write_enable_local;
          gqav5_local_control_buffer i_stage_write_enable_buffer (
            .in_i (stage_write_row_enable_q[
                stage_bank * ROWS + stage_row]),
            .out_o(stage_write_enable_local)
          );
          always_ff @(posedge clk_i) begin
            if (stage_write_enable_local)
              stage_row_q[stage_bank][stage_row]
                         [stage_slice * STAGE_SLICE_W +: STAGE_SLICE_W] <=
                  stage_write_data_q[
                      stage_slice * STAGE_SLICE_W +: STAGE_SLICE_W];
          end
        end
      end
    end
    for (genvar emit_row = 0; emit_row < ROWS; emit_row++) begin : gen_emit_local
      gqav5_local_control_buffer i_emit_bank_row_buffer (
        .in_i (emit_bank_q),
        .out_o(emit_bank_row_local[emit_row])
      );
      for (genvar emit_bit = 0;
           emit_bit < COL_W;
           emit_bit++) begin : gen_emit_row_bit
        gqav5_local_control_buffer i_emit_column_row_buffer (
          .in_i (emit_column_q[emit_bit]),
          .out_o(emit_column_row_local[emit_row][emit_bit])
        );
      end
      for (genvar emit_slice = 0;
           emit_slice < EMIT_SLICES;
           emit_slice++) begin : gen_emit_slice
        gqav5_local_control_buffer i_emit_bank_buffer (
          .in_i (emit_bank_row_local[emit_row]),
          .out_o(emit_bank_local[emit_row][emit_slice])
        );
        for (genvar emit_bit = 0;
             emit_bit < COL_W;
             emit_bit++) begin : gen_emit_bit
          gqav5_local_control_buffer i_emit_column_buffer (
            .in_i (emit_column_row_local[emit_row][emit_bit]),
            .out_o(emit_column_local[emit_row][emit_slice][emit_bit])
          );
        end
      end
    end
  endgenerate

  assign replay_effective_wave_tiles = (replay_wave_tiles_i == '0)
      ? (TILE_W + 1)'(1) : replay_wave_tiles_i;
  assign replay_last_tile_calc = {1'b0, replay_tile_i} +
      replay_effective_wave_tiles - (TILE_W + 1)'(1);
  always_comb begin
    replay_request_valid_tiles =
        replay_effective_wave_tiles <= (TILE_W + 1)'(REDUCTION_TILES) &&
        replay_last_tile_calc < (TILE_W + 1)'(REDUCTION_TILES);
    for (int part = 0; part < PARTITIONS; part++) begin
      for (int tile = 0; tile < REDUCTION_TILES; tile++) begin
        if ((TILE_W + 1)'(tile) >= {1'b0, replay_tile_i} &&
            (TILE_W + 1)'(tile) <
                {1'b0, replay_tile_i} + replay_effective_wave_tiles)
          replay_request_valid_tiles &=
              tile_valid_q[part * REDUCTION_TILES + tile];
      end
    end
  end

  assign replay_start_ready_o = !replay_active_q && !replay_out_valid_q &&
                                replay_request_valid_tiles;
  assign replay_start_fire = replay_start_valid_i && replay_start_ready_o;
  assign replay_current_tile = replay_base_tile_q + replay_wave_index_q;
  assign replay_address = ADDR_W'(replay_current_tile) * ADDR_W'(COLUMNS) +
                          ADDR_W'(replay_issue_column_q);
  assign replay_read_issue = replay_active_q && !replay_all_issued_q &&
      (!replay_out_valid_q || replay_column_ready_i);
  assign replay_last_column_issue =
      replay_issue_column_q == COL_W'(COLUMNS - 1);
  assign replay_last_wave_issue = replay_last_column_issue &&
      ({1'b0, replay_wave_index_q} + (TILE_W + 1)'(1) >=
       replay_wave_tiles_q);

  assign replay_column_valid_o = replay_out_valid_q;
  assign replay_column_index_o = replay_out_column_q;
  assign replay_column_last_o = replay_out_tile_last_q;
  assign replay_tag_o = replay_tag_q;
  assign replay_column_fire = replay_column_valid_o &&
                              replay_column_ready_i;
  assign replay_active_o = replay_active_q || replay_out_valid_q;
  assign tile_valid_o = tile_valid_q;
  assign protocol_error_o = local_error_q;

  generate
    for (genvar part = 0; part < PARTITIONS; part++) begin : gen_partition_ram
      // One branch per partition and one leaf per physical 64-bit RAM bank
      // keep replay backpressure local to the sixteen resident RAMB36s.
      gqav5_local_control_buffer i_replay_read_issue_partition_buffer (
        .in_i (replay_read_issue),
        .out_o(replay_read_issue_partition_local[part])
      );
      assign emit_commit_write_issue[part] = emit_commit_valid_q &&
          (emit_commit_broadcast_q ||
           emit_commit_partition_q == PART_W'(part));
`ifdef YOSYS
      assign replay_partition_column_word_bf16_o[
          part * COLUMNS * 16 +: COLUMNS * 16] = replay_out_data_q[part];
`else
      assign replay_partition_column_word_bf16_o[part] =
          replay_out_data_q[part];
`endif
      for (genvar resident_slice = 0;
           resident_slice < RESIDENT_SLICES;
           resident_slice++) begin : gen_resident_slice
        (* ram_style = "block" *)
        logic [RESIDENT_SLICE_W-1:0] column_mem_q [DEPTH];

        gqav5_local_control_buffer i_replay_read_issue_slice_buffer (
          .in_i (replay_read_issue_partition_local[part]),
          .out_o(replay_read_issue_slice_local[part][resident_slice])
        );
        gqav5_local_control_buffer i_emit_commit_write_issue_buffer (
          .in_i (emit_commit_write_issue[part]),
          .out_o(emit_commit_write_issue_local[part][resident_slice])
        );

        assign replay_out_data_q[part][
            resident_slice * RESIDENT_SLICE_W +: RESIDENT_SLICE_W] =
            replay_out_data_slice_q[part][resident_slice];

        // The transposer supplies one common column address and word, while
        // every 64-bit bank retains its independent synchronous read port.
        always_ff @(posedge clk_i) begin
          if (emit_commit_write_issue_local[part][resident_slice])
            column_mem_q[emit_commit_address_q] <=
                emit_commit_column_word_q[
                    resident_slice * RESIDENT_SLICE_W +:
                    RESIDENT_SLICE_W];
          if (replay_read_issue_slice_local[part][resident_slice])
            replay_out_data_slice_q[part][resident_slice] <=
                column_mem_q[replay_address];
        end
      end
    end
  endgenerate

  gqav5_local_counter64 i_fill_row_counter (
    .clk_i,
    .rst_ni,
    .increment_i(fill_row_fire),
    .count_o    (accepted_fill_row_count_o)
  );

  gqav5_local_counter64 i_commit_column_counter (
    .clk_i,
    .rst_ni,
    .increment_i(emit_commit_valid_q),
    .count_o    (committed_column_count_o)
  );

  gqav5_local_counter64 i_emit_column_counter (
    .clk_i,
    .rst_ni,
    .increment_i(replay_column_fire),
    .count_o    (emitted_column_count_o)
  );

  // Register the complete selected column and its linear destination before
  // touching the four resident BRAM partitions.  This reset-free payload
  // stage preserves one issue/commit per cycle while breaking the former
  // column-counter -> local mux -> distant BRAM-input route-dominated path.
  // Sample it unconditionally: emit_commit_valid_q alone qualifies the BRAM
  // write, so emit_active_q is not routed as a 256-bit payload clock-enable.
  always_ff @(posedge clk_i) begin
    stage_write_data_q <= fill_row_data_i;
    emit_commit_partition_q <= stage_partition_q[emit_bank_q];
    emit_commit_broadcast_q <= stage_broadcast_q[emit_bank_q];
    emit_commit_tile_q <= stage_tile_q[emit_bank_q];
    emit_commit_address_q <= emit_address;
    emit_commit_column_word_q <= emit_column_word;
    emit_commit_last_q <= emit_column_q == COL_W'(COLUMNS - 1);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stage_ready_q <= '0;
      stage_partition_q[0] <= '0;
      stage_partition_q[1] <= '0;
      stage_broadcast_q[0] <= 1'b0;
      stage_broadcast_q[1] <= 1'b0;
      stage_tile_q[0] <= '0;
      stage_tile_q[1] <= '0;
      fill_active_q <= 1'b0;
      fill_bank_q <= 1'b0;
      fill_expected_row_q <= '0;
      stage_write_row_enable_q <= '0;
      stage_write_pending_q <= 1'b0;
      stage_write_bank_q <= 1'b0;
      stage_write_last_q <= 1'b0;
      emit_active_q <= 1'b0;
      emit_bank_q <= 1'b0;
      emit_column_q <= '0;
      emit_commit_valid_q <= 1'b0;
      tile_valid_q <= '0;
      replay_active_q <= 1'b0;
      replay_base_tile_q <= '0;
      replay_wave_tiles_q <= '0;
      replay_wave_index_q <= '0;
      replay_issue_column_q <= '0;
      replay_tag_q <= '0;
      replay_all_issued_q <= 1'b0;
      replay_out_valid_q <= 1'b0;
      replay_out_column_q <= '0;
      replay_out_tile_last_q <= 1'b0;
      replay_out_wave_last_q <= 1'b0;
      fill_done_o <= 1'b0;
      replay_done_o <= 1'b0;
      local_error_q <= 1'b0;
    end else begin
      fill_done_o <= 1'b0;
      replay_done_o <= 1'b0;
      emit_commit_valid_q <= emit_issue;
      stage_write_pending_q <= fill_row_fire;
      stage_write_bank_q <= fill_bank_q;
      stage_write_last_q <=
          fill_expected_row_q == ROW_W'(ROWS - 1);
      for (int bank = 0; bank < 2; bank++) begin
        for (int row = 0; row < ROWS; row++) begin
          stage_write_row_enable_q[bank * ROWS + row] <= fill_row_fire &&
              fill_bank_q == 1'(bank) &&
              fill_row_index_i == ROW_W'(row);
        end
      end
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (invalidate_i) begin
        tile_valid_q <= '0;
        if (fill_active_q || emit_active_q || emit_commit_valid_q ||
            (|stage_ready_q) ||
            replay_active_q || replay_out_valid_q)
          local_error_q <= 1'b1;
      end

      if (fill_start_fire) begin
        fill_active_q <= 1'b1;
        fill_bank_q <= selected_fill_bank;
        fill_expected_row_q <= '0;
        stage_partition_q[selected_fill_bank] <= fill_partition_i;
        stage_broadcast_q[selected_fill_bank] <= fill_broadcast_i;
        stage_tile_q[selected_fill_bank] <= fill_tile_i;
      end
      if (fill_row_valid_i && !fill_row_ready_o)
        local_error_q <= 1'b1;
      if (fill_row_fire) begin
        if (fill_row_index_i != fill_expected_row_q ||
            fill_row_last_i != (fill_expected_row_q == ROW_W'(ROWS - 1)))
          local_error_q <= 1'b1;
        if (fill_expected_row_q == ROW_W'(ROWS - 1)) begin
          fill_active_q <= 1'b0;
          fill_expected_row_q <= '0;
          fill_done_o <= 1'b1;
        end else begin
          fill_expected_row_q <= fill_expected_row_q + ROW_W'(1);
        end
      end
      // The row accepted one cycle earlier is now physically in the selected
      // stage bank.  Publish the tile only on this edge, never before its last
      // 256-bit row has crossed the input pipeline.
      if (stage_write_finishes_tile)
        stage_ready_q[stage_write_bank_q] <= 1'b1;

      if (!emit_active_q && (|stage_ready_q)) begin
        emit_active_q <= 1'b1;
        emit_bank_q <= selected_emit_bank;
        emit_column_q <= '0;
        stage_ready_q[selected_emit_bank] <= 1'b0;
      end else if (emit_active_q) begin
        if (emit_column_q == COL_W'(COLUMNS - 1)) begin
          emit_column_q <= '0;
          // A ready bank, including one whose pipelined final fill row is
          // written on this same edge, takes ownership immediately.  After the initial
          // startup latency this removes the former one-cycle inter-tile
          // bubble and sustains a 16-cycle transpose/commit II.
          if (|stage_ready_q) begin
            emit_active_q <= 1'b1;
            emit_bank_q <= selected_emit_bank;
            stage_ready_q[selected_emit_bank] <= 1'b0;
          end else if (stage_write_finishes_tile) begin
            emit_active_q <= 1'b1;
            emit_bank_q <= stage_write_bank_q;
            stage_ready_q[stage_write_bank_q] <= 1'b0;
          end else begin
            emit_active_q <= 1'b0;
          end
        end else begin
          emit_column_q <= emit_column_q + COL_W'(1);
        end
      end
      if (emit_commit_valid_q && emit_commit_last_q && !invalidate_i) begin
        for (int part = 0; part < PARTITIONS; part++) begin
          if ((emit_commit_broadcast_q ||
               emit_commit_partition_q == PART_W'(part)))
            tile_valid_q[{PART_W'(part),
                          emit_commit_tile_q}] <= 1'b1;
        end
      end


      // A replacement descriptor is stable while valid and stalled.  Mark its
      // target unavailable as soon as it is offered, after emit commit so the
      // new replacement wins any same-edge stale publication.  Fill metadata
      // and payload state remain fire-qualified above.
      if (fill_offer_can_evict) begin
        if (REDUCTION_TILES >= 16 &&
            (fill_tile_i & TILE_W'(7)) == '0) begin
          for (int part = 0; part < PARTITIONS; part++) begin
            if (fill_broadcast_i || fill_partition_i == PART_W'(part)) begin
              for (int tile = 0; tile < 8; tile++)
                tile_valid_q[part * REDUCTION_TILES +
                    ((fill_tile_i >> 3) * 8) + tile] <= 1'b0;
            end
          end
        end
        for (int part = 0; part < PARTITIONS; part++) begin
          if (fill_broadcast_i || fill_partition_i == PART_W'(part))
            tile_valid_q[{PART_W'(part), fill_tile_i}] <= 1'b0;
        end
      end

      if (replay_start_fire) begin
        replay_active_q <= 1'b1;
        replay_base_tile_q <= replay_tile_i;
        replay_wave_tiles_q <= replay_effective_wave_tiles;
        replay_wave_index_q <= '0;
        replay_issue_column_q <= '0;
        replay_tag_q <= replay_tag_i;
        replay_all_issued_q <= 1'b0;
      end
      if (replay_out_valid_q && replay_column_ready_i)
        replay_out_valid_q <= 1'b0;
      if (replay_read_issue) begin
        replay_out_valid_q <= 1'b1;
        replay_out_column_q <= replay_issue_column_q;
        replay_out_tile_last_q <= replay_last_column_issue;
        replay_out_wave_last_q <= replay_last_wave_issue;
        if (replay_last_wave_issue) begin
          replay_all_issued_q <= 1'b1;
        end else if (replay_last_column_issue) begin
          replay_wave_index_q <= replay_wave_index_q + TILE_W'(1);
          replay_issue_column_q <= '0;
        end else begin
          replay_issue_column_q <= replay_issue_column_q + COL_W'(1);
        end
      end
      if (replay_column_fire) begin
        if (replay_out_wave_last_q) begin
          replay_active_q <= 1'b0;
          replay_all_issued_q <= 1'b0;
          replay_wave_index_q <= '0;
          replay_issue_column_q <= '0;
          replay_done_o <= 1'b1;
        end
      end

      if (fill_start_valid_i &&
          ({1'b0, fill_partition_i} >= (PART_W + 1)'(PARTITIONS) ||
           {1'b0, fill_tile_i} >= (TILE_W + 1)'(REDUCTION_TILES)))
        local_error_q <= 1'b1;
      if (replay_start_valid_i && !replay_request_valid_tiles)
        local_error_q <= 1'b1;
    end
  end

  initial begin
    if (PARTITIONS != 4 ||
        (REDUCTION_TILES != 8 && REDUCTION_TILES != 16 &&
         REDUCTION_TILES != 32) ||
        ROWS != 16 || COLUMNS != 16 ||
        COLUMNS * 16 % STAGE_SLICE_W != 0 ||
        16 % EMIT_SLICE_W != 0 ||
        COLUMNS * 16 % RESIDENT_SLICE_W != 0)
      $error("packed K cache targets four 16x128 regions with one, two, or four context slots");
  end
endmodule
