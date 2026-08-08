module gqav5_pv_p_stationary_16x16 #(
  parameter int unsigned K_STEPS     = 16,
  parameter int unsigned OUTPUT_TILES = 8,
  localparam int unsigned K_W = (K_STEPS <= 1) ? 1 : $clog2(K_STEPS),
  localparam int unsigned OUTPUT_W = (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES)
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              p_start_i,
  output logic              p_start_ready_o,
  input  logic              p_row_valid_i,
  output logic              p_row_ready_o,
  input  logic [15:0]       p_row_bf16_i [16],
  output logic              p_loaded_o,
  input  logic              p_discard_i,

  input  logic              output_start_i,
  output logic              output_start_ready_o,
  input  logic              v_step_valid_i,
  output logic              v_step_ready_o,
  input  logic [15:0]       v_bf16_i [16],
  input  logic [15:0]       row_valid_i,
  input  logic [15:0]       col_valid_i,

  output logic              active_o,
  output logic              output_done_o,
  output logic [OUTPUT_W-1:0] output_tile_index_o,
  output logic              partial_row_valid_o,
  input  logic              partial_row_ready_i,
  output logic [31:0]       partial_row_fp32_o [16],
  output logic [3:0]        partial_row_index_o,
  output logic [OUTPUT_W-1:0] partial_row_output_tile_o,
  output logic              partial_row_bank_o,
  output logic              partial_drained_o,
  output logic [8:0]        accepted_macs_cycle_o,
  output logic [63:0]       accepted_macs_total_o,
  output logic [63:0]       p_load_count_o,
  output logic [63:0]       v_output_wave_count_o,
  output logic              protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic              p_load_active_q;
  logic [3:0]        p_row_index_q;
  logic              p_loaded_q;
  // Physical contract: payload arrays have no reset network.  P is fully
  // loaded before use and the first accepted V step overwrites its PE bank.
  logic [15:0]       p_tile_q [16][16];
  logic              compute_active_q;
  logic [K_W-1:0]    k_index_q;
  logic [OUTPUT_W-1:0] output_tile_index_q;
  logic [31:0]       accumulator_q [2][16][16];
  logic [31:0]       product [16][16];
  logic [31:0]       accumulated [16][16];
  logic              p_start_fire;
  logic              output_start_fire;
  logic              v_step_accept;
  logic              compute_bank_q;
  logic [1:0]        partial_bank_ready_q;
  logic [OUTPUT_W-1:0] completed_output_tile_q [2];
  logic              partial_bank_q;
  logic              partial_active_q;
  logic [3:0]        partial_row_index_q;
  logic              partial_row_fire;
  logic              compute_completion;
  logic              other_partial_bank;
  logic              next_partial_available;

  assign p_start_ready_o = !p_loaded_q && !p_load_active_q &&
                           !compute_active_q;
  assign p_row_ready_o = p_load_active_q ||
                         (p_start_i && p_start_ready_o);
  assign p_start_fire = p_start_i && p_start_ready_o;
  assign p_loaded_o = p_loaded_q;

  assign output_start_ready_o = p_loaded_q && !compute_active_q &&
      ((!partial_bank_ready_q[compute_bank_q]) ||
       (partial_row_fire && (partial_row_index_q == 4'd15) &&
        (partial_bank_q == compute_bank_q)));
  // Launch consumes the first V row. Missing DMA data must stall the wave,
  // not advance the reduction counter or complete a partial output early.
  assign output_start_fire = output_start_i && output_start_ready_o &&
                             v_step_valid_i;
  assign v_step_ready_o = compute_active_q || output_start_fire;
  assign v_step_accept = v_step_valid_i && v_step_ready_o;
  assign active_o = compute_active_q;
  assign output_tile_index_o = output_tile_index_q;
  assign partial_row_valid_o = partial_active_q;
  assign partial_row_index_o = partial_row_index_q;
  assign partial_row_output_tile_o = completed_output_tile_q[partial_bank_q];
  assign partial_row_bank_o = partial_bank_q;
  assign partial_row_fire = partial_row_valid_o && partial_row_ready_i;
  assign compute_completion =
      (output_start_fire && (K_STEPS == 1)) ||
      (compute_active_q && v_step_accept &&
       (k_index_q == K_W'(K_STEPS - 1)));
  assign other_partial_bank = ~partial_bank_q;
  assign next_partial_available =
      partial_bank_ready_q[other_partial_bank] ||
      (compute_completion && (compute_bank_q == other_partial_bank));

  always_comb begin
    if (v_step_accept)
      accepted_macs_cycle_o = 9'($countones(row_valid_i) *
                                      $countones(col_valid_i));
    else
      accepted_macs_cycle_o = '0;
  end

  generate
    for (genvar row = 0; row < 16; row++) begin : gen_row
      for (genvar col = 0; col < 16; col++) begin : gen_col
        gqav5_bf16_mul_fp32 i_multiply (
          .a_bf16_i      (p_tile_q[row][k_index_q]),
          .b_bf16_i      (v_bf16_i[col]),
          .product_fp32_o(product[row][col])
        );

        gqav5_fp32_add_rne i_accumulate (
          .a_fp32_i  (accumulator_q[compute_bank_q][row][col]),
          .b_fp32_i  (product[row][col]),
          .sum_fp32_o(accumulated[row][col])
        );
      end
    end
  endgenerate

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_partial_row
      assign partial_row_fp32_o[lane]
        = accumulator_q[partial_bank_q][partial_row_index_q][lane];
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      p_load_active_q        <= 1'b0;
      p_row_index_q          <= '0;
      p_loaded_q             <= 1'b0;
      compute_active_q       <= 1'b0;
      k_index_q              <= '0;
      output_tile_index_q    <= '0;
      compute_bank_q          <= 1'b0;
      partial_bank_ready_q    <= '0;
      completed_output_tile_q[0] <= '0;
      completed_output_tile_q[1] <= '0;
      partial_bank_q          <= 1'b0;
      partial_active_q        <= 1'b0;
      partial_row_index_q     <= '0;
      partial_drained_o       <= 1'b0;
      output_done_o          <= 1'b0;
      accepted_macs_total_o  <= '0;
      p_load_count_o         <= '0;
      v_output_wave_count_o  <= '0;
      protocol_error_o       <= 1'b0;
    end else begin
      output_done_o <= 1'b0;
      partial_drained_o <= 1'b0;

      if (output_start_i && output_start_ready_o && !v_step_valid_i)
        protocol_error_o <= 1'b1;
      if (p_discard_i) begin
        if (!p_loaded_q || p_load_active_q || compute_active_q)
          protocol_error_o <= 1'b1;
        else begin
          p_loaded_q          <= 1'b0;
          output_tile_index_q <= '0;
        end
      end

      if (!partial_active_q) begin
        if (partial_bank_ready_q[partial_bank_q] ||
            (compute_completion && (compute_bank_q == partial_bank_q))) begin
          partial_active_q    <= 1'b1;
          partial_row_index_q <= '0;
        end
      end else if (partial_row_fire) begin
        if (partial_row_index_q == 4'd15) begin
          partial_bank_ready_q[partial_bank_q] <= 1'b0;
          partial_row_index_q <= '0;
          partial_drained_o <= 1'b1;
          if (next_partial_available) begin
            partial_bank_q   <= other_partial_bank;
            partial_active_q <= 1'b1;
          end else begin
            partial_bank_q   <= other_partial_bank;
            partial_active_q <= 1'b0;
          end
        end else begin
          partial_row_index_q <= partial_row_index_q + 4'd1;
        end
      end

      if (p_start_fire) begin
        p_load_active_q <= 1'b1;
        p_row_index_q   <= '0;
        if (!p_row_valid_i)
          protocol_error_o <= 1'b1;
        else begin
          for (int unsigned col = 0; col < 16; col++)
            p_tile_q[0][col] <= p_row_bf16_i[col];
          p_row_index_q <= 4'd1;
        end
      end else if (p_load_active_q) begin
        if (p_row_valid_i) begin
          for (int unsigned col = 0; col < 16; col++)
            p_tile_q[p_row_index_q][col] <= p_row_bf16_i[col];
          if (p_row_index_q == 4'd15) begin
            p_load_active_q <= 1'b0;
            p_row_index_q   <= '0;
            p_loaded_q      <= 1'b1;
            p_load_count_o  <= p_load_count_o + 64'd1;
          end else begin
            p_row_index_q <= p_row_index_q + 4'd1;
          end
        end
      end

      if (output_start_fire) begin
        for (int unsigned row = 0; row < 16; row++) begin
          for (int unsigned col = 0; col < 16; col++) begin
            if (v_step_valid_i && row_valid_i[row] && col_valid_i[col])
              accumulator_q[compute_bank_q][row][col]
                <= product[row][col];
            else
              accumulator_q[compute_bank_q][row][col] <= '0;
          end
        end
        if (v_step_valid_i)
          accepted_macs_total_o <= accepted_macs_total_o +
                                   64'(accepted_macs_cycle_o);

        if (K_STEPS == 1) begin
          compute_active_q      <= 1'b0;
          output_done_o         <= 1'b1;
          partial_bank_ready_q[compute_bank_q] <= 1'b1;
          completed_output_tile_q[compute_bank_q] <= output_tile_index_q;
          compute_bank_q        <= ~compute_bank_q;
          v_output_wave_count_o <= v_output_wave_count_o + 64'd1;
          if (output_tile_index_q == OUTPUT_W'(OUTPUT_TILES - 1)) begin
            output_tile_index_q <= '0;
            p_loaded_q          <= 1'b0;
          end else begin
            output_tile_index_q <= output_tile_index_q + OUTPUT_W'(1);
          end
        end else begin
          compute_active_q <= 1'b1;
          k_index_q        <= K_W'(1);
        end
      end else if (compute_active_q) begin
        if (v_step_valid_i) begin
          for (int unsigned row = 0; row < 16; row++) begin
            for (int unsigned col = 0; col < 16; col++) begin
              if (row_valid_i[row] && col_valid_i[col])
                accumulator_q[compute_bank_q][row][col]
                  <= accumulated[row][col];
            end
          end
          accepted_macs_total_o <= accepted_macs_total_o +
                                   64'(accepted_macs_cycle_o);
          if (k_index_q == K_W'(K_STEPS - 1)) begin
            compute_active_q      <= 1'b0;
            k_index_q             <= '0;
            output_done_o         <= 1'b1;
            partial_bank_ready_q[compute_bank_q] <= 1'b1;
            completed_output_tile_q[compute_bank_q] <= output_tile_index_q;
            compute_bank_q        <= ~compute_bank_q;
            v_output_wave_count_o <= v_output_wave_count_o + 64'd1;
            if (output_tile_index_q == OUTPUT_W'(OUTPUT_TILES - 1)) begin
              output_tile_index_q <= '0;
              p_loaded_q          <= 1'b0;
            end else begin
              output_tile_index_q <= output_tile_index_q + OUTPUT_W'(1);
            end
          end else begin
            k_index_q <= k_index_q + K_W'(1);
          end
        end
      end
    end
  end

  initial begin
    if (K_STEPS < 1 || K_STEPS > 16)
      $error("PV K_STEPS must be in [1,16] for the stationary P tile");
    if (OUTPUT_TILES < 1)
      $error("PV OUTPUT_TILES must be >= 1");
  end
endmodule
