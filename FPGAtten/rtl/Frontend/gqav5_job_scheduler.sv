module gqav5_job_scheduler #(
  parameter int unsigned MAX_SEQ_LEN = 8192,
  parameter int unsigned KV_HEAD_COUNT = 8,
  parameter int unsigned Q_HEADS_PER_KV = 4,
  localparam int unsigned TOKEN_W = $clog2(MAX_SEQ_LEN)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,

  input  logic start_i,
  input  logic [TOKEN_W:0] context_token_count_i,
  input  logic [TOKEN_W:0] query_token_count_i,
  input  logic [4:0] query_valid_rows_i,
  input  logic causal_i,
  input  logic kv_wave_packed_i,
  input  logic prefill_direct_i,

  output logic group_valid_o,
  input  logic group_ready_i,
  output gqav5_pkg::gqav5_tile_desc_t group_desc_o,
  input  logic group_done_i,
  input  logic drain_ready_i,

  output logic busy_o,
  output logic done_o,
  output logic [2:0] active_kv_head_o,
  output logic [8:0] active_context_tile_o,
  output logic [63:0] launched_group_count_o,
  output logic [63:0] completed_group_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_LAUNCH,
    ST_WAIT,
    ST_DRAIN
  } state_t;

  state_t state_q;
  logic [TOKEN_W:0] context_token_count_q;
  logic [TOKEN_W:0] query_token_count_q;
  logic [4:0] query_valid_rows_q;
  logic causal_q;
  logic kv_wave_packed_q;
  logic prefill_direct_q;
  logic [2:0] kv_head_q;
  logic [1:0] q_lane_q;
  logic [8:0] query_tile_q;
  logic [8:0] context_tile_q;
  logic [15:0] txn_base_q;
  logic local_error_q;
  logic [TOKEN_W:0] context_base;
  logic [TOKEN_W:0] context_remaining;
  logic [4:0] context_valid_cols;
  logic [TOKEN_W:0] query_base;
  logic [TOKEN_W:0] query_remaining;
  logic [4:0] query_tile_valid_rows;
  logic [TOKEN_W:0] next_context_base;
  logic [TOKEN_W:0] next_context_remaining;
  logic [4:0] next_context_valid_cols;
  logic group_fire;

  assign context_base = (TOKEN_W + 1)'(context_tile_q) << 4;
  assign query_base = (TOKEN_W + 1)'(query_tile_q) << 4;
  assign context_remaining = context_token_count_q - context_base;
  assign query_remaining = query_token_count_q - query_base;
  assign next_context_base = context_base + (TOKEN_W + 1)'(16);
  assign next_context_remaining =
      context_token_count_q - next_context_base;
  always_comb begin
    if (context_token_count_q <= context_base)
      context_valid_cols = 5'd0;
    else if (context_remaining >= (TOKEN_W + 1)'(16))
      context_valid_cols = 5'd16;
    else
      context_valid_cols = 5'(context_remaining);
  end
  always_comb begin
    if (query_token_count_q <= query_base)
      query_tile_valid_rows = 5'd0;
    else if (query_remaining >= (TOKEN_W + 1)'(16))
      query_tile_valid_rows = 5'd16;
    else
      query_tile_valid_rows = 5'(query_remaining);
  end
  always_comb begin
    if (context_token_count_q <= next_context_base)
      next_context_valid_cols = 5'd0;
    else if (next_context_remaining >= (TOKEN_W + 1)'(16))
      next_context_valid_cols = 5'd16;
    else
      next_context_valid_cols = 5'(next_context_remaining);
  end

  always_comb begin
    group_desc_o = '0;
    group_desc_o.kv_head = kv_head_q;
    group_desc_o.q_lane = prefill_direct_q ? q_lane_q : 2'd0;
    group_desc_o.q_head = {kv_head_q, prefill_direct_q ? q_lane_q : 2'd0};
    group_desc_o.kv_partition = 2'd0;
    group_desc_o.kv_wave_packed = kv_wave_packed_q;
    group_desc_o.prefill_direct = prefill_direct_q;
    group_desc_o.query_tile = prefill_direct_q ? query_tile_q : 9'd0;
    group_desc_o.context_tile = context_tile_q;
    group_desc_o.query_valid_rows = prefill_direct_q
        ? query_tile_valid_rows : query_valid_rows_q;
    group_desc_o.context_valid_cols = context_valid_cols;
    group_desc_o.next_context_valid_cols = next_context_valid_cols;
    group_desc_o.causal = causal_q;
    group_desc_o.first_context = context_tile_q == 0;
    group_desc_o.last_context =
        (context_base + (TOKEN_W + 1)'(16)) >= context_token_count_q;
    group_desc_o.last_output_tile = 1'b1;
    group_desc_o.txn_id = txn_base_q;
  end

  assign group_valid_o = state_q == ST_LAUNCH;
  assign group_fire = group_valid_o && group_ready_i;
  assign busy_o = state_q != ST_IDLE;
  assign active_kv_head_o = kv_head_q;
  assign active_context_tile_o = context_tile_q;
  assign protocol_error_o = local_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                 <= ST_IDLE;
      context_token_count_q   <= '0;
      query_token_count_q     <= '0;
      query_valid_rows_q      <= '0;
      causal_q                <= 1'b0;
      kv_wave_packed_q        <= 1'b0;
      prefill_direct_q        <= 1'b0;
      kv_head_q               <= '0;
      q_lane_q                <= '0;
      query_tile_q            <= '0;
      context_tile_q          <= '0;
      txn_base_q              <= '0;
      local_error_q           <= 1'b0;
      done_o                  <= 1'b0;
      launched_group_count_o  <= '0;
      completed_group_count_o <= '0;
    end else begin
      done_o <= 1'b0;
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (group_done_i && state_q != ST_WAIT)
        local_error_q <= 1'b1;

      unique case (state_q)
        ST_IDLE: begin
          if (start_i) begin
            if (context_token_count_i == 0 ||
                context_token_count_i > (TOKEN_W + 1)'(MAX_SEQ_LEN) ||
                query_valid_rows_i == 0 || query_valid_rows_i > 5'd16 ||
                (prefill_direct_i &&
                 (query_token_count_i == 0 ||
                  query_token_count_i > (TOKEN_W + 1)'(MAX_SEQ_LEN))) ||
                (kv_wave_packed_i && !prefill_direct_i &&
                 ((KV_HEAD_COUNT % 4) != 0))) begin
              local_error_q <= 1'b1;
              done_o <= 1'b1;
            end else begin
              context_token_count_q <= context_token_count_i;
              query_token_count_q   <= query_token_count_i;
              query_valid_rows_q    <= query_valid_rows_i;
              causal_q              <= causal_i;
              kv_wave_packed_q      <= kv_wave_packed_i;
              prefill_direct_q      <= prefill_direct_i;
              kv_head_q             <= 3'd0;
              q_lane_q              <= 2'd0;
              query_tile_q          <= 9'd0;
              context_tile_q        <= 9'd0;
              txn_base_q            <= 16'd0;
              state_q               <= ST_LAUNCH;
            end
          end
        end

        ST_LAUNCH: begin
          if (group_fire) begin
            launched_group_count_o <= launched_group_count_o + 64'd1;
            state_q <= ST_WAIT;
          end
        end

        ST_WAIT: begin
          if (group_done_i) begin
            completed_group_count_o <= completed_group_count_o + 64'd1;
            txn_base_q <= txn_base_q +
                (kv_wave_packed_q ? 16'd16 : 16'd4);
            if (prefill_direct_q &&
                q_lane_q != 2'(Q_HEADS_PER_KV - 1)) begin
              // Interleave the four Q heads at each context tile.  Their
              // softmax states occupy four independent slots, while the
              // current K/V slot remains resident and is consumed four times.
              q_lane_q <= q_lane_q + 2'd1;
              state_q  <= ST_LAUNCH;
            end else if (prefill_direct_q &&
                         (context_base + (TOKEN_W + 1)'(16)) <
                             context_token_count_q) begin
              q_lane_q       <= 2'd0;
              context_tile_q <= context_tile_q + 9'd1;
              state_q        <= ST_LAUNCH;
            end else if (!prefill_direct_q &&
                         (context_base + (TOKEN_W + 1)'(16)) <
                             context_token_count_q) begin
              context_tile_q <= context_tile_q + 9'd1;
              state_q <= ST_LAUNCH;
            end else if (({1'b0, kv_head_q} +
                          ((kv_wave_packed_q && !prefill_direct_q)
                              ? 4'd4 : 4'd1)) <
                         4'(KV_HEAD_COUNT)) begin
              kv_head_q      <= kv_head_q +
                  ((kv_wave_packed_q && !prefill_direct_q)
                      ? 3'd4 : 3'd1);
              q_lane_q       <= 2'd0;
              context_tile_q <= 9'd0;
              state_q        <= ST_LAUNCH;
            end else if (prefill_direct_q &&
                         ((query_base + (TOKEN_W + 1)'(16)) <
                          query_token_count_q)) begin
              query_tile_q   <= query_tile_q + 9'd1;
              kv_head_q      <= 3'd0;
              q_lane_q       <= 2'd0;
              context_tile_q <= 9'd0;
              state_q        <= ST_LAUNCH;
            end else begin
              state_q <= ST_DRAIN;
            end
          end
        end

        ST_DRAIN: begin
          if (drain_ready_i) begin
            done_o  <= 1'b1;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          local_error_q <= 1'b1;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  initial begin
    if (KV_HEAD_COUNT < 1 || KV_HEAD_COUNT > 8)
      $error("KV_HEAD_COUNT must fit the three-bit kv_head field");
    if (Q_HEADS_PER_KV < 1 || Q_HEADS_PER_KV > 4)
      $error("Q_HEADS_PER_KV must fit the two-bit q_lane field");
  end
endmodule
