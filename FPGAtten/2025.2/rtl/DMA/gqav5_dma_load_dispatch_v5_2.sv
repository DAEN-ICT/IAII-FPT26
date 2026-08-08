module gqav5_dma_load_dispatch_v5_2 (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,

  input  logic command_valid_i,
  output logic command_ready_o,
  input  gqav5_pkg::gqav5_dma_op_e command_op_i,
  input  logic [31:0] command_addr_i,
  input  logic [31:0] command_row_stride_bytes_i,
  input  logic [6:0] command_row_bytes_i,
  input  logic [4:0] command_valid_rows_i,
  input  logic command_zero_pad_i,
  input  gqav5_pkg::gqav5_tile_desc_t command_desc_i,

  output logic mover_cmd_valid_o,
  input  logic mover_cmd_ready_i,
  output logic [31:0] mover_cmd_addr_o,
  output logic [31:0] mover_cmd_row_stride_bytes_o,
  output logic [6:0] mover_cmd_row_bytes_o,
  output logic [4:0] mover_cmd_valid_rows_o,
  output logic mover_cmd_zero_pad_o,
  input  logic mover_tile_start_valid_i,
  output logic mover_tile_start_ready_o,
  input  logic [2:0] mover_tile_index_i,
  input  logic mover_row_valid_i,
  output logic mover_row_ready_o,
  input  logic [255:0] mover_row_bf16_i,
  input  logic [3:0] mover_row_index_i,
  input  logic mover_row_last_i,
  input  logic mover_done_i,
  input  logic mover_error_i,

  output logic q_fill_valid_o,
  input  logic q_fill_ready_i,
  output logic [15:0] q_fill_tag_o,
  output logic q_fill_row_valid_o,
  input  logic q_fill_row_ready_i,
  output logic [3:0] q_fill_row_addr_o,
  output logic [255:0] q_fill_row_data_o,
  output logic q_fill_row_last_o,

  output logic k_fill_valid_o,
  input  logic k_fill_ready_i,
  output logic [15:0] k_fill_tag_o,
  output logic k_fill_row_valid_o,
  input  logic k_fill_row_ready_i,
  output logic [3:0] k_fill_row_addr_o,
  output logic [255:0] k_fill_row_data_o,
  output logic k_fill_row_last_o,

  output logic v_fill_valid_o,
  input  logic v_fill_ready_i,
  output logic [15:0] v_fill_tag_o,
  output logic v_fill_row_valid_o,
  input  logic v_fill_row_ready_i,
  output logic [3:0] v_fill_row_addr_o,
  output logic [255:0] v_fill_row_data_o,
  output logic v_fill_row_last_o,

  output logic active_o,
  output logic [63:0] accepted_command_count_o,
  output logic [63:0] transferred_row_count_o,
  output logic [63:0] command_stall_cycle_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  import gqav5_pkg::*;

  // Match the four V5.4 mover banks so command metadata cannot become the
  // limiter before all four long bursts are issued.
  localparam int unsigned QUEUE_DEPTH = 4;
  gqav5_dma_op_e op_q [QUEUE_DEPTH];
  logic [15:0] tag_q [QUEUE_DEPTH];
  logic [1:0] wr_ptr_q;
  logic [1:0] rd_ptr_q;
  logic [2:0] count_q;
  logic stream_active_q;
  logic local_error_q;
  logic command_is_load;
  logic command_fire;
  logic tile_start_fire;
  logic row_fire;
  logic selected_fill_ready;
  logic selected_row_ready;
  logic [15:0] command_tag;
  gqav5_dma_op_e active_op;
  logic [15:3] active_tag;
  logic queue_push;
  logic queue_pop;

  assign command_is_load = command_op_i != GQAV5_DMA_STORE_O;
  always_comb begin
    unique case (command_op_i)
      GQAV5_DMA_LOAD_Q:
        command_tag = {command_desc_i.q_head[1:0],
                       command_desc_i.txn_id[6:0],
                       command_desc_i.kv_head[1:0],
                       command_desc_i.q_lane,
                       command_desc_i.reduction_tile};
      GQAV5_DMA_LOAD_K:
        command_tag = command_desc_i.prefill_direct
            ? {1'b1, command_desc_i.txn_id[7:0],
               command_desc_i.kv_head[1:0],
               command_desc_i.context_tile[1:0],
               command_desc_i.reduction_tile}
            : {1'b0, command_desc_i.txn_id[7:0],
               command_desc_i.kv_head[1:0],
               command_desc_i.context_tile[1:0],
               command_desc_i.reduction_tile};
      GQAV5_DMA_LOAD_V:
        command_tag = command_desc_i.prefill_direct
            ? {1'b1, command_desc_i.txn_id[7:0],
               command_desc_i.kv_head[1:0],
               command_desc_i.context_tile[1:0],
               command_desc_i.output_tile}
            : {1'b0, command_desc_i.txn_id[7:0],
               command_desc_i.kv_head[1:0],
               command_desc_i.context_tile[1:0],
               command_desc_i.output_tile};
      default: command_tag = '0;
    endcase
  end

  assign command_ready_o = command_is_load &&
                           (count_q < 3'(QUEUE_DEPTH)) &&
                           mover_cmd_ready_i;
  assign mover_cmd_valid_o = command_valid_i && command_is_load &&
                             (count_q < 3'(QUEUE_DEPTH));
  assign command_fire = command_valid_i && command_ready_o;
  assign queue_push = command_fire;
  assign queue_pop = mover_done_i && (count_q != 0) && !stream_active_q;

  assign mover_cmd_addr_o = command_addr_i;
  assign mover_cmd_row_stride_bytes_o = command_row_stride_bytes_i;
  assign mover_cmd_row_bytes_o = command_row_bytes_i;
  assign mover_cmd_valid_rows_o = command_valid_rows_i;
  assign mover_cmd_zero_pad_o = command_zero_pad_i;

  assign active_op = op_q[rd_ptr_q];
  assign active_tag = tag_q[rd_ptr_q][15:3];
  always_comb begin
    selected_fill_ready = 1'b0;
    selected_row_ready = 1'b0;
    if (count_q != 0) begin
      unique case (active_op)
        GQAV5_DMA_LOAD_Q: begin
          selected_fill_ready = q_fill_ready_i;
          selected_row_ready = q_fill_row_ready_i;
        end
        GQAV5_DMA_LOAD_K: begin
          selected_fill_ready = k_fill_ready_i;
          selected_row_ready = k_fill_row_ready_i;
        end
        GQAV5_DMA_LOAD_V: begin
          selected_fill_ready = v_fill_ready_i;
          selected_row_ready = v_fill_row_ready_i;
        end
        default: begin
        end
      endcase
    end
  end

  assign mover_tile_start_ready_o = (count_q != 0) &&
      !stream_active_q && selected_fill_ready;
  assign tile_start_fire = mover_tile_start_valid_i &&
                           mover_tile_start_ready_o;
  assign q_fill_valid_o = (count_q != 0) && !stream_active_q &&
      mover_tile_start_valid_i && (active_op == GQAV5_DMA_LOAD_Q);
  assign k_fill_valid_o = (count_q != 0) && !stream_active_q &&
      mover_tile_start_valid_i && (active_op == GQAV5_DMA_LOAD_K);
  assign v_fill_valid_o = (count_q != 0) && !stream_active_q &&
      mover_tile_start_valid_i && (active_op == GQAV5_DMA_LOAD_V);
  assign q_fill_tag_o = {active_tag, mover_tile_index_i};
  assign k_fill_tag_o = {active_tag, mover_tile_index_i};
  assign v_fill_tag_o = {active_tag, mover_tile_index_i};

  assign mover_row_ready_o = (count_q != 0) && stream_active_q &&
                             selected_row_ready;
  assign row_fire = mover_row_valid_i && mover_row_ready_o;
  assign q_fill_row_valid_o = (count_q != 0) && stream_active_q &&
      mover_row_valid_i && (active_op == GQAV5_DMA_LOAD_Q);
  assign k_fill_row_valid_o = (count_q != 0) && stream_active_q &&
      mover_row_valid_i && (active_op == GQAV5_DMA_LOAD_K);
  assign v_fill_row_valid_o = (count_q != 0) && stream_active_q &&
      mover_row_valid_i && (active_op == GQAV5_DMA_LOAD_V);
  assign q_fill_row_addr_o = mover_row_index_i;
  assign k_fill_row_addr_o = mover_row_index_i;
  assign v_fill_row_addr_o = mover_row_index_i;
  assign q_fill_row_data_o = mover_row_bf16_i;
  assign k_fill_row_data_o = mover_row_bf16_i;
  assign v_fill_row_data_o = mover_row_bf16_i;
  assign q_fill_row_last_o = mover_row_last_i;
  assign k_fill_row_last_o = mover_row_last_i;
  assign v_fill_row_last_o = mover_row_last_i;
  assign active_o = count_q != 0;
  assign protocol_error_o = local_error_q || mover_error_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q                     <= '0;
      rd_ptr_q                     <= '0;
      count_q                      <= '0;
      stream_active_q              <= 1'b0;
      accepted_command_count_o     <= '0;
      transferred_row_count_o      <= '0;
      command_stall_cycle_count_o  <= '0;
      local_error_q                <= 1'b0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (command_valid_i && !command_ready_o)
        command_stall_cycle_count_o <= command_stall_cycle_count_o + 64'd1;

      if (queue_push) begin
        op_q[wr_ptr_q] <= command_op_i;
        tag_q[wr_ptr_q] <= command_tag;
        wr_ptr_q <= wr_ptr_q + 2'd1;
        accepted_command_count_o <= accepted_command_count_o + 64'd1;
      end
      if (queue_pop)
        rd_ptr_q <= rd_ptr_q + 2'd1;
      unique case ({queue_push, queue_pop})
        2'b10: count_q <= count_q + 3'd1;
        2'b01: count_q <= count_q - 3'd1;
        default: begin
        end
      endcase

      if (tile_start_fire)
        stream_active_q <= 1'b1;
      if (row_fire) begin
        transferred_row_count_o <= transferred_row_count_o + 64'd1;
        if (mover_row_last_i != (mover_row_index_i == 4'd15))
          local_error_q <= 1'b1;
        if (mover_row_last_i)
          stream_active_q <= 1'b0;
      end

      if ((mover_tile_start_valid_i && count_q == 0) ||
          (mover_row_valid_i && (count_q == 0 || !stream_active_q)) ||
          (mover_done_i && (count_q == 0 || stream_active_q))) begin
        local_error_q <= 1'b1;
`ifndef SYNTHESIS
        $display("LOAD_DISPATCH_V52_ERROR count=%0d stream=%0b tile=%0b row=%0b done=%0b",
                 count_q, stream_active_q, mover_tile_start_valid_i,
                 mover_row_valid_i, mover_done_i);
`endif
      end
    end
  end

  logic unused_metadata;
  assign unused_metadata = ^{
    command_desc_i.kv_head, command_desc_i.q_lane,
    command_desc_i.q_head,
    command_desc_i.kv_partition, command_desc_i.kv_wave_packed,
    command_desc_i.prefill_direct,
    command_desc_i.query_tile, command_desc_i.context_tile,
    command_desc_i.query_valid_rows, command_desc_i.context_valid_cols,
    command_desc_i.next_context_valid_cols,
    command_desc_i.causal, command_desc_i.first_context,
    command_desc_i.last_context, command_desc_i.last_output_tile,
    command_desc_i.decode_packed
  };
endmodule
