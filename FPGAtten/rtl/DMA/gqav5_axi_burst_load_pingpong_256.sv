module gqav5_axi_burst_load_pingpong_256 #(
  parameter int unsigned ADDR_W = 32,
  parameter int unsigned AXI_ID_W = 4,
  parameter logic [AXI_ID_W-1:0] AXI_ID = '0,
  parameter int unsigned BANK_COUNT = 4,
  parameter int unsigned MAX_READ_OUTSTANDING = 4,
  localparam int unsigned BANK_W = $clog2(BANK_COUNT),
  localparam int unsigned OUTSTANDING_W =
      $clog2(MAX_READ_OUTSTANDING + 1)
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
  output logic [63:0] read_beat_count_o,
  output logic [63:0] command_stall_cycle_count_o,
  output logic [31:0] ar_wait_cycle_count_o,
  output logic [31:0] r_gap_cycle_count_o,
  output logic [31:0] r_backpressure_cycle_count_o,
  output logic [31:0] bank_wait_cycle_count_o,
  output logic [31:0] emit_wait_cycle_count_o,
  output logic [7:0] max_outstanding_o,
  output logic [31:0] boundary_split_count_o,
  output logic error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned AXI_BEAT_BYTES = 32;
  localparam int unsigned BF16_ROW_BYTES = 32;
  localparam int unsigned ROW_BYTES = 256;
  localparam int unsigned ROW_BEATS = ROW_BYTES / AXI_BEAT_BYTES;
  localparam int unsigned BANK_BEATS = 16 * ROW_BEATS;
  localparam int unsigned PAYLOAD_BEATS = BANK_COUNT * BANK_BEATS;
  localparam int unsigned PAYLOAD_ADDR_W = $clog2(PAYLOAD_BEATS);
  localparam int unsigned RESPONSE_PTR_W =
      $clog2(MAX_READ_OUTSTANDING);

  // One flattened true dual-port memory keeps independent 4-KiB logical banks
  // in BRAM address bits.  The production CDC wrapper selects eight banks
  // without building a wide payload bank mux in LUTs.
  (* ram_style = "block" *)
  logic [255:0] payload_mem_q [PAYLOAD_BEATS];
  logic [PAYLOAD_ADDR_W-1:0] payload_write_addr;
  logic [PAYLOAD_ADDR_W-1:0] payload_read_addr;

  logic [BANK_COUNT-1:0] bank_busy_q;
  logic [BANK_COUNT-1:0] bank_issue_done_q;
  logic [BANK_COUNT-1:0] bank_full_q;
  logic [4:0] bank_valid_rows_q [BANK_COUNT];
  logic [7:0] bank_received_beats_q [BANK_COUNT];
  logic [ADDR_W-1:0] bank_addr_q [BANK_COUNT];
  logic [ADDR_W-1:0] bank_stride_q [BANK_COUNT];
  logic [BANK_W-1:0] accept_bank_q;
  logic [BANK_W-1:0] issue_expected_bank_q;
  logic [BANK_W-1:0] emit_expected_bank_q;

  logic issue_active_q;
  logic [BANK_W-1:0] issue_bank_q;
  logic [ADDR_W-1:0] issue_addr_q;
  logic [ADDR_W-1:0] issue_stride_q;
  logic [4:0] issue_valid_rows_q;
  logic [4:0] issue_rows_issued_q;
  logic [4:0] issue_rows;
  logic [4:0] rows_remaining;
  logic [4:0] rows_to_4k;
  logic coalesced_issue;
  logic issue_start;
  logic issue_finishes_bank;

  logic [BANK_W-1:0] response_bank_fifo_q [MAX_READ_OUTSTANDING];
  logic [6:0] response_start_fifo_q [MAX_READ_OUTSTANDING];
  logic [7:0] response_len_fifo_q [MAX_READ_OUTSTANDING];
  logic [RESPONSE_PTR_W-1:0] response_wr_ptr_q;
  logic [RESPONSE_PTR_W-1:0] response_rd_ptr_q;
  logic [OUTSTANDING_W-1:0] outstanding_q;
  logic [7:0] response_beat_q;
  logic [BANK_W-1:0] response_bank;
  logic [6:0] response_linear_beat;
  logic ar_fire;
  logic r_fire;
  logic response_pop;
  logic response_last_expected;
  logic response_finishes_bank;

  logic emit_active_q;
  logic [BANK_W-1:0] emit_bank_q;
  logic emit_tile_start_pending_q;
  logic [2:0] emit_tile_q;
  logic [3:0] emit_issue_row_q;
  logic emit_all_rows_issued_q;
  logic [255:0] emit_out_data_q;
  logic [3:0] emit_out_row_q;
  logic emit_out_padding_q;
  logic emit_out_valid_q;
  logic emit_read_issue;
  logic emit_row_fire;

  logic descriptor_ok;
  logic load_cmd_fire;
  logic [OUTSTANDING_W-1:0] outstanding_next;
  logic stats_reset_q;
  (* dont_touch = "yes" *) logic [8:0] stats_reset_local_q;

  assign descriptor_ok =
      (load_cmd_valid_rows_i != 0) &&
      (load_cmd_valid_rows_i <= 5'd16) &&
      (load_cmd_row_bytes_i == 7'(BF16_ROW_BYTES)) &&
      (load_cmd_addr_i[7:0] == 0) &&
      (load_cmd_row_stride_bytes_i[7:0] == 0) &&
      ((load_cmd_valid_rows_i == 5'd16) || load_cmd_zero_pad_i);

  assign load_cmd_ready_o = !bank_busy_q[accept_bank_q];
  assign load_cmd_fire = load_cmd_valid_i && load_cmd_ready_o;
  // In this engine command backpressure is exactly bank-capacity waiting.
  // Reuse the existing counter instead of building a duplicate incrementer.
  assign bank_wait_cycle_count_o = command_stall_cycle_count_o[31:0];
  assign busy_o = (bank_busy_q != '0) || issue_active_q ||
                  emit_active_q || (outstanding_q != 0);

  assign issue_start = !issue_active_q &&
      bank_busy_q[issue_expected_bank_q] &&
      !bank_issue_done_q[issue_expected_bank_q];

  assign rows_remaining = issue_valid_rows_q - issue_rows_issued_q;
  assign rows_to_4k = 5'((13'd4096 - {1'b0, issue_addr_q[11:0]}) >> 8);
  assign coalesced_issue = issue_stride_q == ADDR_W'(ROW_BYTES);
  always_comb begin
    issue_rows = 5'd1;
    if (coalesced_issue) begin
      if (rows_remaining < rows_to_4k)
        issue_rows = rows_remaining;
      else
        issue_rows = rows_to_4k;
    end
  end
  assign issue_finishes_bank =
      (issue_rows_issued_q + issue_rows) == issue_valid_rows_q;

  assign m_axi_arid_o = AXI_ID;
  assign m_axi_araddr_o = issue_addr_q;
  assign m_axi_arlen_o = coalesced_issue
      ? ((8'(issue_rows) << 3) - 8'd1) : 8'(ROW_BEATS - 1);
  assign m_axi_arsize_o = 3'd5;
  assign m_axi_arburst_o = 2'b01;
  assign m_axi_arlock_o = 1'b0;
  assign m_axi_arcache_o = 4'b0011;
  assign m_axi_arprot_o = 3'b000;
  assign m_axi_arqos_o = 4'b0000;
  assign m_axi_arregion_o = 4'b0000;

  assign response_bank = response_bank_fifo_q[response_rd_ptr_q];
  assign response_last_expected =
      response_beat_q == response_len_fifo_q[response_rd_ptr_q];
  assign m_axi_rready_o = outstanding_q != 0;
  assign r_fire = m_axi_rvalid_i && m_axi_rready_o;
  assign response_pop = r_fire && response_last_expected;
  // Reuse a response FIFO slot on the same cycle that its final beat retires.
  assign m_axi_arvalid_o = issue_active_q &&
      (issue_rows_issued_q < issue_valid_rows_q) &&
      ((outstanding_q < OUTSTANDING_W'(MAX_READ_OUTSTANDING)) ||
       response_pop);
  assign ar_fire = m_axi_arvalid_o && m_axi_arready_i;

  assign response_linear_beat =
      response_start_fifo_q[response_rd_ptr_q] + response_beat_q[6:0];
  assign payload_write_addr = {
    response_bank, response_linear_beat[2:0],
    response_linear_beat[6:3]
  };
  assign response_finishes_bank = r_fire &&
      ((bank_received_beats_q[response_bank] + 8'd1) ==
       (8'(bank_valid_rows_q[response_bank]) << 3));

  assign payload_read_addr = {
    emit_bank_q, emit_tile_q, emit_issue_row_q
  };
  assign emit_read_issue = emit_active_q && !emit_tile_start_pending_q &&
      !emit_all_rows_issued_q && (!emit_out_valid_q || load_row_ready_i);

  assign load_tile_start_valid_o = emit_active_q &&
      emit_tile_start_pending_q;
  assign load_tile_index_o = emit_tile_q;
  assign load_row_valid_o = emit_active_q && emit_out_valid_q;
  assign load_row_bf16_o = emit_out_padding_q ? '0 : emit_out_data_q;
  assign load_row_index_o = emit_out_row_q;
  assign load_row_last_o = emit_out_row_q == 4'd15;
  assign emit_row_fire = load_row_valid_o && load_row_ready_i;

  always_comb begin
    outstanding_next = outstanding_q;
    unique case ({ar_fire, response_pop})
      2'b10: outstanding_next = outstanding_q + 1'b1;
      2'b01: outstanding_next = outstanding_q - 1'b1;
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (r_fire)
      payload_mem_q[payload_write_addr] <= m_axi_rdata_i;
    if (emit_read_issue)
      emit_out_data_q <= payload_mem_q[payload_read_addr];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bank_busy_q                  <= '0;
      bank_issue_done_q            <= '0;
      bank_full_q                  <= '0;
      accept_bank_q                <= '0;
      issue_expected_bank_q        <= '0;
      emit_expected_bank_q         <= '0;
      issue_active_q               <= 1'b0;
      issue_bank_q                 <= '0;
      issue_addr_q                 <= '0;
      issue_stride_q               <= '0;
      issue_valid_rows_q           <= '0;
      issue_rows_issued_q          <= '0;
      response_wr_ptr_q            <= '0;
      response_rd_ptr_q            <= '0;
      outstanding_q                <= '0;
      response_beat_q              <= '0;
      emit_active_q                <= 1'b0;
      emit_bank_q                  <= '0;
      emit_tile_start_pending_q    <= 1'b0;
      emit_tile_q                  <= '0;
      emit_issue_row_q             <= '0;
      emit_all_rows_issued_q       <= 1'b0;
      emit_out_row_q               <= '0;
      emit_out_padding_q           <= 1'b0;
      emit_out_valid_q             <= 1'b0;
      load_done_o                  <= 1'b0;
      error_o                      <= 1'b0;
      for (int unsigned bank = 0; bank < BANK_COUNT; bank++) begin
        bank_valid_rows_q[bank] <= '0;
        bank_received_beats_q[bank] <= '0;
      end
    end else begin
      load_done_o <= 1'b0;
      outstanding_q <= outstanding_next;

      if (load_cmd_fire) begin
        if (!descriptor_ok) begin
          error_o <= 1'b1;
          load_done_o <= 1'b1;
        end else begin
          bank_busy_q[accept_bank_q] <= 1'b1;
          bank_issue_done_q[accept_bank_q] <= 1'b0;
          bank_full_q[accept_bank_q] <= 1'b0;
          bank_valid_rows_q[accept_bank_q] <= load_cmd_valid_rows_i;
          bank_received_beats_q[accept_bank_q] <= '0;
          accept_bank_q <= accept_bank_q + 1'b1;
        end
      end

      if (issue_start) begin
        issue_active_q <= 1'b1;
        issue_bank_q <= issue_expected_bank_q;
        issue_addr_q <= bank_addr_q[issue_expected_bank_q];
        issue_stride_q <= bank_stride_q[issue_expected_bank_q];
        issue_valid_rows_q <= bank_valid_rows_q[issue_expected_bank_q];
        issue_rows_issued_q <= '0;
      end

      if (ar_fire) begin
        response_bank_fifo_q[response_wr_ptr_q] <= issue_bank_q;
        response_start_fifo_q[response_wr_ptr_q] <=
            (7'(issue_rows_issued_q) << 3);
        response_len_fifo_q[response_wr_ptr_q] <= m_axi_arlen_o;
        response_wr_ptr_q <= response_wr_ptr_q + 1'b1;
        issue_rows_issued_q <= issue_rows_issued_q + issue_rows;
        issue_addr_q <= coalesced_issue
            ? issue_addr_q + (ADDR_W'(issue_rows) << 8)
            : issue_addr_q + issue_stride_q;
        if (issue_finishes_bank) begin
          bank_issue_done_q[issue_bank_q] <= 1'b1;
          issue_active_q <= 1'b0;
          issue_expected_bank_q <= issue_expected_bank_q + 1'b1;
        end
      end

      if (r_fire) begin
        if (m_axi_rid_i != AXI_ID || m_axi_rresp_i != 2'b00 ||
            m_axi_rlast_i != response_last_expected)
          error_o <= 1'b1;
        bank_received_beats_q[response_bank] <=
            bank_received_beats_q[response_bank] + 8'd1;
        if (response_last_expected) begin
          response_beat_q <= '0;
          response_rd_ptr_q <= response_rd_ptr_q + 1'b1;
        end else begin
          response_beat_q <= response_beat_q + 8'd1;
        end
        if (response_finishes_bank)
          bank_full_q[response_bank] <= 1'b1;
      end

      if (!emit_active_q && bank_full_q[emit_expected_bank_q]) begin
        emit_active_q <= 1'b1;
        emit_bank_q <= emit_expected_bank_q;
        emit_tile_start_pending_q <= 1'b1;
        emit_tile_q <= '0;
        emit_issue_row_q <= '0;
        emit_all_rows_issued_q <= 1'b0;
        emit_out_valid_q <= 1'b0;
      end

      if (load_tile_start_valid_o && load_tile_start_ready_i) begin
        emit_tile_start_pending_q <= 1'b0;
        emit_issue_row_q <= '0;
        emit_all_rows_issued_q <= 1'b0;
        emit_out_valid_q <= 1'b0;
      end

      if (emit_out_valid_q && load_row_ready_i)
        emit_out_valid_q <= 1'b0;
      if (emit_read_issue) begin
        emit_out_valid_q <= 1'b1;
        emit_out_row_q <= emit_issue_row_q;
        emit_out_padding_q <=
            ({1'b0, emit_issue_row_q} >= bank_valid_rows_q[emit_bank_q]);
        if (emit_issue_row_q == 4'd15)
          emit_all_rows_issued_q <= 1'b1;
        else
          emit_issue_row_q <= emit_issue_row_q + 4'd1;
      end

      if (emit_row_fire && load_row_last_o) begin
        emit_out_valid_q <= 1'b0;
        if (emit_tile_q == 3'd7) begin
          load_done_o <= 1'b1;
          bank_busy_q[emit_bank_q] <= 1'b0;
          bank_issue_done_q[emit_bank_q] <= 1'b0;
          bank_full_q[emit_bank_q] <= 1'b0;
          bank_received_beats_q[emit_bank_q] <= '0;
          emit_active_q <= 1'b0;
          emit_tile_start_pending_q <= 1'b0;
          emit_expected_bank_q <= emit_expected_bank_q + 1'b1;
        end else begin
          emit_tile_q <= emit_tile_q + 3'd1;
          emit_tile_start_pending_q <= 1'b1;
          emit_issue_row_q <= '0;
          emit_all_rows_issued_q <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (load_cmd_fire && descriptor_ok) begin
      bank_addr_q[accept_bank_q] <= load_cmd_addr_i;
      bank_stride_q[accept_bank_q] <= load_cmd_row_stride_bytes_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      stats_reset_q <= 1'b1;
    else
      stats_reset_q <= 1'b0;
  end

  always_ff @(posedge clk_i)
    stats_reset_local_q <= {9{stats_reset_q}};

  // Statistics do not participate in protocol control.  Keep their reset
  // synchronous and locally replicated so the wide counters map to ordinary
  // FDREs without one reset-enable net broadcasting across all counter bits.
  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[0])
      ar_transaction_count_o <= '0;
    else if (ar_fire)
      ar_transaction_count_o <= ar_transaction_count_o + 64'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[1])
      read_beat_count_o <= '0;
    else if (r_fire)
      read_beat_count_o <= read_beat_count_o + 64'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[2])
      command_stall_cycle_count_o <= '0;
    else if (load_cmd_valid_i && !load_cmd_ready_o)
      command_stall_cycle_count_o <= command_stall_cycle_count_o + 64'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[3])
      ar_wait_cycle_count_o <= '0;
    else if (m_axi_arvalid_o && !m_axi_arready_i)
      ar_wait_cycle_count_o <= ar_wait_cycle_count_o + 32'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[4])
      r_gap_cycle_count_o <= '0;
    else if ((outstanding_q != 0) && !m_axi_rvalid_i)
      r_gap_cycle_count_o <= r_gap_cycle_count_o + 32'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[5])
      r_backpressure_cycle_count_o <= '0;
    else if (m_axi_rvalid_i && !m_axi_rready_o)
      r_backpressure_cycle_count_o <=
          r_backpressure_cycle_count_o + 32'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[6])
      emit_wait_cycle_count_o <= '0;
    else if ((load_tile_start_valid_o && !load_tile_start_ready_i) ||
             (load_row_valid_o && !load_row_ready_i))
      emit_wait_cycle_count_o <= emit_wait_cycle_count_o + 32'd1;
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[7])
      max_outstanding_o <= '0;
    else if (8'(outstanding_next) > max_outstanding_o)
      max_outstanding_o <= 8'(outstanding_next);
  end

  always_ff @(posedge clk_i) begin
    if (stats_reset_local_q[8])
      boundary_split_count_o <= '0;
    else if (ar_fire && coalesced_issue && (issue_rows < rows_remaining))
      boundary_split_count_o <= boundary_split_count_o + 32'd1;
  end

  initial begin
    if (ADDR_W < 12)
      $error("ADDR_W must preserve AXI 4-KiB boundary bits");
    if (BANK_COUNT < 4 || BANK_COUNT > 16 ||
        (BANK_COUNT & (BANK_COUNT - 1)) != 0)
      $error("BANK_COUNT must be a power of two in the range 4..16");
    if (MAX_READ_OUTSTANDING < 4 || MAX_READ_OUTSTANDING > 16 ||
        (MAX_READ_OUTSTANDING & (MAX_READ_OUTSTANDING - 1)) != 0)
      $error("MAX_READ_OUTSTANDING must be a power of two in 4..16");
    if (ROW_BEATS != 8 || BANK_BEATS != 128)
      $error("V5.4 burst engine targets 128 BF16 dimensions");
  end
endmodule
