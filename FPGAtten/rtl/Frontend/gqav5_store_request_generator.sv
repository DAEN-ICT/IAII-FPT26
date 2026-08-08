module gqav5_store_request_generator (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,

  input  logic context_capture_i,
  input  gqav5_pkg::gqav5_tile_desc_t context_desc_i,

  input  logic result_valid_i,
  input  logic result_fire_i,
  input  logic [2:0] result_output_tile_i,
  input  logic [3:0] result_row_index_i,
  input  logic [15:0] result_txn_id_i,

  output logic request_valid_o,
  input  logic request_ready_i,
  output gqav5_pkg::gqav5_tile_desc_t request_desc_o,
  output logic pending_o,
  output logic [63:0] request_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  // The compute pipeline can keep two descriptors in flight.  Result rows
  // remain ordered, but the next descriptor can be accepted while the
  // current descriptor is still draining its output tiles.  Retain a small
  // metadata FIFO so early descriptor issue never overwrites the store
  // address context of the result stream at the head of the queue.
  localparam int unsigned CONTEXT_DEPTH = 4;
  localparam int unsigned CONTEXT_PTR_W = $clog2(CONTEXT_DEPTH);

  gqav5_tile_desc_t context_fifo_q [CONTEXT_DEPTH];
  logic [CONTEXT_PTR_W-1:0] context_write_ptr_q;
  logic [CONTEXT_PTR_W-1:0] context_read_ptr_q;
  logic [CONTEXT_PTR_W:0] context_count_q;
  gqav5_tile_desc_t active_context_desc;
  logic request_issued_q;
  logic [2:0] expected_output_tile_q;
  logic [3:0] expected_row_q;
  logic local_error_q;
  logic request_fire;
  logic context_pop;

  assign active_context_desc = context_fifo_q[context_read_ptr_q];

  always_comb begin
    request_desc_o = active_context_desc;
    request_desc_o.reduction_tile = 3'd0;
    request_desc_o.output_tile = result_output_tile_i;
    request_desc_o.last_output_tile = result_output_tile_i == 3'd7;
  end

  assign request_valid_o = (context_count_q != 0) && result_valid_i &&
      (result_row_index_i == 4'd0) && !request_issued_q;
  assign request_fire = request_valid_o && request_ready_i;
  assign context_pop = (context_count_q != 0) && result_fire_i &&
      (expected_output_tile_q == 3'd7) && (expected_row_q == 4'd15);
  assign pending_o = (context_count_q != 0) || request_issued_q;
  assign protocol_error_o = local_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      context_fifo_q       <= '{default:'0};
      context_write_ptr_q  <= '0;
      context_read_ptr_q   <= '0;
      context_count_q      <= '0;
      request_issued_q     <= 1'b0;
      expected_output_tile_q <= '0;
      expected_row_q       <= '0;
      request_count_o      <= '0;
      local_error_q        <= 1'b0;
    end else begin
      if (clear_error_i)
        local_error_q <= 1'b0;

      if (context_capture_i) begin
        if ((context_count_q == (CONTEXT_PTR_W + 1)'(CONTEXT_DEPTH)) &&
            !context_pop) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_REQUEST_ERROR context FIFO overflow count=%0d txn=%0h",
                   context_count_q, context_desc_i.txn_id);
`endif
        end else begin
          context_fifo_q[context_write_ptr_q] <= context_desc_i;
          context_write_ptr_q <= context_write_ptr_q + CONTEXT_PTR_W'(1);
        end
      end

      unique case ({context_capture_i &&
                    !((context_count_q ==
                       (CONTEXT_PTR_W + 1)'(CONTEXT_DEPTH)) && !context_pop),
                    context_pop})
        2'b10: context_count_q <= context_count_q + 1'b1;
        2'b01: context_count_q <= context_count_q - 1'b1;
        default: begin end
      endcase

      if (request_fire) begin
        request_issued_q <= 1'b1;
        request_count_o  <= request_count_o + 64'd1;
        if (result_output_tile_i != expected_output_tile_q ||
            result_txn_id_i != active_context_desc.txn_id) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_REQUEST_ERROR request metadata tile=%0d/%0d txn=%0h/%0h",
                   result_output_tile_i, expected_output_tile_q,
                   result_txn_id_i, active_context_desc.txn_id);
`endif
        end
      end

      if (result_fire_i) begin
        if ((context_count_q == 0) || !request_issued_q ||
            result_output_tile_i != expected_output_tile_q ||
            result_row_index_i != expected_row_q ||
            result_txn_id_i != active_context_desc.txn_id) begin
          local_error_q <= 1'b1;
`ifndef SYNTHESIS
          $display("STORE_REQUEST_ERROR result context=%0b issued=%0b tile=%0d/%0d row=%0d/%0d txn=%0h/%0h",
                   context_count_q != 0, request_issued_q,
                   result_output_tile_i, expected_output_tile_q,
                   result_row_index_i, expected_row_q,
                   result_txn_id_i, active_context_desc.txn_id);
`endif
        end
        if (expected_row_q == 4'd15) begin
          request_issued_q <= 1'b0;
          expected_row_q   <= '0;
          if (expected_output_tile_q == 3'd7) begin
            expected_output_tile_q <= '0;
            context_read_ptr_q <= context_read_ptr_q + CONTEXT_PTR_W'(1);
          end else begin
            expected_output_tile_q <= expected_output_tile_q + 3'd1;
          end
        end else begin
          expected_row_q <= expected_row_q + 4'd1;
        end
      end
    end
  end
endmodule
