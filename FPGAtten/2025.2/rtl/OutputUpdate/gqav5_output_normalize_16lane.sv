module gqav5_output_normalize_16lane #(
  parameter int unsigned STATE_SLOT_W = 2,
  parameter int unsigned OUTPUT_TILE_W = 3,
  parameter int unsigned TXN_W = 16
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic                    row_valid_i,
  input  logic [31:0]             updated_fp32_i [16],
  input  logic [31:0]             running_sum_fp32_i,
  input  logic [STATE_SLOT_W-1:0] state_slot_i,
  input  logic [3:0]              row_index_i,
  input  logic [OUTPUT_TILE_W-1:0] output_tile_i,
  input  logic [TXN_W-1:0]        txn_id_i,

  output logic                    out_valid_o,
  input  logic                    out_ready_i,
  output logic [31:0]             normalized_fp32_o [16],
  output logic [31:0]             reciprocal_fp32_o,
  output logic [STATE_SLOT_W-1:0] state_slot_o,
  output logic [3:0]              row_index_o,
  output logic [OUTPUT_TILE_W-1:0] output_tile_o,
  output logic [TXN_W-1:0]        txn_id_o,
  output logic [63:0]             normalized_rows_o,
  output logic [63:0]             reciprocal_busy_cycles_o,
  output logic                    rom_sentinel_ok_o,
  output logic                    protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  typedef enum logic [1:0] {ST_IDLE, ST_RECIP, ST_OUTPUT} state_t;
  state_t state_q;

  logic        row_valid_q;
  logic [31:0] updated_q [16];
  logic [31:0] normalized_q [16];
  logic [31:0] normalized_w [16];
  logic [31:0] reciprocal_q;
  logic [STATE_SLOT_W-1:0] state_slot_q;
  logic [3:0] row_index_q;
  logic [OUTPUT_TILE_W-1:0] output_tile_q;
  logic [TXN_W-1:0] txn_id_q;

  logic reciprocal_start_valid;
  logic reciprocal_start_ready;
  logic reciprocal_result_valid;
  logic reciprocal_result_ready;
  logic [31:0] reciprocal_result;
  logic reciprocal_busy;
  logic reciprocal_error;

  assign in_ready_o = state_q == ST_IDLE;
  assign out_valid_o = state_q == ST_OUTPUT;
  assign reciprocal_start_valid = in_valid_i && in_ready_o && row_valid_i;
  assign reciprocal_result_ready = state_q == ST_RECIP;
  assign reciprocal_fp32_o = reciprocal_q;
  assign state_slot_o = state_slot_q;
  assign row_index_o = row_index_q;
  assign output_tile_o = output_tile_q;
  assign txn_id_o = txn_id_q;

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_normalize_lane
      gqav5_fp32_mul_rne i_normalize (
        .a_fp32_i      (updated_q[lane]),
        .b_fp32_i      (reciprocal_result),
        .product_fp32_o(normalized_w[lane])
      );
      assign normalized_fp32_o[lane] = normalized_q[lane];
    end
  endgenerate

  gqav5_fp32_recip_lut_nr i_reciprocal (
    .clk_i,
    .rst_ni,
    .start_valid_i   (reciprocal_start_valid),
    .start_ready_o   (reciprocal_start_ready),
    .operand_fp32_i  (running_sum_fp32_i),
    .result_valid_o  (reciprocal_result_valid),
    .result_ready_i  (reciprocal_result_ready),
    .result_fp32_o   (reciprocal_result),
    .busy_o          (reciprocal_busy),
    .rom_sentinel_ok_o,
    .protocol_error_o(reciprocal_error)
  );

  // Row payload is qualified by state_q.  Keeping these 1,024 data bits out
  // of the asynchronous-reset process avoids a wide reset tree; the invalid
  // row zero write below is functional output generation, not reset state.
  always_ff @(posedge clk_i) begin
    if ((state_q == ST_IDLE) && in_valid_i) begin
      for (int lane = 0; lane < 16; lane++) begin
        updated_q[lane] <= updated_fp32_i[lane];
        if (!row_valid_i)
          normalized_q[lane] <= 32'h0000_0000;
      end
    end
    if ((state_q == ST_RECIP) && reciprocal_result_valid) begin
      for (int lane = 0; lane < 16; lane++)
        normalized_q[lane] <= normalized_w[lane];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                   <= ST_IDLE;
      row_valid_q               <= 1'b0;
      reciprocal_q              <= '0;
      state_slot_q              <= '0;
      row_index_q               <= '0;
      output_tile_q             <= '0;
      txn_id_q                  <= '0;
      normalized_rows_o         <= '0;
      reciprocal_busy_cycles_o  <= '0;
      protocol_error_o          <= 1'b0;
    end else begin
      if (reciprocal_error || !rom_sentinel_ok_o)
        protocol_error_o <= 1'b1;
      if (reciprocal_busy)
        reciprocal_busy_cycles_o <= reciprocal_busy_cycles_o + 64'd1;

      unique case (state_q)
        ST_IDLE: begin
          if (in_valid_i) begin
            row_valid_q   <= row_valid_i;
            state_slot_q  <= state_slot_i;
            row_index_q   <= row_index_i;
            output_tile_q <= output_tile_i;
            txn_id_q      <= txn_id_i;

            if (!row_valid_i) begin
              reciprocal_q <= 32'h0000_0000;
              state_q <= ST_OUTPUT;
            end else if (!reciprocal_start_ready) begin
              protocol_error_o <= 1'b1;
            end else begin
              state_q <= ST_RECIP;
            end
          end
        end

        ST_RECIP: begin
          if (reciprocal_result_valid) begin
            reciprocal_q <= reciprocal_result;
            state_q <= ST_OUTPUT;
          end
        end

        ST_OUTPUT: begin
          if (out_ready_i) begin
            normalized_rows_o <= normalized_rows_o + 64'(row_valid_q);
            state_q <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  initial begin
    if ((STATE_SLOT_W < 1) || (OUTPUT_TILE_W < 1) || (TXN_W < 1))
      $error("output-normalize metadata widths must be positive");
  end
endmodule
