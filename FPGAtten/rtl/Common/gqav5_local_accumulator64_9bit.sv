module gqav5_local_accumulator64_9bit (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        add_valid_i,
  input  logic [8:0]  add_value_i,
  output logic [63:0] count_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // Performance accounting must not create one 64-bit adder/enable cone in
  // the middle of the array. Four 16-bit slices propagate only a one-bit
  // carry upward; each write qualifier consequently reaches at most 16 FFs.
  logic [15:0] count_q [4];
  logic [16:0] slice_sum [4];

  assign count_o = {count_q[3], count_q[2], count_q[1], count_q[0]};

  always_comb begin
    slice_sum[0] = {1'b0, count_q[0]} + 17'(add_value_i);
    slice_sum[1] = {1'b0, count_q[1]} + 17'(slice_sum[0][16]);
    slice_sum[2] = {1'b0, count_q[2]} + 17'(slice_sum[1][16]);
    slice_sum[3] = {1'b0, count_q[3]} + 17'(slice_sum[2][16]);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int slice = 0; slice < 4; slice++)
        count_q[slice] <= '0;
    end else if (add_valid_i) begin
      count_q[0] <= slice_sum[0][15:0];
      if (slice_sum[0][16])
        count_q[1] <= slice_sum[1][15:0];
      if (slice_sum[1][16])
        count_q[2] <= slice_sum[2][15:0];
      if (slice_sum[2][16])
        count_q[3] <= slice_sum[3][15:0];
    end
  end
endmodule
