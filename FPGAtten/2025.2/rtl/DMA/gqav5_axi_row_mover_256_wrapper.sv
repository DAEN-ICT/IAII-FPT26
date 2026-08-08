/* verilator lint_off DECLFILENAME */
module gqav5_axi_row_mover_256 #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned AXI_ID_W = 4,
  parameter logic [AXI_ID_W-1:0] AXI_ID = '0,
  parameter int unsigned BANK_COUNT = 4,
  parameter int unsigned MAX_READ_OUTSTANDING = 4,
  parameter bit ENABLE_FULL_ROW_BURST = 1'b1
) (
  input logic clk_i, input logic rst_ni,
  input logic load_cmd_valid_i, output logic load_cmd_ready_o,
  input logic [ADDR_W-1:0] load_cmd_addr_i,
  input logic [ADDR_W-1:0] load_cmd_row_stride_bytes_i,
  input logic [6:0] load_cmd_row_bytes_i,
  input logic [4:0] load_cmd_valid_rows_i,
  input logic load_cmd_zero_pad_i,
  output logic load_tile_start_valid_o,
  input logic load_tile_start_ready_i,
  output logic [2:0] load_tile_index_o,
  output logic load_row_valid_o, input logic load_row_ready_i,
  output logic [255:0] load_row_bf16_o,
  output logic [3:0] load_row_index_o,
  output logic load_row_last_o, output logic load_done_o,
  input logic store_cmd_valid_i, output logic store_cmd_ready_o,
  input logic [ADDR_W-1:0] store_cmd_addr_i,
  input logic [ADDR_W-1:0] store_cmd_row_stride_bytes_i,
  input logic [6:0] store_cmd_row_bytes_i,
  input logic [4:0] store_cmd_valid_rows_i,
  input logic store_row_valid_i, output logic store_row_ready_o,
  input logic [511:0] store_row_fp32_i,
  input logic [3:0] store_row_index_i,
  input logic store_row_last_i, output logic store_done_o,
  output logic [AXI_ID_W-1:0] m_axi_awid_o,
  output logic [ADDR_W-1:0] m_axi_awaddr_o,
  output logic [7:0] m_axi_awlen_o, output logic [2:0] m_axi_awsize_o,
  output logic [1:0] m_axi_awburst_o, output logic m_axi_awlock_o,
  output logic [3:0] m_axi_awcache_o, output logic [2:0] m_axi_awprot_o,
  output logic [3:0] m_axi_awqos_o, output logic [3:0] m_axi_awregion_o,
  output logic m_axi_awvalid_o, input logic m_axi_awready_i,
  output logic [255:0] m_axi_wdata_o, output logic [31:0] m_axi_wstrb_o,
  output logic m_axi_wlast_o, output logic m_axi_wvalid_o,
  input logic m_axi_wready_i,
  input logic [AXI_ID_W-1:0] m_axi_bid_i, input logic [1:0] m_axi_bresp_i,
  input logic m_axi_bvalid_i, output logic m_axi_bready_o,
  output logic [AXI_ID_W-1:0] m_axi_arid_o,
  output logic [ADDR_W-1:0] m_axi_araddr_o,
  output logic [7:0] m_axi_arlen_o, output logic [2:0] m_axi_arsize_o,
  output logic [1:0] m_axi_arburst_o, output logic m_axi_arlock_o,
  output logic [3:0] m_axi_arcache_o, output logic [2:0] m_axi_arprot_o,
  output logic [3:0] m_axi_arqos_o, output logic [3:0] m_axi_arregion_o,
  output logic m_axi_arvalid_o, input logic m_axi_arready_i,
  input logic [AXI_ID_W-1:0] m_axi_rid_i, input logic [255:0] m_axi_rdata_i,
  input logic [1:0] m_axi_rresp_i, input logic m_axi_rlast_i,
  input logic m_axi_rvalid_i, output logic m_axi_rready_o,
  output logic busy_o,
  output logic [63:0] ar_transaction_count_o,
  output logic [63:0] aw_transaction_count_o,
  output logic [63:0] read_beat_count_o,
  output logic [63:0] write_beat_count_o,
  output logic [63:0] command_stall_cycle_count_o,
  output logic [63:0] ar_wait_cycle_count_o,
  output logic [63:0] r_gap_cycle_count_o,
  output logic [63:0] r_backpressure_cycle_count_o,
  output logic [63:0] bank_wait_cycle_count_o,
  output logic [63:0] emit_wait_cycle_count_o,
  output logic [7:0] max_outstanding_o,
  output logic [63:0] boundary_split_count_o,
  output logic error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  generate
    if (!ENABLE_FULL_ROW_BURST) begin : gen_legacy
      gqav5_axi_row_mover_256_legacy #(
        .ADDR_W(ADDR_W), .AXI_ID_W(AXI_ID_W), .AXI_ID(AXI_ID),
        .MAX_READ_OUTSTANDING(MAX_READ_OUTSTANDING),
        .ENABLE_FULL_ROW_BURST(1'b0)
      ) i_legacy (.*);
      assign ar_wait_cycle_count_o = '0;
      assign r_gap_cycle_count_o = '0;
      assign r_backpressure_cycle_count_o = '0;
      assign bank_wait_cycle_count_o = '0;
      assign emit_wait_cycle_count_o = '0;
      assign max_outstanding_o = '0;
      assign boundary_split_count_o = '0;
    end else begin : gen_v5_4
      logic load_busy, load_error;
      logic store_busy, store_error;
      logic load_ready_raw, store_ready_raw;
      logic [63:0] load_ar_count, load_read_count, load_stall_count;
      logic [31:0] load_ar_wait_count, load_r_gap_count;
      logic [31:0] load_r_backpressure_count, load_bank_wait_count;
      logic [31:0] load_emit_wait_count, load_boundary_split_count;
      logic [7:0] load_max_outstanding;
      logic [63:0] store_ar_count, store_aw_count;
      logic [63:0] store_read_count, store_write_count, store_stall_count;
      logic unused_legacy_load_ready, unused_legacy_tile_valid;
      logic [2:0] unused_legacy_tile_index;
      logic unused_legacy_row_valid, unused_legacy_row_last;
      logic [255:0] unused_legacy_row_data;
      logic [3:0] unused_legacy_row_index;
      logic unused_legacy_load_done;
      logic [AXI_ID_W-1:0] unused_legacy_arid;
      logic [ADDR_W-1:0] unused_legacy_araddr;
      logic [7:0] unused_legacy_arlen;
      logic [2:0] unused_legacy_arsize;
      logic [1:0] unused_legacy_arburst;
      logic unused_legacy_arlock, unused_legacy_arvalid, unused_legacy_rready;
      logic [3:0] unused_legacy_arcache, unused_legacy_arqos;
      logic [2:0] unused_legacy_arprot;
      logic [3:0] unused_legacy_arregion;

      assign load_cmd_ready_o = load_ready_raw && !store_busy;
      assign store_cmd_ready_o = store_ready_raw && !load_busy &&
                                 !load_cmd_valid_i;
      assign busy_o = load_busy || store_busy;
      assign ar_transaction_count_o = load_ar_count;
      assign aw_transaction_count_o = store_aw_count;
      assign read_beat_count_o = load_read_count;
      assign write_beat_count_o = store_write_count;
      assign command_stall_cycle_count_o = load_stall_count +
                                           store_stall_count;
      assign ar_wait_cycle_count_o = {32'd0, load_ar_wait_count};
      assign r_gap_cycle_count_o = {32'd0, load_r_gap_count};
      assign r_backpressure_cycle_count_o =
          {32'd0, load_r_backpressure_count};
      assign bank_wait_cycle_count_o = {32'd0, load_bank_wait_count};
      assign emit_wait_cycle_count_o = {32'd0, load_emit_wait_count};
      assign max_outstanding_o = load_max_outstanding;
      assign boundary_split_count_o =
          {32'd0, load_boundary_split_count};
      assign error_o = load_error || store_error;

      gqav5_axi_burst_load_pingpong_256 #(
        .ADDR_W(ADDR_W), .AXI_ID_W(AXI_ID_W), .AXI_ID(AXI_ID),
        .BANK_COUNT(BANK_COUNT),
        .MAX_READ_OUTSTANDING(MAX_READ_OUTSTANDING)
      ) i_load (
        .clk_i, .rst_ni,
        .load_cmd_valid_i(load_cmd_valid_i && !store_busy),
        .load_cmd_ready_o(load_ready_raw),
        .load_cmd_addr_i, .load_cmd_row_stride_bytes_i,
        .load_cmd_row_bytes_i, .load_cmd_valid_rows_i,
        .load_cmd_zero_pad_i, .load_tile_start_valid_o,
        .load_tile_start_ready_i, .load_tile_index_o,
        .load_row_valid_o, .load_row_ready_i, .load_row_bf16_o,
        .load_row_index_o, .load_row_last_o, .load_done_o,
        .m_axi_arid_o, .m_axi_araddr_o, .m_axi_arlen_o,
        .m_axi_arsize_o, .m_axi_arburst_o, .m_axi_arlock_o,
        .m_axi_arcache_o, .m_axi_arprot_o, .m_axi_arqos_o,
        .m_axi_arregion_o, .m_axi_arvalid_o, .m_axi_arready_i,
        .m_axi_rid_i, .m_axi_rdata_i, .m_axi_rresp_i,
        .m_axi_rlast_i, .m_axi_rvalid_i, .m_axi_rready_o,
        .busy_o(load_busy), .ar_transaction_count_o(load_ar_count),
        .read_beat_count_o(load_read_count),
        .command_stall_cycle_count_o(load_stall_count),
        .ar_wait_cycle_count_o(load_ar_wait_count),
        .r_gap_cycle_count_o(load_r_gap_count),
        .r_backpressure_cycle_count_o(load_r_backpressure_count),
        .bank_wait_cycle_count_o(load_bank_wait_count),
        .emit_wait_cycle_count_o(load_emit_wait_count),
        .max_outstanding_o(load_max_outstanding),
        .boundary_split_count_o(load_boundary_split_count),
        .error_o(load_error)
      );

      gqav5_axi_row_mover_256_legacy #(
        .ADDR_W(ADDR_W), .AXI_ID_W(AXI_ID_W), .AXI_ID(AXI_ID),
        .MAX_READ_OUTSTANDING(MAX_READ_OUTSTANDING),
        .ENABLE_FULL_ROW_BURST(1'b0)
      ) i_store (
        .clk_i, .rst_ni,
        .load_cmd_valid_i(1'b0), .load_cmd_ready_o(unused_legacy_load_ready),
        .load_cmd_addr_i('0), .load_cmd_row_stride_bytes_i('0),
        .load_cmd_row_bytes_i('0), .load_cmd_valid_rows_i('0),
        .load_cmd_zero_pad_i(1'b0),
        .load_tile_start_valid_o(unused_legacy_tile_valid),
        .load_tile_start_ready_i(1'b0),
        .load_tile_index_o(unused_legacy_tile_index),
        .load_row_valid_o(unused_legacy_row_valid),
        .load_row_ready_i(1'b0), .load_row_bf16_o(unused_legacy_row_data),
        .load_row_index_o(unused_legacy_row_index),
        .load_row_last_o(unused_legacy_row_last),
        .load_done_o(unused_legacy_load_done),
        .store_cmd_valid_i(store_cmd_valid_i && !load_busy &&
                           !load_cmd_valid_i),
        .store_cmd_ready_o(store_ready_raw), .store_cmd_addr_i,
        .store_cmd_row_stride_bytes_i, .store_cmd_row_bytes_i,
        .store_cmd_valid_rows_i, .store_row_valid_i, .store_row_ready_o,
        .store_row_fp32_i, .store_row_index_i, .store_row_last_i,
        .store_done_o, .m_axi_awid_o, .m_axi_awaddr_o, .m_axi_awlen_o,
        .m_axi_awsize_o, .m_axi_awburst_o, .m_axi_awlock_o,
        .m_axi_awcache_o, .m_axi_awprot_o, .m_axi_awqos_o,
        .m_axi_awregion_o, .m_axi_awvalid_o, .m_axi_awready_i,
        .m_axi_wdata_o, .m_axi_wstrb_o, .m_axi_wlast_o,
        .m_axi_wvalid_o, .m_axi_wready_i, .m_axi_bid_i,
        .m_axi_bresp_i, .m_axi_bvalid_i, .m_axi_bready_o,
        .m_axi_arid_o(unused_legacy_arid),
        .m_axi_araddr_o(unused_legacy_araddr),
        .m_axi_arlen_o(unused_legacy_arlen),
        .m_axi_arsize_o(unused_legacy_arsize),
        .m_axi_arburst_o(unused_legacy_arburst),
        .m_axi_arlock_o(unused_legacy_arlock),
        .m_axi_arcache_o(unused_legacy_arcache),
        .m_axi_arprot_o(unused_legacy_arprot),
        .m_axi_arqos_o(unused_legacy_arqos),
        .m_axi_arregion_o(unused_legacy_arregion),
        .m_axi_arvalid_o(unused_legacy_arvalid), .m_axi_arready_i(1'b0),
        .m_axi_rid_i('0), .m_axi_rdata_i('0), .m_axi_rresp_i('0),
        .m_axi_rlast_i(1'b0), .m_axi_rvalid_i(1'b0),
        .m_axi_rready_o(unused_legacy_rready), .busy_o(store_busy),
        .ar_transaction_count_o(store_ar_count),
        .aw_transaction_count_o(store_aw_count),
        .read_beat_count_o(store_read_count),
        .write_beat_count_o(store_write_count),
        .command_stall_cycle_count_o(store_stall_count),
        .error_o(store_error)
      );

      logic unused_store_counts;
      assign unused_store_counts = ^{store_ar_count, store_read_count};
    end
  endgenerate
endmodule
