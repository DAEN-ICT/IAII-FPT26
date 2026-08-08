module gqav5_fp32_add_rne (
  input  logic [31:0] a_fp32_i,
  input  logic [31:0] b_fp32_i,
  output logic [31:0] sum_fp32_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic a_nan;
  logic b_nan;
  logic a_inf;
  logic b_inf;
  logic a_zero;
  logic b_zero;

  function automatic logic [26:0] shift_right_sticky(
    input logic [26:0] value,
    input logic [7:0]  shift
  );
    logic [26:0] shifted;
    logic [53:0] shifted_with_tail;
    begin
      shifted           = '0;
      shifted_with_tail = '0;
      if (shift == 0) begin
        shifted = value;
      end else if (shift >= 8'd27) begin
        shifted[0] = |value;
      end else begin
        // One barrel shift carries the discarded tail with it. Bits [53:27]
        // are the ordinary shifted result; OR-reducing [26:0] produces the
        // exact sticky bit for shifts 1..26.
        shifted_with_tail = {value, 27'b0} >> shift[4:0];
        shifted           = shifted_with_tail[53:27];
        shifted[0]        = shifted[0] | (|shifted_with_tail[26:0]);
      end
      shift_right_sticky = shifted;
    end
  endfunction

  // 27 位规格化前导零计数。用互斥 casez 明确表达优先编码器，
  // 避免综合器把循环中的 found_one 依赖展开成 27 级宽 MUX 链。
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
        default:                            leading_zero_count_27 = 5'd27;
      endcase
    end
  endfunction

  assign a_nan  = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] != '0);
  assign b_nan  = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] != '0);
  assign a_inf  = (a_fp32_i[30:23] == 8'hff) && (a_fp32_i[22:0] == '0);
  assign b_inf  = (b_fp32_i[30:23] == 8'hff) && (b_fp32_i[22:0] == '0);
  // Match the V4.1 arithmetic wrappers: FP32 subnormals are flushed to zero.
  assign a_zero = (a_fp32_i[30:23] == 8'h00);
  assign b_zero = (b_fp32_i[30:23] == 8'h00);

  always_comb begin : p_add
    logic             big_sign;
    logic             small_sign;
    logic [7:0]       big_exp;
    logic [7:0]       small_exp;
    logic [23:0]      big_sig;
    logic [23:0]      small_sig;
    logic [7:0]       exp_delta;
    logic [26:0]      big_ext;
    logic [26:0]      small_ext;
    logic [26:0]      small_aligned;
    logic [27:0]      add_ext;
    logic [26:0]      diff_ext;
    logic [26:0]      normalized_ext;
    logic signed [10:0] normalized_exp;
    logic [23:0]      rounded_sig;
    logic [24:0]      rounded_ext;
    logic             round_increment;
    logic [4:0]       left_shift;

    sum_fp32_o     = 32'h0000_0000;
    big_sign       = 1'b0;
    small_sign     = 1'b0;
    big_exp        = '0;
    small_exp      = '0;
    big_sig        = '0;
    small_sig      = '0;
    exp_delta      = '0;
    big_ext        = '0;
    small_ext      = '0;
    small_aligned  = '0;
    add_ext        = '0;
    diff_ext       = '0;
    normalized_ext = '0;
    normalized_exp = '0;
    rounded_sig    = '0;
    rounded_ext    = '0;
    round_increment = 1'b0;
    left_shift     = '0;

    if (a_nan || b_nan ||
        (a_inf && b_inf && (a_fp32_i[31] != b_fp32_i[31]))) begin
      sum_fp32_o = 32'h7fc0_0000;
    end else if (a_inf) begin
      sum_fp32_o = {a_fp32_i[31], 8'hff, 23'h0};
    end else if (b_inf) begin
      sum_fp32_o = {b_fp32_i[31], 8'hff, 23'h0};
    end else if (a_zero && b_zero) begin
      sum_fp32_o = {(a_fp32_i[31] & b_fp32_i[31]), 31'h0};
    end else if (a_zero) begin
      sum_fp32_o = b_fp32_i;
    end else if (b_zero) begin
      sum_fp32_o = a_fp32_i;
    end else begin
      if ({a_fp32_i[30:23], a_fp32_i[22:0]} >=
          {b_fp32_i[30:23], b_fp32_i[22:0]}) begin
        big_sign   = a_fp32_i[31];
        big_exp    = a_fp32_i[30:23];
        big_sig    = {1'b1, a_fp32_i[22:0]};
        small_sign = b_fp32_i[31];
        small_exp  = b_fp32_i[30:23];
        small_sig  = {1'b1, b_fp32_i[22:0]};
      end else begin
        big_sign   = b_fp32_i[31];
        big_exp    = b_fp32_i[30:23];
        big_sig    = {1'b1, b_fp32_i[22:0]};
        small_sign = a_fp32_i[31];
        small_exp  = a_fp32_i[30:23];
        small_sig  = {1'b1, a_fp32_i[22:0]};
      end

      exp_delta     = big_exp - small_exp;
      big_ext       = {big_sig, 3'b000};
      small_ext     = {small_sig, 3'b000};
      small_aligned = shift_right_sticky(small_ext, exp_delta);
      normalized_exp = $signed({3'b000, big_exp});

      if (big_sign == small_sign) begin
        add_ext = {1'b0, big_ext} + {1'b0, small_aligned};
        if (add_ext[27]) begin
          normalized_ext    = add_ext[27:1];
          normalized_ext[0] = add_ext[1] | add_ext[0];
          normalized_exp    = normalized_exp + 11'sd1;
        end else begin
          normalized_ext = add_ext[26:0];
        end
      end else begin
        diff_ext = big_ext - small_aligned;
        if (diff_ext != '0) begin
          left_shift = leading_zero_count_27(diff_ext);
          normalized_ext = diff_ext << left_shift;
          normalized_exp = normalized_exp -
                           $signed({6'b000000, left_shift});
        end
      end

      if (normalized_ext == '0) begin
        sum_fp32_o = 32'h0000_0000;
      end else begin
        round_increment = normalized_ext[2] &&
                          (normalized_ext[1] || normalized_ext[0] ||
                           normalized_ext[3]);
        rounded_ext = {1'b0, normalized_ext[26:3]} + 25'(round_increment);
        if (rounded_ext[24]) begin
          rounded_sig   = rounded_ext[24:1];
          normalized_exp = normalized_exp + 11'sd1;
        end else begin
          rounded_sig = rounded_ext[23:0];
        end

        if (normalized_exp >= 11'sd255)
          sum_fp32_o = {big_sign, 8'hff, 23'h0};
        else if (normalized_exp <= 0)
          sum_fp32_o = {big_sign, 31'h0};
        else if (!rounded_sig[23])
          sum_fp32_o = {big_sign, 31'h0};
        else
          sum_fp32_o = {big_sign, normalized_exp[7:0], rounded_sig[22:0]};
      end
    end
  end
endmodule
