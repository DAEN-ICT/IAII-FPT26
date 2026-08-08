module gqav5_dma_store_dispatch (
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
  input  gqav5_pkg::gqav5_tile_desc_t command_desc_i,

  output logic mover_cmd_valid_o,
  input  logic mover_cmd_ready_i,
  output logic [31:0] mover_cmd_addr_o,
  output logic [31:0] mover_cmd_row_stride_bytes_o,
  output logic [6:0] mover_cmd_row_bytes_o,
  output logic [4:0] mover_cmd_valid_rows_o,
  output logic mover_row_valid_o,
  input  logic mover_row_ready_i,
  output logic [511:0] mover_row_fp32_o,
  output logic [3:0] mover_row_index_o,
  output logic mover_row_last_o,
  input  logic mover_done_i,
  input  logic mover_error_i,

  input  logic result_valid_i,
  output logic result_ready_o,
  input  logic [31:0] result_fp32_i [16],
  input  logic [2:0] result_output_tile_i,
  input  logic [3:0] result_row_index_i,
  input  logic [15:0] result_txn_id_i,
  input  logic result_row_valid_i,

  output logic active_o,
  output logic [63:0] accepted_command_count_o,
  output logic [63:0] accepted_result_row_count_o,
  output logic [63:0] submitted_store_row_count_o,
  output logic [63:0] command_stall_cycle_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic {
    ST_IDLE,
    ST_STREAM
  } state_t;

  state_t state_q;
  logic [15:0] active_txn_q;
  logic [2:0] active_output_tile_q;
  logic [4:0] active_valid_rows_q;
  logic [3:0] expected_row_q;
  logic all_results_seen_q;
  logic mover_done_seen_q;
  logic local_error_q;
  logic command_is_store;
  logic command_fire;
  logic expected_result_valid;
  logic result_fire;
  logic mover_row_fire;
  logic active_bf16_q;
  logic [15:0] result_bf16 [16];

  assign command_is_store = command_op_i == GQAV5_DMA_STORE_O;
  assign command_ready_o = (state_q == ST_IDLE) && command_is_store &&
      mover_cmd_ready_i;
  assign command_fire = command_valid_i && command_ready_o;
  assign mover_cmd_valid_o = (state_q == ST_IDLE) && command_valid_i &&
      command_is_store;
  assign mover_cmd_addr_o = command_addr_i;
  assign mover_cmd_row_stride_bytes_o = command_row_stride_bytes_i;
  assign mover_cmd_row_bytes_o = command_row_bytes_i;
  assign mover_cmd_valid_rows_o = command_valid_rows_i;

  assign expected_result_valid =
      {1'b0, expected_row_q} < active_valid_rows_q;
  assign result_ready_o = (state_q == ST_STREAM) &&
      !all_results_seen_q &&
      (!expected_result_valid || mover_row_ready_i);
  assign result_fire = result_valid_i && result_ready_o;
  assign mover_row_valid_o = (state_q == ST_STREAM) &&
      !all_results_seen_q && result_valid_i && expected_result_valid;
  assign mover_row_index_o = expected_row_q;
  assign mover_row_last_o =
      ({1'b0, expected_row_q} + 5'd1) >= active_valid_rows_q;
  assign mover_row_fire = mover_row_valid_o && mover_row_ready_i;
  assign active_o = state_q == ST_STREAM;
  assign protocol_error_o = local_error_q || mover_error_i;

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_pack_result
      gqav5_fp32_to_bf16_rne i_convert (
        .fp32_i(result_fp32_i[lane]),
        .bf16_o(result_bf16[lane])
      );
    end
  endgenerate

  always_comb begin
    mover_row_fp32_o = '0;
    for (int unsigned lane = 0; lane < 16; lane++) begin
      if (active_bf16_q)
        mover_row_fp32_o[lane * 16 +: 16] = result_bf16[lane];
      else
        mover_row_fp32_o[lane * 32 +: 32] = result_fp32_i[lane];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                       <= ST_IDLE;
      active_txn_q                  <= '0;
      active_output_tile_q          <= '0;
      active_valid_rows_q           <= '0;
      expected_row_q                <= '0;
      all_results_seen_q            <= 1'b0;
      mover_done_seen_q             <= 1'b0;
      active_bf16_q                 <= 1'b0;
      local_error_q                 <= 1'b0;
      accepted_command_count_o      <= '0;
      accepted_result_row_count_o   <= '0;
      submitted_store_row_count_o   <= '0;
      command_stall_cycle_count_o   <= '0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (command_valid_i && !command_ready_o)
        command_stall_cycle_count_o <= command_stall_cycle_count_o + 64'd1;

      if (command_fire) begin
        state_q                      <= ST_STREAM;
        active_txn_q                 <= command_desc_i.txn_id;
        active_output_tile_q         <= command_desc_i.output_tile;
        active_valid_rows_q          <= command_valid_rows_i;
        active_bf16_q                <= command_row_bytes_i == 7'd32;
        expected_row_q               <= '0;
        all_results_seen_q           <= 1'b0;
        mover_done_seen_q            <= 1'b0;
        accepted_command_count_o     <= accepted_command_count_o + 64'd1;
        if (command_valid_rows_i == 0 || command_valid_rows_i > 5'd16 ||
            ((command_row_bytes_i != 7'd32) &&
             (command_row_bytes_i != 7'd64))) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_DISPATCH_ERROR bad command rows=%0d bytes=%0d",
                   command_valid_rows_i, command_row_bytes_i);
`endif
        end
      end

      if (result_fire) begin
        accepted_result_row_count_o <=
            accepted_result_row_count_o + 64'd1;
        if (result_txn_id_i != active_txn_q ||
            result_output_tile_i != active_output_tile_q ||
            result_row_index_i != expected_row_q ||
            result_row_valid_i != expected_result_valid) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_DISPATCH_ERROR result txn=%0h/%0h tile=%0d/%0d row=%0d/%0d valid=%0b/%0b",
                   result_txn_id_i, active_txn_q,
                   result_output_tile_i, active_output_tile_q,
                   result_row_index_i, expected_row_q,
                   result_row_valid_i, expected_result_valid);
`endif
        end
        if (expected_row_q == 4'd15) begin
          all_results_seen_q <= 1'b1;
          if (mover_done_seen_q)
            state_q <= ST_IDLE;
        end else begin
          expected_row_q <= expected_row_q + 4'd1;
        end
      end

      if (mover_row_fire)
        submitted_store_row_count_o <=
            submitted_store_row_count_o + 64'd1;

      if (mover_done_i) begin
        if (state_q != ST_STREAM) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_DISPATCH_ERROR mover done while idle");
`endif
        end else if (all_results_seen_q ||
                     (result_fire && expected_row_q == 4'd15)) begin
          state_q <= ST_IDLE;
        end else begin
          mover_done_seen_q <= 1'b1;
        end
      end
    end
  end

  logic unused_metadata;
  assign unused_metadata = ^{
    command_desc_i.kv_head,
    command_desc_i.q_lane,
    command_desc_i.q_head,
    command_desc_i.kv_partition,
    command_desc_i.kv_wave_packed,
    command_desc_i.prefill_direct,
    command_desc_i.query_tile,
    command_desc_i.context_tile,
    command_desc_i.reduction_tile,
    command_desc_i.query_valid_rows,
    command_desc_i.context_valid_cols,
    command_desc_i.next_context_valid_cols,
    command_desc_i.causal,
    command_desc_i.first_context,
    command_desc_i.last_context,
    command_desc_i.last_output_tile,
    command_desc_i.decode_packed,
    all_results_seen_q
  };
endmodule
