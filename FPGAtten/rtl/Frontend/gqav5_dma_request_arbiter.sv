module gqav5_dma_request_arbiter (
  input  logic load_valid_i,
  output logic load_ready_o,
  input  gqav5_pkg::gqav5_dma_op_e load_op_i,
  input  gqav5_pkg::gqav5_tile_desc_t load_desc_i,

  input  logic store_valid_i,
  output logic store_ready_o,
  input  gqav5_pkg::gqav5_tile_desc_t store_desc_i,

  output logic request_valid_o,
  input  logic request_ready_i,
  output gqav5_pkg::gqav5_dma_op_e request_op_o,
  output gqav5_pkg::gqav5_tile_desc_t request_desc_o,
  output logic store_selected_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  // A pending output row has already consumed downstream storage, so store
  // requests take priority over speculative prefetch and break V/store cycles.
  assign store_selected_o = store_valid_i;
  assign request_valid_o = store_valid_i || load_valid_i;
  assign request_op_o = store_selected_o ? GQAV5_DMA_STORE_O : load_op_i;
  assign request_desc_o = store_selected_o ? store_desc_i : load_desc_i;
  assign store_ready_o = request_ready_i;
  assign load_ready_o = request_ready_i && !store_valid_i;
endmodule
