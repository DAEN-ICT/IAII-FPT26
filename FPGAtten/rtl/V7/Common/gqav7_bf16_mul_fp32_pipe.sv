module gqav7_bf16_mul_fp32_pipe (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        valid_i,
  input  logic [15:0] a_bf16_i,
  input  logic [15:0] b_bf16_i,
  output logic        valid_o,
  output logic [31:0] product_fp32_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic s0_valid_q;
  logic s0_nan_q;
  logic s0_inf_q;
  logic s0_zero_q;
  logic s0_sign_q;
  logic [7:0] s0_a_sig_q;
  logic [7:0] s0_b_sig_q;
  logic signed [9:0] s0_exponent_q;

  logic s1_valid_q;
  logic s1_nan_q;
  logic s1_inf_q;
  logic s1_zero_q;
  logic s1_sign_q;
  (* use_dsp = "yes" *) logic [15:0] s1_product_q;
  logic signed [9:0] s1_exponent_q;
  logic signed [9:0] s1_normalized_exponent;

  always_comb begin
    s1_normalized_exponent =
        s1_exponent_q + (s1_product_q[15] ? 10'sd1 : 10'sd0);
  end

  always_ff @(posedge clk_i) begin
    // Only visibility state is reset. Payload registers deliberately keep
    // toggling during reset so rst_ni is not synthesized as a CE on every
    // arithmetic bit across all 64 PEs.
    s0_valid_q <= rst_ni ? valid_i : 1'b0;
    s1_valid_q <= rst_ni ? s0_valid_q : 1'b0;
    valid_o    <= rst_ni ? s1_valid_q : 1'b0;

      s0_nan_q      <= ((a_bf16_i[14:7] == 8'hff) &&
                        (a_bf16_i[6:0] != '0)) ||
                       ((b_bf16_i[14:7] == 8'hff) &&
                        (b_bf16_i[6:0] != '0)) ||
                       ((((a_bf16_i[14:7] == 8'hff) &&
                          (a_bf16_i[6:0] == '0)) ||
                         ((b_bf16_i[14:7] == 8'hff) &&
                          (b_bf16_i[6:0] == '0))) &&
                        ((a_bf16_i[14:7] == 8'h00) ||
                         (b_bf16_i[14:7] == 8'h00)));
      s0_inf_q      <= (((a_bf16_i[14:7] == 8'hff) &&
                         (a_bf16_i[6:0] == '0)) ||
                        ((b_bf16_i[14:7] == 8'hff) &&
                         (b_bf16_i[6:0] == '0)));
      s0_zero_q     <= (a_bf16_i[14:7] == 8'h00) ||
                       (b_bf16_i[14:7] == 8'h00);
      s0_sign_q     <= a_bf16_i[15] ^ b_bf16_i[15];
      s0_a_sig_q    <= {1'b1, a_bf16_i[6:0]};
      s0_b_sig_q    <= {1'b1, b_bf16_i[6:0]};
      s0_exponent_q <= $signed({2'b00, a_bf16_i[14:7]}) +
                       $signed({2'b00, b_bf16_i[14:7]}) - 10'sd127;

      s1_nan_q      <= s0_nan_q;
      s1_inf_q      <= s0_inf_q;
      s1_zero_q     <= s0_zero_q;
      s1_sign_q     <= s0_sign_q;
      s1_product_q  <= s0_a_sig_q * s0_b_sig_q;
      s1_exponent_q <= s0_exponent_q;

      if (s1_nan_q) begin
        product_fp32_o <= 32'h7fc0_0000;
      end else if (s1_inf_q) begin
        product_fp32_o <= {s1_sign_q, 8'hff, 23'h0};
      end else if (s1_zero_q) begin
        product_fp32_o <= {s1_sign_q, 31'h0};
      end else if (s1_normalized_exponent >= 10'sd255) begin
        product_fp32_o <= {s1_sign_q, 8'hff, 23'h0};
      end else if (s1_normalized_exponent <= 0) begin
        product_fp32_o <= {s1_sign_q, 31'h0};
      end else if (s1_product_q[15]) begin
        product_fp32_o <= {
          s1_sign_q,
          s1_normalized_exponent[7:0],
          s1_product_q[14:0],
          8'h00
        };
      end else begin
        product_fp32_o <= {
          s1_sign_q,
          s1_exponent_q[7:0],
          s1_product_q[13:0],
          9'h000
        };
      end
  end
endmodule
