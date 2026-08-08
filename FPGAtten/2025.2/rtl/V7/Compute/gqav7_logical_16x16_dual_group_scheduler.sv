// Converts one V5-compatible logical 16x16 QK reduction beat into four
// physical V7 8x8 dual-GQA-group micro-operations.
//
// Two logical waves are interleaved by the caller:
//   context[2]   = logical wave (groups 0..3 or groups 4..7)
//   context[1]   = logical row half / GQA group pair
//   context[0]   = logical column half
// This produces eight independent recurrence contexts, exactly matching the
// eight-cycle BF16-multiply plus FP32-add recurrence latency of the V7 engine.
module gqav7_logical_16x16_dual_group_scheduler #(
  parameter int unsigned TILE_CONTEXTS = 1,
  localparam int unsigned TILE_CONTEXT_W =
      (TILE_CONTEXTS <= 1) ? 1 : $clog2(TILE_CONTEXTS),
  localparam int unsigned PHYSICAL_CONTEXT_W =
      $clog2(8 * TILE_CONTEXTS)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic logical_valid_i,
  output logic logical_ready_o,
  input  logic [TILE_CONTEXT_W-1:0] logical_tile_context_i,
  input  logic logical_wave_i,
  input  logic logical_first_i,
  input  logic logical_last_i,
  input  logic [15:0] logical_row_valid_i,
  input  logic [15:0] logical_col_valid_i,
  input  logic [15:0] q_bf16_i [16],
  input  logic [15:0] k_group_bf16_i [4][16],

  output logic micro_valid_o,
  input  logic micro_ready_i,
  output logic [PHYSICAL_CONTEXT_W-1:0] micro_context_o,
  output logic micro_first_o,
  output logic micro_last_o,
  output logic [7:0] micro_row_valid_o,
  output logic [7:0] micro_col_valid_o,
  output logic [15:0] micro_a_bf16_o [8],
  output logic [15:0] micro_b_group_bf16_o [2][8],

  input  logic [PHYSICAL_CONTEXT_W-1:0] result_context_i,
  input  logic [2:0] result_row_i,
  output logic [TILE_CONTEXT_W-1:0] result_tile_context_o,
  output logic result_wave_o,
  output logic [3:0] result_logical_row_o,
  output logic [3:0] result_logical_col_base_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic buffer_full_q;
  logic [1:0] micro_index_q;
  logic [TILE_CONTEXT_W-1:0] tile_context_q;
  logic wave_q;
  logic first_q;
  logic last_q;
  logic [15:0] row_valid_q;
  logic [15:0] col_valid_q;
  logic [15:0] q_q [16];
  logic [15:0] k_group_q [4][16];
  logic q_capture_local [16];
  logic k_capture_branch [4][2];
  logic k_capture_local [4][16][2];
  logic logical_accept;
  logic micro_accept;
  logic pair_select;
  logic col_half_select;

  assign micro_valid_o = buffer_full_q;
  assign micro_accept = micro_valid_o && micro_ready_i;
  assign logical_ready_o =
      !buffer_full_q ||
      (micro_accept && (micro_index_q == 2'd3));
  assign logical_accept = logical_valid_i && logical_ready_o;
  assign pair_select = micro_index_q[1];
  assign col_half_select = micro_index_q[0];

  generate
    if (TILE_CONTEXTS == 1) begin : gen_single_tile_context
      assign micro_context_o = {wave_q, pair_select, col_half_select};
      assign result_tile_context_o = '0;
    end else begin : gen_multi_tile_context
      assign micro_context_o = {
          tile_context_q, wave_q, pair_select, col_half_select
      };
      assign result_tile_context_o =
          result_context_i[PHYSICAL_CONTEXT_W-1:3];
    end
  endgenerate
  assign micro_first_o = first_q;
  assign micro_last_o = last_q;
  assign micro_row_valid_o =
      pair_select ? row_valid_q[15:8] : row_valid_q[7:0];
  assign micro_col_valid_o =
      col_half_select ? col_valid_q[15:8] : col_valid_q[7:0];

  always_comb begin
    for (int row = 0; row < 8; row++)
      micro_a_bf16_o[row] =
          pair_select ? q_q[row + 8] : q_q[row];
    for (int group = 0; group < 2; group++) begin
      for (int col = 0; col < 8; col++) begin
        micro_b_group_bf16_o[group][col] =
            k_group_q[{pair_select, 1'b0} + group]
                     [{col_half_select, 3'b000} + col];
      end
    end
  end

  assign result_wave_o = result_context_i[2];
  assign result_logical_row_o = {result_context_i[1], result_row_i};
  assign result_logical_col_base_o = {result_context_i[0], 3'b000};

  // Payload is architecturally visible only while buffer_full_q is set.  Open
  // its capture window whenever the one-entry scheduler can accept data, even
  // if logical_valid_i is low; an idle write is overwritten before it can be
  // observed.  This keeps upstream QK/result-retirement valid logic out of the
  // 1280 payload CEs.  Physically explicit LUT1 branches and leaves then keep
  // the remaining local-ready fanout bounded.
  generate
    for (genvar row = 0; row < 16; row++) begin : gen_q_capture_enable
      gqav5_local_control_buffer i_q_capture_enable (
        .in_i (logical_ready_o),
        .out_o(q_capture_local[row])
      );
    end
    for (genvar group = 0; group < 4; group++) begin : gen_k_group
      for (genvar col_half = 0; col_half < 2;
           col_half++) begin : gen_k_capture_branch
        gqav5_local_control_buffer i_k_capture_branch (
          .in_i (logical_ready_o),
          .out_o(k_capture_branch[group][col_half])
        );
      end
      for (genvar col = 0; col < 16; col++) begin : gen_k_capture_enable
        for (genvar bit_half = 0; bit_half < 2;
             bit_half++) begin : gen_k_capture_leaf
          gqav5_local_control_buffer i_k_capture_enable (
            .in_i (k_capture_branch[group][col / 8]),
            .out_o(k_capture_local[group][col][bit_half])
          );
        end
      end
    end
  endgenerate

  // These captured vectors are payload-only.  The resettable buffer_full_q
  // bit owns their visibility, so reset gating thousands of payload FFs only
  // creates a high-fanout CE/control-set network without adding correctness.
  always_ff @(posedge clk_i) begin : p_payload
    for (int row = 0; row < 16; row++)
      if (q_capture_local[row])
        q_q[row] <= q_bf16_i[row];
    for (int group = 0; group < 4; group++)
      for (int col = 0; col < 16; col++) begin
        if (k_capture_local[group][col][0])
          k_group_q[group][col][7:0] <=
              k_group_bf16_i[group][col][7:0];
        if (k_capture_local[group][col][1])
          k_group_q[group][col][15:8] <=
              k_group_bf16_i[group][col][15:8];
      end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      buffer_full_q <= 1'b0;
      micro_index_q <= '0;
      tile_context_q <= '0;
      wave_q <= 1'b0;
      first_q <= 1'b0;
      last_q <= 1'b0;
      row_valid_q <= '0;
      col_valid_q <= '0;
    end else begin
      if (logical_accept) begin
        tile_context_q <= logical_tile_context_i;
        wave_q <= logical_wave_i;
        first_q <= logical_first_i;
        last_q <= logical_last_i;
        row_valid_q <= logical_row_valid_i;
        col_valid_q <= logical_col_valid_i;
      end
      if (micro_accept) begin
        if (micro_index_q == 2'd3) begin
          micro_index_q <= '0;
          buffer_full_q <= logical_accept;
        end else begin
          micro_index_q <= micro_index_q + 2'd1;
        end
      end else if (logical_accept) begin
        micro_index_q <= '0;
        buffer_full_q <= 1'b1;
      end
    end
  end

  initial begin
    if ((TILE_CONTEXTS & (TILE_CONTEXTS - 1)) != 0)
      $error("TILE_CONTEXTS must be a power of two");
  end
endmodule
