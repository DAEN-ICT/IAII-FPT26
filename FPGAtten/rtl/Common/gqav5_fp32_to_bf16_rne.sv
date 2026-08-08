module gqav5_fp32_to_bf16_rne (
  input  logic [31:0] fp32_i,
  output logic [15:0] bf16_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic fp32_is_nan;
  logic round_up;
  logic [15:0] rounded_upper;

  assign fp32_is_nan = (fp32_i[30:23] == 8'hff) &&
                       (fp32_i[22:0] != 23'd0);
  assign round_up = (fp32_i[15:0] > 16'h8000) ||
                    ((fp32_i[15:0] == 16'h8000) && fp32_i[16]);
  assign rounded_upper = fp32_i[31:16] + 16'(round_up);

  always_comb begin
    if (fp32_is_nan) begin
      // Preserve sign/payload while forcing a non-zero quiet BF16 payload.
      bf16_o = {fp32_i[31], 8'hff, 1'b1, fp32_i[21:16]};
    end else begin
      bf16_o = rounded_upper;
    end
  end
endmodule
