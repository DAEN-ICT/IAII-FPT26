module gqav5_dma_load_dispatch (
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
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_WAIT_TILE,
    ST_STREAM
  } state_t;

  state_t state_q;
  gqav5_dma_op_e active_op_q;
  logic [15:0] active_tag_q;
  logic selected_fill_ready;
  logic selected_row_ready;
  logic command_is_load;
  logic command_fire;
  logic row_fire;
  logic tile_start_fire;
  logic local_error_q;
  logic [15:0] command_tag;

  assign command_is_load = command_op_i != GQAV5_DMA_STORE_O;
  // Low tag bits are the resident-cache linear tile address. Keeping the
  // KV region in the tag avoids a wide descriptor broadcast into the BRAM
  // frontend while still leaving the replay-side compute tag independent.
  always_comb begin
    unique case (command_op_i)
      GQAV5_DMA_LOAD_Q:
        command_tag = {command_desc_i.q_head[1:0],
                       command_desc_i.txn_id[6:0],
                       command_desc_i.kv_head[1:0],
                       command_desc_i.q_lane,
                       command_desc_i.reduction_tile};
      GQAV5_DMA_LOAD_K:
        command_tag = {command_desc_i.prefill_direct,
                       command_desc_i.txn_id[8:0],
                       command_desc_i.kv_head[1:0],
                       command_desc_i.context_tile[0],
                       command_desc_i.reduction_tile};
      GQAV5_DMA_LOAD_V:
        command_tag = {command_desc_i.prefill_direct,
                       command_desc_i.txn_id[8:0],
                       command_desc_i.kv_head[1:0],
                       command_desc_i.context_tile[0],
                       command_desc_i.output_tile};
      default: command_tag = '0;
    endcase
  end

  always_comb begin
    selected_fill_ready = 1'b0;
    unique case (active_op_q)
      GQAV5_DMA_LOAD_Q: selected_fill_ready = q_fill_ready_i;
      GQAV5_DMA_LOAD_K: selected_fill_ready = k_fill_ready_i;
      GQAV5_DMA_LOAD_V: selected_fill_ready = v_fill_ready_i;
      default: selected_fill_ready = 1'b0;
    endcase
  end

  assign command_ready_o = (state_q == ST_IDLE) && command_is_load &&
      mover_cmd_ready_i;
  assign command_fire = command_valid_i && command_ready_o;

  // The mover command and destination-bank ownership are one atomic event.
  // Neither side may handshake alone and leave a bank/AXI command orphaned.
  assign mover_cmd_valid_o = (state_q == ST_IDLE) && command_valid_i &&
      command_is_load;
  assign mover_tile_start_ready_o = (state_q == ST_WAIT_TILE) &&
                                    selected_fill_ready;
  assign tile_start_fire = mover_tile_start_valid_i &&
                           mover_tile_start_ready_o;
  assign q_fill_valid_o = (state_q == ST_WAIT_TILE) &&
      mover_tile_start_valid_i && (active_op_q == GQAV5_DMA_LOAD_Q);
  assign k_fill_valid_o = (state_q == ST_WAIT_TILE) &&
      mover_tile_start_valid_i && (active_op_q == GQAV5_DMA_LOAD_K);
  assign v_fill_valid_o = (state_q == ST_WAIT_TILE) &&
      mover_tile_start_valid_i && (active_op_q == GQAV5_DMA_LOAD_V);
  assign q_fill_tag_o = {active_tag_q[15:3], mover_tile_index_i};
  assign k_fill_tag_o = {active_tag_q[15:3], mover_tile_index_i};
  assign v_fill_tag_o = {active_tag_q[15:3], mover_tile_index_i};

  assign mover_cmd_addr_o = command_addr_i;
  assign mover_cmd_row_stride_bytes_o = command_row_stride_bytes_i;
  assign mover_cmd_row_bytes_o = command_row_bytes_i;
  assign mover_cmd_valid_rows_o = command_valid_rows_i;
  assign mover_cmd_zero_pad_o = command_zero_pad_i;

  always_comb begin
    selected_row_ready = 1'b0;
    unique case (active_op_q)
      GQAV5_DMA_LOAD_Q: selected_row_ready = q_fill_row_ready_i;
      GQAV5_DMA_LOAD_K: selected_row_ready = k_fill_row_ready_i;
      GQAV5_DMA_LOAD_V: selected_row_ready = v_fill_row_ready_i;
      default: selected_row_ready = 1'b0;
    endcase
  end

  assign mover_row_ready_o = (state_q == ST_STREAM) && selected_row_ready;
  assign row_fire = mover_row_valid_i && mover_row_ready_o;
  assign q_fill_row_valid_o = (state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_Q) && mover_row_valid_i;
  assign k_fill_row_valid_o = (state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_K) && mover_row_valid_i;
  assign v_fill_row_valid_o = (state_q == ST_STREAM) &&
      (active_op_q == GQAV5_DMA_LOAD_V) && mover_row_valid_i;
  assign q_fill_row_addr_o = mover_row_index_i;
  assign k_fill_row_addr_o = mover_row_index_i;
  assign v_fill_row_addr_o = mover_row_index_i;
  assign q_fill_row_data_o = mover_row_bf16_i;
  assign k_fill_row_data_o = mover_row_bf16_i;
  assign v_fill_row_data_o = mover_row_bf16_i;
  assign q_fill_row_last_o = mover_row_last_i;
  assign k_fill_row_last_o = mover_row_last_i;
  assign v_fill_row_last_o = mover_row_last_i;
  assign active_o = state_q != ST_IDLE;
  assign protocol_error_o = local_error_q || mover_error_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                     <= ST_IDLE;
      active_op_q                 <= GQAV5_DMA_LOAD_Q;
      active_tag_q                <= '0;
      accepted_command_count_o    <= '0;
      transferred_row_count_o     <= '0;
      command_stall_cycle_count_o <= '0;
      local_error_q               <= 1'b0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (command_valid_i && !command_ready_o)
        command_stall_cycle_count_o <= command_stall_cycle_count_o + 64'd1;

      if (command_fire) begin
        active_op_q              <= command_op_i;
        active_tag_q             <= command_tag;
        accepted_command_count_o <= accepted_command_count_o + 64'd1;
        state_q                  <= ST_WAIT_TILE;
      end
      if (tile_start_fire)
        state_q <= ST_STREAM;
      if (row_fire) begin
        transferred_row_count_o <= transferred_row_count_o + 64'd1;
        if (mover_row_last_i != (mover_row_index_i == 4'd15)) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("LOAD_DISPATCH_ERROR row=%0d last=%0b state=%0d",
                   mover_row_index_i, mover_row_last_i, state_q);
`endif
        end
        if (mover_row_last_i)
          state_q <= ST_WAIT_TILE;
      end
      if (mover_done_i) begin
        if (state_q != ST_WAIT_TILE) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("LOAD_DISPATCH_ERROR done state=%0d op=%0d",
                   state_q, active_op_q);
`endif
        end else
          state_q <= ST_IDLE;
      end
    end
  end

  logic unused_metadata;
  assign unused_metadata = ^{
    active_tag_q,
    command_desc_i.kv_head,
    command_desc_i.q_lane,
    command_desc_i.q_head,
    command_desc_i.kv_partition,
    command_desc_i.kv_wave_packed,
    command_desc_i.prefill_direct,
    command_desc_i.query_tile,
    command_desc_i.context_tile,
    command_desc_i.query_valid_rows,
    command_desc_i.context_valid_cols,
    command_desc_i.next_context_valid_cols,
    command_desc_i.causal,
    command_desc_i.first_context,
    command_desc_i.last_context,
    command_desc_i.last_output_tile,
    command_desc_i.decode_packed
  };
endmodule
