module gqav5_resident_operand_frontend #(
  parameter int unsigned Q_HEADS_PER_KV = 4,
  parameter bit ENABLE_ROW_COMPAT = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,
  input  logic invalidate_q_i,
  input  logic invalidate_kv_i,

  input  logic dma_q_fill_valid_i,
  output logic dma_q_fill_ready_o,
  input  logic [15:0] dma_q_fill_tag_i,
  input  logic dma_q_fill_row_valid_i,
  output logic dma_q_fill_row_ready_o,
  input  logic [3:0] dma_q_fill_row_addr_i,
  input  logic [255:0] dma_q_fill_row_data_i,
  input  logic dma_q_fill_row_last_i,
  input  logic dma_k_fill_valid_i,
  output logic dma_k_fill_ready_o,
  input  logic [15:0] dma_k_fill_tag_i,
  input  logic dma_k_fill_row_valid_i,
  output logic dma_k_fill_row_ready_o,
  input  logic [3:0] dma_k_fill_row_addr_i,
  input  logic [255:0] dma_k_fill_row_data_i,
  input  logic dma_k_fill_row_last_i,
  input  logic dma_v_fill_valid_i,
  output logic dma_v_fill_ready_o,
  input  logic [15:0] dma_v_fill_tag_i,
  input  logic dma_v_fill_row_valid_i,
  output logic dma_v_fill_row_ready_o,
  input  logic [3:0] dma_v_fill_row_addr_i,
  input  logic [255:0] dma_v_fill_row_data_i,
  input  logic dma_v_fill_row_last_i,

  input  logic replay_valid_i,
  output logic replay_ready_o,
  input  gqav5_pkg::gqav5_dma_op_e replay_op_i,
  input  gqav5_pkg::gqav5_tile_desc_t replay_desc_i,

  output logic q_fill_valid_o,
  input  logic q_fill_ready_i,
  output logic [15:0] q_fill_tag_o,
  output logic q_fill_row_valid_o,
  input  logic q_fill_row_ready_i,
  output logic [3:0] q_fill_row_addr_o,
  output logic [255:0] q_fill_row_data_o,
  output logic q_fill_row_last_o,
  output logic k_fill_valid_o,
  input  logic k_fill_ready_i,
  output logic k_fill_broadcast_o,
  output logic [1:0] k_fill_partition_o,
  output logic [15:0] k_fill_tag_o,
  output logic k_fill_row_valid_o,
  input  logic k_fill_row_ready_i,
  output logic [3:0] k_fill_row_addr_o,
  output logic [255:0] k_fill_row_data_o,
  output logic k_fill_row_last_o,
  output logic qk_stream_start_valid_o,
  input  logic qk_stream_start_ready_i,
  output logic [15:0] qk_stream_start_tag_o,
  output logic qk_stream_row_valid_o,
  input  logic qk_stream_row_ready_i,
  output logic [3:0] qk_stream_row_index_o,
  output logic [255:0] qk_stream_q_row_bf16_o,
  output logic [255:0] qk_stream_k_partition_row_bf16_o [4],
  output logic qk_stream_row_last_o,
  output logic qk_column_start_valid_o,
  input  logic qk_column_start_ready_i,
  output logic [15:0] qk_column_start_tag_o,
  output logic qk_column_valid_o,
  input  logic qk_column_ready_i,
  output logic [3:0] qk_column_index_o,
  output logic [255:0] qk_column_q_word_bf16_o,
  output logic [255:0] qk_column_k_partition_word_bf16_o [4],
  output logic qk_column_last_o,
  output logic pv_stream_start_valid_o,
  input  logic pv_stream_start_ready_i,
  output logic [15:0] pv_stream_start_tag_o,
  output logic pv_stream_row_valid_o,
  input  logic pv_stream_row_ready_i,
  output logic [3:0] pv_stream_row_index_o,
  output logic [255:0] pv_stream_v_partition_row_bf16_o [4],
  output logic pv_stream_row_last_o,
  output logic v_fill_valid_o,
  input  logic v_fill_ready_i,
  output logic v_fill_broadcast_o,
  output logic [1:0] v_fill_partition_o,
  output logic [15:0] v_fill_tag_o,
  output logic v_fill_row_valid_o,
  input  logic v_fill_row_ready_i,
  output logic [3:0] v_fill_row_addr_o,
  output logic [255:0] v_fill_row_data_o,
  output logic v_fill_row_last_o,

  output logic active_o,
  output logic [127:0] resident_q_tiles_o,
  output logic [127:0] resident_k_tiles_o,
  output logic [127:0] resident_v_tiles_o,
  output logic [63:0] replay_command_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_STREAM,
    ST_PACK_Q_START,
    ST_PACK_Q_STREAM,
    ST_PACK_Q_PAD,
    ST_PACK_QK_STREAM,
    ST_PACK_V_STREAM
  } state_t;
  state_t state_q;
  gqav5_dma_op_e active_op_q;
  logic [15:0] active_tag_q;
  logic [2:0] active_reduction_tile_q;
  logic [1:0] pack_q_lane_q;
  logic [1:0] pack_kv_partition_q;
  logic active_kv_wave_packed_q;
  logic [1:0] active_kv_partition_q;
  logic [3:0] pack_pad_row_q;
  logic [2:0] pack_wave_tile_q;
  logic packed_qk_active_q;
  logic [15:0] packed_qk_tag_q;
  logic local_error_q;
  logic selected_cache_ready;
  logic selected_fill_ready;
  logic replay_fire;
  logic [15:0] replay_tag;

  logic q_cache_replay_start_valid;
  logic q_cache_replay_start_ready;
  logic q_cache_row_valid;
  logic q_cache_row_ready;
  logic [255:0] q_cache_row_data;
  logic [3:0] q_cache_row_index;
  logic q_cache_row_last;
  logic q_cache_replay_done;
  logic q_cache_error;
  logic k_cache_replay_start_valid;
  logic k_cache_replay_start_ready;
  logic k_cache_row_valid;
  logic k_cache_row_ready;
  logic [255:0] k_cache_row_data;
  logic [255:0] k_cache_partition_row_data [4];
  logic [3:0] k_cache_row_index;
  logic k_cache_row_last;
  logic k_cache_replay_done;
  logic k_cache_error;
  logic v_cache_replay_start_valid;
  logic v_cache_replay_start_ready;
  logic v_cache_row_valid;
  logic v_cache_row_ready;
  logic [255:0] v_cache_row_data;
  logic [255:0] v_cache_partition_row_data [4];
  logic [3:0] unused_v_partition_valid;
  logic [3:0] v_cache_row_index;
  logic v_cache_row_last;
  logic v_cache_replay_done;
  logic v_cache_error;
  logic [2:0] cache_fill_done;
  logic [2:0] cache_fill_active;
  logic [2:0] cache_replay_active;
  logic [15:0] cache_replay_tag [3];
  logic packed_qk_request;
  logic packed_qk_resident_ready;
  logic packed_pv_request;
  logic packed_pv_resident_ready;
  logic packed_qk_initial_start;
  logic packed_qk_columns_valid;
  logic packed_qk_column_fire;
  logic packed_qk_column_accept_ready;
  logic packed_qk_column_lookahead_start;
  logic q_direct_fill_start_ready, q_direct_fill_row_ready;
  logic k_direct_fill_start_ready, k_direct_fill_row_ready;
  logic q_row_fill_start_ready, q_row_fill_row_ready;
  logic k_row_fill_start_ready, k_row_fill_row_ready;
  logic q_row_fill_start_valid, q_row_fill_row_valid;
  logic k_row_fill_start_valid, k_row_fill_row_valid;
  logic q_direct_fill_start_valid, q_direct_fill_row_valid;
  logic k_direct_fill_start_valid, k_direct_fill_row_valid;
  logic q_direct_replay_start_valid, q_direct_replay_start_ready;
  logic k_direct_replay_start_valid, k_direct_replay_start_ready;
  logic q_direct_column_valid, q_direct_column_ready;
  logic k_direct_column_valid, k_direct_column_ready;
  logic [255:0] q_direct_column_word;
  logic [255:0] k_direct_partition_column_word [4];
  logic [3:0] q_direct_column_index, k_direct_column_index;
  logic q_direct_column_last, k_direct_column_last;
  logic [15:0] q_direct_replay_tag, k_direct_replay_tag;
  logic q_direct_replay_done, k_direct_replay_done;
  logic [511:0] direct_q_tiles;
  logic [3:0] direct_q_slot_valid;
  logic [127:0] direct_k_tiles;
  logic [127:0] row_q_tiles;
  logic [127:0] row_k_tiles;
  logic [1:0] dma_k_fill_partition;
  logic [1:0] dma_v_fill_partition;
  logic [4:0] dma_k_row_fill_tile;
  logic [4:0] dma_v_fill_tile;
  logic q_direct_error, k_direct_error;
  logic unused_q_direct_fill_done, unused_k_direct_fill_done;
  logic unused_q_direct_fill_active, unused_q_direct_replay_active;
  logic unused_k_direct_fill_active, unused_k_direct_transpose_active;
  logic unused_k_direct_replay_active;
  logic [63:0] unused_direct_counts [5];
  logic [3:0] unused_k_partition_valid;
  logic unused_cache_status;
  logic [63:0] unused_counts [9];

  assign replay_tag = (replay_op_i == GQAV5_DMA_LOAD_V)
      ? {replay_desc_i.txn_id[12:0], replay_desc_i.output_tile}
      : {replay_desc_i.txn_id[12:0], replay_desc_i.reduction_tile};
  assign dma_k_fill_partition = dma_k_fill_tag_i[6:5];
  assign dma_v_fill_partition = dma_v_fill_tag_i[6:5];
  assign dma_k_row_fill_tile = dma_k_fill_tag_i[4:0];
  assign dma_v_fill_tile = dma_v_fill_tag_i[4:0];
  assign packed_qk_request =
      ((state_q == ST_IDLE) || (state_q == ST_PACK_V_STREAM)) &&
      !packed_qk_active_q && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_Q) && replay_desc_i.kv_wave_packed;
  assign packed_pv_request = (state_q == ST_IDLE) && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_V) && replay_desc_i.kv_wave_packed;
  // A command-level K request is considered issued before its AXI payload has
  // necessarily reached the resident BRAM.  The former per-tile replay order
  // hid that latency; a single continuous wave must explicitly wait until all
  // 16 Q x 8 reduction tiles and all 4 K x 8 reduction tiles are resident.
  always_comb begin
    packed_qk_resident_ready = direct_q_slot_valid[
        replay_desc_i.prefill_direct ? replay_desc_i.q_lane : 2'd0];
    for (int part = 0; part < 4; part++) begin
      packed_qk_resident_ready &=
          &direct_k_tiles[part * 32 +
                          replay_desc_i.context_tile[1:0] * 8 +: 8];
      if (ENABLE_ROW_COMPAT)
        packed_qk_resident_ready &=
            &row_k_tiles[part * 32 +
                         replay_desc_i.context_tile[1:0] * 8 +: 8];
    end
    if (ENABLE_ROW_COMPAT)
      packed_qk_resident_ready &= &row_q_tiles;
  end
  assign packed_pv_resident_ready =
      resident_v_tiles_o[{2'd0, replay_desc_i.context_tile[1:0],
                          replay_desc_i.output_tile}] &&
      resident_v_tiles_o[{2'd1, replay_desc_i.context_tile[1:0],
                          replay_desc_i.output_tile}] &&
      resident_v_tiles_o[{2'd2, replay_desc_i.context_tile[1:0],
                          replay_desc_i.output_tile}] &&
      resident_v_tiles_o[{2'd3, replay_desc_i.context_tile[1:0],
                          replay_desc_i.output_tile}];
  assign resident_q_tiles_o = ENABLE_ROW_COMPAT ? row_q_tiles :
                                                   direct_q_tiles[127:0];
  assign resident_k_tiles_o = ENABLE_ROW_COMPAT ? row_k_tiles :
                                                   direct_k_tiles;

  always_comb begin
    selected_cache_ready = 1'b0;
    selected_fill_ready = 1'b0;
    unique case (replay_op_i)
      GQAV5_DMA_LOAD_Q: begin
        selected_cache_ready = replay_desc_i.kv_wave_packed
            ? (q_direct_replay_start_ready &&
               k_direct_replay_start_ready && packed_qk_resident_ready)
            : q_cache_replay_start_ready;
        selected_fill_ready = replay_desc_i.kv_wave_packed
            ? qk_column_start_ready_i : q_fill_ready_i;
      end
      GQAV5_DMA_LOAD_K: begin
        selected_cache_ready = k_cache_replay_start_ready;
        selected_fill_ready = k_fill_ready_i;
      end
      GQAV5_DMA_LOAD_V: begin
        selected_cache_ready = v_cache_replay_start_ready &&
            (!replay_desc_i.kv_wave_packed || packed_pv_resident_ready);
        selected_fill_ready = replay_desc_i.kv_wave_packed
            ? pv_stream_start_ready_i : v_fill_ready_i;
      end
      default: begin
        selected_cache_ready = 1'b0;
        selected_fill_ready = 1'b0;
      end
    endcase
  end

  // Packed QK reads the Q/K column caches while packed PV reads the V row
  // cache.  Keep their command and stream lifetimes independent so the next
  // group's Q wave no longer pauses the current group's V stream.
  assign replay_ready_o = selected_cache_ready && selected_fill_ready &&
      (((state_q == ST_IDLE) &&
        (!packed_qk_active_q ||
         ((replay_op_i == GQAV5_DMA_LOAD_V) &&
          replay_desc_i.kv_wave_packed))) ||
       ((state_q == ST_PACK_V_STREAM) && !packed_qk_active_q &&
        (replay_op_i == GQAV5_DMA_LOAD_Q) &&
        replay_desc_i.kv_wave_packed));
  assign replay_fire = replay_valid_i && replay_ready_o;

  // The compatibility row caches and packed column caches observe every Q/K
  // DMA fill atomically.  Gating each valid with the peer ready prevents one
  // representation from accepting a command or row beat on its own.
  generate
    if (ENABLE_ROW_COMPAT) begin : gen_atomic_row_column_fill
      assign dma_q_fill_ready_o = q_row_fill_start_ready &&
                                  q_direct_fill_start_ready;
      assign q_row_fill_start_valid = dma_q_fill_valid_i &&
                                      q_direct_fill_start_ready;
      assign q_direct_fill_start_valid = dma_q_fill_valid_i &&
                                         q_row_fill_start_ready;
      assign dma_q_fill_row_ready_o = q_row_fill_row_ready &&
                                      q_direct_fill_row_ready;
      assign q_row_fill_row_valid = dma_q_fill_row_valid_i &&
                                    q_direct_fill_row_ready;
      assign q_direct_fill_row_valid = dma_q_fill_row_valid_i &&
                                       q_row_fill_row_ready;

      assign dma_k_fill_ready_o = k_row_fill_start_ready &&
                                  k_direct_fill_start_ready;
      assign k_row_fill_start_valid = dma_k_fill_valid_i &&
                                      k_direct_fill_start_ready;
      assign k_direct_fill_start_valid = dma_k_fill_valid_i &&
                                         k_row_fill_start_ready;
      assign dma_k_fill_row_ready_o = k_row_fill_row_ready &&
                                      k_direct_fill_row_ready;
      assign k_row_fill_row_valid = dma_k_fill_row_valid_i &&
                                    k_direct_fill_row_ready;
      assign k_direct_fill_row_valid = dma_k_fill_row_valid_i &&
                                       k_row_fill_row_ready;
    end else begin : gen_direct_only_fill
      assign dma_q_fill_ready_o = q_direct_fill_start_ready;
      assign q_row_fill_start_valid = 1'b0;
      assign q_direct_fill_start_valid = dma_q_fill_valid_i;
      assign dma_q_fill_row_ready_o = q_direct_fill_row_ready;
      assign q_row_fill_row_valid = 1'b0;
      assign q_direct_fill_row_valid = dma_q_fill_row_valid_i;

      assign dma_k_fill_ready_o = k_direct_fill_start_ready;
      assign k_row_fill_start_valid = 1'b0;
      assign k_direct_fill_start_valid = dma_k_fill_valid_i;
      assign dma_k_fill_row_ready_o = k_direct_fill_row_ready;
      assign k_row_fill_row_valid = 1'b0;
      assign k_direct_fill_row_valid = dma_k_fill_row_valid_i;
    end
  endgenerate

  assign q_cache_replay_start_valid =
      (((state_q == ST_IDLE) && replay_valid_i &&
        (replay_op_i == GQAV5_DMA_LOAD_Q) &&
        !replay_desc_i.kv_wave_packed && q_fill_ready_i) ||
       (state_q == ST_PACK_Q_START));
  assign k_cache_replay_start_valid =
      ((state_q == ST_IDLE) && replay_valid_i &&
       (replay_op_i == GQAV5_DMA_LOAD_K) && k_fill_ready_i);
  assign v_cache_replay_start_valid = (state_q == ST_IDLE) && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_V) &&
      (replay_desc_i.kv_wave_packed
          ? (pv_stream_start_ready_i && packed_pv_resident_ready)
          : v_fill_ready_i);
  assign q_fill_valid_o = (state_q == ST_IDLE) && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_Q) &&
      !replay_desc_i.kv_wave_packed && q_cache_replay_start_ready;
  assign k_fill_valid_o = (state_q == ST_IDLE) && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_K) && k_cache_replay_start_ready;
  assign v_fill_valid_o = (state_q == ST_IDLE) && replay_valid_i &&
      (replay_op_i == GQAV5_DMA_LOAD_V) &&
      !replay_desc_i.kv_wave_packed && v_cache_replay_start_ready;
  assign q_fill_tag_o = (state_q == ST_IDLE) ? replay_tag : active_tag_q;
  assign k_fill_tag_o = (state_q == ST_IDLE) ? replay_tag : active_tag_q;
  assign v_fill_tag_o = (state_q == ST_IDLE) ? replay_tag : active_tag_q;
  assign k_fill_partition_o = (state_q == ST_IDLE)
      ? replay_desc_i.kv_partition : active_kv_partition_q;
  assign v_fill_partition_o = (state_q == ST_IDLE)
      ? replay_desc_i.kv_partition : active_kv_partition_q;
  assign k_fill_broadcast_o = (state_q == ST_IDLE)
      ? !replay_desc_i.kv_wave_packed : !active_kv_wave_packed_q;
  assign v_fill_broadcast_o = (state_q == ST_IDLE)
      ? !replay_desc_i.kv_wave_packed : !active_kv_wave_packed_q;

  assign q_fill_row_valid_o =
      (((state_q == ST_STREAM) &&
        (active_op_q == GQAV5_DMA_LOAD_Q) && q_cache_row_valid) ||
       ((state_q == ST_PACK_Q_STREAM) && q_cache_row_valid &&
        (q_cache_row_index == 4'd0)) ||
       (state_q == ST_PACK_Q_PAD));
  assign k_fill_row_valid_o = (state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_K) && k_cache_row_valid;
  assign v_fill_row_valid_o = (state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_V) && v_cache_row_valid;
  assign q_cache_row_ready =
      (((state_q == ST_STREAM) &&
        (active_op_q == GQAV5_DMA_LOAD_Q) && q_fill_row_ready_i) ||
       ((state_q == ST_PACK_Q_STREAM) &&
        ((q_cache_row_index != 4'd0) || q_fill_row_ready_i)));
  assign k_cache_row_ready = ((state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_K) && k_fill_row_ready_i);
  assign v_cache_row_ready = ((state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_V) && v_fill_row_ready_i) ||
      ((state_q == ST_PACK_V_STREAM) && pv_stream_row_ready_i);
  assign q_fill_row_addr_o = (state_q == ST_PACK_Q_STREAM)
      ? (active_kv_wave_packed_q
          ? {pack_kv_partition_q, pack_q_lane_q}
          : {2'b00, pack_q_lane_q})
      : ((state_q == ST_PACK_Q_PAD) ? pack_pad_row_q : q_cache_row_index);
  assign q_fill_row_data_o = (state_q == ST_PACK_Q_PAD)
      ? '0 : q_cache_row_data;
  assign q_fill_row_last_o = (state_q == ST_STREAM)
      ? q_cache_row_last
      : (((state_q == ST_PACK_Q_STREAM) && active_kv_wave_packed_q &&
          (pack_kv_partition_q == 2'd3) &&
          (pack_q_lane_q == 2'd3)) ||
         ((state_q == ST_PACK_Q_PAD) && (pack_pad_row_q == 4'd15)));
  assign k_fill_row_addr_o = k_cache_row_index;
  assign k_fill_row_data_o = k_cache_row_data;
  assign k_fill_row_last_o = k_cache_row_last;
  assign v_fill_row_addr_o = v_cache_row_index;
  assign v_fill_row_data_o = v_cache_row_data;
  assign v_fill_row_last_o = v_cache_row_last;
  assign pv_stream_start_valid_o = packed_pv_request &&
                                   packed_pv_resident_ready &&
                                   v_cache_replay_start_ready;
  assign pv_stream_start_tag_o = replay_tag;
  assign pv_stream_row_valid_o = (state_q == ST_PACK_V_STREAM) &&
                                 v_cache_row_valid;
  assign pv_stream_row_index_o = v_cache_row_index;
  assign pv_stream_v_partition_row_bf16_o =
      v_cache_partition_row_data;
  assign pv_stream_row_last_o = v_cache_row_last;
  // Legacy packed-row stream remains present for compatibility builds, but
  // production packed waves now use the resident column layout below.
  assign qk_stream_start_valid_o = 1'b0;
  assign qk_stream_start_tag_o = '0;
  assign qk_stream_row_valid_o = 1'b0;
  assign qk_stream_row_index_o = '0;
  assign qk_stream_q_row_bf16_o = '0;
  assign qk_stream_k_partition_row_bf16_o = '{default: '0};
  assign qk_stream_row_last_o = 1'b0;
  assign packed_qk_initial_start = packed_qk_request &&
      packed_qk_resident_ready && q_direct_replay_start_ready &&
      k_direct_replay_start_ready;
  assign q_direct_replay_start_valid = packed_qk_request &&
      packed_qk_resident_ready && k_direct_replay_start_ready &&
      qk_column_start_ready_i;
  assign k_direct_replay_start_valid = packed_qk_request &&
      packed_qk_resident_ready && q_direct_replay_start_ready &&
      qk_column_start_ready_i;
  assign packed_qk_columns_valid = packed_qk_active_q &&
      q_direct_column_valid && k_direct_column_valid;
  assign packed_qk_column_lookahead_start = packed_qk_columns_valid &&
      q_direct_column_last && pack_wave_tile_q != 3'd7;
  assign qk_column_start_valid_o = packed_qk_initial_start ||
                                   packed_qk_column_lookahead_start;
  assign qk_column_start_tag_o = packed_qk_initial_start
      ? replay_tag : {packed_qk_tag_q[15:3], pack_wave_tile_q + 3'd1};
  assign packed_qk_column_accept_ready = qk_column_ready_i &&
      (!packed_qk_column_lookahead_start || qk_column_start_ready_i);
  assign qk_column_valid_o = packed_qk_columns_valid;
  assign packed_qk_column_fire = packed_qk_columns_valid &&
                                 packed_qk_column_accept_ready;
  assign q_direct_column_ready = packed_qk_active_q &&
      k_direct_column_valid && packed_qk_column_accept_ready;
  assign k_direct_column_ready = packed_qk_active_q &&
      q_direct_column_valid && packed_qk_column_accept_ready;
  assign qk_column_index_o = q_direct_column_index;
  assign qk_column_q_word_bf16_o = q_direct_column_word;
  assign qk_column_k_partition_word_bf16_o =
      k_direct_partition_column_word;
  assign qk_column_last_o = q_direct_column_last;
  assign active_o = (state_q != ST_IDLE) || packed_qk_active_q;
  assign protocol_error_o = local_error_q || q_cache_error ||
      k_cache_error || v_cache_error || q_direct_error || k_direct_error;

  generate
  if (ENABLE_ROW_COMPAT) begin : gen_q_row_cache
  gqav5_resident_tile_cache #(.TILE_COUNT(128)) i_q_cache (
    .clk_i,
    .rst_ni,
    .clear_error_i,
    .invalidate_i              (invalidate_q_i),
    .fill_start_valid_i        (q_row_fill_start_valid),
    .fill_start_ready_o        (q_row_fill_start_ready),
    .fill_tile_i               (dma_q_fill_tag_i[6:0]),
    .fill_row_valid_i          (q_row_fill_row_valid),
    .fill_row_ready_o          (q_row_fill_row_ready),
    .fill_row_index_i          (dma_q_fill_row_addr_i),
    .fill_row_data_i           (dma_q_fill_row_data_i),
    .fill_row_last_i           (dma_q_fill_row_last_i),
    .fill_done_o               (cache_fill_done[0]),
    .replay_start_valid_i      (q_cache_replay_start_valid),
    .replay_start_ready_o      (q_cache_replay_start_ready),
    .replay_tile_i             ((state_q == ST_IDLE)
                                   ? (replay_desc_i.kv_wave_packed
                                        ? {4'b0000,
                                           replay_desc_i.reduction_tile}
                                        : {replay_desc_i.kv_head[1:0],
                                           replay_desc_i.q_lane,
                                           replay_desc_i.reduction_tile})
                                   : {pack_kv_partition_q,
                                      pack_q_lane_q,
                                      active_reduction_tile_q}),
    .replay_tag_i              ((state_q == ST_IDLE)
                                   ? replay_tag : active_tag_q),
    .replay_row0_only_i        (((state_q == ST_IDLE) &&
                                  replay_desc_i.decode_packed) ||
                                 (state_q == ST_PACK_Q_START) ||
                                 (state_q == ST_PACK_Q_STREAM)),
    .replay_tile_sequence_i    ((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed),
    .replay_tile_stride_i      (((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed) ? 7'd8 : '0),
    .replay_sequence_rows_i    (((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed) ? 5'd16 : '0),
    .replay_wave_i             ((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed),
    .replay_wave_tiles_i       (((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed) ? 8'd8 : '0),
    .replay_wave_tile_stride_i (((state_q == ST_IDLE) &&
                                 replay_desc_i.kv_wave_packed) ? 7'd1 : '0),
    .replay_row_valid_o        (q_cache_row_valid),
    .replay_row_ready_i        (q_cache_row_ready),
    .replay_row_data_o         (q_cache_row_data),
    .replay_row_index_o        (q_cache_row_index),
    .replay_row_last_o         (q_cache_row_last),
    .replay_tag_o              (cache_replay_tag[0]),
    .replay_done_o             (q_cache_replay_done),
    .tile_valid_o              (row_q_tiles),
    .fill_active_o             (cache_fill_active[0]),
    .replay_active_o           (cache_replay_active[0]),
    .filled_tile_count_o       (unused_counts[0]),
    .replayed_tile_count_o     (unused_counts[1]),
    .replayed_row_count_o      (unused_counts[2]),
    .protocol_error_o          (q_cache_error)
  );
  end else begin : gen_no_q_row_cache
    assign q_row_fill_start_ready = 1'b0;
    assign q_row_fill_row_ready = 1'b0;
    assign q_cache_replay_start_ready = 1'b0;
    assign q_cache_row_valid = 1'b0;
    assign q_cache_row_data = '0;
    assign q_cache_row_index = '0;
    assign q_cache_row_last = 1'b0;
    assign q_cache_replay_done = 1'b0;
    assign q_cache_error = 1'b0;
    assign row_q_tiles = '0;
    assign cache_fill_done[0] = 1'b0;
    assign cache_fill_active[0] = 1'b0;
    assign cache_replay_active[0] = 1'b0;
    assign cache_replay_tag[0] = '0;
    assign unused_counts[0] = '0;
    assign unused_counts[1] = '0;
    assign unused_counts[2] = '0;
  end
  endgenerate

  gqav5_packed_q_column_cache i_q_column_cache (
    .clk_i,
    .rst_ni,
    .clear_error_i,
    .invalidate_i              (invalidate_q_i),
    .fill_start_valid_i        (q_direct_fill_start_valid),
    .fill_start_ready_o        (q_direct_fill_start_ready),
    .fill_slot_i               (dma_q_fill_tag_i[15:14]),
    .fill_tile_i               (dma_q_fill_tag_i[6:0]),
    .fill_row_valid_i          (q_direct_fill_row_valid),
    .fill_row_ready_o          (q_direct_fill_row_ready),
    .fill_row_index_i          (dma_q_fill_row_addr_i),
    .fill_row_data_i           (dma_q_fill_row_data_i),
    .fill_row_last_i           (dma_q_fill_row_last_i),
    .fill_done_o               (unused_q_direct_fill_done),
    .replay_start_valid_i      (q_direct_replay_start_valid),
    .replay_start_ready_o      (q_direct_replay_start_ready),
    .replay_slot_i             (replay_desc_i.prefill_direct
                                   ? replay_desc_i.q_lane : 2'd0),
    .replay_tile_i             (replay_desc_i.reduction_tile),
    .replay_tag_i              (replay_tag),
    .replay_wave_tiles_i       (4'd8),
    .replay_column_valid_o     (q_direct_column_valid),
    .replay_column_ready_i     (q_direct_column_ready),
    .replay_column_word_bf16_o (q_direct_column_word),
    .replay_column_index_o     (q_direct_column_index),
    .replay_column_last_o      (q_direct_column_last),
    .replay_tag_o              (q_direct_replay_tag),
    .replay_done_o             (q_direct_replay_done),
    .tile_valid_o              (direct_q_tiles),
    .slot_valid_o              (direct_q_slot_valid),
    .fill_active_o             (unused_q_direct_fill_active),
    .replay_active_o           (unused_q_direct_replay_active),
    .accepted_fill_row_count_o (unused_direct_counts[0]),
    .emitted_column_count_o    (unused_direct_counts[1]),
    .protocol_error_o          (q_direct_error)
  );

  assign k_cache_row_data =
      k_cache_partition_row_data[active_kv_partition_q];

  generate
  if (ENABLE_ROW_COMPAT) begin : gen_k_row_cache
  gqav5_partitioned_resident_tile_cache #(
    .TILES_PER_PARTITION(32), .PARTITIONS(4)
  ) i_k_cache (
    .clk_i,
    .rst_ni,
    .clear_error_i,
    .invalidate_i              (invalidate_kv_i),
    .fill_start_valid_i        (k_row_fill_start_valid),
    .fill_start_ready_o        (k_row_fill_start_ready),
    .fill_broadcast_i          (dma_k_fill_tag_i[15]),
    .fill_partition_i          (dma_k_fill_partition),
    .fill_tile_i               (dma_k_row_fill_tile),
    .fill_row_valid_i          (k_row_fill_row_valid),
    .fill_row_ready_o          (k_row_fill_row_ready),
    .fill_row_index_i          (dma_k_fill_row_addr_i),
    .fill_row_data_i           (dma_k_fill_row_data_i),
    .fill_row_last_i           (dma_k_fill_row_last_i),
    .fill_done_o               (cache_fill_done[1]),
    .replay_start_valid_i      (k_cache_replay_start_valid),
    .replay_start_ready_o      (k_cache_replay_start_ready),
    .replay_all_partitions_i   (packed_qk_request),
    .replay_partition_i        (replay_desc_i.kv_wave_packed
                                   ? replay_desc_i.kv_partition
                                   : replay_desc_i.kv_head[1:0]),
    .replay_tile_i             ({replay_desc_i.context_tile[1:0],
                                 replay_desc_i.reduction_tile}),
    .replay_tag_i              (replay_tag),
    .replay_wave_i             (packed_qk_request),
    .replay_wave_tiles_i       (packed_qk_request ? 5'd8 : '0),
    .replay_wave_tile_stride_i (packed_qk_request ? 4'd1 : '0),
    .replay_row_valid_o        (k_cache_row_valid),
    .replay_row_ready_i        (k_cache_row_ready),
    .replay_partition_row_data_o(k_cache_partition_row_data),
    .replay_partition_valid_o  (unused_k_partition_valid),
    .replay_row_index_o        (k_cache_row_index),
    .replay_row_last_o         (k_cache_row_last),
    .replay_tag_o              (cache_replay_tag[1]),
    .replay_done_o             (k_cache_replay_done),
    .tile_valid_o              (row_k_tiles),
    .fill_active_o             (cache_fill_active[1]),
    .replay_active_o           (cache_replay_active[1]),
    .filled_tile_count_o       (unused_counts[3]),
    .replayed_tile_count_o     (unused_counts[4]),
    .replayed_row_count_o      (unused_counts[5]),
    .protocol_error_o          (k_cache_error)
  );
  end else begin : gen_no_k_row_cache
    assign k_row_fill_start_ready = 1'b0;
    assign k_row_fill_row_ready = 1'b0;
    assign k_cache_replay_start_ready = 1'b0;
    assign k_cache_row_valid = 1'b0;
    assign k_cache_partition_row_data = '{default: '0};
    assign unused_k_partition_valid = '0;
    assign k_cache_row_index = '0;
    assign k_cache_row_last = 1'b0;
    assign k_cache_replay_done = 1'b0;
    assign k_cache_error = 1'b0;
    assign row_k_tiles = '0;
    assign cache_fill_done[1] = 1'b0;
    assign cache_fill_active[1] = 1'b0;
    assign cache_replay_active[1] = 1'b0;
    assign cache_replay_tag[1] = '0;
    assign unused_counts[3] = '0;
    assign unused_counts[4] = '0;
    assign unused_counts[5] = '0;
  end
  endgenerate

  gqav5_packed_k_column_cache #(
    .REDUCTION_TILES(32)
  ) i_k_column_cache (
    .clk_i,
    .rst_ni,
    .clear_error_i,
    .invalidate_i              (invalidate_kv_i),
    .fill_start_valid_i        (k_direct_fill_start_valid),
    .fill_start_ready_o        (k_direct_fill_start_ready),
    .fill_broadcast_i          (dma_k_fill_tag_i[15]),
    .fill_partition_i          (dma_k_fill_partition),
    .fill_tile_i               (dma_k_row_fill_tile),
    .fill_row_valid_i          (k_direct_fill_row_valid),
    .fill_row_ready_o          (k_direct_fill_row_ready),
    .fill_row_index_i          (dma_k_fill_row_addr_i),
    .fill_row_data_i           (dma_k_fill_row_data_i),
    .fill_row_last_i           (dma_k_fill_row_last_i),
    .fill_done_o               (unused_k_direct_fill_done),
    .replay_start_valid_i      (k_direct_replay_start_valid),
    .replay_start_ready_o      (k_direct_replay_start_ready),
    .replay_tile_i             ({replay_desc_i.context_tile[1:0],
                                 replay_desc_i.reduction_tile}),
    .replay_tag_i              (replay_tag),
    .replay_wave_tiles_i       (6'd8),
    .replay_column_valid_o     (k_direct_column_valid),
    .replay_column_ready_i     (k_direct_column_ready),
    .replay_partition_column_word_bf16_o(
        k_direct_partition_column_word),
    .replay_column_index_o     (k_direct_column_index),
    .replay_column_last_o      (k_direct_column_last),
    .replay_tag_o              (k_direct_replay_tag),
    .replay_done_o             (k_direct_replay_done),
    .tile_valid_o              (direct_k_tiles),
    .fill_active_o             (unused_k_direct_fill_active),
    .transpose_active_o        (unused_k_direct_transpose_active),
    .replay_active_o           (unused_k_direct_replay_active),
    .accepted_fill_row_count_o (unused_direct_counts[2]),
    .committed_column_count_o  (unused_direct_counts[3]),
    .emitted_column_count_o    (unused_direct_counts[4]),
    .protocol_error_o          (k_direct_error)
  );

  assign v_cache_row_data =
      v_cache_partition_row_data[active_kv_partition_q];

  gqav5_partitioned_resident_tile_cache #(
    .TILES_PER_PARTITION(32), .PARTITIONS(4)
  ) i_v_cache (
    .clk_i,
    .rst_ni,
    .clear_error_i,
    .invalidate_i              (invalidate_kv_i),
    .fill_start_valid_i        (dma_v_fill_valid_i),
    .fill_start_ready_o        (dma_v_fill_ready_o),
    .fill_broadcast_i          (dma_v_fill_tag_i[15]),
    .fill_partition_i          (dma_v_fill_partition),
    .fill_tile_i               (dma_v_fill_tile),
    .fill_row_valid_i          (dma_v_fill_row_valid_i),
    .fill_row_ready_o          (dma_v_fill_row_ready_o),
    .fill_row_index_i          (dma_v_fill_row_addr_i),
    .fill_row_data_i           (dma_v_fill_row_data_i),
    .fill_row_last_i           (dma_v_fill_row_last_i),
    .fill_done_o               (cache_fill_done[2]),
    .replay_start_valid_i      (v_cache_replay_start_valid),
    .replay_start_ready_o      (v_cache_replay_start_ready),
    .replay_all_partitions_i   (packed_pv_request),
    .replay_partition_i        (replay_desc_i.kv_wave_packed
                                   ? replay_desc_i.kv_partition
                                   : replay_desc_i.kv_head[1:0]),
    .replay_tile_i             ({replay_desc_i.context_tile[1:0],
                                 replay_desc_i.output_tile}),
    .replay_tag_i              (replay_tag),
    .replay_wave_i             (1'b0),
    .replay_wave_tiles_i       ('0),
    .replay_wave_tile_stride_i ('0),
    .replay_row_valid_o        (v_cache_row_valid),
    .replay_row_ready_i        (v_cache_row_ready),
    .replay_partition_row_data_o(v_cache_partition_row_data),
    .replay_partition_valid_o  (unused_v_partition_valid),
    .replay_row_index_o        (v_cache_row_index),
    .replay_row_last_o         (v_cache_row_last),
    .replay_tag_o              (cache_replay_tag[2]),
    .replay_done_o             (v_cache_replay_done),
    .tile_valid_o              (resident_v_tiles_o),
    .fill_active_o             (cache_fill_active[2]),
    .replay_active_o           (cache_replay_active[2]),
    .filled_tile_count_o       (unused_counts[6]),
    .replayed_tile_count_o     (unused_counts[7]),
    .replayed_row_count_o      (unused_counts[8]),
    .protocol_error_o          (v_cache_error)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                <= ST_IDLE;
      active_op_q            <= GQAV5_DMA_LOAD_Q;
      active_tag_q           <= '0;
      active_reduction_tile_q <= '0;
      pack_q_lane_q          <= '0;
      pack_kv_partition_q    <= '0;
      active_kv_wave_packed_q <= 1'b0;
      active_kv_partition_q  <= '0;
      pack_pad_row_q         <= '0;
      pack_wave_tile_q       <= '0;
      packed_qk_active_q     <= 1'b0;
      packed_qk_tag_q        <= '0;
      replay_command_count_o <= '0;
      local_error_q          <= 1'b0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (replay_fire) begin
        replay_command_count_o <= replay_command_count_o + 64'd1;
        if ((replay_op_i == GQAV5_DMA_LOAD_Q) &&
            replay_desc_i.kv_wave_packed) begin
          packed_qk_active_q <= 1'b1;
          packed_qk_tag_q <= replay_tag;
          pack_wave_tile_q <= '0;
        end else begin
          active_op_q            <= replay_op_i;
          active_tag_q           <= replay_tag;
          active_reduction_tile_q <= replay_desc_i.reduction_tile;
          pack_q_lane_q          <= '0;
          pack_kv_partition_q    <= replay_desc_i.kv_head[1:0];
          active_kv_wave_packed_q <= replay_desc_i.kv_wave_packed;
          active_kv_partition_q  <= replay_desc_i.kv_wave_packed
              ? replay_desc_i.kv_partition : replay_desc_i.kv_head[1:0];
          if ((replay_op_i == GQAV5_DMA_LOAD_V) &&
              replay_desc_i.kv_wave_packed)
            state_q <= ST_PACK_V_STREAM;
          else if ((replay_op_i == GQAV5_DMA_LOAD_Q) &&
                   replay_desc_i.decode_packed)
            state_q <= ST_PACK_Q_STREAM;
          else
            state_q <= ST_STREAM;
        end
      end
      if (state_q == ST_PACK_Q_START && q_cache_replay_start_ready)
        state_q <= ST_PACK_Q_STREAM;
      if (q_cache_replay_done) begin
        if (state_q == ST_PACK_Q_STREAM) begin
          if (pack_q_lane_q == 2'(Q_HEADS_PER_KV - 1)) begin
            pack_q_lane_q <= '0;
            if (active_kv_wave_packed_q &&
                pack_kv_partition_q != 2'd3) begin
              pack_kv_partition_q <= pack_kv_partition_q + 2'd1;
              state_q <= ST_PACK_Q_START;
            end else if (active_kv_wave_packed_q) begin
              pack_kv_partition_q <= '0;
              state_q <= ST_IDLE;
            end else begin
              pack_pad_row_q <= 4'(Q_HEADS_PER_KV);
              state_q <= ST_PACK_Q_PAD;
            end
          end else begin
            pack_q_lane_q <= pack_q_lane_q + 2'd1;
            state_q <= ST_PACK_Q_START;
          end
        end else begin
          if (state_q != ST_STREAM ||
              active_op_q != GQAV5_DMA_LOAD_Q)
            local_error_q <= 1'b1;
          state_q <= ST_IDLE;
        end
      end
      if (k_cache_replay_done || v_cache_replay_done) begin
        if (state_q == ST_PACK_V_STREAM && v_cache_replay_done) begin
          state_q <= ST_IDLE;
        end else if (state_q != ST_STREAM ||
            (k_cache_replay_done && active_op_q != GQAV5_DMA_LOAD_K) ||
            (v_cache_replay_done && active_op_q != GQAV5_DMA_LOAD_V))
          local_error_q <= 1'b1;
        else
          state_q <= ST_IDLE;
      end
      if (packed_qk_column_fire) begin
        if (q_direct_column_index != k_direct_column_index ||
            q_direct_column_last != k_direct_column_last ||
            q_direct_replay_tag != k_direct_replay_tag)
          local_error_q <= 1'b1;
        if (q_direct_column_last && pack_wave_tile_q != 3'd7)
          pack_wave_tile_q <= pack_wave_tile_q + 3'd1;
      end
      if (q_direct_replay_done || k_direct_replay_done) begin
        if (!packed_qk_active_q ||
            !(q_direct_replay_done && k_direct_replay_done) ||
            pack_wave_tile_q != 3'd7)
          local_error_q <= 1'b1;
        packed_qk_active_q <= 1'b0;
      end
      if (state_q == ST_PACK_Q_PAD && q_fill_row_ready_i) begin
        if (pack_pad_row_q == 4'd15)
          state_q <= ST_IDLE;
        else
          pack_pad_row_q <= pack_pad_row_q + 4'd1;
      end
      if (replay_valid_i && replay_op_i == GQAV5_DMA_STORE_O)
        local_error_q <= 1'b1;
    end
  end

  assign unused_cache_status = ^{unused_counts[0], unused_counts[1],
      unused_counts[2], unused_counts[3], unused_counts[4], unused_counts[5],
      unused_counts[6], unused_counts[7], unused_counts[8], cache_fill_done,
      cache_fill_active, cache_replay_active, cache_replay_tag[0],
      cache_replay_tag[1], cache_replay_tag[2], dma_q_fill_tag_i,
      dma_k_fill_tag_i, dma_v_fill_tag_i, replay_desc_i,
      qk_stream_start_ready_i, qk_stream_row_ready_i,
      qk_column_start_ready_i, qk_column_ready_i,
      pv_stream_start_ready_i, pv_stream_row_ready_i,
      unused_k_partition_valid, unused_v_partition_valid,
      unused_q_direct_fill_done, unused_k_direct_fill_done,
      unused_q_direct_fill_active, unused_q_direct_replay_active,
      unused_k_direct_fill_active, unused_k_direct_transpose_active,
      unused_k_direct_replay_active, unused_direct_counts[0],
      unused_direct_counts[1], unused_direct_counts[2],
      unused_direct_counts[3], unused_direct_counts[4],
      active_reduction_tile_q, q_cache_replay_start_valid,
      q_cache_row_ready, k_cache_replay_start_valid, k_cache_row_ready,
      q_row_fill_start_ready, q_row_fill_row_ready,
      k_row_fill_start_ready, k_row_fill_row_ready,
      q_row_fill_start_valid, q_row_fill_row_valid,
      k_row_fill_start_valid, k_row_fill_row_valid,
      direct_q_tiles[511:128]};

  initial begin
    if (Q_HEADS_PER_KV < 1 || Q_HEADS_PER_KV > 4)
      $error("Q_HEADS_PER_KV must fit the two-bit q_lane field");
  end
endmodule
