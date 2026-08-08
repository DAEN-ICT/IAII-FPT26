module gqav5_exp2_neg_lut_bank #(
  parameter int unsigned LANES = 17
) (
  input  logic        clk_i,
  input  logic [31:0] x_fp32_i [LANES],
  output logic [15:0] y_bf16_o [LANES],
  output logic [31:0] y_fp32_o [LANES],
  output logic        rom_sentinel_ok_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic [LANES-1:0] lane_sentinel_ok;

  generate
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_lane
      gqav5_exp2_neg_lut_lane #(
        .CHECK_SENTINEL(lane == 0)
      ) i_lane (
        .clk_i,
        .x_fp32_i       (x_fp32_i[lane]),
        .y_bf16_o       (y_bf16_o[lane]),
        .y_fp32_o       (y_fp32_o[lane]),
        .rom_sentinel_ok_o(lane_sentinel_ok[lane])
      );
    end
  endgenerate

  assign rom_sentinel_ok_o = &lane_sentinel_ok;

  initial begin
    if (LANES < 1)
      $error("exp2 LUT bank must expose at least one lane");
  end
endmodule
