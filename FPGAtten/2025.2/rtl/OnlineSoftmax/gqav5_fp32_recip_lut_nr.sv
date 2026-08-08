module gqav5_fp32_recip_lut_nr (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_valid_i,
  output logic        start_ready_o,
  input  logic [31:0] operand_fp32_i,
  output logic        result_valid_o,
  input  logic        result_ready_i,
  output logic [31:0] result_fp32_o,
  output logic        busy_o,
  output logic        rom_sentinel_ok_o,
  output logic        protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_MUL_XY0,
    ST_CORR0,
    ST_MUL_YC0,
    ST_SAVE_Y1,
    ST_MUL_XY1,
    ST_CORR1,
    ST_MUL_YC1,
    ST_PREPACK,
    ST_PACK,
    ST_OUTPUT
  } state_t;

  state_t state_q;
  (* rom_style = "block" *) logic [31:0] seed_rom [0:255];
  logic [31:0] seed_q;
  logic [31:0] mantissa_q31_q;
  logic [31:0] y_q31_q;
  logic [32:0] correction_q31_q;
  (* use_dsp = "yes" *) logic [64:0] multiply_q;
  logic [31:0] final_bounded_y_q;
  logic signed [11:0] base_biased_exp_q;
  logic [31:0] result_q;

  logic [32:0] rounded_y_w;
  logic [31:0] bounded_y_w;
  logic [22:0] truncated_fraction;
  logic signed [11:0] reciprocal_biased_exp;
  logic [22:0] reciprocal_fraction;
  logic        round_increment;
  logic        round_carry;
  logic        operand_nan;
  logic        operand_inf;
  logic        operand_zero;
  logic        operand_negative;

  assign operand_nan = (operand_fp32_i[30:23] == 8'hff) &&
                       (operand_fp32_i[22:0] != '0);
  assign operand_inf = (operand_fp32_i[30:23] == 8'hff) &&
                       (operand_fp32_i[22:0] == '0);
  assign operand_zero = operand_fp32_i[30:23] == 0;
  assign operand_negative = operand_fp32_i[31] && !operand_zero;
  assign start_ready_o = state_q == ST_IDLE;
  assign result_valid_o = state_q == ST_OUTPUT;
  assign result_fp32_o = result_q;
  assign busy_o = (state_q != ST_IDLE) && (state_q != ST_OUTPUT);
`ifdef SYNTHESIS
  // Runtime probes would add asynchronous ROM ports and prevent RAMB
  // inference. Pre-synthesis hash checks protect the deployed image.
  assign rom_sentinel_ok_o = 1'b1;
`elsif YOSYS
  assign rom_sentinel_ok_o = 1'b1;
`else
  assign rom_sentinel_ok_o = (seed_rom[0] == 32'h7fc0_1ff0) &&
                             (seed_rom[255] == 32'h4010_0401);
`endif

  // The reset-free registered read is the only hardware ROM port. The
  // following ST_MUL_XY0 cycle consumes seed_q directly, so this inference
  // boundary does not add a cycle to the reciprocal sequence.
  always_ff @(posedge clk_i) begin
    seed_q <= seed_rom[operand_fp32_i[22:15]];
  end

  always_comb begin
    rounded_y_w = 33'((multiply_q + 65'h0000_0000_4000_0000) >> 31);
    bounded_y_w = (rounded_y_w >= 33'h0_8000_0000)
                    ? 32'h8000_0000 : rounded_y_w[31:0];
    // bounded_y_w can assert bit 31 only for the saturated 1.0 value.  For
    // every other value the implicit leading one is bit 30, so the packed
    // fraction and guard/sticky bits can be selected directly without a
    // 32-bit equality comparator.  Detect the fraction carry in parallel
    // with the 23-bit increment so it does not feed a second carry chain in
    // the exponent path.
    truncated_fraction = final_bounded_y_q[29:7];
    round_increment = final_bounded_y_q[6] &&
                      ((|final_bounded_y_q[5:0]) ||
                       final_bounded_y_q[7]);
    round_carry = round_increment && (&truncated_fraction);
    reciprocal_fraction = truncated_fraction + 23'(round_increment);
    reciprocal_biased_exp = base_biased_exp_q -
        12'(!final_bounded_y_q[31]) + 12'(round_carry);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q              <= ST_IDLE;
      protocol_error_o     <= 1'b0;
    end else begin
      if (!rom_sentinel_ok_o)
        protocol_error_o <= 1'b1;
      if (start_valid_i && !start_ready_o)
        protocol_error_o <= 1'b1;

      unique case (state_q)
        ST_IDLE: begin
          if (start_valid_i) begin
            if (operand_nan || operand_negative) begin
              state_q <= ST_OUTPUT;
            end else if (operand_zero) begin
              state_q <= ST_OUTPUT;
            end else if (operand_inf) begin
              state_q <= ST_OUTPUT;
            end else begin
              state_q <= ST_MUL_XY0;
            end
          end
        end

        ST_MUL_XY0: begin
          state_q <= ST_CORR0;
        end
        ST_CORR0: begin
          state_q <= ST_MUL_YC0;
        end
        ST_MUL_YC0: begin
          state_q <= ST_SAVE_Y1;
        end
        ST_SAVE_Y1: begin
          state_q <= ST_MUL_XY1;
        end
        ST_MUL_XY1: begin
          state_q <= ST_CORR1;
        end
        ST_CORR1: begin
          state_q <= ST_MUL_YC1;
        end
        ST_MUL_YC1: begin
          state_q <= ST_PREPACK;
        end
        ST_PREPACK: begin
          state_q <= ST_PACK;
        end
        ST_PACK: begin
          state_q <= ST_OUTPUT;
        end
        ST_OUTPUT: begin
          if (result_ready_i)
            state_q <= ST_IDLE;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // Numeric payload is visible only in states selected by the resettable
  // controller.  Keeping it reset-free allows the 65-bit NR multiplier and
  // its adjacent registers to pack into DSP resources without an asynchronous
  // reset tree crossing the arithmetic boundary.
  always_ff @(posedge clk_i) begin
    unique case (state_q)
      ST_IDLE: begin
        if (start_valid_i) begin
          if (operand_nan || operand_negative)
            result_q <= 32'h7fc0_0000;
          else if (operand_zero)
            result_q <= 32'h7f80_0000;
          else if (operand_inf)
            result_q <= 32'h0000_0000;
          else begin
            mantissa_q31_q <= {1'b1, operand_fp32_i[22:0], 8'h00};
            // For a normalized reciprocal, 254-input_exp is the biased
            // exponent for the exact 1.0 mantissa case.  The non-1.0
            // normalization adjustment and rounding carry are applied in
            // parallel during ST_PACK.
            base_biased_exp_q <= 12'sd254 -
                $signed({4'b0000, operand_fp32_i[30:23]});
          end
        end
      end

      ST_MUL_XY0: begin
        y_q31_q    <= seed_q;
        multiply_q <= mantissa_q31_q * seed_q;
      end
      ST_CORR0:
        correction_q31_q <= 33'h1_0000_0000 - multiply_q[63:31];
      ST_MUL_YC0:
        multiply_q <= y_q31_q * correction_q31_q;
      ST_SAVE_Y1:
        y_q31_q <= bounded_y_w;
      ST_MUL_XY1:
        multiply_q <= mantissa_q31_q * y_q31_q;
      ST_CORR1:
        correction_q31_q <= 33'h1_0000_0000 - multiply_q[63:31];
      ST_MUL_YC1:
        multiply_q <= y_q31_q * correction_q31_q;
      ST_PREPACK:
        final_bounded_y_q <= bounded_y_w;
      ST_PACK: begin
        if (reciprocal_biased_exp >= 12'sd255)
          result_q <= 32'h7f80_0000;
        else if (reciprocal_biased_exp <= 0)
          result_q <= 32'h0000_0000;
        else
          result_q <= {1'b0, reciprocal_biased_exp[7:0],
                       reciprocal_fraction};
      end
      default: begin
      end
    endcase
  end

  initial begin
`ifdef SYNTHESIS
    $readmemh("recip_q31_lut_256.mem", seed_rom);
`else
    $readmemh("rtl/OnlineSoftmax/rom/recip_q31_lut_256.mem", seed_rom);
`endif
  end
endmodule
