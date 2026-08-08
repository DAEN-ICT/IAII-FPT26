module gqav5_dma_address_generator #(
  parameter int unsigned ADDR_W      = 32,
  parameter int unsigned MAX_SEQ_LEN = 8192,
  parameter bit ENABLE_FULL_ROW_BURST = 1'b1,
  localparam int unsigned TOKEN_W    = $clog2(MAX_SEQ_LEN)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,

  input  logic [ADDR_W-1:0] q_base_addr_i,
  input  logic [ADDR_W-1:0] k_base_addr_i,
  input  logic [ADDR_W-1:0] v_base_addr_i,
  input  logic [ADDR_W-1:0] o_base_addr_i,
  input  logic [ADDR_W-1:0] q_head_stride_bytes_i,
  input  logic [ADDR_W-1:0] q_token_stride_bytes_i,
  input  logic [ADDR_W-1:0] k_head_stride_bytes_i,
  input  logic [ADDR_W-1:0] k_token_stride_bytes_i,
  input  logic [ADDR_W-1:0] v_head_stride_bytes_i,
  input  logic [ADDR_W-1:0] v_token_stride_bytes_i,
  input  logic [ADDR_W-1:0] o_head_stride_bytes_i,
  input  logic [ADDR_W-1:0] o_token_stride_bytes_i,
  input  logic bf16_output_i,
  input  logic [TOKEN_W:0] context_token_count_i,
  input  logic [TOKEN_W-1:0] query_token_base_i,

  input  logic request_valid_i,
  output logic request_ready_o,
  input  gqav5_pkg::gqav5_dma_op_e request_op_i,
  input  gqav5_pkg::gqav5_tile_desc_t request_desc_i,

  output logic command_valid_o,
  input  logic command_ready_i,
  output gqav5_pkg::gqav5_dma_op_e command_op_o,
  output logic command_is_store_o,
  output logic [ADDR_W-1:0] command_addr_o,
  output logic [ADDR_W-1:0] command_row_stride_bytes_o,
  output logic [6:0] command_row_bytes_o,
  output logic [4:0] command_valid_rows_o,
  output logic command_zero_pad_o,
  output gqav5_pkg::gqav5_tile_desc_t command_desc_o,

  output logic rejected_o,
  output logic error_o,
  output logic [63:0] accepted_count_o,
  output logic [63:0] rejected_count_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_HEAD_OFFSET,
    ST_TOKEN_OFFSET,
    ST_HOLD
  } state_t;

  localparam int unsigned BF16_ROW_BYTES = 32;
  localparam int unsigned FP32_ROW_BYTES = 64;

  state_t state_q;
  gqav5_dma_op_e op_q;
  gqav5_tile_desc_t desc_q;
  logic [ADDR_W-1:0] base_addr_q;
  logic [ADDR_W-1:0] head_offset_q;
  logic [ADDR_W-1:0] token_offset_q;
  logic [ADDR_W-1:0] row_stride_q;
  logic [ADDR_W-1:0] address_q;
  logic [ADDR_W-1:0] tile_offset_q;
  logic [6:0] row_bytes_q;
  logic [4:0] valid_rows_q;

  logic [4:0] request_q_head;
  logic [TOKEN_W:0] request_query_token;
  logic [TOKEN_W:0] request_context_token;
  logic [TOKEN_W:0] context_remaining;
  logic [4:0] context_valid_rows;
  logic [ADDR_W-1:0] selected_base;
  logic [ADDR_W-1:0] selected_head_stride;
  logic [ADDR_W-1:0] selected_token_stride;
  logic [ADDR_W-1:0] selected_row_stride;
  logic [ADDR_W-1:0] selected_tile_offset;
  logic [4:0] selected_head_index;
  logic [TOKEN_W:0] selected_token_index;
  logic [6:0] selected_row_bytes;
  logic [4:0] selected_valid_rows;
  logic config_error;
  logic request_error;
  logic request_fire;
  logic command_fire;

  assign request_q_head = {request_desc_i.kv_head, request_desc_i.q_lane};
  assign request_query_token = {1'b0, query_token_base_i} +
      ((TOKEN_W + 1)'(request_desc_i.query_tile) << 4);
  assign request_context_token =
      ((TOKEN_W + 1)'(request_desc_i.context_tile) << 4);
  assign context_remaining = context_token_count_i - request_context_token;

  always_comb begin
    if (context_token_count_i <= request_context_token)
      context_valid_rows = 5'd0;
    else if (context_remaining >= (TOKEN_W + 1)'(16))
      context_valid_rows = 5'd16;
    else
      context_valid_rows = 5'(context_remaining);
  end

  always_comb begin
    selected_base          = q_base_addr_i;
    selected_head_stride   = q_head_stride_bytes_i;
    selected_token_stride  = q_token_stride_bytes_i;
    selected_row_stride    = q_token_stride_bytes_i;
    selected_tile_offset   = ENABLE_FULL_ROW_BURST
        ? '0 : (ADDR_W'(request_desc_i.reduction_tile) << 5);
    selected_head_index    = request_q_head;
    selected_token_index   = request_query_token;
    selected_row_bytes     = 7'(BF16_ROW_BYTES);
    selected_valid_rows    = request_desc_i.query_valid_rows;

    unique case (request_op_i)
      GQAV5_DMA_LOAD_Q: begin
        selected_base         = q_base_addr_i;
        selected_head_stride  = q_head_stride_bytes_i;
        selected_token_stride = q_token_stride_bytes_i;
        selected_row_stride   = q_token_stride_bytes_i;
        if (request_desc_i.prefill_direct) begin
          selected_head_index = request_desc_i.q_head;
          // Tail waves still fill all sixteen physical banks so the packed
          // cache can launch atomically.  Inactive rows duplicate row zero
          // from the current query tile; query_valid_rows masks them from
          // QK/Softmax/PV/store, and clamping avoids an out-of-range DDR read.
          if ({1'b0, request_desc_i.kv_partition,
               request_desc_i.q_lane} <
              request_desc_i.query_valid_rows)
            selected_token_index = request_query_token +
                (TOKEN_W + 1)'({request_desc_i.kv_partition,
                                request_desc_i.q_lane});
          else
            selected_token_index = request_query_token;
          // The packed Q cache uses its sixteen physical head banks as
          // prefill query rows.  Each command therefore fetches one complete
          // query vector and the mover pads the remaining row slots locally.
          selected_valid_rows = 5'd1;
        end
      end
      GQAV5_DMA_LOAD_K: begin
        selected_base          = k_base_addr_i;
        selected_head_stride   = k_head_stride_bytes_i;
        selected_token_stride  = k_token_stride_bytes_i;
        selected_row_stride    = k_token_stride_bytes_i;
        selected_head_index    = request_desc_i.prefill_direct
            ? {2'b00, request_desc_i.q_head[4:2]}
            : {2'b00, request_desc_i.kv_head};
        selected_token_index   = request_context_token;
        selected_valid_rows    = context_valid_rows;
      end
      GQAV5_DMA_LOAD_V: begin
        selected_base          = v_base_addr_i;
        selected_head_stride   = v_head_stride_bytes_i;
        selected_token_stride  = v_token_stride_bytes_i;
        selected_row_stride    = v_token_stride_bytes_i;
        selected_tile_offset   = ENABLE_FULL_ROW_BURST
            ? '0 : (ADDR_W'(request_desc_i.output_tile) << 5);
        selected_head_index    = request_desc_i.prefill_direct
            ? {2'b00, request_desc_i.q_head[4:2]}
            : {2'b00, request_desc_i.kv_head};
        selected_token_index   = request_context_token;
        selected_valid_rows    = context_valid_rows;
      end
      GQAV5_DMA_STORE_O: begin
        selected_base          = o_base_addr_i;
        selected_head_stride   = o_head_stride_bytes_i;
        selected_token_stride  = o_token_stride_bytes_i;
        selected_row_stride    = request_desc_i.decode_packed
            ? o_head_stride_bytes_i : o_token_stride_bytes_i;
        if (request_desc_i.prefill_direct)
          selected_head_index = request_desc_i.q_head;
        selected_tile_offset   = ADDR_W'(request_desc_i.output_tile) <<
                                 (bf16_output_i ? 5 : 6);
        selected_row_bytes     = bf16_output_i
            ? 7'(BF16_ROW_BYTES) : 7'(FP32_ROW_BYTES);
      end
      default: begin
        selected_base = '0;
      end
    endcase
  end

  assign config_error =
      (context_token_count_i == 0) ||
      (context_token_count_i > (TOKEN_W + 1)'(MAX_SEQ_LEN)) ||
      (ENABLE_FULL_ROW_BURST
          ? ((q_base_addr_i[7:0] != 0) ||
             (k_base_addr_i[7:0] != 0) ||
             (v_base_addr_i[7:0] != 0))
          : ((q_base_addr_i[4:0] != 0) ||
             (k_base_addr_i[4:0] != 0) ||
             (v_base_addr_i[4:0] != 0))) ||
      (bf16_output_i ? (o_base_addr_i[4:0] != 0)
                     : (o_base_addr_i[5:0] != 0)) ||
      (ENABLE_FULL_ROW_BURST
          ? ((q_head_stride_bytes_i[7:0] != 0) ||
             (k_head_stride_bytes_i[7:0] != 0) ||
             (v_head_stride_bytes_i[7:0] != 0))
          : ((q_head_stride_bytes_i[4:0] != 0) ||
             (k_head_stride_bytes_i[4:0] != 0) ||
             (v_head_stride_bytes_i[4:0] != 0))) ||
      (bf16_output_i ? (o_head_stride_bytes_i[4:0] != 0)
                     : (o_head_stride_bytes_i[5:0] != 0)) ||
      (q_token_stride_bytes_i < ADDR_W'(
          ENABLE_FULL_ROW_BURST ? 256 : BF16_ROW_BYTES)) ||
      (k_token_stride_bytes_i < ADDR_W'(
          ENABLE_FULL_ROW_BURST ? 256 : BF16_ROW_BYTES)) ||
      (v_token_stride_bytes_i < ADDR_W'(
          ENABLE_FULL_ROW_BURST ? 256 : BF16_ROW_BYTES)) ||
      (o_token_stride_bytes_i <
       ADDR_W'(bf16_output_i ? BF16_ROW_BYTES : FP32_ROW_BYTES)) ||
      (ENABLE_FULL_ROW_BURST
          ? ((q_token_stride_bytes_i[7:0] != 0) ||
             (k_token_stride_bytes_i[7:0] != 0) ||
             (v_token_stride_bytes_i[7:0] != 0))
          : ((q_token_stride_bytes_i[4:0] != 0) ||
             (k_token_stride_bytes_i[4:0] != 0) ||
             (v_token_stride_bytes_i[4:0] != 0))) ||
      (bf16_output_i ? (o_token_stride_bytes_i[4:0] != 0)
                     : (o_token_stride_bytes_i[5:0] != 0));

  assign request_error = config_error ||
      (request_desc_i.query_valid_rows == 0) ||
      (request_desc_i.query_valid_rows > 5'd16) ||
      ((request_op_i == GQAV5_DMA_LOAD_Q) &&
        ((selected_token_index >= (TOKEN_W + 1)'(MAX_SEQ_LEN)) ||
         ((selected_token_index +
           (TOKEN_W + 1)'(selected_valid_rows)) >
          (TOKEN_W + 1)'(MAX_SEQ_LEN)))) ||
      ((request_op_i == GQAV5_DMA_STORE_O) &&
        ((selected_token_index >= (TOKEN_W + 1)'(MAX_SEQ_LEN)) ||
         (!request_desc_i.decode_packed &&
          ((selected_token_index +
            (TOKEN_W + 1)'(selected_valid_rows)) >
           (TOKEN_W + 1)'(MAX_SEQ_LEN))))) ||
      (((request_op_i == GQAV5_DMA_LOAD_K) ||
        (request_op_i == GQAV5_DMA_LOAD_V)) &&
       ((context_valid_rows == 0) ||
        (request_desc_i.context_valid_cols != context_valid_rows))) ||
      (((request_op_i == GQAV5_DMA_LOAD_Q) ||
        (request_op_i == GQAV5_DMA_STORE_O)) &&
       (request_desc_i.context_valid_cols == 0));

  assign request_ready_o = state_q == ST_IDLE;
  assign request_fire = request_valid_i && request_ready_o;
  assign command_valid_o = state_q == ST_HOLD;
  assign command_fire = command_valid_o && command_ready_i;
  assign command_op_o = op_q;
  assign command_is_store_o = op_q == GQAV5_DMA_STORE_O;
  assign command_addr_o = address_q;
  assign command_row_stride_bytes_o = row_stride_q;
  assign command_row_bytes_o = row_bytes_q;
  assign command_valid_rows_o = valid_rows_q;
  assign command_zero_pad_o = !command_is_store_o && (valid_rows_q < 5'd16);
  assign command_desc_o = desc_q;

  // Capture both programmable-stride products when a request is accepted.
  // The previous time-multiplexed multiplier put the state decode, multiplier,
  // and address accumulator on one 240 MHz path.  Two independent products
  // cost a few DSPs but keep the following states to one address addition each
  // and preserve the existing command latency.
  always_ff @(posedge clk_i) begin
    if (request_fire) begin
      head_offset_q <= ADDR_W'(selected_head_index) *
                       selected_head_stride;
      token_offset_q <= ADDR_W'(selected_token_index) *
                        selected_token_stride;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= ST_IDLE;
      op_q              <= GQAV5_DMA_LOAD_Q;
      desc_q            <= '0;
      base_addr_q       <= '0;
      row_stride_q      <= '0;
      address_q         <= '0;
      tile_offset_q     <= '0;
      row_bytes_q       <= '0;
      valid_rows_q      <= '0;
      rejected_o        <= 1'b0;
      error_o           <= 1'b0;
      accepted_count_o  <= '0;
      rejected_count_o  <= '0;
    end else begin
      rejected_o <= 1'b0;
      if (clear_error_i)
        error_o <= 1'b0;

      unique case (state_q)
        ST_IDLE: begin
          if (request_fire) begin
            if (request_error) begin
              rejected_o       <= 1'b1;
              error_o          <= 1'b1;
              rejected_count_o <= rejected_count_o + 64'd1;
            end else begin
              op_q             <= request_op_i;
              desc_q           <= request_desc_i;
              base_addr_q      <= selected_base;
              row_stride_q     <= selected_row_stride;
              tile_offset_q    <= selected_tile_offset;
              row_bytes_q      <= selected_row_bytes;
              valid_rows_q     <= selected_valid_rows;
              accepted_count_o <= accepted_count_o + 64'd1;
              state_q          <= ST_HEAD_OFFSET;
            end
          end
        end

        ST_HEAD_OFFSET: begin
          address_q <= base_addr_q + head_offset_q;
          state_q   <= ST_TOKEN_OFFSET;
        end

        ST_TOKEN_OFFSET: begin
          address_q <= address_q + token_offset_q + tile_offset_q;
          state_q <= ST_HOLD;
        end

        ST_HOLD: begin
          if (command_fire)
            state_q <= ST_IDLE;
        end

        default: begin
          state_q <= ST_IDLE;
          error_o <= 1'b1;
        end
      endcase
    end
  end

  initial begin
    if (ADDR_W < 32)
      $error("ADDR_W must cover the V4.1 32-bit physical address map");
    if (MAX_SEQ_LEN < 16 || (MAX_SEQ_LEN % 16) != 0)
      $error("MAX_SEQ_LEN must be a positive multiple of 16");
  end
endmodule
