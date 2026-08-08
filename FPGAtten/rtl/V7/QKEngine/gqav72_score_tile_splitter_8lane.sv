// V7.2 logical-8x8 score retirement boundary.
//
// The proven V7.1 QK adapter still owns the physical 8x8 array and its two
// result banks.  This boundary accepts the sixteen full score rows at one
// row/cycle, forwards the low eight columns immediately, and stores only the
// high eight columns.  After row 15 it drains the stored high half.  The QK
// result bank is therefore released after sixteen cycles while Softmax sees
// the recurrence-friendly order
//
//   half0 rows 0..15, half1 rows 0..15.
//
// Tail contexts still emit a masked high half.  That second Softmax beat has
// alpha=1 and zero probability, allowing the probability-pair rescaler and
// the single K=16 PV wave to retain one uniform control path.
module gqav72_score_tile_splitter_8lane #(
  parameter int unsigned STATE_SLOTS = 4,
  parameter int unsigned TXN_W       = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS)
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic [31:0]             in_score_fp32_i [16],
  input  logic [3:0]              in_row_index_i,
  input  logic [STATE_SLOT_W-1:0] in_state_slot_i,
  input  logic [31:0]             in_query_base_i,
  input  logic [31:0]             in_context_base_i,
  input  logic [4:0]              in_query_valid_rows_i,
  input  logic [4:0]              in_context_valid_cols_i,
  input  logic                    in_causal_i,
  input  logic                    in_first_context_i,
  input  logic                    in_last_context_i,
  input  logic [31:0]             in_scale_fp32_i,
  input  logic [TXN_W-1:0]        in_txn_id_i,

  output logic                    out_valid_o,
  input  logic                    out_ready_i,
  output logic [31:0]             out_score_fp32_o [8],
  output logic [3:0]              out_row_index_o,
  output logic                    out_context_half_o,
  output logic [STATE_SLOT_W-1:0] out_state_slot_o,
  output logic [31:0]             out_query_base_o,
  output logic [31:0]             out_context_base_o,
  output logic [4:0]              out_query_valid_rows_o,
  output logic [4:0]              out_context_valid_cols_o,
  output logic                    out_causal_o,
  output logic                    out_first_context_o,
  output logic                    out_last_context_o,
  output logic [31:0]             out_scale_fp32_o,
  output logic [TXN_W-1:0]        out_txn_id_o,
  output logic                    protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef enum logic {DRAIN_LOW, DRAIN_HIGH} drain_state_t;
  drain_state_t drain_state_q;

  (* ram_style = "distributed", rw_addr_collision = "no" *)
  logic [255:0] high_half_q [16];
  logic [3:0] high_row_q;
  logic high_half_present_q;

  logic [STATE_SLOT_W-1:0] meta_state_slot_q;
  logic [31:0] meta_query_base_q;
  logic [31:0] meta_context_base_q;
  logic [4:0] meta_query_valid_rows_q;
  logic [4:0] meta_context_valid_cols_q;
  logic meta_causal_q;
  logic meta_first_context_q;
  logic meta_last_context_q;
  logic [31:0] meta_scale_q;
  logic [TXN_W-1:0] meta_txn_q;

  logic low_fire;
  logic high_fire;

  assign in_ready_o = (drain_state_q == DRAIN_LOW) && out_ready_i;
  assign out_valid_o = (drain_state_q == DRAIN_LOW) ? in_valid_i
                                                    : high_half_present_q;
  assign low_fire = in_valid_i && in_ready_o;
  assign high_fire = (drain_state_q == DRAIN_HIGH) &&
                     high_half_present_q && out_ready_i;

  always_comb begin
    out_context_half_o = drain_state_q == DRAIN_HIGH;
    out_row_index_o = (drain_state_q == DRAIN_LOW) ? in_row_index_i
                                                   : high_row_q;
    for (int lane = 0; lane < 8; lane++) begin
      if (drain_state_q == DRAIN_LOW)
        out_score_fp32_o[lane] = in_score_fp32_i[lane];
      else
        out_score_fp32_o[lane] = high_half_q[high_row_q][lane*32 +: 32];
    end

    if (drain_state_q == DRAIN_LOW) begin
      out_state_slot_o = in_state_slot_i;
      out_query_base_o = in_query_base_i;
      out_context_base_o = in_context_base_i;
      out_query_valid_rows_o = in_query_valid_rows_i;
      out_context_valid_cols_o = in_context_valid_cols_i;
      out_causal_o = in_causal_i;
      out_first_context_o = in_first_context_i;
      out_last_context_o = in_last_context_i;
      out_scale_fp32_o = in_scale_fp32_i;
      out_txn_id_o = in_txn_id_i;
    end else begin
      out_state_slot_o = meta_state_slot_q;
      out_query_base_o = meta_query_base_q;
      out_context_base_o = meta_context_base_q;
      out_query_valid_rows_o = meta_query_valid_rows_q;
      out_context_valid_cols_o = meta_context_valid_cols_q;
      out_causal_o = meta_causal_q;
      out_first_context_o = meta_first_context_q;
      out_last_context_o = meta_last_context_q;
      out_scale_fp32_o = meta_scale_q;
      out_txn_id_o = meta_txn_q;
    end
  end

  // Only the upper half payload is stored; the low half remains a direct
  // registered-ready stream and therefore adds no QK result-bank lifetime.
  always_ff @(posedge clk_i) begin
    if (low_fire) begin
      for (int lane = 0; lane < 8; lane++)
        high_half_q[in_row_index_i][lane*32 +: 32]
            <= in_score_fp32_i[lane + 8];
    end
    if (low_fire && (in_row_index_i == 4'd0)) begin
      meta_state_slot_q <= in_state_slot_i;
      meta_query_base_q <= in_query_base_i;
      meta_context_base_q <= in_context_base_i;
      meta_query_valid_rows_q <= in_query_valid_rows_i;
      meta_context_valid_cols_q <= in_context_valid_cols_i;
      meta_causal_q <= in_causal_i;
      meta_first_context_q <= in_first_context_i;
      meta_last_context_q <= in_last_context_i;
      meta_scale_q <= in_scale_fp32_i;
      meta_txn_q <= in_txn_id_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      drain_state_q <= DRAIN_LOW;
      high_row_q <= '0;
      high_half_present_q <= 1'b0;
      protocol_error_o <= 1'b0;
    end else begin
      if (low_fire && (in_row_index_i == 4'd15)) begin
        drain_state_q <= DRAIN_HIGH;
        high_row_q <= '0;
        high_half_present_q <= 1'b1;
      end

      if (high_fire) begin
        if (high_row_q == 4'd15) begin
          drain_state_q <= DRAIN_LOW;
          high_row_q <= '0;
          high_half_present_q <= 1'b0;
        end else begin
          high_row_q <= high_row_q + 4'd1;
        end
      end

      if (low_fire && (in_row_index_i == 4'd0) &&
          ((in_context_valid_cols_i == 0) ||
           (in_context_valid_cols_i > 5'd16)))
        protocol_error_o <= 1'b1;
      if ((drain_state_q == DRAIN_HIGH) && in_valid_i)
        protocol_error_o <= 1'b1;
    end
  end
endmodule
