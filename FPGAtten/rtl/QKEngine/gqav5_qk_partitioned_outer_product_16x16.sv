module gqav5_qk_partitioned_outer_product_16x16 #(
  parameter int unsigned K_STEPS       = 128,
  parameter int unsigned ROW_PARTITIONS = 4,
  localparam int unsigned K_W = (K_STEPS <= 1) ? 1 : $clog2(K_STEPS),
  localparam int unsigned ROWS_PER_PARTITION = 16 / ROW_PARTITIONS
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              start_i,
  output logic              start_ready_o,
  input  logic              step_valid_i,
  output logic              step_ready_o,
  input  logic [15:0]       a_bf16_i [16],
  input  logic [15:0]       b_partition_bf16_i [ROW_PARTITIONS][16],
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
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic active_q;
  logic [K_W-1:0] k_index_q;
  // The arithmetic feedback loop has one fixed, physically local accumulator
  // per PE.  Completed tiles are copied into two independent drain banks.
  // This deliberately spends one additional 16x16x32 FF bank to remove the
  // old compute-bank select from all 256 FP32 adders.
  logic [31:0] compute_accumulator_q [16][16];
  logic [31:0] result_accumulator_q [2][16][16];
  logic [31:0] product_comb [16][16];
  // A reset-free product register cuts the DSP/formatting path away from the
  // FP32 recurrence.  product_valid_q is the sole ownership qualifier.
  logic [31:0] product_q [16][16];
  logic [31:0] accumulated [16][16];
  logic product_valid_q;
  logic product_last_q;
  // V5.2: use per-PE control FFs instead of two levels of LUT1 replicas.
  // The extra FFs align with product_q on the same edge and turn each wide
  // accumulator CE/select net into a local one-load route.
  (* dont_touch = "yes" *) logic capture_bank_local [16][16];
  (* dont_touch = "yes" *) logic product_valid_local [16][16];
  (* dont_touch = "yes" *) logic product_first_local [16][16];
  (* dont_touch = "yes" *) logic product_last_local [16][16];
  (* dont_touch = "yes" *) logic product_row_valid_local [16][16];
  (* dont_touch = "yes" *) logic product_col_valid_local [16][16];
  logic start_fire;
  logic step_accept;
  logic capture_bank_q;
  // capture_bank_q changes only once per completed tile, but an unbuffered
  // copy-select would still drive both 32-bit result banks in every PE.  A
  // two-level preserved LUT tree limits the root fanout to four, each row
  // cluster to 64 PE leaves, and each leaf to one local 64-bit bank select.
  logic [1:0] result_bank_ready_q;
  logic result_bank_q;
  logic result_active_q;
  logic [3:0] result_row_index_q;
  logic result_row_fire;
  logic compute_completion;
  logic start_capture_bank;
  logic other_result_bank;
  logic next_result_available;
  logic [3:0] result_row_index_local [16];
  logic result_bank_local [16];

  // The previous tile's final registered product may commit while the next
  // tile accepts its first operands.  The new wave reserves the bank that
  // capture_bank_q will select after that same completion edge.
  assign start_capture_bank = compute_completion
      ? ~capture_bank_q : capture_bank_q;
  assign start_ready_o = !active_q &&
      (!product_valid_q || compute_completion) &&
      ((!result_bank_ready_q[start_capture_bank]) ||
       (result_row_fire && (result_row_index_q == 4'd15) &&
        (result_bank_q == start_capture_bank)));
  assign step_ready_o = active_q || (start_i && start_ready_o);
  assign start_fire = start_i && start_ready_o && step_valid_i;
  assign step_accept = step_valid_i && step_ready_o;
  assign active_o = active_q || product_valid_q;
  assign result_row_valid_o = result_active_q;
  assign result_row_index_o = result_row_index_q;
  assign result_row_bank_o = result_bank_q;
  // The descriptor bank identifies the result snapshot slot reserved for the
  // next wave.  It no longer selects the live arithmetic accumulator.
  assign next_compute_bank_o = capture_bank_q;
  assign result_row_fire = result_row_valid_o && result_row_ready_i;
  assign compute_completion = product_valid_q && product_last_q;
  assign other_result_bank = ~result_bank_q;
  assign next_result_available =
      result_bank_ready_q[other_result_bank] ||
      (compute_completion && (capture_bank_q == other_result_bank));

  always_comb begin
    if (step_accept)
      accepted_macs_cycle_o =
          9'($countones(row_valid_i) * $countones(col_valid_i));
    else
      accepted_macs_cycle_o = '0;
  end

  gqav5_local_accumulator64_9bit i_accepted_mac_counter (
    .clk_i,
    .rst_ni,
    .add_valid_i(step_accept),
    .add_value_i(accepted_macs_cycle_o),
    .count_o(accepted_macs_total_o)
  );

  generate
    for (genvar row = 0; row < 16; row++) begin : gen_row
      localparam int unsigned PARTITION = row / ROWS_PER_PARTITION;
      for (genvar col = 0; col < 16; col++) begin : gen_col
        // Each K lane drives only its four local Q rows in the 4-way decode
        // configuration.  There is no run-time partition-select mux here.
        gqav5_bf16_mul_fp32 i_multiply (
          .a_bf16_i      (a_bf16_i[row]),
          .b_bf16_i      (b_partition_bf16_i[PARTITION][col]),
          .product_fp32_o(product_comb[row][col])
        );

        gqav5_fp32_add_rne i_accumulate (
          .a_fp32_i  (compute_accumulator_q[row][col]),
          .b_fp32_i  (product_q[row][col]),
          .sum_fp32_o(accumulated[row][col])
        );
      end
    end
  endgenerate

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_result_row
      gqav5_local_control_buffer i_result_bank_buffer (
        .in_i (result_bank_q),
        .out_o(result_bank_local[lane])
      );
      for (genvar bit_index = 0; bit_index < 4;
           bit_index++) begin : gen_result_index_bit
        gqav5_local_control_buffer i_result_index_buffer (
          .in_i (result_row_index_q[bit_index]),
          .out_o(result_row_index_local[lane][bit_index])
        );
      end
      assign result_row_fp32_o[lane] =
          result_accumulator_q[result_bank_local[lane]]
                              [result_row_index_local[lane]][lane];
    end
  endgenerate

  // Payload state is reset-free.  The per-PE valid FF is overwritten every
  // cycle; resettable ownership/FSM state makes pre-reset payload unobservable.
  always_ff @(posedge clk_i) begin : p_local_payload
    for (int unsigned row = 0; row < 16; row++) begin
      for (int unsigned col = 0; col < 16; col++) begin
        // Intentionally unconditional: this creates local data FFs instead of
        // an 8192-load product clock-enable tree.
        product_q[row][col] <= product_comb[row][col];
        capture_bank_local[row][col] <= start_capture_bank;
        product_valid_local[row][col] <= step_accept;
        product_first_local[row][col] <= start_fire;
        product_last_local[row][col] <= step_accept &&
            ((start_fire && (K_STEPS == 1)) ||
             (active_q && (k_index_q == K_W'(K_STEPS - 1))));
        product_row_valid_local[row][col] <= row_valid_i[row];
        product_col_valid_local[row][col] <= col_valid_i[col];
      end
    end

    for (int unsigned row = 0; row < 16; row++) begin
      for (int unsigned col = 0; col < 16; col++) begin
        if (product_valid_local[row][col]) begin
          if (product_first_local[row][col] &&
              product_last_local[row][col]) begin
            if (!capture_bank_local[row][col]) begin
              if (product_row_valid_local[row][col] &&
                  product_col_valid_local[row][col])
                result_accumulator_q[0][row][col] <= product_q[row][col];
              else
                result_accumulator_q[0][row][col] <= '0;
            end else begin
              if (product_row_valid_local[row][col] &&
                  product_col_valid_local[row][col])
                result_accumulator_q[1][row][col] <= product_q[row][col];
              else
                result_accumulator_q[1][row][col] <= '0;
            end
          end else if (product_first_local[row][col]) begin
            if (product_row_valid_local[row][col] &&
                product_col_valid_local[row][col])
              compute_accumulator_q[row][col] <= product_q[row][col];
            else
              compute_accumulator_q[row][col] <= '0;
          end else if (product_last_local[row][col]) begin
            if (!capture_bank_local[row][col]) begin
              if (product_row_valid_local[row][col] &&
                  product_col_valid_local[row][col])
                result_accumulator_q[0][row][col] <= accumulated[row][col];
              else
                result_accumulator_q[0][row][col] <= '0;
            end else begin
              if (product_row_valid_local[row][col] &&
                  product_col_valid_local[row][col])
                result_accumulator_q[1][row][col] <= accumulated[row][col];
              else
                result_accumulator_q[1][row][col] <= '0;
            end
          end else if (product_row_valid_local[row][col] &&
                       product_col_valid_local[row][col]) begin
            compute_accumulator_q[row][col] <= accumulated[row][col];
          end
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q              <= 1'b0;
      k_index_q             <= '0;
      done_o                <= 1'b0;
      capture_bank_q        <= 1'b0;
      product_valid_q       <= 1'b0;
      product_last_q        <= 1'b0;
      result_bank_ready_q   <= '0;
      result_bank_q         <= 1'b0;
      result_active_q       <= 1'b0;
      result_row_index_q    <= '0;
      result_drained_o      <= 1'b0;
      completed_tiles_o     <= '0;
      protocol_error_o      <= 1'b0;
    end else begin
      done_o <= 1'b0;
      result_drained_o <= 1'b0;
      product_valid_q <= step_accept;
      product_last_q <= step_accept &&
          ((start_fire && (K_STEPS == 1)) ||
           (active_q && (k_index_q == K_W'(K_STEPS - 1))));

      if (start_i && !start_ready_o)
        protocol_error_o <= 1'b1;
      if (start_i && start_ready_o && !step_valid_i)
        protocol_error_o <= 1'b1;

      if (!result_active_q) begin
        if (result_bank_ready_q[result_bank_q] ||
            (compute_completion && (capture_bank_q == result_bank_q))) begin
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
        if (K_STEPS == 1) begin
          active_q <= 1'b0;
          k_index_q <= '0;
        end else begin
          active_q <= 1'b1;
          k_index_q <= K_W'(1);
        end
      end else if (active_q && step_valid_i) begin
        if (k_index_q == K_W'(K_STEPS - 1)) begin
          active_q <= 1'b0;
          k_index_q <= '0;
        end else begin
          k_index_q <= k_index_q + K_W'(1);
        end
      end

      if (compute_completion) begin
        done_o <= 1'b1;
        result_bank_ready_q[capture_bank_q] <= 1'b1;
        capture_bank_q <= ~capture_bank_q;
        completed_tiles_o <= completed_tiles_o + 64'd1;
      end
    end
  end

  initial begin
    if (K_STEPS < 1)
      $error("partitioned QK requires K_STEPS >= 1");
    if (ROW_PARTITIONS < 1 || ROW_PARTITIONS > 16 ||
        (16 % ROW_PARTITIONS) != 0)
      $error("partitioned QK ROW_PARTITIONS must divide 16");
  end
endmodule
