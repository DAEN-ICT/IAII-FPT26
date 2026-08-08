module gqav5_pv_partitioned_p_stationary_16x16 #(
  parameter int unsigned K_STEPS        = 16,
  parameter int unsigned OUTPUT_TILES   = 8,
  parameter int unsigned ROW_PARTITIONS = 4,
  localparam int unsigned K_W = (K_STEPS <= 1) ? 1 : $clog2(K_STEPS),
  localparam int unsigned OUTPUT_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES),
  localparam int unsigned ROWS_PER_PARTITION = 16 / ROW_PARTITIONS
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
  input  logic [15:0]       v_partition_bf16_i [ROW_PARTITIONS][16],
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
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic p_load_active_q;
  logic [3:0] p_row_index_q;
  logic p_loaded_q;
  // P and arithmetic payload arrays deliberately have no reset network.
  logic [15:0] p_tile_q [16][16];
  logic compute_active_q;
  logic [K_W-1:0] k_index_q;
  logic [OUTPUT_W-1:0] output_tile_index_q;
  // One fixed accumulator bank keeps the output-slot selector out of every
  // FP32 recurrence.  Two result banks preserve compute/drain overlap.
  logic [31:0] compute_accumulator_q [16][16];
  logic [31:0] result_accumulator_q [2][16][16];
  logic [31:0] product_comb [16][16];
  logic [31:0] product_q [16][16];
  logic [31:0] accumulated [16][16];
  logic product_valid_q;
  logic product_last_q;
  // V5.2: per-PE FF controls replace the former LUT1 replication tree.
  (* dont_touch = "yes" *) logic capture_bank_local [16][16];
  (* dont_touch = "yes" *) logic product_valid_local [16][16];
  (* dont_touch = "yes" *) logic product_first_local [16][16];
  (* dont_touch = "yes" *) logic product_last_local [16][16];
  (* dont_touch = "yes" *) logic product_row_valid_local [16][16];
  (* dont_touch = "yes" *) logic product_col_valid_local [16][16];
  logic p_start_fire;
  logic output_start_fire;
  logic v_step_accept;
  logic capture_bank_q;
  // Keep the completed-tile bank select local.  Without this preserved
  // two-level tree one control bit drives both 32-bit snapshot banks in all
  // 256 PEs and Vivado promotes it onto global clock resources.
  logic [1:0] partial_bank_ready_q;
  logic [OUTPUT_W-1:0] completed_output_tile_q [2];
  logic partial_bank_q;
  logic partial_active_q;
  logic [3:0] partial_row_index_q;
  logic partial_row_fire;
  logic compute_completion;
  logic start_capture_bank;
  logic other_partial_bank;
  logic next_partial_available;
  logic [3:0] partial_row_index_local [16];
  logic partial_bank_local [16];

  assign p_start_ready_o = !p_loaded_q && !p_load_active_q &&
                           !compute_active_q && !product_valid_q;
  assign p_row_ready_o = p_load_active_q || (p_start_i && p_start_ready_o);
  assign p_start_fire = p_start_i && p_start_ready_o;
  assign p_loaded_o = p_loaded_q;

  // Commit the previous final product and accept the next output tile's first
  // V step on the same edge.  Reserve the post-completion capture bank so the
  // extra product register does not turn the 16-cycle tile II into 17 cycles.
  assign start_capture_bank = compute_completion
      ? ~capture_bank_q : capture_bank_q;
  assign output_start_ready_o = p_loaded_q && !compute_active_q &&
      (!product_valid_q || compute_completion) &&
      ((!partial_bank_ready_q[start_capture_bank]) ||
       (partial_row_fire && (partial_row_index_q == 4'd15) &&
        (partial_bank_q == start_capture_bank)));
  assign output_start_fire = output_start_i && output_start_ready_o &&
                             v_step_valid_i;
  assign v_step_ready_o = compute_active_q || output_start_fire;
  assign v_step_accept = v_step_valid_i && v_step_ready_o;
  assign active_o = compute_active_q || product_valid_q;
  assign output_tile_index_o = output_tile_index_q;
  assign partial_row_valid_o = partial_active_q;
  assign partial_row_index_o = partial_row_index_q;
  assign partial_row_output_tile_o = completed_output_tile_q[partial_bank_q];
  assign partial_row_bank_o = partial_bank_q;
  assign partial_row_fire = partial_row_valid_o && partial_row_ready_i;
  assign compute_completion = product_valid_q && product_last_q;
  assign other_partial_bank = ~partial_bank_q;
  assign next_partial_available =
      partial_bank_ready_q[other_partial_bank] ||
      (compute_completion && (capture_bank_q == other_partial_bank));

  always_comb begin
    if (v_step_accept)
      accepted_macs_cycle_o =
          9'($countones(row_valid_i) * $countones(col_valid_i));
    else
      accepted_macs_cycle_o = '0;
  end

  gqav5_local_accumulator64_9bit i_accepted_mac_counter (
    .clk_i,
    .rst_ni,
    .add_valid_i(v_step_accept),
    .add_value_i(accepted_macs_cycle_o),
    .count_o(accepted_macs_total_o)
  );

  generate
    for (genvar row = 0; row < 16; row++) begin : gen_row
      localparam int unsigned PARTITION = row / ROWS_PER_PARTITION;
      for (genvar col = 0; col < 16; col++) begin : gen_col
        // Static elaboration binds each four-row P region to one V bank.
        // Each V lane therefore fans out to four rows, not all sixteen.
        gqav5_bf16_mul_fp32 i_multiply (
          .a_bf16_i      (p_tile_q[row][4'(k_index_q)]),
          .b_bf16_i      (v_partition_bf16_i[PARTITION][col]),
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
    for (genvar lane = 0; lane < 16; lane++) begin : gen_partial_row
      gqav5_local_control_buffer i_partial_bank_buffer (
        .in_i (partial_bank_q),
        .out_o(partial_bank_local[lane])
      );
      for (genvar bit_index = 0; bit_index < 4;
           bit_index++) begin : gen_partial_index_bit
        gqav5_local_control_buffer i_partial_index_buffer (
          .in_i (partial_row_index_q[bit_index]),
          .out_o(partial_row_index_local[lane][bit_index])
        );
      end
      assign partial_row_fp32_o[lane] =
          result_accumulator_q[partial_bank_local[lane]]
                              [partial_row_index_local[lane]][lane];
    end
  endgenerate

  // Local payload pipeline.  product_q and product_valid_local are written
  // every cycle so that no 8192-load CE tree is introduced.
  always_ff @(posedge clk_i) begin : p_local_payload
    if (p_start_fire && p_row_valid_i) begin
      for (int unsigned col = 0; col < 16; col++)
        p_tile_q[0][col] <= p_row_bf16_i[col];
    end else if (p_load_active_q && p_row_valid_i) begin
      for (int unsigned col = 0; col < 16; col++)
        p_tile_q[p_row_index_q][col] <= p_row_bf16_i[col];
    end

    for (int unsigned row = 0; row < 16; row++) begin
      for (int unsigned col = 0; col < 16; col++) begin
        product_q[row][col] <= product_comb[row][col];
        capture_bank_local[row][col] <= start_capture_bank;
        product_valid_local[row][col] <= v_step_accept;
        product_first_local[row][col] <= output_start_fire;
        product_last_local[row][col] <= v_step_accept &&
            ((output_start_fire && (K_STEPS == 1)) ||
             (compute_active_q &&
              (k_index_q == K_W'(K_STEPS - 1))));
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
      p_load_active_q <= 1'b0;
      p_row_index_q <= '0;
      p_loaded_q <= 1'b0;
      compute_active_q <= 1'b0;
      k_index_q <= '0;
      output_tile_index_q <= '0;
      capture_bank_q <= 1'b0;
      product_valid_q <= 1'b0;
      product_last_q <= 1'b0;
      partial_bank_ready_q <= '0;
      completed_output_tile_q[0] <= '0;
      completed_output_tile_q[1] <= '0;
      partial_bank_q <= 1'b0;
      partial_active_q <= 1'b0;
      partial_row_index_q <= '0;
      partial_drained_o <= 1'b0;
      output_done_o <= 1'b0;
      p_load_count_o <= '0;
      v_output_wave_count_o <= '0;
      protocol_error_o <= 1'b0;
    end else begin
      output_done_o <= 1'b0;
      partial_drained_o <= 1'b0;
      product_valid_q <= v_step_accept;
      product_last_q <= v_step_accept &&
          ((output_start_fire && (K_STEPS == 1)) ||
           (compute_active_q &&
            (k_index_q == K_W'(K_STEPS - 1))));

      if (output_start_i && output_start_ready_o && !v_step_valid_i)
        protocol_error_o <= 1'b1;
      if (p_discard_i) begin
        if (!p_loaded_q || p_load_active_q || compute_active_q ||
            product_valid_q)
          protocol_error_o <= 1'b1;
        else begin
          p_loaded_q <= 1'b0;
          output_tile_index_q <= '0;
        end
      end

      if (!partial_active_q) begin
        if (partial_bank_ready_q[partial_bank_q] ||
            (compute_completion && (capture_bank_q == partial_bank_q))) begin
          partial_active_q <= 1'b1;
          partial_row_index_q <= '0;
        end
      end else if (partial_row_fire) begin
        if (partial_row_index_q == 4'd15) begin
          partial_bank_ready_q[partial_bank_q] <= 1'b0;
          partial_row_index_q <= '0;
          partial_drained_o <= 1'b1;
          if (next_partial_available) begin
            partial_bank_q <= other_partial_bank;
            partial_active_q <= 1'b1;
          end else begin
            partial_bank_q <= other_partial_bank;
            partial_active_q <= 1'b0;
          end
        end else begin
          partial_row_index_q <= partial_row_index_q + 4'd1;
        end
      end

      if (p_start_fire) begin
        p_load_active_q <= 1'b1;
        p_row_index_q <= '0;
        if (!p_row_valid_i) begin
          protocol_error_o <= 1'b1;
        end else begin
          p_row_index_q <= 4'd1;
        end
      end else if (p_load_active_q && p_row_valid_i) begin
        if (p_row_index_q == 4'd15) begin
          p_load_active_q <= 1'b0;
          p_row_index_q <= '0;
          p_loaded_q <= 1'b1;
          p_load_count_o <= p_load_count_o + 64'd1;
        end else begin
          p_row_index_q <= p_row_index_q + 4'd1;
        end
      end

      if (output_start_fire) begin
        if (K_STEPS == 1) begin
          compute_active_q <= 1'b0;
          k_index_q <= '0;
        end else begin
          compute_active_q <= 1'b1;
          k_index_q <= K_W'(1);
        end
      end else if (compute_active_q && v_step_valid_i) begin
        if (k_index_q == K_W'(K_STEPS - 1)) begin
          compute_active_q <= 1'b0;
          k_index_q <= '0;
        end else begin
          k_index_q <= k_index_q + K_W'(1);
        end
      end

      if (compute_completion) begin
        output_done_o <= 1'b1;
        partial_bank_ready_q[capture_bank_q] <= 1'b1;
        completed_output_tile_q[capture_bank_q] <= output_tile_index_q;
        capture_bank_q <= ~capture_bank_q;
        v_output_wave_count_o <= v_output_wave_count_o + 64'd1;
        if (output_tile_index_q == OUTPUT_W'(OUTPUT_TILES - 1)) begin
          output_tile_index_q <= '0;
          p_loaded_q <= 1'b0;
        end else begin
          output_tile_index_q <= output_tile_index_q + OUTPUT_W'(1);
        end
      end
    end
  end

  initial begin
    if (K_STEPS < 1 || K_STEPS > 16)
      $error("partitioned PV K_STEPS must be in [1,16]");
    if (OUTPUT_TILES < 1)
      $error("partitioned PV OUTPUT_TILES must be >= 1");
    if (ROW_PARTITIONS < 1 || ROW_PARTITIONS > 16 ||
        (16 % ROW_PARTITIONS) != 0)
      $error("partitioned PV ROW_PARTITIONS must divide 16");
  end
endmodule
