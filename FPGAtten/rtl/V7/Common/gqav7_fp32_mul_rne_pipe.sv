module gqav7_fp32_mul_rne_pipe (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        advance_i,
  input  logic        valid_i,
  input  logic [31:0] a_fp32_i,
  input  logic [31:0] b_fp32_i,
  output logic        valid_o,
  output logic [31:0] product_fp32_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef struct packed {
    logic               special;
    logic [31:0]        special_value;
    logic               sign;
    logic signed [10:0] exponent;
    logic [47:0]        significand_product;
  } multiply_meta_t;

  typedef struct packed {
    logic               special;
    logic [31:0]        special_value;
    logic               sign;
    logic signed [10:0] exponent;
    logic [23:0]        significand;
    logic               guard_bit;
    logic               sticky_bit;
  } normalize_meta_t;

  logic            s0_valid_q;
  logic            s1_valid_q;
  multiply_meta_t  s0_q;
  normalize_meta_t s1_q;
  (* use_dsp = "yes" *) logic [47:0] significand_product_w;

  assign significand_product_w =
      {1'b1, a_fp32_i[22:0]} * {1'b1, b_fp32_i[22:0]};

  // Keep reset off the wide arithmetic payload.  The valid pipeline is the
  // sole ownership marker, so payload values written while reset is asserted
  // are unobservable.  Keeping these in separate processes prevents rst_ni
  // from becoming a reset/CE tree across every QK, PV and output FP32 lane.
  always_ff @(posedge clk_i) begin : p_valid
    if (!rst_ni) begin
      s0_valid_q <= 1'b0;
      s1_valid_q <= 1'b0;
      valid_o    <= 1'b0;
    end else if (advance_i) begin
      s0_valid_q <= valid_i;
      s1_valid_q <= s0_valid_q;
      valid_o    <= s1_valid_q;
    end
  end

  always_ff @(posedge clk_i) begin : p_payload
    logic        a_nan;
    logic        b_nan;
    logic        a_inf;
    logic        b_inf;
    logic        a_zero;
    logic        b_zero;
    logic [24:0] rounded_ext;
    logic [23:0] rounded_sig;
    logic signed [10:0] rounded_exp;
    logic        round_increment;

    if (advance_i) begin
      a_nan  = (a_fp32_i[30:23] == 8'hff) &&
               (a_fp32_i[22:0] != '0);
      b_nan  = (b_fp32_i[30:23] == 8'hff) &&
               (b_fp32_i[22:0] != '0);
      a_inf  = (a_fp32_i[30:23] == 8'hff) &&
               (a_fp32_i[22:0] == '0);
      b_inf  = (b_fp32_i[30:23] == 8'hff) &&
               (b_fp32_i[22:0] == '0);
      a_zero = (a_fp32_i[30:23] == 8'h00);
      b_zero = (b_fp32_i[30:23] == 8'h00);

      s0_q.special <= a_nan || b_nan ||
                      ((a_inf || b_inf) && (a_zero || b_zero)) ||
                      a_inf || b_inf || a_zero || b_zero;
      if (a_nan || b_nan ||
          ((a_inf || b_inf) && (a_zero || b_zero)))
        s0_q.special_value <= 32'h7fc0_0000;
      else if (a_inf || b_inf)
        s0_q.special_value <= {
          a_fp32_i[31] ^ b_fp32_i[31], 8'hff, 23'h0
        };
      else
        s0_q.special_value <= {
          a_fp32_i[31] ^ b_fp32_i[31], 31'h0
        };
      s0_q.sign <= a_fp32_i[31] ^ b_fp32_i[31];
      s0_q.exponent <=
          $signed({3'b000, a_fp32_i[30:23]}) +
          $signed({3'b000, b_fp32_i[30:23]}) - 11'sd127;
      s0_q.significand_product <= significand_product_w;

      s1_q.special       <= s0_q.special;
      s1_q.special_value <= s0_q.special_value;
      s1_q.sign          <= s0_q.sign;
      if (s0_q.significand_product[47]) begin
        s1_q.exponent    <= s0_q.exponent + 11'sd1;
        s1_q.significand <= s0_q.significand_product[47:24];
        s1_q.guard_bit   <= s0_q.significand_product[23];
        s1_q.sticky_bit  <= |s0_q.significand_product[22:0];
      end else begin
        s1_q.exponent    <= s0_q.exponent;
        s1_q.significand <= s0_q.significand_product[46:23];
        s1_q.guard_bit   <= s0_q.significand_product[22];
        s1_q.sticky_bit  <= |s0_q.significand_product[21:0];
      end

      round_increment = s1_q.guard_bit &&
                        (s1_q.sticky_bit || s1_q.significand[0]);
      rounded_ext = {1'b0, s1_q.significand} +
                    25'(round_increment);
      rounded_exp = s1_q.exponent;
      if (rounded_ext[24]) begin
        rounded_sig = rounded_ext[24:1];
        rounded_exp = s1_q.exponent + 11'sd1;
      end else begin
        rounded_sig = rounded_ext[23:0];
      end

      if (s1_q.special)
        product_fp32_o <= s1_q.special_value;
      else if (rounded_exp >= 11'sd255)
        product_fp32_o <= {s1_q.sign, 8'hff, 23'h0};
      else if (rounded_exp <= 0)
        product_fp32_o <= {s1_q.sign, 31'h0};
      else
        product_fp32_o <= {
          s1_q.sign, rounded_exp[7:0], rounded_sig[22:0]
        };
    end
  end
endmodule
