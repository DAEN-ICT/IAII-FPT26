module gqav7_fp32_add_rne_pipe (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        advance_i,
  input  logic        valid_i,
  input  logic [31:0] a_fp32_i,
  input  logic [31:0] b_fp32_i,
  output logic        valid_o,
  output logic [31:0] sum_fp32_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef struct packed {
    logic special;
    logic [31:0] special_value;
    logic big_sign;
    logic small_sign;
    logic [7:0] big_exp;
    logic [23:0] big_sig;
    logic [23:0] small_sig;
    logic [7:0] exp_delta;
  } compare_meta_t;

  typedef struct packed {
    logic special;
    logic [31:0] special_value;
    logic big_sign;
    logic same_sign;
    logic [7:0] big_exp;
    logic [26:0] big_ext;
    logic [26:0] small_aligned;
  } align_meta_t;

  typedef struct packed {
    logic special;
    logic [31:0] special_value;
    logic sign;
    logic [7:0] exponent;
    logic is_add;
    logic [27:0] add_value;
    logic [26:0] diff_value;
  } add_meta_t;

  typedef struct packed {
    logic special;
    logic [31:0] special_value;
    logic sign;
    logic signed [10:0] exponent;
    logic [26:0] normalized;
  } normalize_meta_t;

  logic s0_valid_q;
  logic s1_valid_q;
  logic s2_valid_q;
  logic s3_valid_q;
  compare_meta_t s0_q;
  align_meta_t s1_q;
  add_meta_t s2_q;
  normalize_meta_t s3_q;

  function automatic logic [26:0] shift_right_sticky(
    input logic [26:0] value,
    input logic [7:0] shift
  );
    logic [53:0] shifted_with_tail;
    begin
      shifted_with_tail = '0;
      if (shift == 0) begin
        shift_right_sticky = value;
      end else if (shift >= 8'd27) begin
        shift_right_sticky = {26'b0, |value};
      end else begin
        shifted_with_tail = {value, 27'b0} >> shift[4:0];
        shift_right_sticky = shifted_with_tail[53:27];
        shift_right_sticky[0] = shifted_with_tail[27] |
                                (|shifted_with_tail[26:0]);
      end
    end
  endfunction

  function automatic logic [4:0] leading_zero_count_27(
    input logic [26:0] value
  );
    begin
      unique casez (value)
        27'b1??????????????????????????: leading_zero_count_27 = 5'd0;
        27'b01?????????????????????????: leading_zero_count_27 = 5'd1;
        27'b001????????????????????????: leading_zero_count_27 = 5'd2;
        27'b0001???????????????????????: leading_zero_count_27 = 5'd3;
        27'b00001??????????????????????: leading_zero_count_27 = 5'd4;
        27'b000001?????????????????????: leading_zero_count_27 = 5'd5;
        27'b0000001????????????????????: leading_zero_count_27 = 5'd6;
        27'b00000001???????????????????: leading_zero_count_27 = 5'd7;
        27'b000000001??????????????????: leading_zero_count_27 = 5'd8;
        27'b0000000001?????????????????: leading_zero_count_27 = 5'd9;
        27'b00000000001????????????????: leading_zero_count_27 = 5'd10;
        27'b000000000001???????????????: leading_zero_count_27 = 5'd11;
        27'b0000000000001??????????????: leading_zero_count_27 = 5'd12;
        27'b00000000000001?????????????: leading_zero_count_27 = 5'd13;
        27'b000000000000001????????????: leading_zero_count_27 = 5'd14;
        27'b0000000000000001???????????: leading_zero_count_27 = 5'd15;
        27'b00000000000000001??????????: leading_zero_count_27 = 5'd16;
        27'b000000000000000001?????????: leading_zero_count_27 = 5'd17;
        27'b0000000000000000001????????: leading_zero_count_27 = 5'd18;
        27'b00000000000000000001???????: leading_zero_count_27 = 5'd19;
        27'b000000000000000000001??????: leading_zero_count_27 = 5'd20;
        27'b0000000000000000000001?????: leading_zero_count_27 = 5'd21;
        27'b00000000000000000000001????: leading_zero_count_27 = 5'd22;
        27'b000000000000000000000001???: leading_zero_count_27 = 5'd23;
        27'b0000000000000000000000001??: leading_zero_count_27 = 5'd24;
        27'b00000000000000000000000001?: leading_zero_count_27 = 5'd25;
        27'b000000000000000000000000001: leading_zero_count_27 = 5'd26;
        default: leading_zero_count_27 = 5'd27;
      endcase
    end
  endfunction

  // Keep reset off the wide arithmetic pipeline.  A valid bit is the sole
  // ownership marker, so payload values written while reset is asserted are
  // unobservable.  Splitting these processes prevents rst_ni from becoming a
  // CE/reset path on every FP32 payload bit in every QK/PV lane.
  always_ff @(posedge clk_i) begin : p_valid
    if (!rst_ni) begin
      s0_valid_q <= 1'b0;
      s1_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
      valid_o    <= 1'b0;
    end else if (advance_i) begin
      s0_valid_q <= valid_i;
      s1_valid_q <= s0_valid_q;
      s2_valid_q <= s1_valid_q;
      s3_valid_q <= s2_valid_q;
      valid_o    <= s3_valid_q;
    end
  end

  always_ff @(posedge clk_i) begin : p_payload
    logic a_nan;
    logic b_nan;
    logic a_inf;
    logic b_inf;
    logic a_zero;
    logic b_zero;
    logic [4:0] left_shift;
    logic [24:0] rounded_ext;
    logic round_increment;
    logic [23:0] rounded_sig;
    logic signed [10:0] rounded_exp;

    if (advance_i) begin
      a_nan  = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] != '0);
      b_nan  = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] != '0);
      a_inf  = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] == '0);
      b_inf  = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] == '0);
      a_zero = (a_fp32_i[30:23] == 8'h00);
      b_zero = (b_fp32_i[30:23] == 8'h00);

      s0_q.special <= a_nan || b_nan ||
                      (a_inf && b_inf &&
                       (a_fp32_i[31] != b_fp32_i[31])) ||
                      a_inf || b_inf || a_zero || b_zero;
      if (a_nan || b_nan ||
          (a_inf && b_inf && (a_fp32_i[31] != b_fp32_i[31])))
        s0_q.special_value <= 32'h7fc0_0000;
      else if (a_inf)
        s0_q.special_value <= {a_fp32_i[31], 8'hff, 23'h0};
      else if (b_inf)
        s0_q.special_value <= {b_fp32_i[31], 8'hff, 23'h0};
      else if (a_zero && b_zero)
        s0_q.special_value <= {
          a_fp32_i[31] & b_fp32_i[31], 31'h0
        };
      else if (a_zero)
        s0_q.special_value <= b_fp32_i;
      else
        s0_q.special_value <= a_fp32_i;

      if ({a_fp32_i[30:23], a_fp32_i[22:0]} >=
          {b_fp32_i[30:23], b_fp32_i[22:0]}) begin
        s0_q.big_sign   <= a_fp32_i[31];
        s0_q.small_sign <= b_fp32_i[31];
        s0_q.big_exp    <= a_fp32_i[30:23];
        s0_q.big_sig    <= {1'b1, a_fp32_i[22:0]};
        s0_q.small_sig  <= {1'b1, b_fp32_i[22:0]};
        s0_q.exp_delta  <= a_fp32_i[30:23] - b_fp32_i[30:23];
      end else begin
        s0_q.big_sign   <= b_fp32_i[31];
        s0_q.small_sign <= a_fp32_i[31];
        s0_q.big_exp    <= b_fp32_i[30:23];
        s0_q.big_sig    <= {1'b1, b_fp32_i[22:0]};
        s0_q.small_sig  <= {1'b1, a_fp32_i[22:0]};
        s0_q.exp_delta  <= b_fp32_i[30:23] - a_fp32_i[30:23];
      end

      s1_q.special        <= s0_q.special;
      s1_q.special_value  <= s0_q.special_value;
      s1_q.big_sign       <= s0_q.big_sign;
      s1_q.same_sign      <= s0_q.big_sign == s0_q.small_sign;
      s1_q.big_exp        <= s0_q.big_exp;
      s1_q.big_ext        <= {s0_q.big_sig, 3'b000};
      s1_q.small_aligned  <= shift_right_sticky(
          {s0_q.small_sig, 3'b000}, s0_q.exp_delta);

      s2_q.special       <= s1_q.special;
      s2_q.special_value <= s1_q.special_value;
      s2_q.sign          <= s1_q.big_sign;
      s2_q.exponent      <= s1_q.big_exp;
      s2_q.is_add        <= s1_q.same_sign;
      s2_q.add_value     <= {1'b0, s1_q.big_ext} +
                            {1'b0, s1_q.small_aligned};
      s2_q.diff_value    <= s1_q.big_ext - s1_q.small_aligned;

      left_shift = leading_zero_count_27(s2_q.diff_value);
      s3_q.special       <= s2_q.special;
      s3_q.special_value <= s2_q.special_value;
      s3_q.sign          <= s2_q.sign;
      if (s2_q.is_add && s2_q.add_value[27]) begin
        s3_q.exponent   <= $signed({3'b000, s2_q.exponent}) + 11'sd1;
        s3_q.normalized <= s2_q.add_value[27:1];
        s3_q.normalized[0] <= s2_q.add_value[1] |
                              s2_q.add_value[0];
      end else if (s2_q.is_add) begin
        s3_q.exponent   <= $signed({3'b000, s2_q.exponent});
        s3_q.normalized <= s2_q.add_value[26:0];
      end else if (s2_q.diff_value == '0) begin
        s3_q.exponent   <= '0;
        s3_q.normalized <= '0;
      end else begin
        s3_q.exponent   <= $signed({3'b000, s2_q.exponent}) -
                           $signed({6'b000000, left_shift});
        s3_q.normalized <= s2_q.diff_value << left_shift;
      end

      round_increment = s3_q.normalized[2] &&
                        (s3_q.normalized[1] ||
                         s3_q.normalized[0] ||
                         s3_q.normalized[3]);
      rounded_ext = {1'b0, s3_q.normalized[26:3]} +
                    25'(round_increment);
      rounded_exp = s3_q.exponent;
      if (rounded_ext[24]) begin
        rounded_sig = rounded_ext[24:1];
        rounded_exp = s3_q.exponent + 11'sd1;
      end else begin
        rounded_sig = rounded_ext[23:0];
      end

      if (s3_q.special)
        sum_fp32_o <= s3_q.special_value;
      else if (s3_q.normalized == '0)
        sum_fp32_o <= 32'h0000_0000;
      else if (rounded_exp >= 11'sd255)
        sum_fp32_o <= {s3_q.sign, 8'hff, 23'h0};
      else if ((rounded_exp <= 0) || !rounded_sig[23])
        sum_fp32_o <= {s3_q.sign, 31'h0};
      else
        sum_fp32_o <= {
          s3_q.sign, rounded_exp[7:0], rounded_sig[22:0]
        };
    end
  end
endmodule
