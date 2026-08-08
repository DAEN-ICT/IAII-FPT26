module gqav5_bf16_mul_fp32 (
  input  logic [15:0] a_bf16_i,
  input  logic [15:0] b_bf16_i,
  output logic [31:0] product_fp32_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic       a_nan;
  logic       b_nan;
  logic       a_inf;
  logic       b_inf;
  logic       a_zero;
  logic       b_zero;
  logic       product_sign;
  logic [7:0] a_sig;
  logic [7:0] b_sig;
  (* use_dsp = "yes" *) logic [15:0] significand_product;
  // 正常 BF16 指数计算范围为 -125..381，规格化后最大 382；
  // 10 位有符号数可完整覆盖，避免每个乘法 lane 保留无效高位。
  logic signed [9:0] exponent_sum;
  logic signed [9:0] normalized_exponent;
  logic [22:0] fraction;

  assign a_nan = (a_bf16_i[14:7] == 8'hff) && (a_bf16_i[6:0] != '0);
  assign b_nan = (b_bf16_i[14:7] == 8'hff) && (b_bf16_i[6:0] != '0);
  assign a_inf = (a_bf16_i[14:7] == 8'hff) && (a_bf16_i[6:0] == '0);
  assign b_inf = (b_bf16_i[14:7] == 8'hff) && (b_bf16_i[6:0] == '0);
  // V4.1 compatibility mode flushes BF16 subnormals to signed zero.
  assign a_zero = (a_bf16_i[14:7] == 8'h00);
  assign b_zero = (b_bf16_i[14:7] == 8'h00);
  assign product_sign = a_bf16_i[15] ^ b_bf16_i[15];
  assign a_sig = {1'b1, a_bf16_i[6:0]};
  assign b_sig = {1'b1, b_bf16_i[6:0]};
  assign significand_product = a_sig * b_sig;
  assign exponent_sum = $signed({2'b00, a_bf16_i[14:7]}) +
                        $signed({2'b00, b_bf16_i[14:7]}) - 10'sd127;

  always_comb begin
    normalized_exponent = exponent_sum;
    fraction            = '0;
    if (significand_product[15]) begin
      normalized_exponent = exponent_sum + 10'sd1;
      fraction            = {significand_product[14:0], 8'h00};
    end else begin
      fraction = {significand_product[13:0], 9'h000};
    end

    if (a_nan || b_nan || ((a_inf || b_inf) && (a_zero || b_zero)))
      product_fp32_o = 32'h7fc0_0000;
    else if (a_inf || b_inf)
      product_fp32_o = {product_sign, 8'hff, 23'h0};
    else if (a_zero || b_zero)
      product_fp32_o = {product_sign, 31'h0};
    else if (normalized_exponent >= 10'sd255)
      product_fp32_o = {product_sign, 8'hff, 23'h0};
    else if (normalized_exponent <= 0)
      product_fp32_o = {product_sign, 31'h0};
    else
      product_fp32_o = {product_sign, normalized_exponent[7:0], fraction};
  end
endmodule
