module gqav5_partitioned_resident_tile_cache #(
  parameter int unsigned DATA_W              = 256,
  parameter int unsigned PARTITIONS          = 4,
  parameter int unsigned TILES_PER_PARTITION = 8,
  parameter int unsigned ROWS                = 16,
  parameter int unsigned TAG_W               = 16,
  localparam int unsigned PART_W =
      (PARTITIONS <= 1) ? 1 : $clog2(PARTITIONS),
  localparam int unsigned TILE_W =
      (TILES_PER_PARTITION <= 1) ? 1 : $clog2(TILES_PER_PARTITION),
  localparam int unsigned ROW_W = (ROWS <= 1) ? 1 : $clog2(ROWS)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic invalidate_i,

  // DDR fill remains one partition/tile at a time.  Only local replay is
  // widened, so this does not increase the external AXI width.
  input  logic fill_start_valid_i,
  output logic fill_start_ready_o,
  input  logic fill_broadcast_i,
  input  logic [PART_W-1:0] fill_partition_i,
  input  logic [TILE_W-1:0] fill_tile_i,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [ROW_W-1:0] fill_row_index_i,
  input  logic [DATA_W-1:0] fill_row_data_i,
  input  logic fill_row_last_i,
  output logic fill_done_o,

  // Packed 4-KV replay starts all four local BRAM banks atomically and emits
  // one row from every partition per cycle.  Compatibility replay may select
  // just one partition.
  input  logic replay_start_valid_i,
  output logic replay_start_ready_o,
  input  logic replay_all_partitions_i,
  input  logic [PART_W-1:0] replay_partition_i,
  input  logic [TILE_W-1:0] replay_tile_i,
  input  logic [TAG_W-1:0] replay_tag_i,
  input  logic replay_wave_i,
  input  logic [TILE_W:0] replay_wave_tiles_i,
  input  logic [TILE_W-1:0] replay_wave_tile_stride_i,
  output logic replay_row_valid_o,
  input  logic replay_row_ready_i,
  output logic [DATA_W-1:0] replay_partition_row_data_o [PARTITIONS],
  output logic [PARTITIONS-1:0] replay_partition_valid_o,
  output logic [ROW_W-1:0] replay_row_index_o,
  output logic replay_row_last_o,
  output logic [TAG_W-1:0] replay_tag_o,
  output logic replay_done_o,

  output logic [PARTITIONS*TILES_PER_PARTITION-1:0] tile_valid_o,
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

  logic cache_fill_start_ready [PARTITIONS];
  logic cache_fill_row_ready [PARTITIONS];
  logic cache_fill_done [PARTITIONS];
  logic cache_replay_start_ready [PARTITIONS];
  logic cache_replay_row_valid [PARTITIONS];
  logic [DATA_W-1:0] cache_replay_row_data [PARTITIONS];
  logic [ROW_W-1:0] cache_replay_row_index [PARTITIONS];
  logic cache_replay_row_last [PARTITIONS];
  logic [TAG_W-1:0] cache_replay_tag [PARTITIONS];
  logic cache_replay_done [PARTITIONS];
  logic [TILES_PER_PARTITION-1:0] cache_tile_valid [PARTITIONS];
  logic cache_fill_active [PARTITIONS];
  logic cache_replay_active [PARTITIONS];
  logic cache_error [PARTITIONS];
  logic [63:0] unused_counts [PARTITIONS][3];

  logic [PART_W-1:0] fill_partition_q;
  logic fill_broadcast_q;
  logic [PARTITIONS-1:0] replay_mask_q;
  logic [PART_W-1:0] replay_source_partition_q;
  logic replay_active_q;
  logic all_selected_start_ready;
  logic replay_source_row_valid;
  logic all_selected_done;
  logic any_cache_fill_active;
  logic any_cache_replay_active;
  logic local_error_q;
  logic fill_start_fire;
  logic replay_start_fire;
  logic replay_row_fire;

  always_comb begin
    all_selected_start_ready = 1'b1;
    any_cache_fill_active = 1'b0;
    any_cache_replay_active = 1'b0;
    for (int unsigned part = 0; part < PARTITIONS; part++) begin
      any_cache_fill_active |= cache_fill_active[part];
      any_cache_replay_active |= cache_replay_active[part];
      if (replay_all_partitions_i ||
          replay_partition_i == PART_W'(part))
        all_selected_start_ready &= cache_replay_start_ready[part];
    end
  end

  always_comb begin
    fill_start_ready_o = 1'b1;
    if (fill_broadcast_i) begin
      for (int unsigned part = 0; part < PARTITIONS; part++)
        fill_start_ready_o &= cache_fill_start_ready[part];
    end else begin
      fill_start_ready_o = cache_fill_start_ready[fill_partition_i];
    end
  end
  assign fill_start_fire = fill_start_valid_i && fill_start_ready_o;
  always_comb begin
    fill_row_ready_o = 1'b1;
    fill_done_o = 1'b1;
    if (fill_broadcast_q) begin
      for (int unsigned part = 0; part < PARTITIONS; part++) begin
        fill_row_ready_o &= cache_fill_row_ready[part];
        fill_done_o &= cache_fill_done[part];
      end
    end else begin
      fill_row_ready_o = cache_fill_row_ready[fill_partition_q];
      fill_done_o = cache_fill_done[fill_partition_q];
    end
  end
  assign fill_active_o = any_cache_fill_active;

  assign replay_start_ready_o = !replay_active_q &&
                                all_selected_start_ready;
  assign replay_start_fire = replay_start_valid_i && replay_start_ready_o;

  always_comb begin
    all_selected_done = replay_active_q;
    for (int unsigned part = 0; part < PARTITIONS; part++) begin
      if (replay_mask_q[part])
        all_selected_done &= cache_replay_done[part];
    end
  end

  // Every selected partition receives the same replay start and the same
  // ready pulse, so the four local caches advance in lockstep.  Use the
  // registered leader valid on the forward datapath instead of AND-reducing
  // four physically distant valid nets.  The protocol check below still
  // reports any lockstep mismatch.
  assign replay_source_row_valid = replay_active_q &&
      cache_replay_row_valid[replay_source_partition_q];
  assign replay_row_valid_o = replay_source_row_valid;
  assign replay_row_fire = replay_row_valid_o && replay_row_ready_i;
  assign replay_partition_valid_o = replay_mask_q;
  assign replay_row_index_o =
      cache_replay_row_index[replay_source_partition_q];
  assign replay_row_last_o =
      cache_replay_row_last[replay_source_partition_q];
  assign replay_tag_o = cache_replay_tag[replay_source_partition_q];
  assign replay_done_o = all_selected_done;
  assign replay_active_o = replay_active_q || any_cache_replay_active;

  generate
    for (genvar part = 0; part < PARTITIONS; part++) begin : gen_partition
      assign replay_partition_row_data_o[part] =
          cache_replay_row_data[part];
      assign tile_valid_o[part * TILES_PER_PARTITION +:
                          TILES_PER_PARTITION] = cache_tile_valid[part];

      gqav5_resident_tile_cache #(
        .DATA_W(DATA_W), .TILE_COUNT(TILES_PER_PARTITION),
        .ROWS(ROWS), .TAG_W(TAG_W),
        .OVERWRITE_SLOT_TILES(
            TILES_PER_PARTITION >= 16 ? TILES_PER_PARTITION / 2 : 0)
      ) i_cache (
        .clk_i,
        .rst_ni,
        .clear_error_i,
        .invalidate_i,
        .fill_start_valid_i(fill_start_valid_i &&
            (fill_broadcast_i ||
             fill_partition_i == PART_W'(part))),
        .fill_start_ready_o(cache_fill_start_ready[part]),
        .fill_tile_i,
        .fill_row_valid_i(fill_row_valid_i &&
            (fill_broadcast_q ||
             fill_partition_q == PART_W'(part))),
        .fill_row_ready_o(cache_fill_row_ready[part]),
        .fill_row_index_i,
        .fill_row_data_i,
        .fill_row_last_i,
        .fill_done_o(cache_fill_done[part]),
        .replay_start_valid_i(replay_start_valid_i &&
            replay_start_ready_o &&
            (replay_all_partitions_i ||
             replay_partition_i == PART_W'(part))),
        .replay_start_ready_o(cache_replay_start_ready[part]),
        .replay_tile_i,
        .replay_tag_i,
        .replay_row0_only_i(1'b0),
        .replay_tile_sequence_i(1'b0),
        .replay_tile_stride_i('0),
        .replay_sequence_rows_i('0),
        .replay_wave_i,
        .replay_wave_tiles_i,
        .replay_wave_tile_stride_i,
        .replay_row_valid_o(cache_replay_row_valid[part]),
        .replay_row_ready_i(replay_row_ready_i &&
            replay_source_row_valid && replay_mask_q[part]),
        .replay_row_data_o(cache_replay_row_data[part]),
        .replay_row_index_o(cache_replay_row_index[part]),
        .replay_row_last_o(cache_replay_row_last[part]),
        .replay_tag_o(cache_replay_tag[part]),
        .replay_done_o(cache_replay_done[part]),
        .tile_valid_o(cache_tile_valid[part]),
        .fill_active_o(cache_fill_active[part]),
        .replay_active_o(cache_replay_active[part]),
        .filled_tile_count_o(unused_counts[part][0]),
        .replayed_tile_count_o(unused_counts[part][1]),
        .replayed_row_count_o(unused_counts[part][2]),
        .protocol_error_o(cache_error[part])
      );
    end
  endgenerate

  always_comb begin
    protocol_error_o = local_error_q;
    for (int unsigned part = 0; part < PARTITIONS; part++) begin
      protocol_error_o |= cache_error[part];
      if (replay_active_q && replay_mask_q[part]) begin
        if (cache_replay_row_valid[part] != replay_source_row_valid)
          protocol_error_o = 1'b1;
        else if (replay_source_row_valid &&
                 (cache_replay_row_index[part] != replay_row_index_o ||
                  cache_replay_row_last[part] != replay_row_last_o ||
                  cache_replay_tag[part] != replay_tag_o))
          protocol_error_o = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_partition_q <= '0;
      fill_broadcast_q <= 1'b0;
      replay_mask_q <= '0;
      replay_source_partition_q <= '0;
      replay_active_q <= 1'b0;
      filled_tile_count_o <= '0;
      replayed_tile_count_o <= '0;
      replayed_row_count_o <= '0;
      local_error_q <= 1'b0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (fill_start_fire) begin
        fill_partition_q <= fill_partition_i;
        fill_broadcast_q <= fill_broadcast_i;
      end
      if (fill_done_o)
        filled_tile_count_o <= filled_tile_count_o + 64'd1;

      if (replay_start_fire) begin
        replay_active_q <= 1'b1;
        replay_source_partition_q <= replay_all_partitions_i
            ? '0 : replay_partition_i;
        for (int unsigned part = 0; part < PARTITIONS; part++)
          replay_mask_q[part] <= replay_all_partitions_i ||
                                 replay_partition_i == PART_W'(part);
      end
      if (replay_row_fire)
        replayed_row_count_o <= replayed_row_count_o + 64'd1;
      if (replay_done_o) begin
        replay_active_q <= 1'b0;
        replay_mask_q <= '0;
        replayed_tile_count_o <= replayed_tile_count_o + 64'd1;
      end

      if (fill_start_valid_i &&
          ({1'b0, fill_partition_i} >= (PART_W + 1)'(PARTITIONS)))
        local_error_q <= 1'b1;
      if (replay_start_valid_i && !replay_all_partitions_i &&
          ({1'b0, replay_partition_i} >= (PART_W + 1)'(PARTITIONS)))
        local_error_q <= 1'b1;
    end
  end

  initial begin
    if (PARTITIONS != 4)
      $error("partitioned resident cache currently targets four KV banks");
    if (TILES_PER_PARTITION < 1 || ROWS < 1)
      $error("partitioned resident cache dimensions must be positive");
  end
endmodule
