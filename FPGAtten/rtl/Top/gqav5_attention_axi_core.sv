module gqav5_attention_axi_core #(
  parameter int unsigned MAX_SEQ_LEN     = 8192,
  parameter int unsigned KV_HEAD_COUNT   = 8,
  parameter int unsigned Q_HEADS_PER_KV  = 4,
  parameter int unsigned AXI_ID_W         = 4,
  parameter bit ENABLE_ROW_COMPAT         = 1'b0,
  parameter bit ENABLE_DUAL_DMA           = 1'b0,
  localparam int unsigned TOKEN_W         = $clog2(MAX_SEQ_LEN)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic dma_clk_i,
  input  logic dma_rst_ni,
  input  logic start_i,

  input  logic [TOKEN_W:0] context_token_count_i,
  input  logic [TOKEN_W-1:0] query_token_base_i,
  input  logic [4:0] query_valid_rows_i,
  input  logic causal_i,
  input  logic prefill_direct_i,
  input  logic [TOKEN_W:0] prefill_query_token_count_i,
  input  logic [31:0] attention_scale_fp32_i,
  input  logic [31:0] q_base_addr_i,
  input  logic [31:0] k_base_addr_i,
  input  logic [31:0] v_base_addr_i,
  input  logic [31:0] o_base_addr_i,
  input  logic [31:0] q_head_stride_bytes_i,
  input  logic [31:0] q_token_stride_bytes_i,
  input  logic [31:0] k_head_stride_bytes_i,
  input  logic [31:0] k_token_stride_bytes_i,
  input  logic [31:0] v_head_stride_bytes_i,
  input  logic [31:0] v_token_stride_bytes_i,
  input  logic [31:0] o_head_stride_bytes_i,
  input  logic [31:0] o_token_stride_bytes_i,
  input  logic bf16_output_i,
  input  logic pv_skip_enable_i,
  input  logic [31:0] pv_skip_lambda_fp32_i,

  output logic busy_o,
  output logic done_o,
  output logic error_o,
  output logic [31:0] total_cycle_count_o,
  output logic [31:0] overlap_cycle_count_o,
  output logic [31:0] load_stall_cycle_count_o,
  output logic [31:0] dma_ar_count_o,
  output logic [31:0] dma_read_beat_count_o,
  output logic [31:0] dma_ar_wait_cycle_count_o,
  output logic [31:0] dma_r_gap_cycle_count_o,
  output logic [31:0] dma_r_backpressure_cycle_count_o,
  output logic [31:0] dma_bank_wait_cycle_count_o,
  output logic [31:0] dma_emit_wait_cycle_count_o,
  output logic [7:0] dma_max_outstanding_o,
  output logic [31:0] dma_boundary_split_count_o,
  output logic [31:0] qk_cycle_count_o,
  output logic [31:0] softmax_cycle_count_o,
  output logic [31:0] pv_cycle_count_o,
  output logic [31:0] qk_pv_overlap_cycle_count_o,
  output logic [31:0] dma_lane_overlap_cycle_count_o,
  output logic [63:0] qk_accepted_macs_o,
  output logic [63:0] pv_accepted_macs_o,
  output logic [63:0] pv_blocks_total_o,
  output logic [63:0] pv_blocks_skipped_o,
  output logic [31:0] kv_resident_hit_count_o,
  output logic [31:0] kv_resident_miss_count_o,
  output logic [31:0] prefetch_issue_count_o,

  output logic [AXI_ID_W-1:0] m_axi_awid_o,
  output logic [31:0] m_axi_awaddr_o,
  output logic [7:0] m_axi_awlen_o,
  output logic [2:0] m_axi_awsize_o,
  output logic [1:0] m_axi_awburst_o,
  output logic m_axi_awlock_o,
  output logic [3:0] m_axi_awcache_o,
  output logic [2:0] m_axi_awprot_o,
  output logic [3:0] m_axi_awqos_o,
  output logic [3:0] m_axi_awregion_o,
  output logic m_axi_awvalid_o,
  input  logic m_axi_awready_i,
  output logic [255:0] m_axi_wdata_o,
  output logic [31:0] m_axi_wstrb_o,
  output logic m_axi_wlast_o,
  output logic m_axi_wvalid_o,
  input  logic m_axi_wready_i,
  input  logic [AXI_ID_W-1:0] m_axi_bid_i,
  input  logic [1:0] m_axi_bresp_i,
  input  logic m_axi_bvalid_i,
  output logic m_axi_bready_o,
  output logic [AXI_ID_W-1:0] m_axi_arid_o,
  output logic [31:0] m_axi_araddr_o,
  output logic [7:0] m_axi_arlen_o,
  output logic [2:0] m_axi_arsize_o,
  output logic [1:0] m_axi_arburst_o,
  output logic m_axi_arlock_o,
  output logic [3:0] m_axi_arcache_o,
  output logic [2:0] m_axi_arprot_o,
  output logic [3:0] m_axi_arqos_o,
  output logic [3:0] m_axi_arregion_o,
  output logic m_axi_arvalid_o,
  input  logic m_axi_arready_i,
  input  logic [AXI_ID_W-1:0] m_axi_rid_i,
  input  logic [255:0] m_axi_rdata_i,
  input  logic [1:0] m_axi_rresp_i,
  input  logic m_axi_rlast_i,
  input  logic m_axi_rvalid_i,
  output logic m_axi_rready_o,

  // Independent V-load lane. The board shell aggregates this lane and the
  // K/Q lane into the 512-bit MIG path at 300 MHz.
  output logic [AXI_ID_W-1:0] m_axi_v_awid_o,
  output logic [31:0] m_axi_v_awaddr_o,
  output logic [7:0] m_axi_v_awlen_o,
  output logic [2:0] m_axi_v_awsize_o,
  output logic [1:0] m_axi_v_awburst_o,
  output logic m_axi_v_awlock_o,
  output logic [3:0] m_axi_v_awcache_o,
  output logic [2:0] m_axi_v_awprot_o,
  output logic [3:0] m_axi_v_awqos_o,
  output logic [3:0] m_axi_v_awregion_o,
  output logic m_axi_v_awvalid_o,
  input  logic m_axi_v_awready_i,
  output logic [255:0] m_axi_v_wdata_o,
  output logic [31:0] m_axi_v_wstrb_o,
  output logic m_axi_v_wlast_o,
  output logic m_axi_v_wvalid_o,
  input  logic m_axi_v_wready_i,
  input  logic [AXI_ID_W-1:0] m_axi_v_bid_i,
  input  logic [1:0] m_axi_v_bresp_i,
  input  logic m_axi_v_bvalid_i,
  output logic m_axi_v_bready_o,
  output logic [AXI_ID_W-1:0] m_axi_v_arid_o,
  output logic [31:0] m_axi_v_araddr_o,
  output logic [7:0] m_axi_v_arlen_o,
  output logic [2:0] m_axi_v_arsize_o,
  output logic [1:0] m_axi_v_arburst_o,
  output logic m_axi_v_arlock_o,
  output logic [3:0] m_axi_v_arcache_o,
  output logic [2:0] m_axi_v_arprot_o,
  output logic [3:0] m_axi_v_arqos_o,
  output logic [3:0] m_axi_v_arregion_o,
  output logic m_axi_v_arvalid_o,
  input  logic m_axi_v_arready_i,
  input  logic [AXI_ID_W-1:0] m_axi_v_rid_i,
  input  logic [255:0] m_axi_v_rdata_i,
  input  logic [1:0] m_axi_v_rresp_i,
  input  logic m_axi_v_rlast_i,
  input  logic m_axi_v_rvalid_i,
  output logic m_axi_v_rready_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  logic clear_error;
  logic group_launch_valid;
  logic group_launch_ready;
  gqav5_tile_desc_t group_launch_desc;
  gqav5_tile_desc_t group_launch_desc_raw;
  logic decode_pack_enable;
  logic kv_wave_pack_enable;
  logic group_done;
  logic group_active;
  logic [1:0] group_active_q_lane;
  logic job_error;
  logic group_error;
  logic [63:0] launched_groups;
  logic [63:0] completed_groups;
  logic [63:0] compute_desc_count;
  logic [63:0] load_request_count;
  logic [63:0] completed_q_heads;
  logic [63:0] kv_resident_hits;
  logic [63:0] kv_resident_misses;
  logic [63:0] prefetch_issues;
  logic [2:0] active_kv_head;
  logic [8:0] active_context_tile;

  logic compute_desc_valid;
  logic compute_desc_ready;
  gqav5_tile_desc_t compute_desc;
  logic [1:0] compute_state_slot;
  logic compute_desc_fire;
  logic load_request_valid;
  logic load_request_ready;
  gqav5_dma_op_e load_request_op;
  gqav5_tile_desc_t load_request_desc;
  logic replay_request_valid;
  logic replay_request_ready;
  gqav5_dma_op_e replay_request_op;
  gqav5_tile_desc_t replay_request_desc;
  logic invalidate_q_cache;
  logic invalidate_kv_cache;
  logic [63:0] replay_request_count;

  logic store_request_valid;
  logic store_request_ready;
  gqav5_tile_desc_t store_request_desc;
  logic store_request_pending;
  logic [63:0] store_request_count;
  logic store_request_error;
  logic arb_request_valid;
  logic arb_request_ready;
  gqav5_dma_op_e arb_request_op;
  gqav5_tile_desc_t arb_request_desc;
  logic arb_store_selected;
  gqav5_dma_op_e request_fifo_op_q [2];
  gqav5_tile_desc_t request_fifo_desc_q [2];
  logic request_fifo_rd_q;
  logic request_fifo_wr_q;
  logic [1:0] request_fifo_count_q;
  logic request_fifo_push;
  logic request_fifo_pop;
  logic address_request_valid;
  logic address_request_ready;
  gqav5_dma_op_e address_request_op;
  gqav5_tile_desc_t address_request_desc;

  logic address_command_valid;
  logic address_command_ready;
  gqav5_dma_op_e address_command_op;
  logic address_command_is_store;
  logic address_command_is_v_load;
  logic [31:0] address_command_addr;
  logic [31:0] address_command_stride;
  logic [6:0] address_command_row_bytes;
  logic [4:0] address_command_valid_rows;
  logic address_command_zero_pad;
  gqav5_tile_desc_t address_command_desc;
  logic address_rejected;
  logic address_error;
  logic [63:0] address_accepted_count;
  logic [63:0] address_rejected_count;

  logic load_dispatch_command_ready;
  logic load_dispatch_active;
  logic load_dispatch_error;
  logic load_dispatch_command_ready_kq;
  logic load_dispatch_command_ready_v;
  logic load_dispatch_active_kq;
  logic load_dispatch_active_v;
  logic load_dispatch_error_kq;
  logic load_dispatch_error_v;
  logic load_mover_cmd_valid;
  logic load_mover_cmd_ready;
  logic [31:0] load_mover_cmd_addr;
  logic [31:0] load_mover_cmd_stride;
  logic [6:0] load_mover_cmd_row_bytes;
  logic [4:0] load_mover_cmd_valid_rows;
  logic load_mover_cmd_zero_pad;
  logic mover_load_tile_start_valid;
  logic mover_load_tile_start_ready;
  logic [2:0] mover_load_tile_index;
  logic mover_load_row_valid;
  logic mover_load_row_ready;
  logic [255:0] mover_load_row_data;
  logic [3:0] mover_load_row_index;
  logic mover_load_row_last;
  logic mover_load_done;
  logic [63:0] load_dispatch_commands;
  logic [63:0] load_dispatch_rows;
  logic [63:0] load_dispatch_stalls;
  logic [63:0] load_dispatch_commands_kq;
  logic [63:0] load_dispatch_rows_kq;
  logic [63:0] load_dispatch_stalls_kq;
  logic [63:0] load_dispatch_commands_v;
  logic [63:0] load_dispatch_rows_v;
  logic [63:0] load_dispatch_stalls_v;

  logic v_load_mover_cmd_valid;
  logic v_load_mover_cmd_ready;
  logic [31:0] v_load_mover_cmd_addr;
  logic [31:0] v_load_mover_cmd_stride;
  logic [6:0] v_load_mover_cmd_row_bytes;
  logic [4:0] v_load_mover_cmd_valid_rows;
  logic v_load_mover_cmd_zero_pad;
  logic v_mover_load_tile_start_valid;
  logic v_mover_load_tile_start_ready;
  logic [2:0] v_mover_load_tile_index;
  logic v_mover_load_row_valid;
  logic v_mover_load_row_ready;
  logic [255:0] v_mover_load_row_data;
  logic [3:0] v_mover_load_row_index;
  logic v_mover_load_row_last;
  logic v_mover_load_done;

  logic q_fill_valid;
  logic q_fill_ready;
  logic [15:0] q_fill_tag;
  logic q_fill_row_valid;
  logic q_fill_row_ready;
  logic [3:0] q_fill_row_addr;
  logic [255:0] q_fill_row_data;
  logic q_fill_row_last;
  logic q_fill_bank;
  logic k_fill_valid;
  logic k_fill_ready;
  logic [1:0] k_fill_partition;
  logic k_fill_broadcast;
  logic [15:0] k_fill_tag;
  logic k_fill_row_valid;
  logic k_fill_row_ready;
  logic [3:0] k_fill_row_addr;
  logic [255:0] k_fill_row_data;
  logic k_fill_row_last;
  logic k_fill_bank;
  logic qk_stream_start_valid, qk_stream_start_ready;
  logic [15:0] qk_stream_start_tag;
  logic qk_stream_row_valid, qk_stream_row_ready;
  logic [3:0] qk_stream_row_index;
  logic [255:0] qk_stream_q_row_bf16;
  logic [255:0] qk_stream_k_partition_row_bf16 [4];
  logic qk_stream_row_last;
  logic qk_column_start_valid, qk_column_start_ready;
  logic [15:0] qk_column_start_tag;
  logic qk_column_valid, qk_column_ready;
  logic [3:0] qk_column_index;
  logic [255:0] qk_column_q_word_bf16;
  logic [255:0] qk_column_k_partition_word_bf16 [4];
  logic qk_column_last;
  logic pv_stream_start_valid, pv_stream_start_ready;
  logic [15:0] pv_stream_start_tag;
  logic pv_stream_row_valid, pv_stream_row_ready;
  logic [3:0] pv_stream_row_index;
  logic [255:0] pv_stream_v_partition_row_bf16 [4];
  logic pv_stream_row_last;
  logic v_fill_valid;
  logic v_fill_ready;
  logic [1:0] v_fill_partition;
  logic v_fill_broadcast;
  logic [15:0] v_fill_tag;
  logic v_fill_row_valid;
  logic v_fill_row_ready;
  logic [3:0] v_fill_row_addr;
  logic [255:0] v_fill_row_data;
  logic v_fill_row_last;
  logic v_fill_bank;
  logic dma_q_fill_valid;
  logic dma_q_fill_ready;
  logic [15:0] dma_q_fill_tag;
  logic dma_q_fill_row_valid;
  logic dma_q_fill_row_ready;
  logic [3:0] dma_q_fill_row_addr;
  logic [255:0] dma_q_fill_row_data;
  logic dma_q_fill_row_last;
  logic dma_k_fill_valid;
  logic dma_k_fill_ready;
  logic [15:0] dma_k_fill_tag;
  logic dma_k_fill_row_valid;
  logic dma_k_fill_row_ready;
  logic [3:0] dma_k_fill_row_addr;
  logic [255:0] dma_k_fill_row_data;
  logic dma_k_fill_row_last;
  logic dma_v_fill_valid;
  logic dma_v_fill_ready;
  logic [15:0] dma_v_fill_tag;
  logic dma_v_fill_row_valid;
  logic dma_v_fill_row_ready;
  logic [3:0] dma_v_fill_row_addr;
  logic [255:0] dma_v_fill_row_data;
  logic dma_v_fill_row_last;
  logic dma_v_fill_valid_kq;
  logic dma_v_fill_ready_kq;
  logic [15:0] dma_v_fill_tag_kq;
  logic dma_v_fill_row_valid_kq;
  logic dma_v_fill_row_ready_kq;
  logic [3:0] dma_v_fill_row_addr_kq;
  logic [255:0] dma_v_fill_row_data_kq;
  logic dma_v_fill_row_last_kq;
  logic dma_v_fill_valid_v;
  logic dma_v_fill_ready_v;
  logic [15:0] dma_v_fill_tag_v;
  logic dma_v_fill_row_valid_v;
  logic dma_v_fill_row_ready_v;
  logic [3:0] dma_v_fill_row_addr_v;
  logic [255:0] dma_v_fill_row_data_v;
  logic dma_v_fill_row_last_v;
  logic resident_frontend_active;
  logic resident_frontend_error;
  logic [127:0] resident_q_tiles;
  logic [127:0] resident_k_tiles;
  logic [127:0] resident_v_tiles;
  logic [63:0] resident_replay_commands;

  logic store_dispatch_command_ready;
  logic store_dispatch_active;
  logic store_dispatch_error;
  logic store_mover_cmd_valid;
  logic store_mover_cmd_ready;
  logic [31:0] store_mover_cmd_addr;
  logic [31:0] store_mover_cmd_stride;
  logic [6:0] store_mover_cmd_row_bytes;
  logic [4:0] store_mover_cmd_valid_rows;
  logic store_mover_row_valid;
  logic store_mover_row_ready;
  logic [511:0] store_mover_row_data;
  logic [3:0] store_mover_row_index;
  logic store_mover_row_last;
  logic mover_store_done;
  logic [63:0] store_dispatch_commands;
  logic [63:0] store_dispatch_results;
  logic [63:0] store_dispatch_rows;
  logic [63:0] store_dispatch_stalls;

  logic result_valid;
  logic result_ready;
  logic [31:0] result_fp32 [16];
  logic [2:0] result_output_tile;
  logic [3:0] result_row_index;
  logic [15:0] result_txn_id;
  logic result_row_valid;
  logic result_fire;
  logic qk_active;
  logic softmax_active;
  logic pv_active;
  logic update_active;
  logic pipeline_done;
  logic pipeline_issue_done;
  logic pipeline_error;
  logic pv_skip_decision_valid;
  logic pv_skip_decision;
  logic [63:0] operand_overlap_cycles;
  logic [63:0] v_overlap_cycles;
  logic [63:0] qk_operand_bram_reads;
  logic [63:0] v_operand_bram_reads;
  logic [63:0] completed_result_rows;

  logic mover_busy;
  logic mover_error;
  logic [63:0] mover_ar_count;
  logic [63:0] mover_aw_count;
  logic [63:0] mover_read_beats;
  logic [63:0] mover_write_beats;
  logic [63:0] mover_command_stalls;
  logic [63:0] mover_ar_wait_cycles;
  logic [63:0] mover_r_gap_cycles;
  logic [63:0] mover_r_backpressure_cycles;
  logic [63:0] mover_bank_wait_cycles;
  logic [63:0] mover_emit_wait_cycles;
  logic [7:0] mover_max_outstanding;
  logic [63:0] mover_boundary_splits;
  logic mover_busy_kq;
  logic mover_error_kq;
  logic [63:0] mover_ar_count_kq;
  logic [63:0] mover_aw_count_kq;
  logic [63:0] mover_read_beats_kq;
  logic [63:0] mover_write_beats_kq;
  logic [63:0] mover_command_stalls_kq;
  logic [63:0] mover_ar_wait_cycles_kq;
  logic [63:0] mover_r_gap_cycles_kq;
  logic [63:0] mover_r_backpressure_cycles_kq;
  logic [63:0] mover_bank_wait_cycles_kq;
  logic [63:0] mover_emit_wait_cycles_kq;
  logic [7:0] mover_max_outstanding_kq;
  logic [63:0] mover_boundary_splits_kq;
  logic mover_busy_v;
  logic mover_error_v;
  logic [63:0] mover_ar_count_v;
  logic [63:0] mover_aw_count_v;
  logic [63:0] mover_read_beats_v;
  logic [63:0] mover_write_beats_v;
  logic [63:0] mover_command_stalls_v;
  logic [63:0] mover_ar_wait_cycles_v;
  logic [63:0] mover_r_gap_cycles_v;
  logic [63:0] mover_r_backpressure_cycles_v;
  logic [63:0] mover_bank_wait_cycles_v;
  logic [63:0] mover_emit_wait_cycles_v;
  logic [7:0] mover_max_outstanding_v;
  logic [63:0] mover_boundary_splits_v;
  logic drain_ready;
  logic job_start;
  logic direct_only_unsupported_start;
  logic direct_only_unsupported_error_q;
  (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *)
  logic error_pipe_a_q;
  (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *)
  logic error_pipe_b_q;

  assign clear_error = start_i;
  assign decode_pack_enable = !prefill_direct_i &&
      (Q_HEADS_PER_KV > 1) &&
      (query_valid_rows_i == 5'd1) &&
      (!causal_i ||
       (({1'b0, query_token_base_i} + (TOKEN_W + 1)'(1)) >=
        context_token_count_i));
  assign kv_wave_pack_enable = prefill_direct_i ||
      (decode_pack_enable && ((KV_HEAD_COUNT % 4) == 0));
  assign direct_only_unsupported_start = start_i &&
      !ENABLE_ROW_COMPAT && !kv_wave_pack_enable;
  assign job_start = start_i && !direct_only_unsupported_start;
  always_comb begin
    group_launch_desc = group_launch_desc_raw;
    group_launch_desc.decode_packed = decode_pack_enable;
    group_launch_desc.kv_wave_packed = kv_wave_pack_enable;
    group_launch_desc.prefill_direct = prefill_direct_i;
  end
  assign compute_desc_fire = compute_desc_valid && compute_desc_ready;
  assign result_fire = result_valid && result_ready;
  assign address_command_is_v_load =
      address_command_op == GQAV5_DMA_LOAD_V;
  assign load_dispatch_command_ready = ENABLE_DUAL_DMA &&
      address_command_is_v_load
      ? load_dispatch_command_ready_v
      : load_dispatch_command_ready_kq;
  assign address_command_ready = address_command_is_store
      ? store_dispatch_command_ready : load_dispatch_command_ready;
  assign load_dispatch_active =
      load_dispatch_active_kq || load_dispatch_active_v;
  assign load_dispatch_error =
      load_dispatch_error_kq || load_dispatch_error_v;
  assign load_dispatch_commands =
      load_dispatch_commands_kq + load_dispatch_commands_v;
  assign load_dispatch_rows =
      load_dispatch_rows_kq + load_dispatch_rows_v;
  assign load_dispatch_stalls =
      load_dispatch_stalls_kq + load_dispatch_stalls_v;
  assign mover_busy = mover_busy_kq || mover_busy_v;
  assign mover_error = mover_error_kq || mover_error_v;
  assign mover_ar_count = mover_ar_count_kq + mover_ar_count_v;
  assign mover_aw_count = mover_aw_count_kq + mover_aw_count_v;
  assign mover_read_beats = mover_read_beats_kq + mover_read_beats_v;
  assign mover_write_beats = mover_write_beats_kq + mover_write_beats_v;
  assign mover_command_stalls =
      mover_command_stalls_kq + mover_command_stalls_v;
  assign mover_ar_wait_cycles =
      mover_ar_wait_cycles_kq + mover_ar_wait_cycles_v;
  assign mover_r_gap_cycles =
      mover_r_gap_cycles_kq + mover_r_gap_cycles_v;
  assign mover_r_backpressure_cycles =
      mover_r_backpressure_cycles_kq + mover_r_backpressure_cycles_v;
  assign mover_bank_wait_cycles =
      mover_bank_wait_cycles_kq + mover_bank_wait_cycles_v;
  assign mover_emit_wait_cycles =
      mover_emit_wait_cycles_kq + mover_emit_wait_cycles_v;
  assign mover_max_outstanding =
      mover_max_outstanding_kq > mover_max_outstanding_v
      ? mover_max_outstanding_kq : mover_max_outstanding_v;
  assign mover_boundary_splits =
      mover_boundary_splits_kq + mover_boundary_splits_v;
  assign dma_v_fill_valid = ENABLE_DUAL_DMA
      ? dma_v_fill_valid_v : dma_v_fill_valid_kq;
  assign dma_v_fill_tag = ENABLE_DUAL_DMA
      ? dma_v_fill_tag_v : dma_v_fill_tag_kq;
  assign dma_v_fill_row_valid = ENABLE_DUAL_DMA
      ? dma_v_fill_row_valid_v : dma_v_fill_row_valid_kq;
  assign dma_v_fill_row_addr = ENABLE_DUAL_DMA
      ? dma_v_fill_row_addr_v : dma_v_fill_row_addr_kq;
  assign dma_v_fill_row_data = ENABLE_DUAL_DMA
      ? dma_v_fill_row_data_v : dma_v_fill_row_data_kq;
  assign dma_v_fill_row_last = ENABLE_DUAL_DMA
      ? dma_v_fill_row_last_v : dma_v_fill_row_last_kq;
  assign dma_v_fill_ready_kq =
      ENABLE_DUAL_DMA ? 1'b0 : dma_v_fill_ready;
  assign dma_v_fill_row_ready_kq =
      ENABLE_DUAL_DMA ? 1'b0 : dma_v_fill_row_ready;
  assign dma_v_fill_ready_v =
      ENABLE_DUAL_DMA ? dma_v_fill_ready : 1'b0;
  assign dma_v_fill_row_ready_v =
      ENABLE_DUAL_DMA ? dma_v_fill_row_ready : 1'b0;
  assign drain_ready = !group_active && !load_dispatch_active &&
      !store_dispatch_active && !resident_frontend_active && !mover_busy &&
      (request_fifo_count_q == 0) && address_request_ready &&
      !address_command_valid && !store_request_pending && !result_valid;

  gqav5_job_scheduler #(
    .MAX_SEQ_LEN  (MAX_SEQ_LEN),
    .KV_HEAD_COUNT(KV_HEAD_COUNT),
    .Q_HEADS_PER_KV(Q_HEADS_PER_KV)
  ) i_job_scheduler (
    .clk_i,
    .rst_ni,
    .clear_error_i          (clear_error),
    .start_i                (job_start),
    .context_token_count_i,
    .query_token_count_i     (prefill_query_token_count_i),
    .query_valid_rows_i,
    .causal_i,
    .kv_wave_packed_i        (kv_wave_pack_enable),
    .prefill_direct_i,
    .group_valid_o          (group_launch_valid),
    .group_ready_i          (group_launch_ready),
    .group_desc_o           (group_launch_desc_raw),
    .group_done_i           (group_done),
    .drain_ready_i          (drain_ready),
    .busy_o,
    .done_o,
    .active_kv_head_o       (active_kv_head),
    .active_context_tile_o  (active_context_tile),
    .launched_group_count_o (launched_groups),
    .completed_group_count_o(completed_groups),
    .protocol_error_o       (job_error)
  );

  gqav5_resident_group_scheduler #(
    .Q_HEADS_PER_KV(Q_HEADS_PER_KV),
    .ENABLE_DUAL_DMA(ENABLE_DUAL_DMA)
  ) i_group_scheduler (
    .clk_i,
    .rst_ni,
    .clear_error_i          (clear_error),
    .pv_skip_enable_i,
    .pv_skip_decision_valid_i(pv_skip_decision_valid),
    .pv_skip_decision_i     (pv_skip_decision),
    .launch_valid_i         (group_launch_valid),
    .launch_ready_o         (group_launch_ready),
    .launch_desc_i          (group_launch_desc),
    .invalidate_q_cache_o   (invalidate_q_cache),
    .invalidate_kv_cache_o  (invalidate_kv_cache),
    .compute_desc_valid_o   (compute_desc_valid),
    .compute_desc_ready_i   (compute_desc_ready),
    .compute_desc_o         (compute_desc),
    .compute_state_slot_o   (compute_state_slot),
    .load_request_valid_o   (load_request_valid),
    .load_request_ready_i   (load_request_ready),
    .load_request_op_o      (load_request_op),
    .load_request_desc_o    (load_request_desc),
    .replay_request_valid_o (replay_request_valid),
    .replay_request_ready_i (replay_request_ready),
    .replay_request_op_o    (replay_request_op),
    .replay_request_desc_o  (replay_request_desc),
    .load_pipeline_idle_i   (!load_dispatch_active),
    .compute_issue_done_i   (pipeline_issue_done),
    .compute_done_i         (pipeline_done),
    .group_done_o           (group_done),
    .active_o               (group_active),
    .active_q_lane_o        (group_active_q_lane),
    .compute_descriptor_count_o(compute_desc_count),
    .load_request_count_o   (load_request_count),
    .replay_request_count_o (replay_request_count),
    .completed_q_head_count_o(completed_q_heads),
    .kv_resident_hit_count_o (kv_resident_hits),
    .kv_resident_miss_count_o(kv_resident_misses),
    .prefetch_issue_count_o   (prefetch_issues),
    .protocol_error_o       (group_error)
  );

  gqav5_store_request_generator i_store_request (
    .clk_i,
    .rst_ni,
    .clear_error_i          (clear_error),
    // Online Softmax only emits normalized result rows after the final
    // context tile.  Intermediate descriptors update resident state but do
    // not own a store transaction, so they must not consume store metadata
    // FIFO entries when multiple groups overlap.
    .context_capture_i      (compute_desc_fire && compute_desc.last_context),
    .context_desc_i         (compute_desc),
    .result_valid_i         (result_valid),
    .result_fire_i          (result_fire),
    .result_output_tile_i   (result_output_tile),
    .result_row_index_i     (result_row_index),
    .result_txn_id_i        (result_txn_id),
    .request_valid_o        (store_request_valid),
    .request_ready_i        (store_request_ready),
    .request_desc_o         (store_request_desc),
    .pending_o              (store_request_pending),
    .request_count_o        (store_request_count),
    .protocol_error_o       (store_request_error)
  );

  gqav5_dma_request_arbiter i_request_arbiter (
    .load_valid_i    (load_request_valid),
    .load_ready_o    (load_request_ready),
    .load_op_i       (load_request_op),
    .load_desc_i     (load_request_desc),
    .store_valid_i   (store_request_valid),
    .store_ready_o   (store_request_ready),
    .store_desc_i    (store_request_desc),
    .request_valid_o (arb_request_valid),
    .request_ready_i (arb_request_ready),
    .request_op_o    (arb_request_op),
    .request_desc_o  (arb_request_desc),
    .store_selected_o(arb_store_selected)
  );

  // Decouple scheduler/store metadata from the address generator.  The
  // registered two-entry queue cuts the former normalize -> scheduler -> DMA
  // address-generator ready/validation cone while allowing the next request
  // to wait behind the multi-cycle programmable-stride calculation.
  assign arb_request_ready = request_fifo_count_q < 2;
  assign request_fifo_push = arb_request_valid && arb_request_ready;
  assign address_request_valid = request_fifo_count_q != 0;
  assign address_request_op = request_fifo_op_q[request_fifo_rd_q];
  assign address_request_desc = request_fifo_desc_q[request_fifo_rd_q];
  assign request_fifo_pop = address_request_valid && address_request_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      request_fifo_op_q[0]   <= GQAV5_DMA_LOAD_Q;
      request_fifo_op_q[1]   <= GQAV5_DMA_LOAD_Q;
      request_fifo_desc_q[0] <= '0;
      request_fifo_desc_q[1] <= '0;
      request_fifo_rd_q      <= 1'b0;
      request_fifo_wr_q      <= 1'b0;
      request_fifo_count_q   <= '0;
    end else begin
      unique case ({request_fifo_push, request_fifo_pop})
        2'b10: begin
          request_fifo_op_q[request_fifo_wr_q]   <= arb_request_op;
          request_fifo_desc_q[request_fifo_wr_q] <= arb_request_desc;
          request_fifo_wr_q                      <= ~request_fifo_wr_q;
          request_fifo_count_q                   <= request_fifo_count_q + 2'd1;
        end
        2'b01: begin
          request_fifo_rd_q    <= ~request_fifo_rd_q;
          request_fifo_count_q <= request_fifo_count_q - 2'd1;
        end
        2'b11: begin
          request_fifo_op_q[request_fifo_wr_q]   <= arb_request_op;
          request_fifo_desc_q[request_fifo_wr_q] <= arb_request_desc;
          request_fifo_wr_q                      <= ~request_fifo_wr_q;
          request_fifo_rd_q                      <= ~request_fifo_rd_q;
        end
        default: begin
        end
      endcase
    end
  end

  gqav5_dma_address_generator #(.MAX_SEQ_LEN(MAX_SEQ_LEN)) i_address (
    .clk_i,
    .rst_ni,
    .clear_error_i                (clear_error),
    .q_base_addr_i,
    .k_base_addr_i,
    .v_base_addr_i,
    .o_base_addr_i,
    .q_head_stride_bytes_i,
    .q_token_stride_bytes_i,
    .k_head_stride_bytes_i,
    .k_token_stride_bytes_i,
    .v_head_stride_bytes_i,
    .v_token_stride_bytes_i,
    .o_head_stride_bytes_i,
    .o_token_stride_bytes_i,
    .bf16_output_i,
    .context_token_count_i,
    .query_token_base_i,
    .request_valid_i              (address_request_valid),
    .request_ready_o              (address_request_ready),
    .request_op_i                 (address_request_op),
    .request_desc_i               (address_request_desc),
    .command_valid_o              (address_command_valid),
    .command_ready_i              (address_command_ready),
    .command_op_o                 (address_command_op),
    .command_is_store_o           (address_command_is_store),
    .command_addr_o               (address_command_addr),
    .command_row_stride_bytes_o   (address_command_stride),
    .command_row_bytes_o          (address_command_row_bytes),
    .command_valid_rows_o         (address_command_valid_rows),
    .command_zero_pad_o           (address_command_zero_pad),
    .command_desc_o               (address_command_desc),
    .rejected_o                   (address_rejected),
    .error_o                      (address_error),
    .accepted_count_o             (address_accepted_count),
    .rejected_count_o             (address_rejected_count)
  );

  gqav5_dma_load_dispatch_v5_2 i_load_dispatch (
    .clk_i,
    .rst_ni,
    .clear_error_i              (clear_error),
    .command_valid_i            (address_command_valid &&
                                 !address_command_is_store &&
                                 (!ENABLE_DUAL_DMA ||
                                  !address_command_is_v_load)),
    .command_ready_o            (load_dispatch_command_ready_kq),
    .command_op_i               (address_command_op),
    .command_addr_i             (address_command_addr),
    .command_row_stride_bytes_i (address_command_stride),
    .command_row_bytes_i        (address_command_row_bytes),
    .command_valid_rows_i       (address_command_valid_rows),
    .command_zero_pad_i         (address_command_zero_pad),
    .command_desc_i             (address_command_desc),
    .mover_cmd_valid_o          (load_mover_cmd_valid),
    .mover_cmd_ready_i          (load_mover_cmd_ready),
    .mover_cmd_addr_o           (load_mover_cmd_addr),
    .mover_cmd_row_stride_bytes_o(load_mover_cmd_stride),
    .mover_cmd_row_bytes_o      (load_mover_cmd_row_bytes),
    .mover_cmd_valid_rows_o     (load_mover_cmd_valid_rows),
    .mover_cmd_zero_pad_o       (load_mover_cmd_zero_pad),
    .mover_tile_start_valid_i   (mover_load_tile_start_valid),
    .mover_tile_start_ready_o   (mover_load_tile_start_ready),
    .mover_tile_index_i         (mover_load_tile_index),
    .mover_row_valid_i          (mover_load_row_valid),
    .mover_row_ready_o          (mover_load_row_ready),
    .mover_row_bf16_i           (mover_load_row_data),
    .mover_row_index_i          (mover_load_row_index),
    .mover_row_last_i           (mover_load_row_last),
    .mover_done_i               (mover_load_done),
    .mover_error_i              (mover_error_kq),
    .q_fill_valid_o             (dma_q_fill_valid),
    .q_fill_ready_i             (dma_q_fill_ready),
    .q_fill_tag_o               (dma_q_fill_tag),
    .q_fill_row_valid_o         (dma_q_fill_row_valid),
    .q_fill_row_ready_i         (dma_q_fill_row_ready),
    .q_fill_row_addr_o          (dma_q_fill_row_addr),
    .q_fill_row_data_o          (dma_q_fill_row_data),
    .q_fill_row_last_o          (dma_q_fill_row_last),
    .k_fill_valid_o             (dma_k_fill_valid),
    .k_fill_ready_i             (dma_k_fill_ready),
    .k_fill_tag_o               (dma_k_fill_tag),
    .k_fill_row_valid_o         (dma_k_fill_row_valid),
    .k_fill_row_ready_i         (dma_k_fill_row_ready),
    .k_fill_row_addr_o          (dma_k_fill_row_addr),
    .k_fill_row_data_o          (dma_k_fill_row_data),
    .k_fill_row_last_o          (dma_k_fill_row_last),
    .v_fill_valid_o             (dma_v_fill_valid_kq),
    .v_fill_ready_i             (dma_v_fill_ready_kq),
    .v_fill_tag_o               (dma_v_fill_tag_kq),
    .v_fill_row_valid_o         (dma_v_fill_row_valid_kq),
    .v_fill_row_ready_i         (dma_v_fill_row_ready_kq),
    .v_fill_row_addr_o          (dma_v_fill_row_addr_kq),
    .v_fill_row_data_o          (dma_v_fill_row_data_kq),
    .v_fill_row_last_o          (dma_v_fill_row_last_kq),
    .active_o                   (load_dispatch_active_kq),
    .accepted_command_count_o  (load_dispatch_commands_kq),
    .transferred_row_count_o   (load_dispatch_rows_kq),
    .command_stall_cycle_count_o(load_dispatch_stalls_kq),
    .protocol_error_o          (load_dispatch_error_kq)
  );

  generate
    if (ENABLE_DUAL_DMA) begin : gen_v_load_dispatch
      /* verilator lint_off PINCONNECTEMPTY */
      gqav5_dma_load_dispatch_v5_2 i_v_load_dispatch (
        .clk_i,
        .rst_ni,
        .clear_error_i              (clear_error),
        .command_valid_i            (address_command_valid &&
                                     !address_command_is_store &&
                                     address_command_is_v_load),
        .command_ready_o            (load_dispatch_command_ready_v),
        .command_op_i               (address_command_op),
        .command_addr_i             (address_command_addr),
        .command_row_stride_bytes_i (address_command_stride),
        .command_row_bytes_i        (address_command_row_bytes),
        .command_valid_rows_i       (address_command_valid_rows),
        .command_zero_pad_i         (address_command_zero_pad),
        .command_desc_i             (address_command_desc),
        .mover_cmd_valid_o          (v_load_mover_cmd_valid),
        .mover_cmd_ready_i          (v_load_mover_cmd_ready),
        .mover_cmd_addr_o           (v_load_mover_cmd_addr),
        .mover_cmd_row_stride_bytes_o(v_load_mover_cmd_stride),
        .mover_cmd_row_bytes_o      (v_load_mover_cmd_row_bytes),
        .mover_cmd_valid_rows_o     (v_load_mover_cmd_valid_rows),
        .mover_cmd_zero_pad_o       (v_load_mover_cmd_zero_pad),
        .mover_tile_start_valid_i   (v_mover_load_tile_start_valid),
        .mover_tile_start_ready_o   (v_mover_load_tile_start_ready),
        .mover_tile_index_i         (v_mover_load_tile_index),
        .mover_row_valid_i          (v_mover_load_row_valid),
        .mover_row_ready_o          (v_mover_load_row_ready),
        .mover_row_bf16_i           (v_mover_load_row_data),
        .mover_row_index_i          (v_mover_load_row_index),
        .mover_row_last_i           (v_mover_load_row_last),
        .mover_done_i               (v_mover_load_done),
        .mover_error_i              (mover_error_v),
        .q_fill_valid_o             (),
        .q_fill_ready_i             (1'b0),
        .q_fill_tag_o               (),
        .q_fill_row_valid_o         (),
        .q_fill_row_ready_i         (1'b0),
        .q_fill_row_addr_o          (),
        .q_fill_row_data_o          (),
        .q_fill_row_last_o          (),
        .k_fill_valid_o             (),
        .k_fill_ready_i             (1'b0),
        .k_fill_tag_o               (),
        .k_fill_row_valid_o         (),
        .k_fill_row_ready_i         (1'b0),
        .k_fill_row_addr_o          (),
        .k_fill_row_data_o          (),
        .k_fill_row_last_o          (),
        .v_fill_valid_o             (dma_v_fill_valid_v),
        .v_fill_ready_i             (dma_v_fill_ready_v),
        .v_fill_tag_o               (dma_v_fill_tag_v),
        .v_fill_row_valid_o         (dma_v_fill_row_valid_v),
        .v_fill_row_ready_i         (dma_v_fill_row_ready_v),
        .v_fill_row_addr_o          (dma_v_fill_row_addr_v),
        .v_fill_row_data_o          (dma_v_fill_row_data_v),
        .v_fill_row_last_o          (dma_v_fill_row_last_v),
        .active_o                   (load_dispatch_active_v),
        .accepted_command_count_o  (load_dispatch_commands_v),
        .transferred_row_count_o   (load_dispatch_rows_v),
        .command_stall_cycle_count_o(load_dispatch_stalls_v),
        .protocol_error_o          (load_dispatch_error_v)
      );
      /* verilator lint_on PINCONNECTEMPTY */
    end else begin : gen_no_v_load_dispatch
      assign load_dispatch_command_ready_v = 1'b0;
      assign load_dispatch_active_v = 1'b0;
      assign load_dispatch_error_v = 1'b0;
      assign load_dispatch_commands_v = '0;
      assign load_dispatch_rows_v = '0;
      assign load_dispatch_stalls_v = '0;
      assign v_load_mover_cmd_valid = 1'b0;
      assign v_load_mover_cmd_addr = '0;
      assign v_load_mover_cmd_stride = '0;
      assign v_load_mover_cmd_row_bytes = '0;
      assign v_load_mover_cmd_valid_rows = '0;
      assign v_load_mover_cmd_zero_pad = 1'b0;
      assign v_mover_load_tile_start_ready = 1'b0;
      assign v_mover_load_row_ready = 1'b0;
      assign dma_v_fill_valid_v = 1'b0;
      assign dma_v_fill_tag_v = '0;
      assign dma_v_fill_row_valid_v = 1'b0;
      assign dma_v_fill_row_addr_v = '0;
      assign dma_v_fill_row_data_v = '0;
      assign dma_v_fill_row_last_v = 1'b0;
    end
  endgenerate

  gqav5_resident_operand_frontend #(
    .Q_HEADS_PER_KV(Q_HEADS_PER_KV),
    .ENABLE_ROW_COMPAT(ENABLE_ROW_COMPAT)
  ) i_resident_operands (
    .clk_i,
    .rst_ni,
    .clear_error_i              (clear_error),
    .invalidate_q_i             (invalidate_q_cache),
    .invalidate_kv_i            (invalidate_kv_cache),
    .dma_q_fill_valid_i         (dma_q_fill_valid),
    .dma_q_fill_ready_o         (dma_q_fill_ready),
    .dma_q_fill_tag_i           (dma_q_fill_tag),
    .dma_q_fill_row_valid_i     (dma_q_fill_row_valid),
    .dma_q_fill_row_ready_o     (dma_q_fill_row_ready),
    .dma_q_fill_row_addr_i      (dma_q_fill_row_addr),
    .dma_q_fill_row_data_i      (dma_q_fill_row_data),
    .dma_q_fill_row_last_i      (dma_q_fill_row_last),
    .dma_k_fill_valid_i         (dma_k_fill_valid),
    .dma_k_fill_ready_o         (dma_k_fill_ready),
    .dma_k_fill_tag_i           (dma_k_fill_tag),
    .dma_k_fill_row_valid_i     (dma_k_fill_row_valid),
    .dma_k_fill_row_ready_o     (dma_k_fill_row_ready),
    .dma_k_fill_row_addr_i      (dma_k_fill_row_addr),
    .dma_k_fill_row_data_i      (dma_k_fill_row_data),
    .dma_k_fill_row_last_i      (dma_k_fill_row_last),
    .dma_v_fill_valid_i         (dma_v_fill_valid),
    .dma_v_fill_ready_o         (dma_v_fill_ready),
    .dma_v_fill_tag_i           (dma_v_fill_tag),
    .dma_v_fill_row_valid_i     (dma_v_fill_row_valid),
    .dma_v_fill_row_ready_o     (dma_v_fill_row_ready),
    .dma_v_fill_row_addr_i      (dma_v_fill_row_addr),
    .dma_v_fill_row_data_i      (dma_v_fill_row_data),
    .dma_v_fill_row_last_i      (dma_v_fill_row_last),
    .replay_valid_i             (replay_request_valid),
    .replay_ready_o             (replay_request_ready),
    .replay_op_i                (replay_request_op),
    .replay_desc_i              (replay_request_desc),
    .q_fill_valid_o             (q_fill_valid),
    .q_fill_ready_i             (q_fill_ready),
    .q_fill_tag_o               (q_fill_tag),
    .q_fill_row_valid_o         (q_fill_row_valid),
    .q_fill_row_ready_i         (q_fill_row_ready),
    .q_fill_row_addr_o          (q_fill_row_addr),
    .q_fill_row_data_o          (q_fill_row_data),
    .q_fill_row_last_o          (q_fill_row_last),
    .k_fill_valid_o             (k_fill_valid),
    .k_fill_ready_i             (k_fill_ready),
    .k_fill_broadcast_o         (k_fill_broadcast),
    .k_fill_partition_o         (k_fill_partition),
    .k_fill_tag_o               (k_fill_tag),
    .k_fill_row_valid_o         (k_fill_row_valid),
    .k_fill_row_ready_i         (k_fill_row_ready),
    .k_fill_row_addr_o          (k_fill_row_addr),
    .k_fill_row_data_o          (k_fill_row_data),
    .k_fill_row_last_o          (k_fill_row_last),
    .qk_stream_start_valid_o    (qk_stream_start_valid),
    .qk_stream_start_ready_i    (qk_stream_start_ready),
    .qk_stream_start_tag_o      (qk_stream_start_tag),
    .qk_stream_row_valid_o      (qk_stream_row_valid),
    .qk_stream_row_ready_i      (qk_stream_row_ready),
    .qk_stream_row_index_o      (qk_stream_row_index),
    .qk_stream_q_row_bf16_o     (qk_stream_q_row_bf16),
    .qk_stream_k_partition_row_bf16_o(
        qk_stream_k_partition_row_bf16),
    .qk_stream_row_last_o       (qk_stream_row_last),
    .qk_column_start_valid_o    (qk_column_start_valid),
    .qk_column_start_ready_i    (qk_column_start_ready),
    .qk_column_start_tag_o      (qk_column_start_tag),
    .qk_column_valid_o          (qk_column_valid),
    .qk_column_ready_i          (qk_column_ready),
    .qk_column_index_o          (qk_column_index),
    .qk_column_q_word_bf16_o    (qk_column_q_word_bf16),
    .qk_column_k_partition_word_bf16_o(
        qk_column_k_partition_word_bf16),
    .qk_column_last_o           (qk_column_last),
    .pv_stream_start_valid_o    (pv_stream_start_valid),
    .pv_stream_start_ready_i    (pv_stream_start_ready),
    .pv_stream_start_tag_o      (pv_stream_start_tag),
    .pv_stream_row_valid_o      (pv_stream_row_valid),
    .pv_stream_row_ready_i      (pv_stream_row_ready),
    .pv_stream_row_index_o      (pv_stream_row_index),
    .pv_stream_v_partition_row_bf16_o(
        pv_stream_v_partition_row_bf16),
    .pv_stream_row_last_o       (pv_stream_row_last),
    .v_fill_valid_o             (v_fill_valid),
    .v_fill_ready_i             (v_fill_ready),
    .v_fill_broadcast_o         (v_fill_broadcast),
    .v_fill_partition_o         (v_fill_partition),
    .v_fill_tag_o               (v_fill_tag),
    .v_fill_row_valid_o         (v_fill_row_valid),
    .v_fill_row_ready_i         (v_fill_row_ready),
    .v_fill_row_addr_o          (v_fill_row_addr),
    .v_fill_row_data_o          (v_fill_row_data),
    .v_fill_row_last_o          (v_fill_row_last),
    .active_o                   (resident_frontend_active),
    .resident_q_tiles_o        (resident_q_tiles),
    .resident_k_tiles_o        (resident_k_tiles),
    .resident_v_tiles_o        (resident_v_tiles),
    .replay_command_count_o    (resident_replay_commands),
    .protocol_error_o          (resident_frontend_error)
  );

  gqav5_dma_store_dispatch i_store_dispatch (
    .clk_i,
    .rst_ni,
    .clear_error_i              (clear_error),
    .command_valid_i            (address_command_valid &&
                                 address_command_is_store),
    .command_ready_o            (store_dispatch_command_ready),
    .command_op_i               (address_command_op),
    .command_addr_i             (address_command_addr),
    .command_row_stride_bytes_i (address_command_stride),
    .command_row_bytes_i        (address_command_row_bytes),
    .command_valid_rows_i       (address_command_valid_rows),
    .command_desc_i             (address_command_desc),
    .mover_cmd_valid_o          (store_mover_cmd_valid),
    .mover_cmd_ready_i          (store_mover_cmd_ready),
    .mover_cmd_addr_o           (store_mover_cmd_addr),
    .mover_cmd_row_stride_bytes_o(store_mover_cmd_stride),
    .mover_cmd_row_bytes_o      (store_mover_cmd_row_bytes),
    .mover_cmd_valid_rows_o     (store_mover_cmd_valid_rows),
    .mover_row_valid_o          (store_mover_row_valid),
    .mover_row_ready_i          (store_mover_row_ready),
    .mover_row_fp32_o           (store_mover_row_data),
    .mover_row_index_o          (store_mover_row_index),
    .mover_row_last_o           (store_mover_row_last),
    .mover_done_i               (mover_store_done),
    .mover_error_i              (mover_error),
    .result_valid_i             (result_valid),
    .result_ready_o             (result_ready),
    .result_fp32_i              (result_fp32),
    .result_output_tile_i       (result_output_tile),
    .result_row_index_i         (result_row_index),
    .result_txn_id_i            (result_txn_id),
    .result_row_valid_i         (result_row_valid),
    .active_o                   (store_dispatch_active),
    .accepted_command_count_o  (store_dispatch_commands),
    .accepted_result_row_count_o(store_dispatch_results),
    .submitted_store_row_count_o(store_dispatch_rows),
    .command_stall_cycle_count_o(store_dispatch_stalls),
    .protocol_error_o          (store_dispatch_error)
  );

  gqav5_partitioned_buffered_attention_pipeline #(
    .ENABLE_ROW_COMPAT(ENABLE_ROW_COMPAT)
  ) i_pipeline (
    .clk_i,
    .rst_ni,
    .desc_valid_i               (compute_desc_valid),
    .desc_ready_o               (compute_desc_ready),
    .desc_state_slot_i          (compute_state_slot),
    .desc_query_base_i          (32'(query_token_base_i) +
                                  (32'(compute_desc.query_tile) << 4)),
    .desc_context_base_i        (32'(compute_desc.context_tile) << 4),
    .desc_query_valid_rows_i    (compute_desc.query_valid_rows),
    .desc_context_valid_cols_i  (compute_desc.context_valid_cols),
    .desc_causal_i              (compute_desc.causal),
    .desc_first_context_i       (compute_desc.first_context),
    .desc_last_context_i        (compute_desc.last_context),
    .attention_scale_fp32_i,
    .desc_txn_id_i              (compute_desc.txn_id),
    .pv_skip_enable_i,
    .pv_skip_lambda_fp32_i,
    .q_fill_valid_i             (q_fill_valid),
    .q_fill_ready_o             (q_fill_ready),
    .q_fill_tag_i               (q_fill_tag),
    .q_fill_bank_o              (q_fill_bank),
    .q_fill_row_valid_i         (q_fill_row_valid),
    .q_fill_row_ready_o         (q_fill_row_ready),
    .q_fill_row_addr_i          (q_fill_row_addr),
    .q_fill_row_data_i          (q_fill_row_data),
    .q_fill_row_last_i          (q_fill_row_last),
    .k_fill_valid_i             (k_fill_valid),
    .k_fill_ready_o             (k_fill_ready),
    .k_fill_broadcast_i         (k_fill_broadcast),
    .k_fill_partition_i         (k_fill_partition),
    .k_fill_tag_i               (k_fill_tag),
    .k_fill_bank_o              (k_fill_bank),
    .k_fill_row_valid_i         (k_fill_row_valid),
    .k_fill_row_ready_o         (k_fill_row_ready),
    .k_fill_row_addr_i          (k_fill_row_addr),
    .k_fill_row_data_i          (k_fill_row_data),
    .k_fill_row_last_i          (k_fill_row_last),
    .qk_stream_start_valid_i    (qk_stream_start_valid),
    .qk_stream_start_ready_o    (qk_stream_start_ready),
    .qk_stream_start_tag_i      (qk_stream_start_tag),
    .qk_stream_row_valid_i      (qk_stream_row_valid),
    .qk_stream_row_ready_o      (qk_stream_row_ready),
    .qk_stream_row_index_i      (qk_stream_row_index),
    .qk_stream_q_row_bf16_i     (qk_stream_q_row_bf16),
    .qk_stream_k_partition_row_bf16_i(
        qk_stream_k_partition_row_bf16),
    .qk_stream_row_last_i       (qk_stream_row_last),
    .qk_column_start_valid_i    (qk_column_start_valid),
    .qk_column_start_ready_o    (qk_column_start_ready),
    .qk_column_start_tag_i      (qk_column_start_tag),
    .qk_column_valid_i          (qk_column_valid),
    .qk_column_ready_o          (qk_column_ready),
    .qk_column_index_i          (qk_column_index),
    .qk_column_q_word_bf16_i    (qk_column_q_word_bf16),
    .qk_column_k_partition_word_bf16_i(
        qk_column_k_partition_word_bf16),
    .qk_column_last_i           (qk_column_last),
    .pv_stream_start_valid_i    (pv_stream_start_valid),
    .pv_stream_start_ready_o    (pv_stream_start_ready),
    .pv_stream_start_tag_i      (pv_stream_start_tag),
    .pv_stream_row_valid_i      (pv_stream_row_valid),
    .pv_stream_row_ready_o      (pv_stream_row_ready),
    .pv_stream_row_index_i      (pv_stream_row_index),
    .pv_stream_v_partition_row_bf16_i(
        pv_stream_v_partition_row_bf16),
    .pv_stream_row_last_i       (pv_stream_row_last),
    .v_fill_valid_i             (v_fill_valid),
    .v_fill_ready_o             (v_fill_ready),
    .v_fill_broadcast_i         (v_fill_broadcast),
    .v_fill_partition_i         (v_fill_partition),
    .v_fill_tag_i               (v_fill_tag),
    .v_fill_bank_o              (v_fill_bank),
    .v_fill_row_valid_i         (v_fill_row_valid),
    .v_fill_row_ready_o         (v_fill_row_ready),
    .v_fill_row_addr_i          (v_fill_row_addr),
    .v_fill_row_data_i          (v_fill_row_data),
    .v_fill_row_last_i          (v_fill_row_last),
    .result_valid_o             (result_valid),
    .result_ready_i             (result_ready),
    .result_fp32_o              (result_fp32),
    .result_output_tile_o       (result_output_tile),
    .result_row_index_o         (result_row_index),
    .result_txn_id_o            (result_txn_id),
    .result_row_valid_o         (result_row_valid),
    .qk_active_o                (qk_active),
    .softmax_active_o           (softmax_active),
    .pv_active_o                (pv_active),
    .update_active_o            (update_active),
    .done_o                     (pipeline_done),
    .qk_accepted_macs_o,
    .pv_accepted_macs_o,
    .qk_operand_bram_reads_o    (qk_operand_bram_reads),
    .v_operand_bram_reads_o     (v_operand_bram_reads),
    .operand_prefetch_overlap_cycles_o(operand_overlap_cycles),
    .v_prefetch_overlap_cycles_o(v_overlap_cycles),
    .completed_result_rows_o   (completed_result_rows),
    .pv_blocks_total_o,
    .pv_blocks_skipped_o,
    .pv_skip_decision_valid_o(pv_skip_decision_valid),
    .pv_skip_decision_o     (pv_skip_decision),
    .issue_done_o            (pipeline_issue_done),
    .error_o                    (pipeline_error)
  );

  gqav5_axi_row_mover_256_cdc #(
    .AXI_ID_W(AXI_ID_W),
    .BANK_COUNT(8),
    .MAX_READ_OUTSTANDING(8)
  ) i_row_mover (
    .core_clk_i(clk_i),
    .core_rst_ni(rst_ni),
    .dma_clk_i,
    .dma_rst_ni,
    .load_cmd_valid_i            (load_mover_cmd_valid),
    .load_cmd_ready_o            (load_mover_cmd_ready),
    .load_cmd_addr_i             (load_mover_cmd_addr),
    .load_cmd_row_stride_bytes_i (load_mover_cmd_stride),
    .load_cmd_row_bytes_i        (load_mover_cmd_row_bytes),
    .load_cmd_valid_rows_i       (load_mover_cmd_valid_rows),
    .load_cmd_zero_pad_i         (load_mover_cmd_zero_pad),
    .load_tile_start_valid_o     (mover_load_tile_start_valid),
    .load_tile_start_ready_i     (mover_load_tile_start_ready),
    .load_tile_index_o           (mover_load_tile_index),
    .load_row_valid_o            (mover_load_row_valid),
    .load_row_ready_i            (mover_load_row_ready),
    .load_row_bf16_o             (mover_load_row_data),
    .load_row_index_o            (mover_load_row_index),
    .load_row_last_o             (mover_load_row_last),
    .load_done_o                 (mover_load_done),
    .store_cmd_valid_i           (store_mover_cmd_valid),
    .store_cmd_ready_o           (store_mover_cmd_ready),
    .store_cmd_addr_i            (store_mover_cmd_addr),
    .store_cmd_row_stride_bytes_i(store_mover_cmd_stride),
    .store_cmd_row_bytes_i       (store_mover_cmd_row_bytes),
    .store_cmd_valid_rows_i      (store_mover_cmd_valid_rows),
    .store_row_valid_i           (store_mover_row_valid),
    .store_row_ready_o           (store_mover_row_ready),
    .store_row_fp32_i            (store_mover_row_data),
    .store_row_index_i           (store_mover_row_index),
    .store_row_last_i            (store_mover_row_last),
    .store_done_o                (mover_store_done),
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
    .busy_o                       (mover_busy_kq),
    .ar_transaction_count_o       (mover_ar_count_kq),
    .aw_transaction_count_o       (mover_aw_count_kq),
    .read_beat_count_o            (mover_read_beats_kq),
    .write_beat_count_o           (mover_write_beats_kq),
    .command_stall_cycle_count_o  (mover_command_stalls_kq),
    .ar_wait_cycle_count_o        (mover_ar_wait_cycles_kq),
    .r_gap_cycle_count_o          (mover_r_gap_cycles_kq),
    .r_backpressure_cycle_count_o (mover_r_backpressure_cycles_kq),
    .bank_wait_cycle_count_o      (mover_bank_wait_cycles_kq),
    .emit_wait_cycle_count_o      (mover_emit_wait_cycles_kq),
    .max_outstanding_o            (mover_max_outstanding_kq),
    .boundary_split_count_o       (mover_boundary_splits_kq),
    .error_o                      (mover_error_kq)
  );

  generate
    if (ENABLE_DUAL_DMA) begin : gen_v_row_mover
      /* verilator lint_off PINCONNECTEMPTY */
      gqav5_axi_row_mover_256_cdc #(
        .AXI_ID_W(AXI_ID_W),
        .AXI_ID(AXI_ID_W'(1)),
        .BANK_COUNT(8),
        .MAX_READ_OUTSTANDING(8)
      ) i_v_row_mover (
        .core_clk_i(clk_i),
        .core_rst_ni(rst_ni),
        .dma_clk_i,
        .dma_rst_ni,
        .load_cmd_valid_i            (v_load_mover_cmd_valid),
        .load_cmd_ready_o            (v_load_mover_cmd_ready),
        .load_cmd_addr_i             (v_load_mover_cmd_addr),
        .load_cmd_row_stride_bytes_i (v_load_mover_cmd_stride),
        .load_cmd_row_bytes_i        (v_load_mover_cmd_row_bytes),
        .load_cmd_valid_rows_i       (v_load_mover_cmd_valid_rows),
        .load_cmd_zero_pad_i         (v_load_mover_cmd_zero_pad),
        .load_tile_start_valid_o     (v_mover_load_tile_start_valid),
        .load_tile_start_ready_i     (v_mover_load_tile_start_ready),
        .load_tile_index_o           (v_mover_load_tile_index),
        .load_row_valid_o            (v_mover_load_row_valid),
        .load_row_ready_i            (v_mover_load_row_ready),
        .load_row_bf16_o             (v_mover_load_row_data),
        .load_row_index_o            (v_mover_load_row_index),
        .load_row_last_o             (v_mover_load_row_last),
        .load_done_o                 (v_mover_load_done),
        .store_cmd_valid_i           (1'b0),
        .store_cmd_ready_o           (),
        .store_cmd_addr_i            ('0),
        .store_cmd_row_stride_bytes_i('0),
        .store_cmd_row_bytes_i       ('0),
        .store_cmd_valid_rows_i      ('0),
        .store_row_valid_i           (1'b0),
        .store_row_ready_o           (),
        .store_row_fp32_i            ('0),
        .store_row_index_i           ('0),
        .store_row_last_i            (1'b0),
        .store_done_o                (),
        .m_axi_awid_o                (m_axi_v_awid_o),
        .m_axi_awaddr_o              (m_axi_v_awaddr_o),
        .m_axi_awlen_o               (m_axi_v_awlen_o),
        .m_axi_awsize_o              (m_axi_v_awsize_o),
        .m_axi_awburst_o             (m_axi_v_awburst_o),
        .m_axi_awlock_o              (m_axi_v_awlock_o),
        .m_axi_awcache_o             (m_axi_v_awcache_o),
        .m_axi_awprot_o              (m_axi_v_awprot_o),
        .m_axi_awqos_o               (m_axi_v_awqos_o),
        .m_axi_awregion_o            (m_axi_v_awregion_o),
        .m_axi_awvalid_o             (m_axi_v_awvalid_o),
        .m_axi_awready_i             (m_axi_v_awready_i),
        .m_axi_wdata_o               (m_axi_v_wdata_o),
        .m_axi_wstrb_o               (m_axi_v_wstrb_o),
        .m_axi_wlast_o               (m_axi_v_wlast_o),
        .m_axi_wvalid_o              (m_axi_v_wvalid_o),
        .m_axi_wready_i              (m_axi_v_wready_i),
        .m_axi_bid_i                 (m_axi_v_bid_i),
        .m_axi_bresp_i               (m_axi_v_bresp_i),
        .m_axi_bvalid_i              (m_axi_v_bvalid_i),
        .m_axi_bready_o              (m_axi_v_bready_o),
        .m_axi_arid_o                (m_axi_v_arid_o),
        .m_axi_araddr_o              (m_axi_v_araddr_o),
        .m_axi_arlen_o               (m_axi_v_arlen_o),
        .m_axi_arsize_o              (m_axi_v_arsize_o),
        .m_axi_arburst_o             (m_axi_v_arburst_o),
        .m_axi_arlock_o              (m_axi_v_arlock_o),
        .m_axi_arcache_o             (m_axi_v_arcache_o),
        .m_axi_arprot_o              (m_axi_v_arprot_o),
        .m_axi_arqos_o               (m_axi_v_arqos_o),
        .m_axi_arregion_o            (m_axi_v_arregion_o),
        .m_axi_arvalid_o             (m_axi_v_arvalid_o),
        .m_axi_arready_i             (m_axi_v_arready_i),
        .m_axi_rid_i                 (m_axi_v_rid_i),
        .m_axi_rdata_i               (m_axi_v_rdata_i),
        .m_axi_rresp_i               (m_axi_v_rresp_i),
        .m_axi_rlast_i               (m_axi_v_rlast_i),
        .m_axi_rvalid_i              (m_axi_v_rvalid_i),
        .m_axi_rready_o              (m_axi_v_rready_o),
        .busy_o                      (mover_busy_v),
        .ar_transaction_count_o      (mover_ar_count_v),
        .aw_transaction_count_o      (mover_aw_count_v),
        .read_beat_count_o           (mover_read_beats_v),
        .write_beat_count_o          (mover_write_beats_v),
        .command_stall_cycle_count_o (mover_command_stalls_v),
        .ar_wait_cycle_count_o       (mover_ar_wait_cycles_v),
        .r_gap_cycle_count_o         (mover_r_gap_cycles_v),
        .r_backpressure_cycle_count_o(mover_r_backpressure_cycles_v),
        .bank_wait_cycle_count_o     (mover_bank_wait_cycles_v),
        .emit_wait_cycle_count_o     (mover_emit_wait_cycles_v),
        .max_outstanding_o           (mover_max_outstanding_v),
        .boundary_split_count_o      (mover_boundary_splits_v),
        .error_o                     (mover_error_v)
      );
      /* verilator lint_on PINCONNECTEMPTY */
    end else begin : gen_no_v_row_mover
      assign v_load_mover_cmd_ready = 1'b0;
      assign v_mover_load_tile_start_valid = 1'b0;
      assign v_mover_load_tile_index = '0;
      assign v_mover_load_row_valid = 1'b0;
      assign v_mover_load_row_data = '0;
      assign v_mover_load_row_index = '0;
      assign v_mover_load_row_last = 1'b0;
      assign v_mover_load_done = 1'b0;
      assign mover_busy_v = 1'b0;
      assign mover_error_v = 1'b0;
      assign mover_ar_count_v = '0;
      assign mover_aw_count_v = '0;
      assign mover_read_beats_v = '0;
      assign mover_write_beats_v = '0;
      assign mover_command_stalls_v = '0;
      assign mover_ar_wait_cycles_v = '0;
      assign mover_r_gap_cycles_v = '0;
      assign mover_r_backpressure_cycles_v = '0;
      assign mover_bank_wait_cycles_v = '0;
      assign mover_emit_wait_cycles_v = '0;
      assign mover_max_outstanding_v = '0;
      assign mover_boundary_splits_v = '0;
      assign m_axi_v_awid_o = '0;
      assign m_axi_v_awaddr_o = '0;
      assign m_axi_v_awlen_o = '0;
      assign m_axi_v_awsize_o = '0;
      assign m_axi_v_awburst_o = '0;
      assign m_axi_v_awlock_o = 1'b0;
      assign m_axi_v_awcache_o = '0;
      assign m_axi_v_awprot_o = '0;
      assign m_axi_v_awqos_o = '0;
      assign m_axi_v_awregion_o = '0;
      assign m_axi_v_awvalid_o = 1'b0;
      assign m_axi_v_wdata_o = '0;
      assign m_axi_v_wstrb_o = '0;
      assign m_axi_v_wlast_o = 1'b0;
      assign m_axi_v_wvalid_o = 1'b0;
      assign m_axi_v_bready_o = 1'b0;
      assign m_axi_v_arid_o = '0;
      assign m_axi_v_araddr_o = '0;
      assign m_axi_v_arlen_o = '0;
      assign m_axi_v_arsize_o = '0;
      assign m_axi_v_arburst_o = '0;
      assign m_axi_v_arlock_o = 1'b0;
      assign m_axi_v_arcache_o = '0;
      assign m_axi_v_arprot_o = '0;
      assign m_axi_v_arqos_o = '0;
      assign m_axi_v_arregion_o = '0;
      assign m_axi_v_arvalid_o = 1'b0;
      assign m_axi_v_rready_o = 1'b0;
    end
  endgenerate

  // Keep the diagnostic error reduction out of the performance datapath.
  // Without this register boundary Vivado can collapse the source modules'
  // sticky flags into the AXI register bank's sticky flag, producing a
  // cross-floorplan, fourteen-level control path.  The grouped registers
  // preserve all error pulses until the next job and add only diagnostic
  // reporting latency.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      error_pipe_a_q <= 1'b0;
      error_pipe_b_q <= 1'b0;
    end else if (clear_error) begin
      error_pipe_a_q <= 1'b0;
      error_pipe_b_q <= 1'b0;
    end else begin
      error_pipe_a_q <= error_pipe_a_q ||
          direct_only_unsupported_error_q || job_error || group_error ||
          store_request_error || address_error;
      error_pipe_b_q <= error_pipe_b_q ||
          load_dispatch_error || store_dispatch_error ||
          resident_frontend_error || pipeline_error || mover_error;
    end
  end

  assign error_o = error_pipe_a_q || error_pipe_b_q;
  assign load_stall_cycle_count_o = 32'(load_dispatch_stalls);
  assign dma_ar_count_o = 32'(mover_ar_count);
  assign dma_read_beat_count_o = 32'(mover_read_beats);
  assign dma_ar_wait_cycle_count_o = 32'(mover_ar_wait_cycles);
  assign dma_r_gap_cycle_count_o = 32'(mover_r_gap_cycles);
  assign dma_r_backpressure_cycle_count_o =
      32'(mover_r_backpressure_cycles);
  assign dma_bank_wait_cycle_count_o = 32'(mover_bank_wait_cycles);
  assign dma_emit_wait_cycle_count_o = 32'(mover_emit_wait_cycles);
  assign dma_max_outstanding_o = mover_max_outstanding;
  assign dma_boundary_split_count_o = 32'(mover_boundary_splits);
  assign kv_resident_hit_count_o = 32'(kv_resident_hits);
  assign kv_resident_miss_count_o = 32'(kv_resident_misses);
  assign prefetch_issue_count_o = 32'(prefetch_issues);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      direct_only_unsupported_error_q <= 1'b0;
      total_cycle_count_o   <= '0;
      overlap_cycle_count_o <= '0;
      qk_cycle_count_o      <= '0;
      softmax_cycle_count_o <= '0;
      pv_cycle_count_o      <= '0;
      qk_pv_overlap_cycle_count_o <= '0;
      dma_lane_overlap_cycle_count_o <= '0;
    end else if (start_i) begin
      direct_only_unsupported_error_q <= direct_only_unsupported_start;
      total_cycle_count_o   <= '0;
      overlap_cycle_count_o <= '0;
      qk_cycle_count_o      <= '0;
      softmax_cycle_count_o <= '0;
      pv_cycle_count_o      <= '0;
      qk_pv_overlap_cycle_count_o <= '0;
      dma_lane_overlap_cycle_count_o <= '0;
    end else if (busy_o) begin
      total_cycle_count_o <= total_cycle_count_o + 32'd1;
      if ((load_dispatch_active &&
           (qk_active || softmax_active || pv_active || update_active)) ||
          (qk_active && (softmax_active || pv_active || update_active)) ||
          (softmax_active && (pv_active || update_active)) ||
          (pv_active && update_active))
        overlap_cycle_count_o <= overlap_cycle_count_o + 32'd1;
      if (qk_active)
        qk_cycle_count_o <= qk_cycle_count_o + 32'd1;
      if (softmax_active)
        softmax_cycle_count_o <= softmax_cycle_count_o + 32'd1;
      if (pv_active)
        pv_cycle_count_o <= pv_cycle_count_o + 32'd1;
      if (qk_active && pv_active)
        qk_pv_overlap_cycle_count_o <=
            qk_pv_overlap_cycle_count_o + 32'd1;
      if (mover_busy_kq && mover_busy_v)
        dma_lane_overlap_cycle_count_o <=
            dma_lane_overlap_cycle_count_o + 32'd1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    active_kv_head, active_context_tile, launched_groups, completed_groups,
    compute_desc_count, load_request_count, completed_q_heads,
    replay_request_count, resident_replay_commands,
    group_active_q_lane, store_request_count, arb_store_selected,
    address_rejected, address_accepted_count, address_rejected_count,
    load_dispatch_commands, load_dispatch_rows, load_dispatch_stalls,
    store_dispatch_commands, store_dispatch_results, store_dispatch_rows,
    store_dispatch_stalls, operand_overlap_cycles, v_overlap_cycles,
    qk_operand_bram_reads, v_operand_bram_reads,
    completed_result_rows, mover_ar_count, mover_aw_count,
    mover_read_beats, mover_write_beats, mover_command_stalls,
    mover_ar_wait_cycles, mover_r_gap_cycles,
    mover_r_backpressure_cycles, mover_bank_wait_cycles,
    mover_emit_wait_cycles, mover_max_outstanding,
    mover_boundary_splits,
    q_fill_bank, k_fill_bank, v_fill_bank, resident_q_tiles,
    kv_resident_hits[63:32], kv_resident_misses[63:32],
    prefetch_issues[63:32],
    resident_k_tiles, resident_v_tiles
  };
endmodule
