module gqav5_axi_lite_regs #(
  parameter int unsigned AXIL_ADDR_W = 12,
  parameter int unsigned TOKEN_W     = 13
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic accelerator_busy_i,
  input  logic accelerator_done_i,
  input  logic accelerator_error_i,
  input  logic [31:0] total_cycle_count_i,
  input  logic [31:0] overlap_cycle_count_i,
  input  logic [31:0] load_stall_cycle_count_i,
  input  logic [31:0] core_cycle_total_i,
  input  logic [31:0] core_cycle_qk_i,
  input  logic [31:0] core_cycle_softmax_i,
  input  logic [31:0] core_cycle_pv_i,
  input  logic [31:0] qk_pv_overlap_cycle_count_i,
  input  logic [31:0] dma_lane_overlap_cycle_count_i,
  input  logic [31:0] core_cycle_dma_stall_i,
  input  logic [31:0] pv_blocks_total_i,
  input  logic [31:0] pv_blocks_skipped_i,
  input  logic [31:0] dma_ar_count_i,
  input  logic [31:0] dma_read_beat_count_i,
  input  logic [31:0] dma_ar_wait_cycle_count_i,
  input  logic [31:0] dma_r_gap_cycle_count_i,
  input  logic [31:0] dma_r_backpressure_cycle_count_i,
  input  logic [31:0] dma_bank_wait_cycle_count_i,
  input  logic [31:0] dma_emit_wait_cycle_count_i,
  input  logic [31:0] dma_max_outstanding_i,
  input  logic [31:0] dma_boundary_split_count_i,
  input  logic [31:0] kv_resident_hit_count_i,
  input  logic [31:0] kv_resident_miss_count_i,
  input  logic [31:0] prefetch_issue_count_i,

  output logic start_pulse_o,
  output logic soft_reset_pulse_o,
  output logic interrupt_o,
  output logic [TOKEN_W:0] context_token_count_o,
  output logic [TOKEN_W-1:0] query_token_base_o,
  output logic [4:0] query_valid_tokens_o,
  output logic causal_o,
  output logic bf16_output_o,
  output logic pv_skip_enable_o,
  output logic prefill_direct_o,
  output logic [TOKEN_W:0] prefill_query_tokens_o,
  output logic [31:0] pv_skip_lambda_o,
  output logic [31:0] q_base_addr_o,
  output logic [31:0] k_base_addr_o,
  output logic [31:0] v_base_addr_o,
  output logic [31:0] o_base_addr_o,
  output logic [31:0] q_head_stride_bytes_o,
  output logic [31:0] q_token_stride_bytes_o,
  output logic [31:0] k_head_stride_bytes_o,
  output logic [31:0] k_token_stride_bytes_o,
  output logic [31:0] v_head_stride_bytes_o,
  output logic [31:0] v_token_stride_bytes_o,
  output logic [31:0] o_head_stride_bytes_o,
  output logic [31:0] o_token_stride_bytes_o,

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
  input  logic s_axil_rready_i
);
  timeunit 1ns;
  timeprecision 1ps;

  localparam logic [AXIL_ADDR_W-1:0] ADDR_CONTROL       = 12'h000;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_STATUS        = 12'h004;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CONTEXT       = 12'h008;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_QUERY_CONFIG  = 12'h00c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_Q_BASE        = 12'h010;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_K_BASE        = 12'h014;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_V_BASE        = 12'h018;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_O_BASE        = 12'h01c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_Q_HEAD_STRIDE = 12'h020;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_Q_TOKEN_STRIDE = 12'h024;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_K_HEAD_STRIDE = 12'h028;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_K_TOKEN_STRIDE = 12'h02c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_V_HEAD_STRIDE = 12'h030;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_V_TOKEN_STRIDE = 12'h034;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_O_HEAD_STRIDE = 12'h038;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_O_TOKEN_STRIDE = 12'h03c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_VERSION        = 12'h044;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_TOTAL_CYCLES   = 12'h048;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_OVERLAP_CYCLES = 12'h04c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_LOAD_STALL     = 12'h050;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_OPT_CTRL       = 12'h060;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_PV_LAMBDA      = 12'h064;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CORE_TOTAL     = 12'h068;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CORE_QK        = 12'h06c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CORE_SOFTMAX   = 12'h070;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CORE_PV        = 12'h074;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_CORE_DMA_STALL = 12'h078;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_PV_BLOCK_TOTAL = 12'h07c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_PV_BLOCK_SKIP  = 12'h080;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_BUILD_ID       = 12'h084;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_AR_COUNT   = 12'h088;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_READ_BEATS = 12'h08c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_AR_WAIT    = 12'h090;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_R_GAP      = 12'h094;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_R_BP       = 12'h098;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_BANK_WAIT  = 12'h09c;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_EMIT_WAIT  = 12'h0a0;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_MAX_OUT    = 12'h0a4;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_4K_SPLITS  = 12'h0a8;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_PREFILL_QUERIES = 12'h0ac;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_KV_CACHE_HITS  = 12'h0b0;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_KV_CACHE_MISSES = 12'h0b4;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_PREFETCH_ISSUES = 12'h0b8;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_QK_PV_OVERLAP = 12'h0bc;
  localparam logic [AXIL_ADDR_W-1:0] ADDR_DMA_LANE_OVERLAP = 12'h0c0;

  localparam logic [31:0] VERSION  = 32'h4751_4131;
  localparam logic [31:0] BUILD_ID = 32'h5637_0002;

  logic aw_pending_q;
  logic [AXIL_ADDR_W-1:0] awaddr_q;
  logic w_pending_q;
  logic [31:0] wdata_q;
  logic [3:0] wstrb_q;
  logic done_sticky_q;
  logic error_sticky_q;
  logic aw_fire;
  logic w_fire;
  logic write_commit;
  logic [AXIL_ADDR_W-1:0] write_addr;
  logic [31:0] write_data;
  logic [3:0] write_strb;
  logic soft_reset_request;
  logic accepted_start_request;
  logic [31:0] query_config_current;
  logic [31:0] query_config_merged;
  logic [31:0] opt_ctrl_current;
  logic [31:0] opt_ctrl_merged;
  logic unused_prot;

  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0] byte_enable
  );
    logic [31:0] merged;
    begin
      merged = old_value;
      for (int byte_index = 0; byte_index < 4; byte_index++) begin
        if (byte_enable[byte_index])
          merged[byte_index * 8 +: 8] =
              new_value[byte_index * 8 +: 8];
      end
      return merged;
    end
  endfunction

  assign s_axil_awready_o = !aw_pending_q && !s_axil_bvalid_o;
  assign s_axil_wready_o  = !w_pending_q && !s_axil_bvalid_o;
  assign aw_fire = s_axil_awvalid_i && s_axil_awready_o;
  assign w_fire  = s_axil_wvalid_i && s_axil_wready_o;
  assign write_commit = !s_axil_bvalid_o &&
      (aw_pending_q || aw_fire) && (w_pending_q || w_fire);
  assign write_addr = aw_pending_q ? awaddr_q : s_axil_awaddr_i;
  assign write_data = w_pending_q ? wdata_q : s_axil_wdata_i;
  assign write_strb = w_pending_q ? wstrb_q : s_axil_wstrb_i;
  assign soft_reset_request = write_commit &&
      (write_addr == ADDR_CONTROL) && write_strb[0] && write_data[3];
  assign accepted_start_request = write_commit &&
      (write_addr == ADDR_CONTROL) && write_strb[0] && write_data[0] &&
      !write_data[3] && !accelerator_busy_i;
  assign s_axil_arready_o = !s_axil_rvalid_o;
  assign interrupt_o = done_sticky_q || error_sticky_q;
  assign unused_prot = ^{
    s_axil_awprot_i, s_axil_arprot_i,
    query_config_merged[31:25], query_config_merged[23:21],
    query_config_merged[15:13], opt_ctrl_merged[31:4],
    opt_ctrl_merged[31:5], opt_ctrl_merged[1:0]
  };

  always_comb begin
    query_config_current = '0;
    query_config_current[TOKEN_W-1:0] = query_token_base_o;
    query_config_current[20:16] = query_valid_tokens_o;
    query_config_current[24] = causal_o;
    query_config_merged = apply_wstrb(
        query_config_current, write_data, write_strb);
    // Preserve the V4.1 optimized CSR encoding. QK reuse is fixed on (bit 0)
    // and the retired look-ahead flag remains read-only zero (bit 1).
    opt_ctrl_current = {
      27'd0, prefill_direct_o, pv_skip_enable_o,
      bf16_output_o, 1'b0, 1'b1
    };
    opt_ctrl_merged = apply_wstrb(opt_ctrl_current, write_data, write_strb);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pending_q            <= 1'b0;
      awaddr_q                <= '0;
      w_pending_q             <= 1'b0;
      wdata_q                 <= '0;
      wstrb_q                 <= '0;
      s_axil_bresp_o          <= 2'b00;
      s_axil_bvalid_o         <= 1'b0;
      s_axil_rdata_o          <= '0;
      s_axil_rresp_o          <= 2'b00;
      s_axil_rvalid_o         <= 1'b0;
      start_pulse_o           <= 1'b0;
      soft_reset_pulse_o      <= 1'b0;
      done_sticky_q           <= 1'b0;
      error_sticky_q          <= 1'b0;
      context_token_count_o   <= (TOKEN_W + 1)'(16);
      query_token_base_o      <= '0;
      query_valid_tokens_o    <= 5'd16;
      causal_o                <= 1'b0;
      bf16_output_o           <= 1'b0;
      pv_skip_enable_o        <= 1'b0;
      prefill_direct_o        <= 1'b0;
      prefill_query_tokens_o  <= (TOKEN_W + 1)'(16);
      pv_skip_lambda_o        <= 32'hc0a0_0000;
      q_base_addr_o           <= '0;
      k_base_addr_o           <= '0;
      v_base_addr_o           <= '0;
      o_base_addr_o           <= '0;
      q_head_stride_bytes_o   <= 32'h0020_0000;
      q_token_stride_bytes_o  <= 32'd256;
      k_head_stride_bytes_o   <= 32'h0020_0000;
      k_token_stride_bytes_o  <= 32'd256;
      v_head_stride_bytes_o   <= 32'h0020_0000;
      v_token_stride_bytes_o  <= 32'd256;
      o_head_stride_bytes_o   <= 32'h0040_0000;
      o_token_stride_bytes_o  <= 32'd512;
    end else begin
      start_pulse_o      <= 1'b0;
      soft_reset_pulse_o <= 1'b0;

      if (s_axil_bvalid_o && s_axil_bready_i)
        s_axil_bvalid_o <= 1'b0;
      if (s_axil_rvalid_o && s_axil_rready_i)
        s_axil_rvalid_o <= 1'b0;

      if (aw_fire) begin
        aw_pending_q <= 1'b1;
        awaddr_q     <= s_axil_awaddr_i;
      end
      if (w_fire) begin
        w_pending_q <= 1'b1;
        wdata_q     <= s_axil_wdata_i;
        wstrb_q     <= s_axil_wstrb_i;
      end

      if (write_commit) begin
        aw_pending_q    <= 1'b0;
        w_pending_q     <= 1'b0;
        s_axil_bvalid_o <= 1'b1;
        s_axil_bresp_o  <= 2'b00;
        unique case (write_addr)
          ADDR_CONTROL: begin
            if (write_strb[0]) begin
              if (write_data[3]) begin
                soft_reset_pulse_o <= 1'b1;
                done_sticky_q      <= 1'b0;
                error_sticky_q     <= 1'b0;
              end else begin
                if (write_data[0]) begin
                  if (accelerator_busy_i)
                    s_axil_bresp_o <= 2'b10;
                  else begin
                    start_pulse_o <= 1'b1;
                    done_sticky_q <= 1'b0;
                    error_sticky_q <= 1'b0;
                  end
                end
                if (write_data[1]) done_sticky_q <= 1'b0;
                if (write_data[2]) error_sticky_q <= 1'b0;
              end
            end
          end
          ADDR_CONTEXT: begin
            if (accelerator_busy_i)
              s_axil_bresp_o <= 2'b10;
            else
              context_token_count_o <= (TOKEN_W + 1)'(
                  apply_wstrb(32'(context_token_count_o),
                              write_data, write_strb));
          end
          ADDR_QUERY_CONFIG: begin
            if (accelerator_busy_i)
              s_axil_bresp_o <= 2'b10;
            else begin
              query_token_base_o <= query_config_merged[TOKEN_W-1:0];
              query_valid_tokens_o <= query_config_merged[20:16];
              causal_o <= query_config_merged[24];
            end
          end
          ADDR_Q_BASE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else q_base_addr_o <= apply_wstrb(q_base_addr_o, write_data, write_strb);
          end
          ADDR_K_BASE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else k_base_addr_o <= apply_wstrb(k_base_addr_o, write_data, write_strb);
          end
          ADDR_V_BASE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else v_base_addr_o <= apply_wstrb(v_base_addr_o, write_data, write_strb);
          end
          ADDR_O_BASE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else o_base_addr_o <= apply_wstrb(o_base_addr_o, write_data, write_strb);
          end
          ADDR_Q_HEAD_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else q_head_stride_bytes_o <= apply_wstrb(q_head_stride_bytes_o, write_data, write_strb);
          end
          ADDR_Q_TOKEN_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else q_token_stride_bytes_o <= apply_wstrb(q_token_stride_bytes_o, write_data, write_strb);
          end
          ADDR_K_HEAD_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else k_head_stride_bytes_o <= apply_wstrb(k_head_stride_bytes_o, write_data, write_strb);
          end
          ADDR_K_TOKEN_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else k_token_stride_bytes_o <= apply_wstrb(k_token_stride_bytes_o, write_data, write_strb);
          end
          ADDR_V_HEAD_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else v_head_stride_bytes_o <= apply_wstrb(v_head_stride_bytes_o, write_data, write_strb);
          end
          ADDR_V_TOKEN_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else v_token_stride_bytes_o <= apply_wstrb(v_token_stride_bytes_o, write_data, write_strb);
          end
          ADDR_O_HEAD_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else o_head_stride_bytes_o <= apply_wstrb(o_head_stride_bytes_o, write_data, write_strb);
          end
          ADDR_O_TOKEN_STRIDE: begin
            if (accelerator_busy_i) s_axil_bresp_o <= 2'b10;
            else o_token_stride_bytes_o <= apply_wstrb(o_token_stride_bytes_o, write_data, write_strb);
          end
          ADDR_OPT_CTRL: begin
            if (accelerator_busy_i)
              s_axil_bresp_o <= 2'b10;
            else begin
              bf16_output_o    <= opt_ctrl_merged[2];
              pv_skip_enable_o <= opt_ctrl_merged[3];
              prefill_direct_o <= opt_ctrl_merged[4];
            end
          end
          ADDR_PREFILL_QUERIES: begin
            if (accelerator_busy_i)
              s_axil_bresp_o <= 2'b10;
            else
              prefill_query_tokens_o <= (TOKEN_W + 1)'(
                  apply_wstrb(32'(prefill_query_tokens_o),
                              write_data, write_strb));
          end
          ADDR_PV_LAMBDA: begin
            if (accelerator_busy_i)
              s_axil_bresp_o <= 2'b10;
            else
              pv_skip_lambda_o <= apply_wstrb(
                  pv_skip_lambda_o, write_data, write_strb);
          end
          default: s_axil_bresp_o <= 2'b10;
        endcase
      end

      if (s_axil_arvalid_i && s_axil_arready_o) begin
        s_axil_rvalid_o <= 1'b1;
        s_axil_rresp_o  <= 2'b00;
        unique case (s_axil_araddr_i)
          ADDR_CONTROL: s_axil_rdata_o <= 32'd0;
          ADDR_STATUS: s_axil_rdata_o <= {
            28'd0, interrupt_o, error_sticky_q,
            done_sticky_q, accelerator_busy_i
          };
          ADDR_CONTEXT: s_axil_rdata_o <= 32'(context_token_count_o);
          ADDR_QUERY_CONFIG: s_axil_rdata_o <= query_config_current;
          ADDR_Q_BASE: s_axil_rdata_o <= q_base_addr_o;
          ADDR_K_BASE: s_axil_rdata_o <= k_base_addr_o;
          ADDR_V_BASE: s_axil_rdata_o <= v_base_addr_o;
          ADDR_O_BASE: s_axil_rdata_o <= o_base_addr_o;
          ADDR_Q_HEAD_STRIDE: s_axil_rdata_o <= q_head_stride_bytes_o;
          ADDR_Q_TOKEN_STRIDE: s_axil_rdata_o <= q_token_stride_bytes_o;
          ADDR_K_HEAD_STRIDE: s_axil_rdata_o <= k_head_stride_bytes_o;
          ADDR_K_TOKEN_STRIDE: s_axil_rdata_o <= k_token_stride_bytes_o;
          ADDR_V_HEAD_STRIDE: s_axil_rdata_o <= v_head_stride_bytes_o;
          ADDR_V_TOKEN_STRIDE: s_axil_rdata_o <= v_token_stride_bytes_o;
          ADDR_O_HEAD_STRIDE: s_axil_rdata_o <= o_head_stride_bytes_o;
          ADDR_O_TOKEN_STRIDE: s_axil_rdata_o <= o_token_stride_bytes_o;
          ADDR_VERSION: s_axil_rdata_o <= VERSION;
          ADDR_TOTAL_CYCLES: s_axil_rdata_o <= total_cycle_count_i;
          ADDR_OVERLAP_CYCLES: s_axil_rdata_o <= overlap_cycle_count_i;
          ADDR_LOAD_STALL: s_axil_rdata_o <= load_stall_cycle_count_i;
          ADDR_OPT_CTRL: s_axil_rdata_o <= opt_ctrl_current;
          ADDR_PV_LAMBDA: s_axil_rdata_o <= pv_skip_lambda_o;
          ADDR_CORE_TOTAL: s_axil_rdata_o <= core_cycle_total_i;
          ADDR_CORE_QK: s_axil_rdata_o <= core_cycle_qk_i;
          ADDR_CORE_SOFTMAX: s_axil_rdata_o <= core_cycle_softmax_i;
          ADDR_CORE_PV: s_axil_rdata_o <= core_cycle_pv_i;
          ADDR_CORE_DMA_STALL: s_axil_rdata_o <= core_cycle_dma_stall_i;
          ADDR_PV_BLOCK_TOTAL: s_axil_rdata_o <= pv_blocks_total_i;
          ADDR_PV_BLOCK_SKIP: s_axil_rdata_o <= pv_blocks_skipped_i;
          ADDR_BUILD_ID: s_axil_rdata_o <= BUILD_ID;
          ADDR_DMA_AR_COUNT: s_axil_rdata_o <= dma_ar_count_i;
          ADDR_DMA_READ_BEATS: s_axil_rdata_o <= dma_read_beat_count_i;
          ADDR_DMA_AR_WAIT: s_axil_rdata_o <= dma_ar_wait_cycle_count_i;
          ADDR_DMA_R_GAP: s_axil_rdata_o <= dma_r_gap_cycle_count_i;
          ADDR_DMA_R_BP:
            s_axil_rdata_o <= dma_r_backpressure_cycle_count_i;
          ADDR_DMA_BANK_WAIT:
            s_axil_rdata_o <= dma_bank_wait_cycle_count_i;
          ADDR_DMA_EMIT_WAIT:
            s_axil_rdata_o <= dma_emit_wait_cycle_count_i;
          ADDR_DMA_MAX_OUT: s_axil_rdata_o <= dma_max_outstanding_i;
          ADDR_DMA_4K_SPLITS:
            s_axil_rdata_o <= dma_boundary_split_count_i;
          ADDR_PREFILL_QUERIES:
            s_axil_rdata_o <= 32'(prefill_query_tokens_o);
          ADDR_KV_CACHE_HITS:
            s_axil_rdata_o <= kv_resident_hit_count_i;
          ADDR_KV_CACHE_MISSES:
            s_axil_rdata_o <= kv_resident_miss_count_i;
          ADDR_PREFETCH_ISSUES:
            s_axil_rdata_o <= prefetch_issue_count_i;
          ADDR_QK_PV_OVERLAP:
            s_axil_rdata_o <= qk_pv_overlap_cycle_count_i;
          ADDR_DMA_LANE_OVERLAP:
            s_axil_rdata_o <= dma_lane_overlap_cycle_count_i;
          default: begin
            s_axil_rdata_o <= 32'd0;
            s_axil_rresp_o <= 2'b10;
          end
        endcase
      end

      if (!soft_reset_request && !soft_reset_pulse_o &&
          !accepted_start_request) begin
        if (accelerator_done_i) done_sticky_q <= 1'b1;
        if (accelerator_error_i) error_sticky_q <= 1'b1;
      end
    end
  end

  initial begin
    if (AXIL_ADDR_W < 12)
      $error("AXIL_ADDR_W must expose the V4.1-compatible 4 KiB CSR page");
    if (TOKEN_W > 13)
      $error("V4.1 QUERY_CONFIG reserves only 13 query-base bits");
  end
endmodule
