module gqav5_packed_q_column_cache #(
  parameter int unsigned TAG_W           = 16,
  parameter int unsigned Q_HEADS         = 16,
  parameter int unsigned Q_SLOTS         = 4,
  parameter int unsigned REDUCTION_TILES = 8,
  parameter int unsigned COLUMNS         = 16,
  localparam int unsigned HEAD_W =
      (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
  localparam int unsigned TILE_W =
      (REDUCTION_TILES <= 1) ? 1 : $clog2(REDUCTION_TILES),
  localparam int unsigned COL_W =
      (COLUMNS <= 1) ? 1 : $clog2(COLUMNS),
  localparam int unsigned TILE_INDEX_W = HEAD_W + TILE_W,
  localparam int unsigned SLOT_W =
      (Q_SLOTS <= 1) ? 1 : $clog2(Q_SLOTS),
  localparam int unsigned DEPTH =
      Q_SLOTS * REDUCTION_TILES * COLUMNS,
  localparam int unsigned ADDR_W =
      (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  localparam int unsigned TILE_VALID_BITS =
      Q_SLOTS * Q_HEADS * REDUCTION_TILES,
  localparam int unsigned VALID_SLICES = TILE_VALID_BITS / 16
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic invalidate_i,

  // The normal Q DMA tile is row-major.  In packed decode only row zero is
  // live, so its sixteen BF16 elements are serialized over the tile's
  // sixteen accepted row beats into one narrow BRAM bank per Q head.  This
  // uses the existing DMA cadence and avoids a wide partial-write memory.
  input  logic fill_start_valid_i,
  output logic fill_start_ready_o,
  input  logic [SLOT_W-1:0] fill_slot_i,
  input  logic [TILE_INDEX_W-1:0] fill_tile_i,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [COL_W-1:0] fill_row_index_i,
  input  logic [COLUMNS*16-1:0] fill_row_data_i,
  input  logic fill_row_last_i,
  output logic fill_done_o,

  // One replay command emits all requested reduction tiles.  Every cycle
  // reads the same {tile,column} address from all sixteen Q-head banks and
  // therefore produces the 16-lane Q operand needed by one outer product.
  input  logic replay_start_valid_i,
  output logic replay_start_ready_o,
  input  logic [SLOT_W-1:0] replay_slot_i,
  input  logic [TILE_W-1:0] replay_tile_i,
  input  logic [TAG_W-1:0] replay_tag_i,
  input  logic [TILE_W:0] replay_wave_tiles_i,
  output logic replay_column_valid_o,
  input  logic replay_column_ready_i,
  output logic [COLUMNS*16-1:0] replay_column_word_bf16_o,
  output logic [COL_W-1:0] replay_column_index_o,
  output logic replay_column_last_o,
  output logic [TAG_W-1:0] replay_tag_o,
  output logic replay_done_o,

  output logic [Q_SLOTS*Q_HEADS*REDUCTION_TILES-1:0] tile_valid_o,
  output logic [Q_SLOTS-1:0] slot_valid_o,
  output logic fill_active_o,
  output logic replay_active_o,
  output logic [63:0] accepted_fill_row_count_o,
  output logic [63:0] emitted_column_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // Each bank is only 16 bits wide and 128 words deep at the production
  // geometry.  Vivado can map the sixteen independent read ports to sixteen
  // RAMB18 primitives instead of building a 16x16 transpose in FFs.
  // Row zero arrives as one 256-bit DMA beat, while the existing tile mover
  // still supplies sixteen row slots.  Keep the remaining fifteen elements
  // in a local shift register so every following beat consumes its low word.
  // A variable part-select here synthesized into a 257-fanout mux cone; the
  // fixed 16-bit shift keeps each payload bit local to its neighbour.  Each
  // word has its own preserved enable/select copy as well, avoiding a new
  // 240-register clock-enable broadcast while the row is serialized.
  logic [15:0] fill_row_shift_q [COLUMNS-1];
  (* keep = "true", max_fanout = 16 *)
  logic [COLUMNS-2:0] fill_shift_enable_slice;
  (* keep = "true", max_fanout = 16 *)
  logic [COLUMNS-2:0] fill_shift_load_slice;
  (* keep = "true", max_fanout = 16 *)
  logic [VALID_SLICES-1:0] invalidate_tile_slice;
  logic fill_is_row_zero;
  logic [Q_SLOTS*Q_HEADS*REDUCTION_TILES-1:0] tile_valid_q;
  logic fill_active_q;
  logic [SLOT_W-1:0] fill_slot_q;
  logic [HEAD_W-1:0] fill_head_q;
  logic [TILE_W-1:0] fill_reduction_tile_q;
  logic [COL_W-1:0] fill_expected_row_q;

  logic replay_active_q;
  logic [SLOT_W-1:0] replay_slot_q;
  logic [TILE_W-1:0] replay_base_tile_q;
  logic [TILE_W:0] replay_wave_tiles_q;
  logic [TILE_W-1:0] replay_wave_index_q;
  logic [COL_W-1:0] replay_issue_column_q;
  logic [TAG_W-1:0] replay_tag_q;
  logic replay_all_issued_q;
  logic replay_out_valid_q;
  logic [15:0] replay_out_element_q [Q_HEADS];
  logic [COL_W-1:0] replay_out_column_q;
  logic replay_out_tile_last_q;
  logic replay_out_wave_last_q;
  logic local_error_q;

  logic fill_start_fire, fill_row_fire;
  logic replay_start_fire, replay_column_fire, replay_read_issue;
  logic replay_read_issue_local [Q_HEADS];
  logic replay_last_column_issue, replay_last_wave_issue;
  logic replay_request_valid_tiles;
  logic [TILE_W:0] replay_effective_wave_tiles;
  logic [TILE_W:0] replay_last_tile_calc;
  logic [TILE_W-1:0] replay_current_tile;
  logic [ADDR_W-1:0] fill_address, replay_address;

  assign replay_effective_wave_tiles = (replay_wave_tiles_i == '0)
      ? (TILE_W + 1)'(1) : replay_wave_tiles_i;

  generate
    for (genvar slice = 0; slice < VALID_SLICES;
         slice++) begin : gen_invalidate_tile_slice
      gqav5_local_control_buffer i_invalidate_buffer (
        .in_i (invalidate_i),
        .out_o(invalidate_tile_slice[slice])
      );
    end
  endgenerate
  assign fill_is_row_zero = fill_row_index_i == '0;
  assign replay_last_tile_calc = {1'b0, replay_tile_i} +
      replay_effective_wave_tiles - (TILE_W + 1)'(1);

  always_comb begin
    replay_request_valid_tiles =
        replay_effective_wave_tiles <= (TILE_W + 1)'(REDUCTION_TILES) &&
        replay_last_tile_calc < (TILE_W + 1)'(REDUCTION_TILES);
    for (int head = 0; head < Q_HEADS; head++) begin
      for (int tile = 0; tile < REDUCTION_TILES; tile++) begin
        if ((TILE_W + 1)'(tile) >= {1'b0, replay_tile_i} &&
            (TILE_W + 1)'(tile) <
                {1'b0, replay_tile_i} + replay_effective_wave_tiles)
          replay_request_valid_tiles &= tile_valid_q[
              replay_slot_i * (Q_HEADS * REDUCTION_TILES) +
              head * REDUCTION_TILES + tile];
      end
    end
  end

  assign fill_start_ready_o = !fill_active_q && !replay_active_q &&
                              !replay_out_valid_q;
  assign fill_start_fire = fill_start_valid_i && fill_start_ready_o;
  assign fill_row_ready_o = fill_active_q;
  assign fill_row_fire = fill_row_valid_i && fill_row_ready_o;
  assign fill_address =
      ADDR_W'(fill_slot_q) *
          ADDR_W'(REDUCTION_TILES * COLUMNS) +
      ADDR_W'(fill_reduction_tile_q) * ADDR_W'(COLUMNS) +
                        ADDR_W'(fill_row_index_i);

  assign replay_start_ready_o = !replay_active_q && !replay_out_valid_q &&
                                !fill_active_q &&
                                replay_request_valid_tiles;
  assign replay_start_fire = replay_start_valid_i && replay_start_ready_o;
  assign replay_current_tile = replay_base_tile_q + replay_wave_index_q;
  assign replay_address =
      ADDR_W'(replay_slot_q) *
          ADDR_W'(REDUCTION_TILES * COLUMNS) +
      ADDR_W'(replay_current_tile) * ADDR_W'(COLUMNS) +
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
  assign tile_valid_o = tile_valid_q;
  assign fill_active_o = fill_active_q;
  assign replay_active_o = replay_active_q || replay_out_valid_q;
  assign protocol_error_o = local_error_q;

  generate
    for (genvar slot = 0; slot < Q_SLOTS; slot++) begin : gen_slot_valid
      assign slot_valid_o[slot] = &tile_valid_q[
          slot * Q_HEADS * REDUCTION_TILES +:
          Q_HEADS * REDUCTION_TILES];
    end
    for (genvar head = 0; head < Q_HEADS; head++) begin : gen_head_bank
      (* ram_style = "block" *) logic [15:0] element_mem_q [DEPTH];
      // Each Q head owns one RAMB18.  Preserve a local enable leaf beside the
      // memory so downstream QK backpressure does not drive all sixteen REGCE
      // pins over one long shared route.
      gqav5_local_control_buffer i_replay_read_issue_buffer (
        .in_i (replay_read_issue),
        .out_o(replay_read_issue_local[head])
      );
      assign replay_column_word_bf16_o[head * 16 +: 16] =
          replay_out_element_q[head];
      always_ff @(posedge clk_i) begin
        if (fill_row_fire && fill_head_q == HEAD_W'(head)) begin
          if (fill_row_index_i == '0)
            element_mem_q[fill_address] <= fill_row_data_i[15:0];
          else
            element_mem_q[fill_address] <= fill_row_shift_q[0];
        end
        if (replay_read_issue_local[head])
          replay_out_element_q[head] <= element_mem_q[replay_address];
      end
    end
  endgenerate

  gqav5_local_counter64 i_fill_row_counter (
    .clk_i,
    .rst_ni,
    .increment_i(fill_row_fire),
    .count_o    (accepted_fill_row_count_o)
  );

  gqav5_local_counter64 i_emit_column_counter (
    .clk_i,
    .rst_ni,
    .increment_i(replay_column_fire),
    .count_o    (emitted_column_count_o)
  );

  // Payload storage is intentionally reset-free.  Valid bits and stream FSM
  // state are the sole visibility qualifiers, preserving BRAM inference.
  generate
    for (genvar element = 0; element < COLUMNS - 1;
         element++) begin : gen_fill_shift_word
      gqav5_local_control_buffer i_enable_buffer (
        .in_i (fill_row_fire),
        .out_o(fill_shift_enable_slice[element])
      );
      gqav5_local_control_buffer i_load_buffer (
        .in_i (fill_is_row_zero),
        .out_o(fill_shift_load_slice[element])
      );
      always_ff @(posedge clk_i) begin
        if (fill_shift_enable_slice[element]) begin
          if (fill_shift_load_slice[element])
            fill_row_shift_q[element] <=
                fill_row_data_i[(element + 1) * 16 +: 16];
          else if (element == COLUMNS - 2)
            fill_row_shift_q[element] <= '0;
          else
            fill_row_shift_q[element] <= fill_row_shift_q[element + 1];
        end
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tile_valid_q <= '0;
      fill_active_q <= 1'b0;
      fill_slot_q <= '0;
      fill_head_q <= '0;
      fill_reduction_tile_q <= '0;
      fill_expected_row_q <= '0;
      replay_active_q <= 1'b0;
      replay_slot_q <= '0;
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
      if (clear_error_i)
        local_error_q <= 1'b0;
      for (int slice = 0; slice < VALID_SLICES; slice++) begin
        if (invalidate_tile_slice[slice])
          tile_valid_q[slice * 16 +: 16] <= '0;
      end
      if (invalidate_i &&
          (fill_active_q || replay_active_q || replay_out_valid_q))
        local_error_q <= 1'b1;

      if (fill_start_fire) begin
        fill_active_q <= 1'b1;
        fill_slot_q <= fill_slot_i;
        fill_head_q <= fill_tile_i[TILE_INDEX_W-1 -: HEAD_W];
        fill_reduction_tile_q <= fill_tile_i[TILE_W-1:0];
        fill_expected_row_q <= '0;
      end
      if (fill_row_valid_i && !fill_row_ready_o)
        local_error_q <= 1'b1;
      if (fill_row_fire) begin
        if (fill_row_index_i != fill_expected_row_q ||
            fill_row_last_i != (fill_expected_row_q == COL_W'(COLUMNS - 1)))
          local_error_q <= 1'b1;
        if (fill_expected_row_q == COL_W'(COLUMNS - 1)) begin
          fill_active_q <= 1'b0;
          fill_expected_row_q <= '0;
          tile_valid_q[
              {fill_slot_q, fill_head_q, fill_reduction_tile_q}] <= 1'b1;
          fill_done_o <= 1'b1;
        end else begin
          fill_expected_row_q <= fill_expected_row_q + COL_W'(1);
        end
      end

      // A ready/valid producer holds this descriptor stable until acceptance.
      // Evict on the offer, after the completion update above, so cache fill
      // readiness cannot feed back into the wide tile-valid next-state cone.
      if (fill_start_valid_i)
        tile_valid_q[{fill_slot_i, fill_tile_i}] <= 1'b0;

      if (replay_start_fire) begin
        replay_active_q <= 1'b1;
        replay_slot_q <= replay_slot_i;
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
          ({1'b0, fill_slot_i} >= (SLOT_W + 1)'(Q_SLOTS) ||
           {1'b0, fill_tile_i} >=
              (TILE_INDEX_W + 1)'(Q_HEADS * REDUCTION_TILES)))
        local_error_q <= 1'b1;
      if (replay_start_valid_i &&
          {1'b0, replay_slot_i} >= (SLOT_W + 1)'(Q_SLOTS))
        local_error_q <= 1'b1;
      if (replay_start_valid_i && !replay_request_valid_tiles)
        local_error_q <= 1'b1;
    end
  end

  initial begin
    if (Q_HEADS != 16 || Q_SLOTS < 1 || Q_SLOTS > 4 ||
        REDUCTION_TILES != 8 || COLUMNS != 16)
      $error("packed Q column cache targets up to four 16x128 Q slots");
    if (TILE_VALID_BITS % 16 != 0)
      $error("packed Q tile-valid vector must divide into 16-bit slices");
  end
endmodule
