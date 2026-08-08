module gqav5_rv_slice #(
  parameter int unsigned DATA_W = 1
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              s_valid_i,
  output logic              s_ready_o,
  input  logic [DATA_W-1:0] s_data_i,

  output logic              m_valid_o,
  input  logic              m_ready_i,
  output logic [DATA_W-1:0] m_data_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic              valid_q;
  logic [DATA_W-1:0] data_q;

  assign s_ready_o = !valid_q || m_ready_i;
  assign m_valid_o = valid_q;
  assign m_data_o  = data_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      data_q  <= '0;
    end else if (s_ready_o) begin
      valid_q <= s_valid_i;
      if (s_valid_i)
        data_q <= s_data_i;
    end
  end
endmodule
