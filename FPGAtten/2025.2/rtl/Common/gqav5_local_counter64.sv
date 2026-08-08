module gqav5_local_counter64 (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        increment_i,
  output logic [63:0] count_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // Four carry-qualified 16-bit slices keep one performance event from
  // becoming a 64-register clock-enable broadcast.  Upper slices toggle only
  // on a real carry, preserving exact modulo-2^64 counter semantics.
  logic [15:0] count_q [4];
  (* keep = "true", max_fanout = 16 *) logic [3:0] increment_slice;

  assign count_o = {count_q[3], count_q[2], count_q[1], count_q[0]};
  assign increment_slice[0] = increment_i;
  assign increment_slice[1] = increment_i && &count_q[0];
  assign increment_slice[2] = increment_i && &count_q[1] && &count_q[0];
  assign increment_slice[3] = increment_i && &count_q[2] &&
      &count_q[1] && &count_q[0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int slice = 0; slice < 4; slice++)
        count_q[slice] <= '0;
    end else begin
      for (int slice = 0; slice < 4; slice++) begin
        if (increment_slice[slice])
          count_q[slice] <= count_q[slice] + 16'd1;
      end
    end
  end
endmodule
