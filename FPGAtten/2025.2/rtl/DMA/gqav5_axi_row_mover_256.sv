/* verilator lint_off DECLFILENAME */
module gqav5_axi_row_mover_256_legacy #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned AXI_ID_W = 4,
  parameter logic [AXI_ID_W-1:0] AXI_ID = '0,
  parameter int unsigned MAX_READ_OUTSTANDING = 16,
  parameter bit ENABLE_FULL_ROW_BURST = 1'b1
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic load_cmd_valid_i,
  output logic load_cmd_ready_o,
  input  logic [ADDR_W-1:0] load_cmd_addr_i,
  input  logic [ADDR_W-1:0] load_cmd_row_stride_bytes_i,
  input  logic [6:0] load_cmd_row_bytes_i,
  input  logic [4:0] load_cmd_valid_rows_i,
  input  logic load_cmd_zero_pad_i,
  output logic load_tile_start_valid_o,
  input  logic load_tile_start_ready_i,
  output logic [2:0] load_tile_index_o,
  output logic load_row_valid_o,
  input  logic load_row_ready_i,
  output logic [255:0] load_row_bf16_o,
  output logic [3:0] load_row_index_o,
  output logic load_row_last_o,
  output logic load_done_o,

  input  logic store_cmd_valid_i,
  output logic store_cmd_ready_o,
  input  logic [ADDR_W-1:0] store_cmd_addr_i,
  input  logic [ADDR_W-1:0] store_cmd_row_stride_bytes_i,
  input  logic [6:0] store_cmd_row_bytes_i,
  input  logic [4:0] store_cmd_valid_rows_i,
  input  logic store_row_valid_i,
  output logic store_row_ready_o,
  input  logic [511:0] store_row_fp32_i,
  input  logic [3:0] store_row_index_i,
  input  logic store_row_last_i,
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
  input  logic m_axi_arready_i,
  input  logic [AXI_ID_W-1:0] m_axi_rid_i,
  input  logic [255:0] m_axi_rdata_i,
  input  logic [1:0] m_axi_rresp_i,
  input  logic m_axi_rlast_i,
  input  logic m_axi_rvalid_i,
  output logic m_axi_rready_o,

  output logic busy_o,
  output logic [63:0] ar_transaction_count_o,
  output logic [63:0] aw_transaction_count_o,
  output logic [63:0] read_beat_count_o,
  output logic [63:0] write_beat_count_o,
  output logic [63:0] command_stall_cycle_count_o,
  output logic error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_LOAD_TILE_START,
    ST_LOAD_SINGLE,
    ST_LOAD_BURST_FETCH,
    ST_LOAD_BURST_EMIT,
    ST_STORE_WAIT_ROW,
    ST_STORE_AW,
    ST_STORE_W0,
    ST_STORE_W1,
    ST_STORE_B
  } state_t;

  localparam int unsigned AXI_BEAT_BYTES = 32;
  localparam int unsigned BF16_ROW_BYTES = 32;
  localparam int unsigned FP32_ROW_BYTES = 64;
  localparam int unsigned LOAD_BURST_BEATS = 8;
  localparam int unsigned LOAD_BURST_BYTES =
      AXI_BEAT_BYTES * LOAD_BURST_BEATS;
  localparam int unsigned LOAD_BURST_BUFFER_DEPTH = 16 * LOAD_BURST_BEATS;

  state_t state_q;
  logic [ADDR_W-1:0] row_addr_q;
  logic [ADDR_W-1:0] row_stride_q;
  logic [4:0] valid_rows_q;
  logic [4:0] emitted_rows_q;
  logic [3:0] row_index_q;
  logic [ADDR_W-1:0] load_ar_addr_q;
  logic [4:0] load_ar_issued_q;
  logic [4:0] load_r_completed_q;
  logic [5:0] load_outstanding;
  logic [2:0] load_r_beat_q;
  logic [2:0] load_tile_index_q;

  // Stage-1 compatibility path: sixteen requests may be outstanding, while
  // two payload FF stages break the old combinational RREADY-to-cache path.
  // The production burst build constant-prunes this branch.
  logic [255:0] single_fifo_data0_q;
  // Only referenced inside the statically disabled compatibility generate
  // branch in production; keep strict Verilator lint from treating the
  // intentional constant-pruned storage as a production-path defect.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [255:0] single_fifo_data1_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic single_fifo_valid0_q;
  logic single_fifo_valid1_q;
  logic single_fifo_push;
  logic single_fifo_pop;

  // Stage-2 path: token-major AXI beats are written at {tile,row}.  A single
  // 4-KiB block RAM then emits the original tile-major stream, avoiding a
  // wide transpose crossbar and keeping payload storage out of LUT/FF fabric.
  (* ram_style = "block" *) logic [255:0]
      load_burst_mem_q [LOAD_BURST_BUFFER_DEPTH];
  logic [6:0] load_burst_write_addr;
  logic [6:0] load_burst_read_addr;
  logic [3:0] load_burst_issue_row_q;
  logic load_burst_all_issued_q;
  logic [255:0] load_burst_out_data_q;
  logic [3:0] load_burst_out_row_q;
  logic load_burst_out_padding_q;
  logic load_burst_out_valid_q;
  logic load_burst_read_issue;

  logic [511:0] store_row_data_q;
  logic store_bf16_q;
  logic load_descriptor_ok;
  logic store_descriptor_ok;
  logic load_cmd_fire;
  logic store_cmd_fire;
  logic load_tile_start_fire;
  logic load_row_fire;
  logic store_row_fire;
  logic ar_fire;
  logic r_fire;
  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic load_last_row;
  logic store_last_row;

  assign load_descriptor_ok =
      (load_cmd_valid_rows_i != 0) &&
      (load_cmd_valid_rows_i <= 5'd16) &&
      (load_cmd_row_bytes_i == 7'(BF16_ROW_BYTES)) &&
      (ENABLE_FULL_ROW_BURST
          ? ((load_cmd_addr_i[7:0] == 0) &&
             (load_cmd_row_stride_bytes_i[7:0] == 0) &&
             ({1'b0, load_cmd_addr_i[11:0]} +
              13'(LOAD_BURST_BYTES) <= 13'd4096))
          : ((load_cmd_addr_i[4:0] == 0) &&
             (load_cmd_row_stride_bytes_i[4:0] == 0) &&
             ({1'b0, load_cmd_addr_i[11:0]} + 13'd32 <= 13'd4096))) &&
      ((load_cmd_valid_rows_i == 5'd16) || load_cmd_zero_pad_i);
  assign store_descriptor_ok =
      (store_cmd_valid_rows_i != 0) &&
      (store_cmd_valid_rows_i <= 5'd16) &&
      ((store_cmd_row_bytes_i == 7'(BF16_ROW_BYTES)) ||
       (store_cmd_row_bytes_i == 7'(FP32_ROW_BYTES))) &&
      ((store_cmd_row_bytes_i == 7'(BF16_ROW_BYTES))
         ? ((store_cmd_addr_i[4:0] == 0) &&
            (store_cmd_row_stride_bytes_i[4:0] == 0))
         : ((store_cmd_addr_i[5:0] == 0) &&
            (store_cmd_row_stride_bytes_i[5:0] == 0))) &&
      ({1'b0, store_cmd_addr_i[11:0]} +
       13'(store_cmd_row_bytes_i) <= 13'd4096);

  assign load_cmd_ready_o = state_q == ST_IDLE;
  assign store_cmd_ready_o = (state_q == ST_IDLE) && !load_cmd_valid_i;
  assign load_cmd_fire = load_cmd_valid_i && load_cmd_ready_o;
  assign store_cmd_fire = store_cmd_valid_i && store_cmd_ready_o;

  assign load_tile_start_valid_o = state_q == ST_LOAD_TILE_START;
  assign load_tile_index_o = load_tile_index_q;
  assign load_tile_start_fire = load_tile_start_valid_o &&
                                load_tile_start_ready_i;
  assign load_row_valid_o = (state_q == ST_LOAD_SINGLE)
      ? (single_fifo_valid0_q ||
         (({1'b0, row_index_q} >= valid_rows_q) &&
          ({1'b0, row_index_q} < emitted_rows_q)))
      : ((state_q == ST_LOAD_BURST_EMIT) && load_burst_out_valid_q);
  assign load_row_bf16_o = (state_q == ST_LOAD_SINGLE)
      ? (single_fifo_valid0_q ? single_fifo_data0_q : '0)
      : (load_burst_out_padding_q ? '0 : load_burst_out_data_q);
  assign load_row_index_o = (state_q == ST_LOAD_SINGLE)
      ? row_index_q : load_burst_out_row_q;
  assign load_last_row = load_row_index_o == 4'd15;
  assign load_row_last_o = load_last_row;
  assign load_row_fire = load_row_valid_o && load_row_ready_i;
  assign single_fifo_pop = (state_q == ST_LOAD_SINGLE) && load_row_fire &&
                           ({1'b0, row_index_q} < valid_rows_q);

  assign store_row_ready_o = state_q == ST_STORE_WAIT_ROW;
  assign store_row_fire = store_row_valid_i && store_row_ready_o;
  assign store_last_row = ({1'b0, row_index_q} + 5'd1) >= valid_rows_q;

  assign m_axi_arid_o = AXI_ID;
  assign load_outstanding = {1'b0, load_ar_issued_q} -
                            {1'b0, load_r_completed_q};
  assign m_axi_araddr_o = load_ar_addr_q;
  assign m_axi_arlen_o = ENABLE_FULL_ROW_BURST
      ? 8'(LOAD_BURST_BEATS - 1) : 8'd0;
  assign m_axi_arsize_o = 3'd5;
  assign m_axi_arburst_o = 2'b01;
  assign m_axi_arlock_o = 1'b0;
  assign m_axi_arcache_o = 4'b0011;
  assign m_axi_arprot_o = 3'b000;
  assign m_axi_arqos_o = 4'b0000;
  assign m_axi_arregion_o = 4'b0000;
  assign m_axi_arvalid_o = ((state_q == ST_LOAD_SINGLE) ||
                            (state_q == ST_LOAD_BURST_FETCH)) &&
      (load_ar_issued_q < valid_rows_q) &&
      (load_outstanding < 6'(MAX_READ_OUTSTANDING));
  assign m_axi_rready_o = ((state_q == ST_LOAD_SINGLE) &&
      (load_r_completed_q < valid_rows_q) &&
      (!single_fifo_valid1_q || single_fifo_pop)) ||
      (state_q == ST_LOAD_BURST_FETCH);
  assign ar_fire = m_axi_arvalid_o && m_axi_arready_i;
  assign r_fire = m_axi_rvalid_i && m_axi_rready_o;
  assign single_fifo_push = r_fire && (state_q == ST_LOAD_SINGLE);

  assign load_burst_write_addr = {load_r_beat_q,
                                  load_r_completed_q[3:0]};
  assign load_burst_read_addr = {load_tile_index_q,
                                 load_burst_issue_row_q};
  assign load_burst_read_issue = (state_q == ST_LOAD_BURST_EMIT) &&
      !load_burst_all_issued_q &&
      (!load_burst_out_valid_q || load_row_ready_i);

  assign m_axi_awid_o = AXI_ID;
  assign m_axi_awaddr_o = row_addr_q;
  assign m_axi_awlen_o = store_bf16_q ? 8'd0 : 8'd1;
  assign m_axi_awsize_o = 3'd5;
  assign m_axi_awburst_o = 2'b01;
  assign m_axi_awlock_o = 1'b0;
  assign m_axi_awcache_o = 4'b0011;
  assign m_axi_awprot_o = 3'b000;
  assign m_axi_awqos_o = 4'b0000;
  assign m_axi_awregion_o = 4'b0000;
  assign m_axi_awvalid_o = state_q == ST_STORE_AW;
  assign m_axi_wdata_o = (state_q == ST_STORE_W1)
      ? store_row_data_q[511:256] : store_row_data_q[255:0];
  assign m_axi_wstrb_o = 32'hffff_ffff;
  assign m_axi_wlast_o = store_bf16_q
      ? (state_q == ST_STORE_W0) : (state_q == ST_STORE_W1);
  assign m_axi_wvalid_o = (state_q == ST_STORE_W0) ||
                          (state_q == ST_STORE_W1);
  assign m_axi_bready_o = state_q == ST_STORE_B;
  assign aw_fire = m_axi_awvalid_o && m_axi_awready_i;
  assign w_fire = m_axi_wvalid_o && m_axi_wready_i;
  assign b_fire = m_axi_bvalid_i && m_axi_bready_o;
  assign busy_o = state_q != ST_IDLE;

  // Payload memories and registers are reset-free.  Valid/owner control is
  // the sole visibility qualifier, preserving BRAM inference and avoiding a
  // global asynchronous reset across wide datapaths.
  always_ff @(posedge clk_i) begin
    if (r_fire && state_q == ST_LOAD_BURST_FETCH)
      load_burst_mem_q[load_burst_write_addr] <= m_axi_rdata_i;
    if (load_burst_read_issue)
      load_burst_out_data_q <= load_burst_mem_q[load_burst_read_addr];

    if (store_row_fire)
      store_row_data_q <= store_row_fp32_i;
  end

  // Keep the compatibility payload registers in a generate branch.  Merely
  // selecting the burst state with a constant is not sufficient for every
  // synthesis tool to prove ST_LOAD_SINGLE unreachable after state upset.
  // This explicit structural choice guarantees that the production burst
  // build does not retain the extra 512 payload flip-flops.
  generate
    if (!ENABLE_FULL_ROW_BURST) begin : gen_single_payload_fifo
      always_ff @(posedge clk_i) begin
        unique case ({single_fifo_push, single_fifo_pop})
          2'b10: begin
            if (!single_fifo_valid0_q)
              single_fifo_data0_q <= m_axi_rdata_i;
            else
              single_fifo_data1_q <= m_axi_rdata_i;
          end
          2'b01: begin
            if (single_fifo_valid1_q)
              single_fifo_data0_q <= single_fifo_data1_q;
          end
          2'b11: begin
            if (single_fifo_valid1_q) begin
              single_fifo_data0_q <= single_fifo_data1_q;
              single_fifo_data1_q <= m_axi_rdata_i;
            end else begin
              single_fifo_data0_q <= m_axi_rdata_i;
            end
          end
          default: begin
          end
        endcase
      end
    end else begin : gen_no_single_payload_fifo
      always_comb begin
        single_fifo_data0_q = '0;
        single_fifo_data1_q = '0;
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                       <= ST_IDLE;
      row_addr_q                    <= '0;
      row_stride_q                  <= '0;
      valid_rows_q                  <= '0;
      emitted_rows_q                <= '0;
      row_index_q                   <= '0;
      load_ar_addr_q                <= '0;
      load_ar_issued_q              <= '0;
      load_r_completed_q            <= '0;
      load_r_beat_q                 <= '0;
      load_tile_index_q             <= '0;
      single_fifo_valid0_q          <= 1'b0;
      single_fifo_valid1_q          <= 1'b0;
      load_burst_issue_row_q        <= '0;
      load_burst_all_issued_q       <= 1'b0;
      load_burst_out_row_q          <= '0;
      load_burst_out_padding_q      <= 1'b0;
      load_burst_out_valid_q        <= 1'b0;
      store_bf16_q                  <= 1'b0;
      load_done_o                   <= 1'b0;
      store_done_o                  <= 1'b0;
      ar_transaction_count_o        <= '0;
      aw_transaction_count_o        <= '0;
      read_beat_count_o             <= '0;
      write_beat_count_o            <= '0;
      command_stall_cycle_count_o   <= '0;
      error_o                       <= 1'b0;
    end else begin
      load_done_o  <= 1'b0;
      store_done_o <= 1'b0;

      if ((load_cmd_valid_i && !load_cmd_ready_o) ||
          (store_cmd_valid_i && !store_cmd_ready_o))
        command_stall_cycle_count_o <= command_stall_cycle_count_o + 64'd1;
      if (ar_fire)
        ar_transaction_count_o <= ar_transaction_count_o + 64'd1;
      if (aw_fire)
        aw_transaction_count_o <= aw_transaction_count_o + 64'd1;
      if (r_fire)
        read_beat_count_o <= read_beat_count_o + 64'd1;
      if (w_fire)
        write_beat_count_o <= write_beat_count_o + 64'd1;

      unique case (state_q)
        ST_IDLE: begin
          row_index_q <= '0;
          single_fifo_valid0_q <= 1'b0;
          single_fifo_valid1_q <= 1'b0;
          load_burst_out_valid_q <= 1'b0;
          if (load_cmd_fire) begin
            row_addr_q        <= load_cmd_addr_i;
            row_stride_q      <= load_cmd_row_stride_bytes_i;
            valid_rows_q      <= load_cmd_valid_rows_i;
            emitted_rows_q    <= load_cmd_zero_pad_i
                ? 5'd16 : load_cmd_valid_rows_i;
            load_ar_addr_q    <= load_cmd_addr_i;
            load_ar_issued_q  <= '0;
            load_r_completed_q <= '0;
            load_r_beat_q     <= '0;
            load_tile_index_q <= '0;
            if (!load_descriptor_ok) begin
              error_o     <= 1'b1;
              load_done_o <= 1'b1;
            end else begin
              state_q <= ENABLE_FULL_ROW_BURST
                  ? ST_LOAD_BURST_FETCH : ST_LOAD_TILE_START;
            end
          end else if (store_cmd_fire) begin
            row_addr_q     <= store_cmd_addr_i;
            row_stride_q   <= store_cmd_row_stride_bytes_i;
            valid_rows_q   <= store_cmd_valid_rows_i;
            emitted_rows_q <= store_cmd_valid_rows_i;
            store_bf16_q   <= store_cmd_row_bytes_i ==
                              7'(BF16_ROW_BYTES);
            if (!store_descriptor_ok) begin
              error_o      <= 1'b1;
              store_done_o <= 1'b1;
            end else begin
              state_q <= ST_STORE_WAIT_ROW;
            end
          end
        end

        ST_LOAD_TILE_START: begin
          if (load_tile_start_fire) begin
            row_index_q <= '0;
            load_burst_issue_row_q <= '0;
            load_burst_all_issued_q <= 1'b0;
            load_burst_out_valid_q <= 1'b0;
            state_q <= ENABLE_FULL_ROW_BURST
                ? ST_LOAD_BURST_EMIT : ST_LOAD_SINGLE;
          end
        end

        ST_LOAD_SINGLE: begin
          if (ar_fire) begin
            load_ar_issued_q <= load_ar_issued_q + 5'd1;
            load_ar_addr_q <= load_ar_addr_q + row_stride_q;
          end
          if (load_row_fire) begin
            if (load_last_row) begin
              load_done_o <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              row_index_q <= row_index_q + 4'd1;
            end
          end
          if (r_fire) begin
            load_r_completed_q <= load_r_completed_q + 5'd1;
            if (m_axi_rresp_i != 2'b00 || !m_axi_rlast_i ||
                m_axi_rid_i != AXI_ID)
              error_o <= 1'b1;
          end

          unique case ({single_fifo_push, single_fifo_pop})
            2'b10: begin
              if (!single_fifo_valid0_q)
                single_fifo_valid0_q <= 1'b1;
              else
                single_fifo_valid1_q <= 1'b1;
            end
            2'b01: begin
              if (single_fifo_valid1_q)
                single_fifo_valid1_q <= 1'b0;
              else
                single_fifo_valid0_q <= 1'b0;
            end
            2'b11: begin
              if (!single_fifo_valid1_q) begin
                single_fifo_valid0_q <= 1'b1;
                single_fifo_valid1_q <= 1'b0;
              end
            end
            default: begin
            end
          endcase
        end

        ST_LOAD_BURST_FETCH: begin
          if (ar_fire) begin
            load_ar_issued_q <= load_ar_issued_q + 5'd1;
            load_ar_addr_q <= load_ar_addr_q + row_stride_q;
          end
          if (r_fire) begin
            if (m_axi_rresp_i != 2'b00 || m_axi_rid_i != AXI_ID ||
                (m_axi_rlast_i !=
                 (load_r_beat_q == 3'(LOAD_BURST_BEATS - 1))))
              error_o <= 1'b1;
            if (load_r_beat_q == 3'(LOAD_BURST_BEATS - 1)) begin
              load_r_beat_q <= '0;
              load_r_completed_q <= load_r_completed_q + 5'd1;
              if ((load_r_completed_q + 5'd1) >= valid_rows_q) begin
                load_tile_index_q <= '0;
                state_q <= ST_LOAD_TILE_START;
              end
            end else begin
              load_r_beat_q <= load_r_beat_q + 3'd1;
            end
          end
        end

        ST_LOAD_BURST_EMIT: begin
          if (load_burst_out_valid_q && load_row_ready_i)
            load_burst_out_valid_q <= 1'b0;
          if (load_burst_read_issue) begin
            load_burst_out_valid_q <= 1'b1;
            load_burst_out_row_q <= load_burst_issue_row_q;
            load_burst_out_padding_q <=
                ({1'b0, load_burst_issue_row_q} >= valid_rows_q);
            if (load_burst_issue_row_q == 4'd15)
              load_burst_all_issued_q <= 1'b1;
            else
              load_burst_issue_row_q <= load_burst_issue_row_q + 4'd1;
          end
          if (load_row_fire && load_last_row) begin
            load_burst_out_valid_q <= 1'b0;
            if (load_tile_index_q == 3'd7) begin
              load_done_o <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              load_tile_index_q <= load_tile_index_q + 3'd1;
              state_q <= ST_LOAD_TILE_START;
            end
          end
        end

        ST_STORE_WAIT_ROW: begin
          if (store_row_fire) begin
            if (store_row_index_i != row_index_q ||
                store_row_last_i != store_last_row) begin
              error_o <= 1'b1;
`ifndef SYNTHESIS
              $display("ROW_MOVER_STORE_ERROR row=%0d/%0d last=%0b/%0b",
                       store_row_index_i, row_index_q,
                       store_row_last_i, store_last_row);
`endif
            end
            state_q <= ST_STORE_AW;
          end
        end

        ST_STORE_AW: begin
          if (aw_fire)
            state_q <= ST_STORE_W0;
        end

        ST_STORE_W0: begin
          if (w_fire)
            state_q <= store_bf16_q ? ST_STORE_B : ST_STORE_W1;
        end

        ST_STORE_W1: begin
          if (w_fire)
            state_q <= ST_STORE_B;
        end

        ST_STORE_B: begin
          if (b_fire) begin
            if (m_axi_bresp_i != 2'b00 || m_axi_bid_i != AXI_ID)
              error_o <= 1'b1;
            if (store_last_row) begin
              store_done_o <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              row_index_q <= row_index_q + 4'd1;
              row_addr_q  <= row_addr_q + row_stride_q;
              state_q <= ST_STORE_WAIT_ROW;
            end
          end
        end

        default: begin
          error_o <= 1'b1;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  initial begin
    if (ADDR_W < 8)
      $error("ADDR_W must preserve 256-byte burst alignment bits");
    if ((MAX_READ_OUTSTANDING < 1) || (MAX_READ_OUTSTANDING > 16))
      $error("MAX_READ_OUTSTANDING must be in the range 1..16");
    if (LOAD_BURST_BEATS != 8 || LOAD_BURST_BUFFER_DEPTH != 128)
      $error("full-row burst path targets 128 BF16 dimensions");
    if (AXI_BEAT_BYTES != BF16_ROW_BYTES ||
        (2 * AXI_BEAT_BYTES) != FP32_ROW_BYTES)
      $error("row widths do not match the 256-bit AXI contract");
  end
endmodule
