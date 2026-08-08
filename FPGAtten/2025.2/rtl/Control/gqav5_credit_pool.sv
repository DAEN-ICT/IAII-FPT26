module gqav5_credit_pool #(
  parameter int unsigned CREDITS = 2,
  localparam int unsigned COUNT_W = $clog2(CREDITS + 1)
) (
  input  logic               clk_i,
  input  logic               rst_ni,

  input  logic               reserve_valid_i,
  output logic               reserve_ready_o,
  input  logic               release_i,

  output logic [COUNT_W-1:0] available_o,
  output logic [COUNT_W-1:0] reserved_o,
  output logic               protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic [COUNT_W-1:0] available_q;
  logic               reserve_fire;

  assign reserve_ready_o = (available_q != '0) || release_i;
  assign reserve_fire    = reserve_valid_i && reserve_ready_o;
  assign available_o     = available_q;
  assign reserved_o      = COUNT_W'(CREDITS) - available_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      available_q     <= COUNT_W'(CREDITS);
      protocol_error_o <= 1'b0;
    end else begin
      unique case ({reserve_fire, release_i})
        2'b10: available_q <= available_q - COUNT_W'(1);
        2'b01: begin
          if (available_q == COUNT_W'(CREDITS))
            protocol_error_o <= 1'b1;
          else
            available_q <= available_q + COUNT_W'(1);
        end
        default: available_q <= available_q;
      endcase
    end
  end

  initial begin
    if (CREDITS < 1)
      $error("gqav5_credit_pool requires CREDITS >= 1");
  end
endmodule
