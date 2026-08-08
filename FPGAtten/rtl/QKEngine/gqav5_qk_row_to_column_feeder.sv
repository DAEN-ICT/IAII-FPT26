module gqav5_qk_row_to_column_feeder #(
  parameter int unsigned TAG_W = 16
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_valid_i,
  output logic start_ready_o,
  input  logic [TAG_W-1:0] start_tag_i,
  input  logic row_valid_i,
  output logic row_ready_o,
  input  logic [3:0] row_index_i,
  input  logic [255:0] q_row_bf16_i,
  input  logic [255:0] k_row_bf16_i,
  input  logic row_last_i,

  output logic step_valid_o,
  input  logic step_ready_i,
  output logic [15:0] q_column_bf16_o [16],
  output logic [15:0] k_column_bf16_o [16],
  output logic [3:0] step_index_o,
  output logic [TAG_W-1:0] step_tag_o,
  output logic done_o,
  output logic [63:0] accepted_row_count_o,
  output logic [63:0] emitted_step_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_LOAD,
    ST_PRIME,
    ST_EMIT
  } state_t;

  state_t state_q;
  // This is the bounded parallel working set required to feed 256 QK MACs.
  // It is local to the array adapter, has no reset, and never crosses a module
  // boundary as a tile. Persistent/prefetch storage remains in BRAM.
  logic [255:0] q_row_working_q [16];
  logic [255:0] k_row_working_q [16];
  logic [255:0] q_column_q;
  logic [255:0] k_column_q;
  logic [255:0] selected_q_column;
  logic [255:0] selected_k_column;
  logic [3:0] row_index_q;
  logic [3:0] column_index_q;
  logic [3:0] select_column_index;
  logic [TAG_W-1:0] tag_q;
  logic start_fire;
  logic row_fire;
  logic step_fire;

  assign start_ready_o = state_q == ST_IDLE;
  assign start_fire = start_valid_i && start_ready_o;
  assign row_ready_o = state_q == ST_LOAD;
  assign row_fire = row_valid_i && row_ready_o;
  assign step_valid_o = state_q == ST_EMIT;
  assign step_fire = step_valid_o && step_ready_i;
  assign step_index_o = column_index_q;
  assign step_tag_o = tag_q;
  assign select_column_index = (state_q == ST_EMIT)
      ? column_index_q + 4'd1 : 4'd0;

  always_comb begin
    selected_q_column = '0;
    selected_k_column = '0;
    for (int row = 0; row < 16; row++) begin
      selected_q_column[row * 16 +: 16] =
          q_row_working_q[row][select_column_index * 16 +: 16];
      selected_k_column[row * 16 +: 16] =
          k_row_working_q[row][select_column_index * 16 +: 16];
    end
  end

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_column_output
      assign q_column_bf16_o[lane] = q_column_q[lane * 16 +: 16];
      assign k_column_bf16_o[lane] = k_column_q[lane * 16 +: 16];
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q                <= ST_IDLE;
      row_index_q            <= '0;
      column_index_q         <= '0;
      tag_q                  <= '0;
      done_o                 <= 1'b0;
      accepted_row_count_o   <= '0;
      emitted_step_count_o   <= '0;
      completed_tile_count_o <= '0;
      protocol_error_o       <= 1'b0;
    end else begin
      done_o <= 1'b0;

      unique case (state_q)
        ST_IDLE: begin
          if (start_fire) begin
            tag_q          <= start_tag_i;
            row_index_q    <= '0;
            column_index_q <= '0;
            state_q        <= ST_LOAD;
          end
        end

        ST_LOAD: begin
          if (row_fire) begin
            accepted_row_count_o <= accepted_row_count_o + 64'd1;
            if (row_index_i != row_index_q ||
                row_last_i != (row_index_q == 4'd15))
              protocol_error_o <= 1'b1;
            if (row_index_q == 4'd15) begin
              row_index_q <= '0;
              state_q     <= ST_PRIME;
            end else begin
              row_index_q <= row_index_q + 4'd1;
            end
          end
        end

        // Isolate the 16:1 row-word selection from the multiplier inputs.
        ST_PRIME: begin
          column_index_q <= '0;
          state_q        <= ST_EMIT;
        end

        ST_EMIT: begin
          if (step_fire) begin
            emitted_step_count_o <= emitted_step_count_o + 64'd1;
            if (column_index_q == 4'd15) begin
              done_o                 <= 1'b1;
              completed_tile_count_o <= completed_tile_count_o + 64'd1;
              column_index_q         <= '0;
              state_q                <= ST_IDLE;
            end else begin
              column_index_q <= column_index_q + 4'd1;
            end
          end
        end

        default: begin
          state_q          <= ST_IDLE;
          protocol_error_o <= 1'b1;
        end
      endcase
    end
  end

  // All transpose and registered-column payload is qualified by the feeder
  // FSM.  Keep the bounded datapath in a reset-free process so the global
  // asynchronous reset does not fan out through 512 column bits or the local
  // working set.
  always_ff @(posedge clk_i) begin
    if (row_fire) begin
      q_row_working_q[row_index_q] <= q_row_bf16_i;
      k_row_working_q[row_index_q] <= k_row_bf16_i;
    end
    if (state_q == ST_PRIME) begin
      q_column_q <= selected_q_column;
      k_column_q <= selected_k_column;
    end else if (step_fire && (column_index_q != 4'd15)) begin
      q_column_q <= selected_q_column;
      k_column_q <= selected_k_column;
    end
  end
endmodule
