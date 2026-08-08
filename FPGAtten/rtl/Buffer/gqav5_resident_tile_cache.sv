module gqav5_resident_tile_cache #(
  parameter int unsigned DATA_W     = 256,
  parameter int unsigned TILE_COUNT = 8,
  parameter int unsigned ROWS       = 16,
  parameter int unsigned TAG_W      = 16,
  // When non-zero, the cache is split into equally-sized replacement slots.
  // Starting tile zero of a slot invalidates the whole slot before the new
  // DMA wave is accepted.  This prevents old valid bits from making a
  // partially overwritten ping-pong slot replayable.
  parameter int unsigned OVERWRITE_SLOT_TILES = 0,
  localparam int unsigned TILE_W =
      (TILE_COUNT <= 1) ? 1 : $clog2(TILE_COUNT),
  localparam int unsigned ROW_W = (ROWS <= 1) ? 1 : $clog2(ROWS),
  localparam int unsigned DEPTH = TILE_COUNT * ROWS,
  localparam int unsigned ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic invalidate_i,

  input  logic fill_start_valid_i,
  output logic fill_start_ready_o,
  input  logic [TILE_W-1:0] fill_tile_i,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [ROW_W-1:0] fill_row_index_i,
  input  logic [DATA_W-1:0] fill_row_data_i,
  input  logic fill_row_last_i,
  output logic fill_done_o,

  input  logic replay_start_valid_i,
  output logic replay_start_ready_o,
  input  logic [TILE_W-1:0] replay_tile_i,
  input  logic [TAG_W-1:0] replay_tag_i,
  input  logic replay_row0_only_i,
  // Optional row-zero tile sequence.  It turns a set of strided resident
  // tiles (for example sixteen decode Q heads at one reduction index) into
  // one contiguous row stream without repeated start/stop bubbles.
  input  logic replay_tile_sequence_i,
  input  logic [TILE_W-1:0] replay_tile_stride_i,
  input  logic [ROW_W:0] replay_sequence_rows_i,
  // Optional outer tile wave.  Sequence mode maps
  // tile=base+wave*wave_stride+row*sequence_stride and emits row zero;
  // normal mode emits every row of each strided tile.  One command can thus
  // sustain the complete eight-reduction-tile QK wave without restart gaps.
  input  logic replay_wave_i,
  input  logic [TILE_W:0] replay_wave_tiles_i,
  input  logic [TILE_W-1:0] replay_wave_tile_stride_i,
  output logic replay_row_valid_o,
  input  logic replay_row_ready_i,
  output logic [DATA_W-1:0] replay_row_data_o,
  output logic [ROW_W-1:0] replay_row_index_o,
  output logic replay_row_last_o,
  output logic [TAG_W-1:0] replay_tag_o,
  output logic replay_done_o,

  output logic [TILE_COUNT-1:0] tile_valid_o,
  output logic fill_active_o,
  output logic replay_active_o,
  output logic [63:0] filled_tile_count_o,
  output logic [63:0] replayed_tile_count_o,
  output logic [63:0] replayed_row_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  (* ram_style = "block" *) logic [DATA_W-1:0] row_mem_q [DEPTH];
  logic [TILE_COUNT-1:0] tile_valid_q;
  logic fill_active_q;
  logic [TILE_W-1:0] fill_tile_q;
  logic [ROW_W-1:0] fill_expected_row_q;
  logic replay_active_q;
  logic [TILE_W-1:0] replay_tile_q;
  logic [TAG_W-1:0] replay_tag_q;
  logic replay_row0_only_q;
  logic replay_tile_sequence_q;
  logic [TILE_W-1:0] replay_tile_stride_q;
  logic [ROW_W:0] replay_sequence_rows_q;
  logic [TILE_W:0] replay_wave_tiles_q;
  logic [TILE_W-1:0] replay_wave_tile_stride_q;
  logic [TILE_W-1:0] replay_wave_index_q;
  logic [ROW_W-1:0] replay_issue_row_q;
  logic replay_all_issued_q;
  logic replay_out_valid_q;
  logic [DATA_W-1:0] replay_out_data_q;
  logic [ROW_W-1:0] replay_out_row_q;
  logic replay_out_last_q;
  logic replay_out_wave_last_q;
  logic local_error_q;
  logic fill_start_fire;
  logic fill_row_fire;
  logic replay_start_fire;
  logic replay_row_fire;
  logic replay_read_issue;
  logic replay_last_issue;
  logic replay_wave_last_issue;
  logic replay_sequence_all_valid;
  logic [ADDR_W-1:0] fill_address;
  logic [ADDR_W-1:0] replay_address;
  localparam int unsigned CALC_W = 2 * TILE_W + 2;
  logic [CALC_W-1:0] replay_start_last_tile_calc;
  logic [CALC_W-1:0] replay_current_tile_calc;
  logic replay_current_tile_valid;
  logic [TILE_W:0] replay_start_wave_tiles;
  logic fill_replaces_active_slot;

  assign replay_start_wave_tiles = replay_wave_i
      ? replay_wave_tiles_i : (TILE_W + 1)'(1);
  always_comb begin
    replay_start_last_tile_calc = CALC_W'(replay_tile_i);
    if (replay_wave_i && replay_wave_tiles_i != '0)
      replay_start_last_tile_calc +=
          CALC_W'(replay_wave_tiles_i - (TILE_W + 1)'(1)) *
          CALC_W'(replay_wave_tile_stride_i);
    if (replay_tile_sequence_i && replay_sequence_rows_i != '0)
      replay_start_last_tile_calc +=
          CALC_W'(replay_sequence_rows_i - (ROW_W + 1)'(1)) *
          CALC_W'(replay_tile_stride_i);
    replay_sequence_all_valid =
        replay_start_wave_tiles != '0 &&
        replay_start_wave_tiles <= (TILE_W + 1)'(TILE_COUNT) &&
        (!replay_tile_sequence_i ||
         (replay_sequence_rows_i != '0 &&
          replay_sequence_rows_i <= (ROW_W + 1)'(ROWS))) &&
        replay_start_last_tile_calc < CALC_W'(TILE_COUNT) &&
        tile_valid_q[replay_tile_i];
  end

  always_comb begin
    replay_current_tile_calc = CALC_W'(replay_tile_q) +
        CALC_W'(replay_wave_index_q) *
        CALC_W'(replay_wave_tile_stride_q);
    if (replay_tile_sequence_q)
      replay_current_tile_calc += CALC_W'(replay_issue_row_q) *
                                  CALC_W'(replay_tile_stride_q);
    replay_current_tile_valid =
        replay_current_tile_calc < CALC_W'(TILE_COUNT) &&
        tile_valid_q[TILE_W'(replay_current_tile_calc)];
  end

  assign replay_start_ready_o = !replay_active_q &&
      replay_sequence_all_valid &&
      !(fill_active_q &&
        (replay_tile_sequence_i || (fill_tile_q == replay_tile_i)));
  // A slot boundary fill invalidates every valid bit in that physical slot.
  // Do not let a speculative next-context fill erase the validity of a
  // different tile that is still being replayed from the same slot.  The DMA
  // mover keeps fill_start_valid asserted, so this is lossless backpressure
  // and only delays a parity-slot reuse until its final replay row retires.
  generate
    if (OVERWRITE_SLOT_TILES > 0) begin : gen_slot_replay_guard
      always_comb begin
        fill_replaces_active_slot =
            (32'(fill_tile_i) % OVERWRITE_SLOT_TILES) == 0 &&
            (((replay_active_q || replay_out_valid_q) &&
              (32'(fill_tile_i) / OVERWRITE_SLOT_TILES) ==
                  (32'(replay_tile_q) / OVERWRITE_SLOT_TILES)) ||
             (replay_start_valid_i && replay_start_ready_o &&
              (32'(fill_tile_i) / OVERWRITE_SLOT_TILES) ==
                  (32'(replay_tile_i) / OVERWRITE_SLOT_TILES)));
      end
    end else begin : gen_no_slot_replay_guard
      assign fill_replaces_active_slot = 1'b0;
    end
  endgenerate
  // A replay already offered for the same tile wins a simultaneous conflict.
  assign fill_start_ready_o = !fill_active_q &&
      !fill_replaces_active_slot &&
      !(replay_active_q &&
        (replay_tile_sequence_q || replay_wave_tiles_q > 1 ||
         (replay_tile_q == fill_tile_i))) &&
      !(replay_start_valid_i && replay_start_ready_o &&
        (replay_tile_sequence_i || replay_wave_i ||
         replay_tile_i == fill_tile_i));
  assign fill_start_fire = fill_start_valid_i && fill_start_ready_o;
  assign fill_row_ready_o = fill_active_q;
  assign fill_row_fire = fill_row_valid_i && fill_row_ready_o;
  assign replay_start_fire = replay_start_valid_i && replay_start_ready_o;
  assign replay_row_valid_o = replay_out_valid_q;
  assign replay_row_data_o = replay_out_data_q;
  assign replay_row_index_o = replay_out_row_q;
  assign replay_row_last_o = replay_out_last_q;
  assign replay_tag_o = replay_tag_q;
  assign replay_row_fire = replay_row_valid_o && replay_row_ready_i;
  assign replay_read_issue = replay_active_q && !replay_all_issued_q &&
      replay_current_tile_valid &&
      (!replay_out_valid_q || replay_row_ready_i);
  assign replay_last_issue = replay_tile_sequence_q
      ? ({1'b0, replay_issue_row_q} + (ROW_W + 1)'(1) >=
         replay_sequence_rows_q)
      : (replay_row0_only_q ||
         replay_issue_row_q == ROW_W'(ROWS - 1));
  assign replay_wave_last_issue = replay_last_issue &&
      ({1'b0, replay_wave_index_q} + (TILE_W + 1)'(1) >=
       replay_wave_tiles_q);
  assign fill_address = ADDR_W'(fill_tile_q) * ADDR_W'(ROWS) +
                        ADDR_W'(fill_row_index_i);
  assign replay_address = replay_tile_sequence_q
      ? (ADDR_W'(replay_current_tile_calc) * ADDR_W'(ROWS))
      : (ADDR_W'(replay_current_tile_calc) * ADDR_W'(ROWS) +
         ADDR_W'(replay_issue_row_q));
  assign tile_valid_o = tile_valid_q;
  assign fill_active_o = fill_active_q;
  assign replay_active_o = replay_active_q || replay_out_valid_q;
  assign protocol_error_o = local_error_q;

  // Keep the addressable payload in a reset-free process.  Even when the RAM
  // itself is not explicitly cleared, placing its accesses in an asynchronous
  // reset process can make synthesis conservatively expand it into FFs.
  // Valid/owner state below prevents an uninitialised word from being used.
  always_ff @(posedge clk_i) begin
    if (fill_row_fire)
      row_mem_q[fill_address] <= fill_row_data_i;
    if (replay_read_issue)
      replay_out_data_q <= row_mem_q[replay_address];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tile_valid_q          <= '0;
      fill_active_q         <= 1'b0;
      fill_tile_q           <= '0;
      fill_expected_row_q   <= '0;
      replay_active_q       <= 1'b0;
      replay_tile_q         <= '0;
      replay_tag_q          <= '0;
      replay_row0_only_q    <= 1'b0;
      replay_tile_sequence_q <= 1'b0;
      replay_tile_stride_q  <= '0;
      replay_sequence_rows_q <= '0;
      replay_wave_tiles_q    <= (TILE_W + 1)'(1);
      replay_wave_tile_stride_q <= '0;
      replay_wave_index_q    <= '0;
      replay_issue_row_q    <= '0;
      replay_all_issued_q   <= 1'b0;
      replay_out_valid_q    <= 1'b0;
      replay_out_row_q      <= '0;
      replay_out_last_q     <= 1'b0;
      replay_out_wave_last_q <= 1'b0;
      fill_done_o           <= 1'b0;
      replay_done_o         <= 1'b0;
      filled_tile_count_o   <= '0;
      replayed_tile_count_o <= '0;
      replayed_row_count_o  <= '0;
      local_error_q         <= 1'b0;
    end else begin
      fill_done_o   <= 1'b0;
      replay_done_o <= 1'b0;
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (invalidate_i) begin
        tile_valid_q <= '0;
        if (fill_active_q || replay_active_q || replay_out_valid_q)
          local_error_q <= 1'b1;
      end

      if (fill_start_fire) begin
        fill_active_q       <= 1'b1;
        fill_tile_q         <= fill_tile_i;
        fill_expected_row_q <= '0;
        if (OVERWRITE_SLOT_TILES > 0) begin
          for (int slot = 0;
               slot < TILE_COUNT / OVERWRITE_SLOT_TILES;
               slot++) begin
            if (fill_tile_i ==
                TILE_W'(slot * OVERWRITE_SLOT_TILES)) begin
              for (int tile = 0;
                   tile < ((OVERWRITE_SLOT_TILES > 0)
                       ? OVERWRITE_SLOT_TILES : 1);
                   tile++)
                tile_valid_q[slot * OVERWRITE_SLOT_TILES + tile] <= 1'b0;
            end
          end
        end
        tile_valid_q[fill_tile_i] <= 1'b0;
      end
      if (fill_row_valid_i && !fill_row_ready_o)
        local_error_q <= 1'b1;
      if (fill_row_fire) begin
        if ((fill_row_index_i != fill_expected_row_q) ||
            (fill_row_last_i !=
             (fill_expected_row_q == ROW_W'(ROWS - 1))))
          local_error_q <= 1'b1;
        if (fill_expected_row_q == ROW_W'(ROWS - 1)) begin
          fill_active_q <= 1'b0;
          fill_expected_row_q <= '0;
          tile_valid_q[fill_tile_q] <= 1'b1;
          fill_done_o <= 1'b1;
          filled_tile_count_o <= filled_tile_count_o + 64'd1;
        end else begin
          fill_expected_row_q <= fill_expected_row_q + ROW_W'(1);
        end
      end

      if (replay_start_fire) begin
        replay_active_q     <= 1'b1;
        replay_tile_q       <= replay_tile_i;
        replay_tag_q        <= replay_tag_i;
        replay_row0_only_q  <= replay_row0_only_i;
        replay_tile_sequence_q <= replay_tile_sequence_i;
        replay_tile_stride_q <= replay_tile_stride_i;
        replay_sequence_rows_q <= replay_sequence_rows_i;
        replay_wave_tiles_q <= replay_start_wave_tiles;
        replay_wave_tile_stride_q <= replay_wave_i
            ? replay_wave_tile_stride_i : '0;
        replay_wave_index_q <= '0;
        replay_issue_row_q  <= '0;
        replay_all_issued_q <= 1'b0;
      end
      if (replay_out_valid_q && replay_row_ready_i)
        replay_out_valid_q <= 1'b0;
      if (replay_read_issue) begin
        replay_out_row_q   <= replay_issue_row_q;
        replay_out_last_q  <= replay_last_issue;
        replay_out_wave_last_q <= replay_wave_last_issue;
        replay_out_valid_q <= 1'b1;
        if (replay_wave_last_issue) begin
          replay_all_issued_q <= 1'b1;
        end else if (replay_last_issue) begin
          replay_wave_index_q <= replay_wave_index_q + TILE_W'(1);
          replay_issue_row_q <= '0;
        end else begin
          replay_issue_row_q <= replay_issue_row_q + ROW_W'(1);
        end
      end
      if (replay_row_fire) begin
        replayed_row_count_o <= replayed_row_count_o + 64'd1;
        if (replay_out_wave_last_q) begin
          replay_active_q       <= 1'b0;
          replay_all_issued_q   <= 1'b0;
          replay_issue_row_q    <= '0;
          replay_wave_index_q   <= '0;
          replay_done_o         <= 1'b1;
          replayed_tile_count_o <= replayed_tile_count_o +
                                   64'(replay_wave_tiles_q);
        end
      end

      if (fill_start_valid_i &&
          ({1'b0, fill_tile_i} >= (TILE_W + 1)'(TILE_COUNT)))
        local_error_q <= 1'b1;
      if (replay_start_valid_i &&
          ({1'b0, replay_tile_i} >= (TILE_W + 1)'(TILE_COUNT)))
        local_error_q <= 1'b1;
      if (replay_start_valid_i && replay_tile_sequence_i &&
          !replay_sequence_all_valid)
        local_error_q <= 1'b1;
      if (replay_active_q && !replay_all_issued_q &&
          !replay_current_tile_valid)
        local_error_q <= 1'b1;
    end
  end

  initial begin
    if (DATA_W < 1 || TILE_COUNT < 1 || ROWS < 1 ||
        (OVERWRITE_SLOT_TILES > 0 &&
         TILE_COUNT % OVERWRITE_SLOT_TILES != 0))
      $error("resident tile cache parameters must be positive");
  end
endmodule
