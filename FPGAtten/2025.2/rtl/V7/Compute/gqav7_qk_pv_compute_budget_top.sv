// Physical-budget gate for the two concurrently resident V7 arithmetic
// stages. This is not the AXI production top; it keeps QK and PV as separate
// 64-DSP pipelines so synthesis/route can measure the combined 128-DSP
// compute budget before the inherited Softmax/frontend integration is cut in.
module gqav7_qk_pv_compute_budget_top (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic qk_valid_i,
  output logic qk_ready_o,
  input  logic qk_wave_i,
  input  logic qk_first_i,
  input  logic qk_last_i,
  input  logic [15:0] qk_row_valid_i,
  input  logic [15:0] qk_col_valid_i,
  input  logic [15:0] q_bf16_i [16],
  input  logic [15:0] k_group_bf16_i [4][16],
  output logic qk_result_valid_o,
  input  logic qk_result_ready_i,
  output logic qk_result_wave_o,
  output logic [3:0] qk_result_row_o,
  output logic [3:0] qk_result_col_base_o,
  output logic [31:0] qk_result_data_o [8],

  input  logic pv_valid_i,
  output logic pv_ready_o,
  input  logic pv_wave_i,
  input  logic pv_first_i,
  input  logic pv_last_i,
  input  logic [15:0] pv_row_valid_i,
  input  logic [15:0] pv_col_valid_i,
  input  logic [15:0] p_bf16_i [16],
  input  logic [15:0] v_group_bf16_i [4][16],
  output logic pv_result_valid_o,
  input  logic pv_result_ready_i,
  output logic pv_result_wave_o,
  output logic [3:0] pv_result_row_o,
  output logic [3:0] pv_result_col_base_o,
  output logic [31:0] pv_result_data_o [8],

  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] pv_accepted_macs_o,
  output logic error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic qk_error;
  logic pv_error;
  logic qk_result_last;
  logic pv_result_last;

  gqav7_qk_logical_16x16_dual_group i_qk (
    .clk_i,
    .rst_ni,
    .logical_valid_i(qk_valid_i),
    .logical_ready_o(qk_ready_o),
    .logical_tile_context_i('0),
    .logical_wave_i(qk_wave_i),
    .logical_first_i(qk_first_i),
    .logical_last_i(qk_last_i),
    .logical_row_valid_i(qk_row_valid_i),
    .logical_col_valid_i(qk_col_valid_i),
    .q_bf16_i,
    .k_group_bf16_i,
    .result_valid_o(qk_result_valid_o),
    .result_ready_i(qk_result_ready_i),
    .result_tile_context_o(),
    .result_wave_o(qk_result_wave_o),
    .result_logical_row_o(qk_result_row_o),
    .result_logical_col_base_o(qk_result_col_base_o),
    .result_data_o(qk_result_data_o),
    .result_last_o(qk_result_last),
    .accepted_macs_o(qk_accepted_macs_o),
    .protocol_error_o(qk_error)
  );

  gqav7_pv_logical_16x16_dual_group i_pv (
    .clk_i,
    .rst_ni,
    .logical_valid_i(pv_valid_i),
    .logical_ready_o(pv_ready_o),
    .logical_wave_i(pv_wave_i),
    .logical_first_i(pv_first_i),
    .logical_last_i(pv_last_i),
    .logical_row_valid_i(pv_row_valid_i),
    .logical_col_valid_i(pv_col_valid_i),
    .p_bf16_i,
    .v_group_bf16_i,
    .result_valid_o(pv_result_valid_o),
    .result_ready_i(pv_result_ready_i),
    .result_wave_o(pv_result_wave_o),
    .result_logical_row_o(pv_result_row_o),
    .result_logical_col_base_o(pv_result_col_base_o),
    .result_data_o(pv_result_data_o),
    .result_last_o(pv_result_last),
    .accepted_macs_o(pv_accepted_macs_o),
    .protocol_error_o(pv_error)
  );

  assign error_o = qk_error || pv_error;

  logic unused_result_last;
  assign unused_result_last = qk_result_last ^ pv_result_last;
endmodule
