module gqav5_qk_outer_product_16x16 #(
  parameter int unsigned K_STEPS = 128,
  localparam int unsigned K_W = (K_STEPS <= 1) ? 1 : $clog2(K_STEPS)
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              start_i,
  output logic              start_ready_o,
  input  logic              step_valid_i,
  output logic              step_ready_o,
  input  logic [15:0]       a_bf16_i [16],
  input  logic [15:0]       b_bf16_i [16],
  input  logic [15:0]       row_valid_i,
  input  logic [15:0]       col_valid_i,

  output logic              active_o,
  output logic              done_o,
  output logic              result_row_valid_o,
  input  logic              result_row_ready_i,
  output logic [31:0]       result_row_fp32_o [16],
  output logic [3:0]        result_row_index_o,
  output logic              result_row_bank_o,
  output logic              result_drained_o,
  output logic              next_compute_bank_o,
  output logic [8:0]        accepted_macs_cycle_o,
  output logic [63:0]       accepted_macs_total_o,
  output logic [63:0]       completed_tiles_o,
  output logic              protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic              active_q;
  logic [K_W-1:0]    k_index_q;
  // Physical contract: this 256-lane PE state has no reset network.  Every
  // element of the selected bank is overwritten by the first accepted K step.
  logic [31:0]       accumulator_q [2][16][16];
  logic [31:0]       product [16][16];
  logic [31:0]       accumulated [16][16];
  logic              start_fire;
  logic              step_accept;
  logic              compute_bank_q;
  logic [1:0]        result_bank_ready_q;
  logic              result_bank_q;
  logic              result_active_q;
  logic [3:0]        result_row_index_q;
  logic              result_row_fire;
  logic              compute_completion;
  logic              other_result_bank;
  logic              next_result_available;

  assign start_ready_o = !active_q &&
      ((!result_bank_ready_q[compute_bank_q]) ||
       (result_row_fire && (result_row_index_q == 4'd15) &&
        (result_bank_q == compute_bank_q)));
  assign step_ready_o  = active_q || (start_i && start_ready_o);
  // The first reduction vector is part of the launch transaction. A start
  // pulse without data is rejected and, importantly, cannot advance k_index.
  assign start_fire    = start_i && start_ready_o && step_valid_i;
  assign step_accept   = step_valid_i && step_ready_o;
  assign active_o      = active_q;
  assign result_row_valid_o = result_active_q;
  assign result_row_index_o = result_row_index_q;
  assign result_row_bank_o = result_bank_q;
  assign next_compute_bank_o = compute_bank_q;
  assign result_row_fire = result_row_valid_o && result_row_ready_i;
  assign compute_completion =
      (start_fire && (K_STEPS == 1)) ||
      (active_q && step_accept &&
       (k_index_q == K_W'(K_STEPS - 1)));
  assign other_result_bank = ~result_bank_q;
  assign next_result_available =
      result_bank_ready_q[other_result_bank] ||
      (compute_completion && (compute_bank_q == other_result_bank));

  always_comb begin
    if (step_accept)
      accepted_macs_cycle_o = 9'($countones(row_valid_i) *
                                      $countones(col_valid_i));
    else
      accepted_macs_cycle_o = '0;
  end

  generate
    for (genvar row = 0; row < 16; row++) begin : gen_row
      for (genvar col = 0; col < 16; col++) begin : gen_col
        gqav5_bf16_mul_fp32 i_multiply (
          .a_bf16_i     (a_bf16_i[row]),
          .b_bf16_i     (b_bf16_i[col]),
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
    for (genvar lane = 0; lane < 16; lane++) begin : gen_result_row
      assign result_row_fp32_o[lane]
        = accumulator_q[result_bank_q][result_row_index_q][lane];
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q              <= 1'b0;
      k_index_q             <= '0;
      done_o                <= 1'b0;
      compute_bank_q        <= 1'b0;
      result_bank_ready_q   <= '0;
      result_bank_q         <= 1'b0;
      result_active_q       <= 1'b0;
      result_row_index_q    <= '0;
      result_drained_o      <= 1'b0;
      accepted_macs_total_o <= '0;
      completed_tiles_o     <= '0;
      protocol_error_o      <= 1'b0;
    end else begin
      done_o <= 1'b0;
      result_drained_o <= 1'b0;

      if (start_i && !start_ready_o)
        protocol_error_o <= 1'b1;
      if (start_i && start_ready_o && !step_valid_i)
        protocol_error_o <= 1'b1;

      if (!result_active_q) begin
        if (result_bank_ready_q[result_bank_q] ||
            (compute_completion && (compute_bank_q == result_bank_q))) begin
          result_active_q    <= 1'b1;
          result_row_index_q <= '0;
        end
      end else if (result_row_fire) begin
        if (result_row_index_q == 4'd15) begin
          result_bank_ready_q[result_bank_q] <= 1'b0;
          result_row_index_q <= '0;
          result_drained_o   <= 1'b1;
          if (next_result_available) begin
            result_bank_q   <= other_result_bank;
            result_active_q <= 1'b1;
          end else begin
            result_bank_q   <= other_result_bank;
            result_active_q <= 1'b0;
          end
        end else begin
          result_row_index_q <= result_row_index_q + 4'd1;
        end
      end

      if (start_fire) begin
        for (int unsigned row = 0; row < 16; row++) begin
          for (int unsigned col = 0; col < 16; col++) begin
            if (step_valid_i && row_valid_i[row] && col_valid_i[col])
              accumulator_q[compute_bank_q][row][col]
                <= product[row][col];
            else
              accumulator_q[compute_bank_q][row][col] <= '0;
          end
        end
        if (step_valid_i)
          accepted_macs_total_o <= accepted_macs_total_o +
                                   64'(accepted_macs_cycle_o);

        if (K_STEPS == 1) begin
          active_q          <= 1'b0;
          done_o            <= 1'b1;
          result_bank_ready_q[compute_bank_q] <= 1'b1;
          compute_bank_q    <= ~compute_bank_q;
          completed_tiles_o <= completed_tiles_o + 64'd1;
          k_index_q         <= '0;
        end else begin
          active_q  <= 1'b1;
          k_index_q <= K_W'(1);
        end
      end else if (active_q) begin
        if (step_valid_i) begin
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
            active_q          <= 1'b0;
            k_index_q         <= '0;
            done_o            <= 1'b1;
            result_bank_ready_q[compute_bank_q] <= 1'b1;
            compute_bank_q    <= ~compute_bank_q;
            completed_tiles_o <= completed_tiles_o + 64'd1;
          end else begin
            k_index_q <= k_index_q + K_W'(1);
          end
        end
      end
    end
  end

  initial begin
    if (K_STEPS < 1)
      $error("gqav5_qk_outer_product_16x16 requires K_STEPS >= 1");
  end
endmodule
