module gqav5_attention_group_scheduler #(
  parameter int unsigned Q_HEADS_PER_KV = 4
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic clear_error_i,

  input  logic launch_valid_i,
  output logic launch_ready_o,
  input  gqav5_pkg::gqav5_tile_desc_t launch_desc_i,

  output logic compute_desc_valid_o,
  input  logic compute_desc_ready_i,
  output gqav5_pkg::gqav5_tile_desc_t compute_desc_o,
  output logic [1:0] compute_state_slot_o,

  output logic request_valid_o,
  input  logic request_ready_i,
  output gqav5_pkg::gqav5_dma_op_e request_op_o,
  output gqav5_pkg::gqav5_tile_desc_t request_desc_o,

  input  logic compute_done_i,
  output logic group_done_o,
  output logic active_o,
  output logic [1:0] active_q_lane_o,
  output logic [63:0] compute_descriptor_count_o,
  output logic [63:0] load_request_count_o,
  output logic [63:0] completed_q_head_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_DESC,
    ST_LOAD_Q,
    ST_LOAD_K,
    ST_LOAD_V,
    ST_WAIT
  } state_t;

  state_t state_q;
  gqav5_tile_desc_t base_desc_q;
  logic [1:0] q_lane_q;
  logic [2:0] reduction_tile_q;
  logic [2:0] output_tile_q;
  logic local_error_q;
  logic compute_desc_fire;
  logic request_fire;

  always_comb begin
    compute_desc_o = base_desc_q;
    compute_desc_o.q_lane = q_lane_q;
    compute_desc_o.reduction_tile = 3'd0;
    compute_desc_o.output_tile = 3'd0;
    compute_desc_o.last_output_tile = 1'b1;
    compute_desc_o.txn_id = base_desc_q.txn_id + 16'(q_lane_q);

    request_desc_o = compute_desc_o;
    request_desc_o.reduction_tile = reduction_tile_q;
    request_desc_o.output_tile = output_tile_q;

    request_op_o = GQAV5_DMA_LOAD_Q;
    unique case (state_q)
      ST_LOAD_Q: request_op_o = GQAV5_DMA_LOAD_Q;
      ST_LOAD_K: request_op_o = GQAV5_DMA_LOAD_K;
      ST_LOAD_V: request_op_o = GQAV5_DMA_LOAD_V;
      default:   request_op_o = GQAV5_DMA_LOAD_Q;
    endcase
  end

  assign launch_ready_o = state_q == ST_IDLE;
  assign compute_desc_valid_o = state_q == ST_DESC;
  assign compute_desc_fire = compute_desc_valid_o && compute_desc_ready_i;
  assign request_valid_o = (state_q == ST_LOAD_Q) ||
      (state_q == ST_LOAD_K) || (state_q == ST_LOAD_V);
  assign request_fire = request_valid_o && request_ready_i;
  assign active_o = state_q != ST_IDLE;
  assign active_q_lane_o = q_lane_q;
  assign compute_state_slot_o = q_lane_q;
  assign protocol_error_o = local_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                    <= ST_IDLE;
      base_desc_q                <= '0;
      q_lane_q                   <= '0;
      reduction_tile_q          <= '0;
      output_tile_q             <= '0;
      local_error_q              <= 1'b0;
      group_done_o               <= 1'b0;
      compute_descriptor_count_o <= '0;
      load_request_count_o       <= '0;
      completed_q_head_count_o   <= '0;
    end else begin
      group_done_o <= 1'b0;
      if (clear_error_i)
        local_error_q <= 1'b0;
      if (compute_done_i && state_q != ST_WAIT)
        local_error_q <= 1'b1;

      unique case (state_q)
        ST_IDLE: begin
          if (launch_valid_i && launch_ready_o) begin
            base_desc_q       <= launch_desc_i;
            q_lane_q          <= 2'd0;
            reduction_tile_q <= 3'd0;
            output_tile_q    <= 3'd0;
            state_q           <= ST_DESC;
          end
        end

        ST_DESC: begin
          if (compute_desc_fire) begin
            compute_descriptor_count_o <=
                compute_descriptor_count_o + 64'd1;
            reduction_tile_q <= 3'd0;
            output_tile_q    <= 3'd0;
            state_q          <= ST_LOAD_Q;
          end
        end

        ST_LOAD_Q: begin
          if (request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            state_q <= ST_LOAD_K;
          end
        end

        ST_LOAD_K: begin
          if (request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (reduction_tile_q == 3'd7) begin
              output_tile_q <= 3'd0;
              state_q <= ST_LOAD_V;
            end else begin
              reduction_tile_q <= reduction_tile_q + 3'd1;
              state_q <= ST_LOAD_Q;
            end
          end
        end

        ST_LOAD_V: begin
          if (request_fire) begin
            load_request_count_o <= load_request_count_o + 64'd1;
            if (output_tile_q == 3'd7) begin
              state_q <= ST_WAIT;
            end else begin
              output_tile_q <= output_tile_q + 3'd1;
            end
          end
        end

        ST_WAIT: begin
          if (compute_done_i) begin
            completed_q_head_count_o <= completed_q_head_count_o + 64'd1;
            if (q_lane_q == 2'(Q_HEADS_PER_KV - 1)) begin
              group_done_o <= 1'b1;
              state_q <= ST_IDLE;
            end else begin
              q_lane_q          <= q_lane_q + 2'd1;
              reduction_tile_q <= 3'd0;
              output_tile_q    <= 3'd0;
              state_q          <= ST_DESC;
            end
          end
        end

        default: begin
          local_error_q <= 1'b1;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  initial begin
    if (REDUCTION_TILES != 8 || OUTPUT_TILES != 8)
      $error("group scheduler currently targets head_dim=128 and 16-wide tiles");
    if (Q_HEADS_PER_KV < 1 || Q_HEADS_PER_KV > 4)
      $error("Q_HEADS_PER_KV must fit the two-bit q_lane field");
  end
endmodule
