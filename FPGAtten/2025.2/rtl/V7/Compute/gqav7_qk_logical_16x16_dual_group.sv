// V7 QK compute slice: V5-compatible logical 16x16 beats on the input,
// dual-GQA-group physical 8x8 execution internally, and logical coordinates
// restored on the result stream.
module gqav7_qk_logical_16x16_dual_group #(
  parameter int unsigned TILE_CONTEXTS = 1,
  localparam int unsigned TILE_CONTEXT_W =
      (TILE_CONTEXTS <= 1) ? 1 : $clog2(TILE_CONTEXTS),
  localparam int unsigned PHYSICAL_CONTEXTS = 8 * TILE_CONTEXTS,
  localparam int unsigned PHYSICAL_CONTEXT_W =
      $clog2(PHYSICAL_CONTEXTS)
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

  output logic result_valid_o,
  input  logic result_ready_i,
  output logic [TILE_CONTEXT_W-1:0] result_tile_context_o,
  output logic result_wave_o,
  output logic [3:0] result_logical_row_o,
  output logic [3:0] result_logical_col_base_o,
  output logic [31:0] result_data_o [8],
  output logic result_last_o,

  output logic [63:0] accepted_macs_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic micro_valid;
  logic micro_ready;
  logic [PHYSICAL_CONTEXT_W-1:0] micro_context;
  logic micro_first;
  logic micro_last;
  logic [7:0] micro_row_valid;
  logic [7:0] micro_col_valid;
  logic [15:0] micro_a [8];
  logic [15:0] micro_b_group [2][8];
  logic [PHYSICAL_CONTEXT_W-1:0] result_context;
  logic [2:0] result_physical_row;

  gqav7_logical_16x16_dual_group_scheduler #(
    .TILE_CONTEXTS(TILE_CONTEXTS)
  ) i_scheduler (
    .clk_i,
    .rst_ni,
    .logical_valid_i,
    .logical_ready_o,
    .logical_tile_context_i,
    .logical_wave_i,
    .logical_first_i,
    .logical_last_i,
    .logical_row_valid_i,
    .logical_col_valid_i,
    .q_bf16_i,
    .k_group_bf16_i,
    .micro_valid_o(micro_valid),
    .micro_ready_i(micro_ready),
    .micro_context_o(micro_context),
    .micro_first_o(micro_first),
    .micro_last_o(micro_last),
    .micro_row_valid_o(micro_row_valid),
    .micro_col_valid_o(micro_col_valid),
    .micro_a_bf16_o(micro_a),
    .micro_b_group_bf16_o(micro_b_group),
    .result_context_i(result_context),
    .result_row_i(result_physical_row),
    .result_tile_context_o,
    .result_wave_o,
    .result_logical_row_o,
    .result_logical_col_base_o
  );

  gqav7_dual_group_outer_product_8x8 #(
    .CONTEXTS(PHYSICAL_CONTEXTS)
  ) i_engine (
    .clk_i,
    .rst_ni,
    .valid_i(micro_valid),
    .ready_o(micro_ready),
    .context_i(micro_context),
    .first_i(micro_first),
    .last_i(micro_last),
    .row_valid_i(micro_row_valid),
    .col_valid_i(micro_col_valid),
    .a_bf16_i(micro_a),
    .b_group_bf16_i(micro_b_group),
    .result_valid_o,
    .result_ready_i,
    .result_context_o(result_context),
    .result_row_o(result_physical_row),
    .result_data_o,
    .result_last_o,
    .accepted_macs_o,
    .protocol_error_o
  );

  initial begin
    if ((TILE_CONTEXTS & (TILE_CONTEXTS - 1)) != 0)
      $error("TILE_CONTEXTS must be a power of two");
  end
endmodule
