module gqav5_axi_row_mover_256_cdc #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned AXI_ID_W = 4,
  parameter logic [AXI_ID_W-1:0] AXI_ID = '0,
  parameter int unsigned BANK_COUNT = 8,
  parameter int unsigned MAX_READ_OUTSTANDING = 8
) (
  input logic core_clk_i,
  input logic core_rst_ni,
  input logic dma_clk_i,
  input logic dma_rst_ni,

  input logic load_cmd_valid_i,
  output logic load_cmd_ready_o,
  input logic [ADDR_W-1:0] load_cmd_addr_i,
  input logic [ADDR_W-1:0] load_cmd_row_stride_bytes_i,
  input logic [6:0] load_cmd_row_bytes_i,
  input logic [4:0] load_cmd_valid_rows_i,
  input logic load_cmd_zero_pad_i,
  output logic load_tile_start_valid_o,
  input logic load_tile_start_ready_i,
  output logic [2:0] load_tile_index_o,
  output logic load_row_valid_o,
  input logic load_row_ready_i,
  output logic [255:0] load_row_bf16_o,
  output logic [3:0] load_row_index_o,
  output logic load_row_last_o,
  output logic load_done_o,

  input logic store_cmd_valid_i,
  output logic store_cmd_ready_o,
  input logic [ADDR_W-1:0] store_cmd_addr_i,
  input logic [ADDR_W-1:0] store_cmd_row_stride_bytes_i,
  input logic [6:0] store_cmd_row_bytes_i,
  input logic [4:0] store_cmd_valid_rows_i,
  input logic store_row_valid_i,
  output logic store_row_ready_o,
  input logic [511:0] store_row_fp32_i,
  input logic [3:0] store_row_index_i,
  input logic store_row_last_i,
  output logic store_done_o,

  output logic [AXI_ID_W-1:0] m_axi_awid_o,
  output logic [ADDR_W-1:0] m_axi_awaddr_o,
  output logic [7:0] m_axi_awlen_o,
  output logic [2:0] m_axi_awsize_o,
  output logic [1:0] m_axi_awburst_o,
  output logic m_axi_awlock_o,
  output logic [3:0] m_axi_awcache_o,
  output logic [2:0] m_axi_awprot_o,
  output logic [3:0] m_axi_awqos_o,
  output logic [3:0] m_axi_awregion_o,
  output logic m_axi_awvalid_o,
  input logic m_axi_awready_i,
  output logic [255:0] m_axi_wdata_o,
  output logic [31:0] m_axi_wstrb_o,
  output logic m_axi_wlast_o,
  output logic m_axi_wvalid_o,
  input logic m_axi_wready_i,
  input logic [AXI_ID_W-1:0] m_axi_bid_i,
  input logic [1:0] m_axi_bresp_i,
  input logic m_axi_bvalid_i,
  output logic m_axi_bready_o,
  output logic [AXI_ID_W-1:0] m_axi_arid_o,
  output logic [ADDR_W-1:0] m_axi_araddr_o,
  output logic [7:0] m_axi_arlen_o,
  output logic [2:0] m_axi_arsize_o,
  output logic [1:0] m_axi_arburst_o,
  output logic m_axi_arlock_o,
  output logic [3:0] m_axi_arcache_o,
  output logic [2:0] m_axi_arprot_o,
  output logic [3:0] m_axi_arqos_o,
  output logic [3:0] m_axi_arregion_o,
  output logic m_axi_arvalid_o,
  input logic m_axi_arready_i,
  input logic [AXI_ID_W-1:0] m_axi_rid_i,
  input logic [255:0] m_axi_rdata_i,
  input logic [1:0] m_axi_rresp_i,
  input logic m_axi_rlast_i,
  input logic m_axi_rvalid_i,
  output logic m_axi_rready_o,

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

  localparam int unsigned LOAD_CMD_W = 1 + 5 + 7 + ADDR_W + ADDR_W;
  localparam int unsigned STORE_CMD_W = 5 + 7 + ADDR_W + ADDR_W;
  localparam int unsigned STORE_ROW_W = 1 + 4 + 512;
  localparam int unsigned LOAD_EVENT_W = 2 + 3 + 1 + 4 + 256;
  localparam int unsigned STATS_W = 11 * 64 + 8;

  localparam logic [1:0] LOAD_EVENT_TILE = 2'd0;
  localparam logic [1:0] LOAD_EVENT_ROW  = 2'd1;
  localparam logic [1:0] LOAD_EVENT_DONE = 2'd2;

  logic load_cmd_fifo_wr_ready;
  logic load_cmd_fifo_rd_valid;
  logic load_cmd_fifo_rd_ready;
  logic [LOAD_CMD_W-1:0] load_cmd_fifo_rd_data;
  logic load_cmd_dma_valid;
  logic load_cmd_dma_ready;
  logic [LOAD_CMD_W-1:0] load_cmd_dma_data;
  logic load_cmd_fire_core;

  logic store_cmd_fifo_wr_ready;
  logic store_cmd_fifo_rd_valid;
  logic store_cmd_fifo_rd_ready;
  logic [STORE_CMD_W-1:0] store_cmd_fifo_rd_data;
  logic store_cmd_dma_valid;
  logic store_cmd_dma_ready;
  logic [STORE_CMD_W-1:0] store_cmd_dma_data;
  logic store_cmd_fire_core;

  logic store_row_fifo_wr_ready;
  logic store_row_fifo_rd_valid;
  logic store_row_fifo_rd_ready;
  logic [STORE_ROW_W-1:0] store_row_fifo_rd_data;

  logic load_tile_valid_dma;
  logic load_tile_ready_dma;
  logic [2:0] load_tile_index_dma;
  logic load_row_valid_dma;
  logic load_row_ready_dma;
  logic [255:0] load_row_data_dma;
  logic [3:0] load_row_index_dma;
  logic load_row_last_dma;
  logic load_done_dma;
  logic load_done_pending_q;

  logic load_event_fifo_wr_valid;
  logic load_event_fifo_wr_ready;
  logic [LOAD_EVENT_W-1:0] load_event_fifo_wr_data;
  logic load_event_fifo_rd_valid;
  logic load_event_fifo_rd_ready;
  logic [LOAD_EVENT_W-1:0] load_event_fifo_rd_data;
  logic [LOAD_EVENT_W-1:0] load_event_buffer_q [2];
  logic [1:0] load_event_buffer_rd_ptr_q;
  logic [1:0] load_event_buffer_wr_ptr_q;
  logic load_event_buffer_empty;
  logic load_event_buffer_full;
  logic load_event_buffer_push;
  logic load_event_buffer_pop;
  logic load_event_consumer_ready;
  logic [LOAD_EVENT_W-1:0] load_event_core_data;
  logic [1:0] load_event_type_core;
  logic [2:0] load_event_tile_core;
  logic load_event_last_core;
  logic [3:0] load_event_row_core;
  logic [255:0] load_event_data_core;

  logic store_done_dma;
  logic store_done_pending_q;
  logic store_done_fifo_wr_ready;
  logic store_done_fifo_rd_valid;
  logic unused_store_done_data;

  logic mover_busy_dma;
  logic mover_error_dma;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic mover_error_sync1_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic mover_error_sync2_q;
  logic [7:0] load_pending_q;
  logic [7:0] store_pending_q;
  logic store_stream_active_q;
  logic [4:0] store_rows_remaining_q;
  logic store_row_fire_core;

  logic [63:0] ar_count_dma;
  logic [63:0] aw_count_dma;
  logic [63:0] read_count_dma;
  logic [63:0] write_count_dma;
  logic [63:0] stall_count_dma;
  logic [63:0] ar_wait_dma;
  logic [63:0] r_gap_dma;
  logic [63:0] r_backpressure_dma;
  logic [63:0] bank_wait_dma;
  logic [63:0] emit_wait_dma;
  logic [7:0] max_outstanding_dma;
  logic [63:0] boundary_split_dma;

  logic stats_pending_q;
  logic [STATS_W-1:0] stats_pending_data_q;
  logic stats_fifo_wr_ready;
  logic stats_fifo_rd_valid;
  logic [STATS_W-1:0] stats_fifo_rd_data;
  logic stats_capture;

  assign load_cmd_ready_o = load_cmd_fifo_wr_ready;
  assign load_cmd_fire_core = load_cmd_valid_i && load_cmd_ready_o;
  gqav5_async_fifo #(.WIDTH(LOAD_CMD_W), .DEPTH(8)) i_load_command_cdc (
    .wr_clk_i(core_clk_i),
    .wr_rst_ni(core_rst_ni),
    .wr_valid_i(load_cmd_valid_i),
    .wr_ready_o(load_cmd_fifo_wr_ready),
    .wr_data_i({load_cmd_zero_pad_i, load_cmd_valid_rows_i,
                load_cmd_row_bytes_i, load_cmd_row_stride_bytes_i,
                load_cmd_addr_i}),
    .rd_clk_i(dma_clk_i),
    .rd_rst_ni(dma_rst_ni),
    .rd_valid_o(load_cmd_fifo_rd_valid),
    .rd_ready_i(load_cmd_fifo_rd_ready),
    .rd_data_o(load_cmd_fifo_rd_data)
  );

  assign store_cmd_ready_o = store_cmd_fifo_wr_ready;
  assign store_cmd_fire_core = store_cmd_valid_i && store_cmd_ready_o;
  gqav5_async_fifo #(.WIDTH(STORE_CMD_W), .DEPTH(8)) i_store_command_cdc (
    .wr_clk_i(core_clk_i),
    .wr_rst_ni(core_rst_ni),
    .wr_valid_i(store_cmd_valid_i),
    .wr_ready_o(store_cmd_fifo_wr_ready),
    .wr_data_i({store_cmd_valid_rows_i, store_cmd_row_bytes_i,
                store_cmd_row_stride_bytes_i, store_cmd_addr_i}),
    .rd_clk_i(dma_clk_i),
    .rd_rst_ni(dma_rst_ni),
    .rd_valid_o(store_cmd_fifo_rd_valid),
    .rd_ready_i(store_cmd_fifo_rd_ready),
    .rd_data_o(store_cmd_fifo_rd_data)
  );

  // Register both command descriptors in the DMA domain before they enter the
  // row-mover control logic.  The asynchronous FIFO output is backed by BRAM;
  // consuming that payload directly made the BRAM CLK/DOUT -> state-machine CE
  // path the limiting 300 MHz DMA path.  This V5 ready/valid slice preserves
  // one-command-per-cycle throughput while isolating the descriptor decode and
  // state transitions from the CDC memory output.
  gqav5_rv_slice #(.DATA_W(LOAD_CMD_W)) i_load_command_dma_slice (
    .clk_i(dma_clk_i),
    .rst_ni(dma_rst_ni),
    .s_valid_i(load_cmd_fifo_rd_valid),
    .s_ready_o(load_cmd_fifo_rd_ready),
    .s_data_i(load_cmd_fifo_rd_data),
    .m_valid_o(load_cmd_dma_valid),
    .m_ready_i(load_cmd_dma_ready),
    .m_data_o(load_cmd_dma_data)
  );

  gqav5_rv_slice #(.DATA_W(STORE_CMD_W)) i_store_command_dma_slice (
    .clk_i(dma_clk_i),
    .rst_ni(dma_rst_ni),
    .s_valid_i(store_cmd_fifo_rd_valid),
    .s_ready_o(store_cmd_fifo_rd_ready),
    .s_data_i(store_cmd_fifo_rd_data),
    .m_valid_o(store_cmd_dma_valid),
    .m_ready_i(store_cmd_dma_ready),
    .m_data_o(store_cmd_dma_data)
  );

  // Preserve the original row-mover ordering contract in the core domain:
  // the first result row may only fire after the store descriptor has fired.
  // Without this gate a deep CDC FIFO can accept descriptor and row in the
  // same core cycle, which violates the store request generator protocol.
  assign store_row_ready_o =
      store_stream_active_q && (store_rows_remaining_q != 0) &&
      store_row_fifo_wr_ready;
  assign store_row_fire_core = store_row_valid_i && store_row_ready_o;
  gqav5_async_fifo #(.WIDTH(STORE_ROW_W), .DEPTH(32)) i_store_row_cdc (
    .wr_clk_i(core_clk_i),
    .wr_rst_ni(core_rst_ni),
    .wr_valid_i(store_row_valid_i && store_stream_active_q &&
                (store_rows_remaining_q != 0)),
    .wr_ready_o(store_row_fifo_wr_ready),
    .wr_data_i({store_row_last_i, store_row_index_i, store_row_fp32_i}),
    .rd_clk_i(dma_clk_i),
    .rd_rst_ni(dma_rst_ni),
    .rd_valid_o(store_row_fifo_rd_valid),
    .rd_ready_i(store_row_fifo_rd_ready),
    .rd_data_o(store_row_fifo_rd_data)
  );

  always_comb begin
    load_event_fifo_wr_valid = 1'b0;
    load_event_fifo_wr_data = '0;
    load_tile_ready_dma = 1'b0;
    load_row_ready_dma = 1'b0;
    if (load_done_pending_q) begin
      load_event_fifo_wr_valid = 1'b1;
      load_event_fifo_wr_data[LOAD_EVENT_W-1 -: 2] = LOAD_EVENT_DONE;
    end else if (load_tile_valid_dma) begin
      load_event_fifo_wr_valid = 1'b1;
      load_event_fifo_wr_data[LOAD_EVENT_W-1 -: 2] = LOAD_EVENT_TILE;
      load_event_fifo_wr_data[LOAD_EVENT_W-3 -: 3] =
          load_tile_index_dma;
      load_tile_ready_dma = load_event_fifo_wr_ready;
    end else if (load_row_valid_dma) begin
      load_event_fifo_wr_valid = 1'b1;
      load_event_fifo_wr_data[LOAD_EVENT_W-1 -: 2] = LOAD_EVENT_ROW;
      load_event_fifo_wr_data[LOAD_EVENT_W-6] = load_row_last_dma;
      load_event_fifo_wr_data[LOAD_EVENT_W-7 -: 4] =
          load_row_index_dma;
      load_event_fifo_wr_data[255:0] = load_row_data_dma;
      load_row_ready_dma = load_event_fifo_wr_ready;
    end
  end

  always_ff @(posedge dma_clk_i or negedge dma_rst_ni) begin
    if (!dma_rst_ni) begin
      load_done_pending_q <= 1'b0;
    end else begin
      if (load_done_dma)
        load_done_pending_q <= 1'b1;
      else if (load_done_pending_q && load_event_fifo_wr_ready)
        load_done_pending_q <= 1'b0;
    end
  end

  gqav5_async_fifo #(.WIDTH(LOAD_EVENT_W), .DEPTH(128))
      i_load_event_cdc (
    .wr_clk_i(dma_clk_i),
    .wr_rst_ni(dma_rst_ni),
    .wr_valid_i(load_event_fifo_wr_valid),
    .wr_ready_o(load_event_fifo_wr_ready),
    .wr_data_i(load_event_fifo_wr_data),
    .rd_clk_i(core_clk_i),
    .rd_rst_ni(core_rst_ni),
    .rd_valid_o(load_event_fifo_rd_valid),
    .rd_ready_i(load_event_fifo_rd_ready),
    .rd_data_o(load_event_fifo_rd_data)
  );

  // Keep the wide async FIFO pointer update independent of the downstream
  // cache/scheduler ready chain.  The extra pointer bit records the wrap phase,
  // so full/empty are derived from independently updated read/write pointers
  // instead of a shared push/pop counter enable.  The queue still accepts and
  // retires one event per core cycle without adding a visible pipeline stage.
  assign load_event_buffer_empty =
      load_event_buffer_rd_ptr_q == load_event_buffer_wr_ptr_q;
  assign load_event_buffer_full =
      (load_event_buffer_rd_ptr_q[0] == load_event_buffer_wr_ptr_q[0]) &&
      (load_event_buffer_rd_ptr_q[1] != load_event_buffer_wr_ptr_q[1]);
  assign load_event_fifo_rd_ready = !load_event_buffer_full;
  assign load_event_buffer_push =
      load_event_fifo_rd_valid && load_event_fifo_rd_ready;
  assign load_event_core_data =
      !load_event_buffer_empty
      ? load_event_buffer_q[load_event_buffer_rd_ptr_q[0]] : '0;
  assign load_event_buffer_pop =
      !load_event_buffer_empty && load_event_consumer_ready;

  // Event ownership is carried by the extended queue pointers.  Keep the two
  // wide payload slots off the asynchronous core reset tree.
  always_ff @(posedge core_clk_i) begin
    if (load_event_buffer_push)
      load_event_buffer_q[load_event_buffer_wr_ptr_q[0]]
          <= load_event_fifo_rd_data;
  end

  always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
    if (!core_rst_ni) begin
      load_event_buffer_rd_ptr_q <= '0;
      load_event_buffer_wr_ptr_q <= '0;
    end else begin
      if (load_event_buffer_push)
        load_event_buffer_wr_ptr_q <= load_event_buffer_wr_ptr_q + 2'd1;
      if (load_event_buffer_pop)
        load_event_buffer_rd_ptr_q <= load_event_buffer_rd_ptr_q + 2'd1;
    end
  end

  assign load_event_type_core =
      load_event_core_data[LOAD_EVENT_W-1 -: 2];
  assign load_event_tile_core =
      load_event_core_data[LOAD_EVENT_W-3 -: 3];
  assign load_event_last_core = load_event_core_data[LOAD_EVENT_W-6];
  assign load_event_row_core =
      load_event_core_data[LOAD_EVENT_W-7 -: 4];
  assign load_event_data_core = load_event_core_data[255:0];
  assign load_tile_start_valid_o =
      !load_event_buffer_empty &&
      load_event_type_core == LOAD_EVENT_TILE;
  assign load_tile_index_o = load_event_tile_core;
  assign load_row_valid_o =
      !load_event_buffer_empty &&
      load_event_type_core == LOAD_EVENT_ROW;
  assign load_row_bf16_o = load_event_data_core;
  assign load_row_index_o = load_event_row_core;
  assign load_row_last_o = load_event_last_core;
  assign load_done_o = !load_event_buffer_empty &&
      load_event_type_core == LOAD_EVENT_DONE;
  always_comb begin
    unique case (load_event_type_core)
      LOAD_EVENT_TILE:
        load_event_consumer_ready = load_tile_start_ready_i;
      LOAD_EVENT_ROW:
        load_event_consumer_ready = load_row_ready_i;
      default:
        load_event_consumer_ready = 1'b1;
    endcase
  end

  always_ff @(posedge dma_clk_i or negedge dma_rst_ni) begin
    if (!dma_rst_ni) begin
      store_done_pending_q <= 1'b0;
    end else begin
      if (store_done_dma)
        store_done_pending_q <= 1'b1;
      else if (store_done_pending_q && store_done_fifo_wr_ready)
        store_done_pending_q <= 1'b0;
    end
  end

  gqav5_async_fifo #(.WIDTH(1), .DEPTH(4)) i_store_done_cdc (
    .wr_clk_i(dma_clk_i),
    .wr_rst_ni(dma_rst_ni),
    .wr_valid_i(store_done_pending_q),
    .wr_ready_o(store_done_fifo_wr_ready),
    .wr_data_i(1'b1),
    .rd_clk_i(core_clk_i),
    .rd_rst_ni(core_rst_ni),
    .rd_valid_o(store_done_fifo_rd_valid),
    .rd_ready_i(1'b1),
    .rd_data_o(unused_store_done_data)
  );
  assign store_done_o = store_done_fifo_rd_valid;

  always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
    if (!core_rst_ni) begin
      load_pending_q <= '0;
      store_pending_q <= '0;
      store_stream_active_q <= 1'b0;
      store_rows_remaining_q <= '0;
    end else begin
      unique case ({load_cmd_fire_core, load_done_o})
        2'b10: load_pending_q <= load_pending_q + 8'd1;
        2'b01: load_pending_q <= load_pending_q - 8'd1;
        default: begin
        end
      endcase
      unique case ({store_cmd_fire_core, store_done_o})
        2'b10: store_pending_q <= store_pending_q + 8'd1;
        2'b01: store_pending_q <= store_pending_q - 8'd1;
        default: begin
        end
      endcase
      if (store_cmd_fire_core) begin
        store_stream_active_q <= 1'b1;
        store_rows_remaining_q <= store_cmd_valid_rows_i;
      end
      if (store_row_fire_core)
        store_rows_remaining_q <= store_rows_remaining_q - 5'd1;
      if (store_done_o) begin
        store_stream_active_q <= 1'b0;
        store_rows_remaining_q <= '0;
      end
    end
  end
  assign busy_o = (load_pending_q != 0) || (store_pending_q != 0);

  always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
    if (!core_rst_ni) begin
      mover_error_sync1_q <= 1'b0;
      mover_error_sync2_q <= 1'b0;
    end else begin
      mover_error_sync1_q <= mover_error_dma;
      mover_error_sync2_q <= mover_error_sync1_q;
    end
  end
  assign error_o = mover_error_sync2_q;

  assign stats_capture = load_done_dma || store_done_dma;
  // The pending flag owns this snapshot.  Resetting all 712 payload bits
  // would add a large 300 MHz DMA reset/CE tree with no visible benefit.
  always_ff @(posedge dma_clk_i) begin
    if (stats_capture) begin
      stats_pending_data_q <= {
        boundary_split_dma, max_outstanding_dma, emit_wait_dma,
        bank_wait_dma, r_backpressure_dma, r_gap_dma, ar_wait_dma,
        stall_count_dma, write_count_dma, read_count_dma,
        aw_count_dma, ar_count_dma
      };
    end
  end

  always_ff @(posedge dma_clk_i or negedge dma_rst_ni) begin
    if (!dma_rst_ni) begin
      stats_pending_q <= 1'b0;
    end else begin
      if (stats_capture) begin
        stats_pending_q <= 1'b1;
      end else if (stats_pending_q && stats_fifo_wr_ready) begin
        stats_pending_q <= 1'b0;
      end
    end
  end

  gqav5_async_fifo #(.WIDTH(STATS_W), .DEPTH(4)) i_stats_cdc (
    .wr_clk_i(dma_clk_i),
    .wr_rst_ni(dma_rst_ni),
    .wr_valid_i(stats_pending_q),
    .wr_ready_o(stats_fifo_wr_ready),
    .wr_data_i(stats_pending_data_q),
    .rd_clk_i(core_clk_i),
    .rd_rst_ni(core_rst_ni),
    .rd_valid_o(stats_fifo_rd_valid),
    .rd_ready_i(1'b1),
    .rd_data_o(stats_fifo_rd_data)
  );

  always_ff @(posedge core_clk_i or negedge core_rst_ni) begin
    if (!core_rst_ni) begin
      ar_transaction_count_o <= '0;
      aw_transaction_count_o <= '0;
      read_beat_count_o <= '0;
      write_beat_count_o <= '0;
      command_stall_cycle_count_o <= '0;
      ar_wait_cycle_count_o <= '0;
      r_gap_cycle_count_o <= '0;
      r_backpressure_cycle_count_o <= '0;
      bank_wait_cycle_count_o <= '0;
      emit_wait_cycle_count_o <= '0;
      max_outstanding_o <= '0;
      boundary_split_count_o <= '0;
    end else if (stats_fifo_rd_valid) begin
      {
        boundary_split_count_o, max_outstanding_o, emit_wait_cycle_count_o,
        bank_wait_cycle_count_o, r_backpressure_cycle_count_o,
        r_gap_cycle_count_o, ar_wait_cycle_count_o,
        command_stall_cycle_count_o, write_beat_count_o,
        read_beat_count_o, aw_transaction_count_o,
        ar_transaction_count_o
      } <= stats_fifo_rd_data;
    end
  end

  gqav5_axi_row_mover_256 #(
    .ADDR_W(ADDR_W),
    .AXI_ID_W(AXI_ID_W),
    .AXI_ID(AXI_ID),
    .BANK_COUNT(BANK_COUNT),
    .MAX_READ_OUTSTANDING(MAX_READ_OUTSTANDING),
    .ENABLE_FULL_ROW_BURST(1'b1)
  ) i_dma_row_mover (
    .clk_i(dma_clk_i),
    .rst_ni(dma_rst_ni),
    .load_cmd_valid_i(load_cmd_dma_valid),
    .load_cmd_ready_o(load_cmd_dma_ready),
    .load_cmd_addr_i(load_cmd_dma_data[ADDR_W-1:0]),
    .load_cmd_row_stride_bytes_i(
        load_cmd_dma_data[2*ADDR_W-1:ADDR_W]),
    .load_cmd_row_bytes_i(
        load_cmd_dma_data[2*ADDR_W+6:2*ADDR_W]),
    .load_cmd_valid_rows_i(
        load_cmd_dma_data[2*ADDR_W+11:2*ADDR_W+7]),
    .load_cmd_zero_pad_i(load_cmd_dma_data[LOAD_CMD_W-1]),
    .load_tile_start_valid_o(load_tile_valid_dma),
    .load_tile_start_ready_i(load_tile_ready_dma),
    .load_tile_index_o(load_tile_index_dma),
    .load_row_valid_o(load_row_valid_dma),
    .load_row_ready_i(load_row_ready_dma),
    .load_row_bf16_o(load_row_data_dma),
    .load_row_index_o(load_row_index_dma),
    .load_row_last_o(load_row_last_dma),
    .load_done_o(load_done_dma),
    .store_cmd_valid_i(store_cmd_dma_valid),
    .store_cmd_ready_o(store_cmd_dma_ready),
    .store_cmd_addr_i(store_cmd_dma_data[ADDR_W-1:0]),
    .store_cmd_row_stride_bytes_i(
        store_cmd_dma_data[2*ADDR_W-1:ADDR_W]),
    .store_cmd_row_bytes_i(
        store_cmd_dma_data[2*ADDR_W+6:2*ADDR_W]),
    .store_cmd_valid_rows_i(
        store_cmd_dma_data[STORE_CMD_W-1:2*ADDR_W+7]),
    .store_row_valid_i(store_row_fifo_rd_valid),
    .store_row_ready_o(store_row_fifo_rd_ready),
    .store_row_fp32_i(store_row_fifo_rd_data[511:0]),
    .store_row_index_i(store_row_fifo_rd_data[515:512]),
    .store_row_last_i(store_row_fifo_rd_data[STORE_ROW_W-1]),
    .store_done_o(store_done_dma),
    .m_axi_awid_o,
    .m_axi_awaddr_o,
    .m_axi_awlen_o,
    .m_axi_awsize_o,
    .m_axi_awburst_o,
    .m_axi_awlock_o,
    .m_axi_awcache_o,
    .m_axi_awprot_o,
    .m_axi_awqos_o,
    .m_axi_awregion_o,
    .m_axi_awvalid_o,
    .m_axi_awready_i,
    .m_axi_wdata_o,
    .m_axi_wstrb_o,
    .m_axi_wlast_o,
    .m_axi_wvalid_o,
    .m_axi_wready_i,
    .m_axi_bid_i,
    .m_axi_bresp_i,
    .m_axi_bvalid_i,
    .m_axi_bready_o,
    .m_axi_arid_o,
    .m_axi_araddr_o,
    .m_axi_arlen_o,
    .m_axi_arsize_o,
    .m_axi_arburst_o,
    .m_axi_arlock_o,
    .m_axi_arcache_o,
    .m_axi_arprot_o,
    .m_axi_arqos_o,
    .m_axi_arregion_o,
    .m_axi_arvalid_o,
    .m_axi_arready_i,
    .m_axi_rid_i,
    .m_axi_rdata_i,
    .m_axi_rresp_i,
    .m_axi_rlast_i,
    .m_axi_rvalid_i,
    .m_axi_rready_o,
    .busy_o(mover_busy_dma),
    .ar_transaction_count_o(ar_count_dma),
    .aw_transaction_count_o(aw_count_dma),
    .read_beat_count_o(read_count_dma),
    .write_beat_count_o(write_count_dma),
    .command_stall_cycle_count_o(stall_count_dma),
    .ar_wait_cycle_count_o(ar_wait_dma),
    .r_gap_cycle_count_o(r_gap_dma),
    .r_backpressure_cycle_count_o(r_backpressure_dma),
    .bank_wait_cycle_count_o(bank_wait_dma),
    .emit_wait_cycle_count_o(emit_wait_dma),
    .max_outstanding_o(max_outstanding_dma),
    .boundary_split_count_o(boundary_split_dma),
    .error_o(mover_error_dma)
  );

  logic unused_dma_busy;
  assign unused_dma_busy = mover_busy_dma;
endmodule
