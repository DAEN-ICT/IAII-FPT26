module gqav5_fp32_mul_rne (
  input  logic [31:0] a_fp32_i,
  input  logic [31:0] b_fp32_i,
  output logic [31:0] product_fp32_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic        a_nan;
  logic        b_nan;
  logic        a_inf;
  logic        b_inf;
  logic        a_zero;
  logic        b_zero;
  logic        product_sign;
  logic [23:0] a_sig;
  logic [23:0] b_sig;
  (* use_dsp = "yes" *) logic [47:0] significand_product;
  logic signed [10:0] exponent_sum;

  assign a_nan = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] != '0);
  assign b_nan = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] != '0);
  assign a_inf = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] == '0);
  assign b_inf = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] == '0);
  assign a_zero = (a_fp32_i[30:23] == 8'h00);
  assign b_zero = (b_fp32_i[30:23] == 8'h00);
  assign product_sign = a_fp32_i[31] ^ b_fp32_i[31];
  assign a_sig = {1'b1, a_fp32_i[22:0]};
  assign b_sig = {1'b1, b_fp32_i[22:0]};
  assign significand_product = a_sig * b_sig;
  assign exponent_sum = $signed({3'b000, a_fp32_i[30:23]}) +
                        $signed({3'b000, b_fp32_i[30:23]}) - 11'sd127;

  always_comb begin : p_pack
    logic signed [10:0] normalized_exp;
    logic [23:0] normalized_sig;
    logic        guard_bit;
    logic        sticky_bit;
    logic        round_increment;
    logic [24:0] rounded_ext;

    normalized_exp = exponent_sum;
    normalized_sig = '0;
    guard_bit       = 1'b0;
    sticky_bit      = 1'b0;
    round_increment = 1'b0;
    rounded_ext     = '0;

    if (a_nan || b_nan || ((a_inf || b_inf) && (a_zero || b_zero))) begin
      product_fp32_o = 32'h7fc0_0000;
    end else if (a_inf || b_inf) begin
      product_fp32_o = {product_sign, 8'hff, 23'h0};
    end else if (a_zero || b_zero) begin
      product_fp32_o = {product_sign, 31'h0};
    end else begin
      if (significand_product[47]) begin
        normalized_exp = exponent_sum + 11'sd1;
        normalized_sig = significand_product[47:24];
        guard_bit       = significand_product[23];
        sticky_bit      = |significand_product[22:0];
      end else begin
        normalized_sig = significand_product[46:23];
        guard_bit       = significand_product[22];
        sticky_bit      = |significand_product[21:0];
      end

      round_increment = guard_bit && (sticky_bit || normalized_sig[0]);
      rounded_ext = {1'b0, normalized_sig} + 25'(round_increment);
      if (rounded_ext[24]) begin
        normalized_sig = rounded_ext[24:1];
        normalized_exp = normalized_exp + 11'sd1;
      end else begin
        normalized_sig = rounded_ext[23:0];
      end

      if (normalized_exp >= 11'sd255)
        product_fp32_o = {product_sign, 8'hff, 23'h0};
      else if (normalized_exp <= 0)
        product_fp32_o = {product_sign, 31'h0};
      else
        product_fp32_o = {product_sign, normalized_exp[7:0],
                          normalized_sig[22:0]};
    end
  end
endmodule
