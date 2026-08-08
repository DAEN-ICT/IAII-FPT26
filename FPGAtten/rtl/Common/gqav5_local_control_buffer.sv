(* keep_hierarchy = "yes" *)
module gqav5_local_control_buffer (
  input  logic in_i,
  output logic out_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // A physically explicit one-LUT replica is used only by Vivado synthesis.
  // DONT_TOUCH prevents equivalent local enable/select copies from being
  // merged back into the broad control net that this module is meant to cut.
`ifdef YOSYS
  assign out_o = in_i;
`elsif SYNTHESIS
  (* dont_touch = "yes" *)
  LUT1 #(.INIT(2'b10)) i_local_lut (
    .I0(in_i),
    .O (out_o)
  );
`else
  assign out_o = in_i;
`endif
endmodule
