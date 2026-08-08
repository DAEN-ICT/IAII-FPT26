module gqav5_axi_accelerator_top #(
  parameter int unsigned MAX_SEQ_LEN    = 8192,
  parameter int unsigned KV_HEAD_COUNT  = 8,
  parameter int unsigned Q_HEADS_PER_KV = 4,
  parameter int unsigned AXI_ID_W        = 4,
  parameter int unsigned AXIL_ADDR_W     = 12,
  parameter bit ENABLE_ROW_COMPAT        = 1'b0,
  parameter bit ENABLE_DUAL_DMA          = 1'b1,
  parameter logic [31:0] ATTENTION_SCALE_FP32 = 32'h3db5_04f3,
  localparam int unsigned TOKEN_W = $clog2(MAX_SEQ_LEN)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic dma_clk_i,
  input  logic dma_rst_ni,
  output logic interrupt_o,
  output logic busy_o,
  output logic done_o,
  output logic error_o,

  input  logic [AXIL_ADDR_W-1:0] s_axil_awaddr_i,
  input  logic [2:0] s_axil_awprot_i,
  input  logic s_axil_awvalid_i,
  output logic s_axil_awready_o,
  input  logic [31:0] s_axil_wdata_i,
  input  logic [3:0] s_axil_wstrb_i,
  input  logic s_axil_wvalid_i,
  output logic s_axil_wready_o,
  output logic [1:0] s_axil_bresp_o,
  output logic s_axil_bvalid_o,
  input  logic s_axil_bready_i,
  input  logic [AXIL_ADDR_W-1:0] s_axil_araddr_i,
  input  logic [2:0] s_axil_arprot_i,
  input  logic s_axil_arvalid_i,
  output logic s_axil_arready_o,
  output logic [31:0] s_axil_rdata_o,
  output logic [1:0] s_axil_rresp_o,
  output logic s_axil_rvalid_o,
  input  logic s_axil_rready_i,

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

  logic start_pulse;
  logic soft_reset_pulse;
  logic [TOKEN_W:0] context_token_count;
  logic [TOKEN_W-1:0] query_token_base;
  logic [4:0] query_valid_tokens;
  logic causal;
  logic bf16_output;
  logic pv_skip_enable;
  logic prefill_direct;
  logic [TOKEN_W:0] prefill_query_tokens;
  logic [31:0] pv_skip_lambda;
  logic [31:0] q_base_addr;
  logic [31:0] k_base_addr;
  logic [31:0] v_base_addr;
  logic [31:0] o_base_addr;
  logic [31:0] q_head_stride_bytes;
  logic [31:0] q_token_stride_bytes;
  logic [31:0] k_head_stride_bytes;
  logic [31:0] k_token_stride_bytes;
  logic [31:0] v_head_stride_bytes;
  logic [31:0] v_token_stride_bytes;
  logic [31:0] o_head_stride_bytes;
  logic [31:0] o_token_stride_bytes;
  logic core_rst_ni;
  logic dma_core_rst_ni;
  logic [3:0] soft_reset_hold_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic core_reset_dma_sync1_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic core_reset_dma_sync2_q;
  logic core_start;
  logic core_busy;
  logic core_done;
  logic core_error;
  logic accelerator_error;
  logic [31:0] total_cycles;
  logic [31:0] overlap_cycles;
  logic [31:0] load_stall_cycles;
  logic [31:0] dma_ar_count;
  logic [31:0] dma_read_beats;
  logic [31:0] dma_ar_wait_cycles;
  logic [31:0] dma_r_gap_cycles;
  logic [31:0] dma_r_backpressure_cycles;
  logic [31:0] dma_bank_wait_cycles;
  logic [31:0] dma_emit_wait_cycles;
  logic [7:0] dma_max_outstanding;
  logic [31:0] dma_boundary_splits;
  logic [31:0] qk_cycles;
  logic [31:0] softmax_cycles;
  logic [31:0] pv_cycles;
  logic [31:0] qk_pv_overlap_cycles;
  logic [31:0] dma_lane_overlap_cycles;
  logic [63:0] qk_macs;
  logic [63:0] pv_macs;
  logic [63:0] pv_blocks_total;
  logic [63:0] pv_blocks_skipped;
  logic [31:0] kv_resident_hits;
  logic [31:0] kv_resident_misses;
  logic [31:0] prefetch_issues;

  // Stretch the software reset so both halves of every asynchronous FIFO
  // observe reset together.  A one-core-cycle pulse can otherwise be seen
  // by the DMA side only after the core side has already resumed, allowing a
  // stale pre-reset row/event to reappear after pointer reinitialization.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      soft_reset_hold_q <= '0;
    else if (soft_reset_pulse)
      soft_reset_hold_q <= '1;
    else
      soft_reset_hold_q <= {1'b0, soft_reset_hold_q[3:1]};
  end
  assign core_rst_ni =
      rst_ni && !soft_reset_pulse && (soft_reset_hold_q == 0);
  always_ff @(posedge dma_clk_i or negedge dma_rst_ni) begin
    if (!dma_rst_ni) begin
      core_reset_dma_sync1_q <= 1'b0;
      core_reset_dma_sync2_q <= 1'b0;
    end else begin
      core_reset_dma_sync1_q <= core_rst_ni;
      core_reset_dma_sync2_q <= core_reset_dma_sync1_q;
    end
  end
  assign dma_core_rst_ni = core_reset_dma_sync2_q;
  assign core_start = start_pulse;
  assign accelerator_error = core_error;
  assign busy_o = core_busy;
  assign done_o = core_done;
  assign error_o = accelerator_error;

  gqav5_axi_lite_regs #(
    .AXIL_ADDR_W(AXIL_ADDR_W),
    .TOKEN_W    (TOKEN_W)
  ) i_regs (
    .clk_i,
    .rst_ni,
    .accelerator_busy_i        (core_busy),
    .accelerator_done_i        (core_done),
    .accelerator_error_i       (accelerator_error),
    .total_cycle_count_i       (total_cycles),
    .overlap_cycle_count_i     (overlap_cycles),
    .load_stall_cycle_count_i  (load_stall_cycles),
    .core_cycle_total_i        (total_cycles),
    .core_cycle_qk_i           (qk_cycles),
    .core_cycle_softmax_i      (softmax_cycles),
    .core_cycle_pv_i           (pv_cycles),
    .qk_pv_overlap_cycle_count_i(qk_pv_overlap_cycles),
    .dma_lane_overlap_cycle_count_i(dma_lane_overlap_cycles),
    .core_cycle_dma_stall_i    (load_stall_cycles),
    .pv_blocks_total_i         (32'(pv_blocks_total)),
    .pv_blocks_skipped_i       (32'(pv_blocks_skipped)),
    .dma_ar_count_i            (dma_ar_count),
    .dma_read_beat_count_i     (dma_read_beats),
    .dma_ar_wait_cycle_count_i (dma_ar_wait_cycles),
    .dma_r_gap_cycle_count_i   (dma_r_gap_cycles),
    .dma_r_backpressure_cycle_count_i(dma_r_backpressure_cycles),
    .dma_bank_wait_cycle_count_i(dma_bank_wait_cycles),
    .dma_emit_wait_cycle_count_i(dma_emit_wait_cycles),
    .dma_max_outstanding_i     ({24'd0, dma_max_outstanding}),
    .dma_boundary_split_count_i(dma_boundary_splits),
    .kv_resident_hit_count_i  (kv_resident_hits),
    .kv_resident_miss_count_i (kv_resident_misses),
    .prefetch_issue_count_i    (prefetch_issues),
    .start_pulse_o             (start_pulse),
    .soft_reset_pulse_o        (soft_reset_pulse),
    .interrupt_o,
    .context_token_count_o     (context_token_count),
    .query_token_base_o        (query_token_base),
    .query_valid_tokens_o      (query_valid_tokens),
    .causal_o                  (causal),
    .bf16_output_o             (bf16_output),
    .pv_skip_enable_o          (pv_skip_enable),
    .prefill_direct_o          (prefill_direct),
    .prefill_query_tokens_o    (prefill_query_tokens),
    .pv_skip_lambda_o          (pv_skip_lambda),
    .q_base_addr_o             (q_base_addr),
    .k_base_addr_o             (k_base_addr),
    .v_base_addr_o             (v_base_addr),
    .o_base_addr_o             (o_base_addr),
    .q_head_stride_bytes_o     (q_head_stride_bytes),
    .q_token_stride_bytes_o    (q_token_stride_bytes),
    .k_head_stride_bytes_o     (k_head_stride_bytes),
    .k_token_stride_bytes_o    (k_token_stride_bytes),
    .v_head_stride_bytes_o     (v_head_stride_bytes),
    .v_token_stride_bytes_o    (v_token_stride_bytes),
    .o_head_stride_bytes_o     (o_head_stride_bytes),
    .o_token_stride_bytes_o    (o_token_stride_bytes),
    .s_axil_awaddr_i,
    .s_axil_awprot_i,
    .s_axil_awvalid_i,
    .s_axil_awready_o,
    .s_axil_wdata_i,
    .s_axil_wstrb_i,
    .s_axil_wvalid_i,
    .s_axil_wready_o,
    .s_axil_bresp_o,
    .s_axil_bvalid_o,
    .s_axil_bready_i,
    .s_axil_araddr_i,
    .s_axil_arprot_i,
    .s_axil_arvalid_i,
    .s_axil_arready_o,
    .s_axil_rdata_o,
    .s_axil_rresp_o,
    .s_axil_rvalid_o,
    .s_axil_rready_i
  );

  gqav5_attention_axi_core #(
    .MAX_SEQ_LEN    (MAX_SEQ_LEN),
    .KV_HEAD_COUNT  (KV_HEAD_COUNT),
    .Q_HEADS_PER_KV (Q_HEADS_PER_KV),
    .AXI_ID_W        (AXI_ID_W),
    .ENABLE_ROW_COMPAT(ENABLE_ROW_COMPAT),
    .ENABLE_DUAL_DMA (ENABLE_DUAL_DMA)
  ) i_core (
    .clk_i,
    .rst_ni                       (core_rst_ni),
    .dma_clk_i,
    .dma_rst_ni                   (dma_core_rst_ni),
    .start_i                      (core_start),
    .context_token_count_i        (context_token_count),
    .query_token_base_i           (query_token_base),
    .query_valid_rows_i           (query_valid_tokens),
    .causal_i                     (causal),
    .prefill_direct_i             (prefill_direct),
    .prefill_query_token_count_i  (prefill_query_tokens),
    .attention_scale_fp32_i       (ATTENTION_SCALE_FP32),
    .q_base_addr_i                (q_base_addr),
    .k_base_addr_i                (k_base_addr),
    .v_base_addr_i                (v_base_addr),
    .o_base_addr_i                (o_base_addr),
    .q_head_stride_bytes_i        (q_head_stride_bytes),
    .q_token_stride_bytes_i       (q_token_stride_bytes),
    .k_head_stride_bytes_i        (k_head_stride_bytes),
    .k_token_stride_bytes_i       (k_token_stride_bytes),
    .v_head_stride_bytes_i        (v_head_stride_bytes),
    .v_token_stride_bytes_i       (v_token_stride_bytes),
    .o_head_stride_bytes_i        (o_head_stride_bytes),
    .o_token_stride_bytes_i       (o_token_stride_bytes),
    .bf16_output_i                (bf16_output),
    .pv_skip_enable_i             (pv_skip_enable),
    .pv_skip_lambda_fp32_i        (pv_skip_lambda),
    .busy_o                       (core_busy),
    .done_o                       (core_done),
    .error_o                      (core_error),
    .total_cycle_count_o          (total_cycles),
    .overlap_cycle_count_o        (overlap_cycles),
    .load_stall_cycle_count_o     (load_stall_cycles),
    .dma_ar_count_o               (dma_ar_count),
    .dma_read_beat_count_o        (dma_read_beats),
    .dma_ar_wait_cycle_count_o    (dma_ar_wait_cycles),
    .dma_r_gap_cycle_count_o      (dma_r_gap_cycles),
    .dma_r_backpressure_cycle_count_o(dma_r_backpressure_cycles),
    .dma_bank_wait_cycle_count_o  (dma_bank_wait_cycles),
    .dma_emit_wait_cycle_count_o  (dma_emit_wait_cycles),
    .dma_max_outstanding_o        (dma_max_outstanding),
    .dma_boundary_split_count_o   (dma_boundary_splits),
    .qk_cycle_count_o             (qk_cycles),
    .softmax_cycle_count_o        (softmax_cycles),
    .pv_cycle_count_o             (pv_cycles),
    .qk_pv_overlap_cycle_count_o  (qk_pv_overlap_cycles),
    .dma_lane_overlap_cycle_count_o(dma_lane_overlap_cycles),
    .qk_accepted_macs_o           (qk_macs),
    .pv_accepted_macs_o           (pv_macs),
    .pv_blocks_total_o            (pv_blocks_total),
    .pv_blocks_skipped_o          (pv_blocks_skipped),
    .kv_resident_hit_count_o      (kv_resident_hits),
    .kv_resident_miss_count_o     (kv_resident_misses),
    .prefetch_issue_count_o       (prefetch_issues),
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
    .m_axi_v_awid_o,
    .m_axi_v_awaddr_o,
    .m_axi_v_awlen_o,
    .m_axi_v_awsize_o,
    .m_axi_v_awburst_o,
    .m_axi_v_awlock_o,
    .m_axi_v_awcache_o,
    .m_axi_v_awprot_o,
    .m_axi_v_awqos_o,
    .m_axi_v_awregion_o,
    .m_axi_v_awvalid_o,
    .m_axi_v_awready_i,
    .m_axi_v_wdata_o,
    .m_axi_v_wstrb_o,
    .m_axi_v_wlast_o,
    .m_axi_v_wvalid_o,
    .m_axi_v_wready_i,
    .m_axi_v_bid_i,
    .m_axi_v_bresp_i,
    .m_axi_v_bvalid_i,
    .m_axi_v_bready_o,
    .m_axi_v_arid_o,
    .m_axi_v_araddr_o,
    .m_axi_v_arlen_o,
    .m_axi_v_arsize_o,
    .m_axi_v_arburst_o,
    .m_axi_v_arlock_o,
    .m_axi_v_arcache_o,
    .m_axi_v_arprot_o,
    .m_axi_v_arqos_o,
    .m_axi_v_arregion_o,
    .m_axi_v_arvalid_o,
    .m_axi_v_arready_i,
    .m_axi_v_rid_i,
    .m_axi_v_rdata_i,
    .m_axi_v_rresp_i,
    .m_axi_v_rlast_i,
    .m_axi_v_rvalid_i,
    .m_axi_v_rready_o
  );

  logic unused_options;
  assign unused_options = ^{
    qk_macs, pv_macs, pv_blocks_total[63:32], pv_blocks_skipped[63:32]
  };
endmodule
