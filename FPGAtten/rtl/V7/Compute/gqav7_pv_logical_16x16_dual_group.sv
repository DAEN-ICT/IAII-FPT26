// PV semantic wrapper around the V7 dual-group outer-product slice.
// In GQA, four probability rows share one V head, which is the same physical
// broadcast pattern as four Q rows sharing one K head in QK. Keeping one
// verified arithmetic implementation for both stages reduces divergence.
module gqav7_pv_logical_16x16_dual_group (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic logical_valid_i,
  output logic logical_ready_o,
  input  logic logical_wave_i,
  input  logic logical_first_i,
  input  logic logical_last_i,
  input  logic [15:0] logical_row_valid_i,
  input  logic [15:0] logical_col_valid_i,
  input  logic [15:0] p_bf16_i [16],
  input  logic [15:0] v_group_bf16_i [4][16],

  output logic result_valid_o,
  input  logic result_ready_i,
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

  gqav7_qk_logical_16x16_dual_group i_shared_outer_product (
    .clk_i,
    .rst_ni,
    .logical_valid_i,
    .logical_ready_o,
    .logical_tile_context_i('0),
    .logical_wave_i,
    .logical_first_i,
    .logical_last_i,
    .logical_row_valid_i,
    .logical_col_valid_i,
    .q_bf16_i(p_bf16_i),
    .k_group_bf16_i(v_group_bf16_i),
    .result_valid_o,
    .result_ready_i,
    .result_tile_context_o(),
    .result_wave_o,
    .result_logical_row_o,
    .result_logical_col_base_o,
    .result_data_o,
    .result_last_o,
    .accepted_macs_o,
    .protocol_error_o
  );
endmodule
