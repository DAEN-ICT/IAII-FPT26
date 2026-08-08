module gqav5_sync_fifo #(
  parameter int unsigned DATA_W = 1,
  parameter int unsigned DEPTH  = 2,
  localparam int unsigned OCC_W = $clog2(DEPTH + 1)
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              s_valid_i,
  output logic              s_ready_o,
  input  logic [DATA_W-1:0] s_data_i,

  output logic              m_valid_o,
  input  logic              m_ready_i,
  output logic [DATA_W-1:0] m_data_o,

  output logic [OCC_W-1:0]  occupancy_o,
  output logic [OCC_W-1:0]  high_watermark_o,
  output logic              full_o,
  output logic              empty_o
);
  timeunit 1ns;
  timeprecision 1ps;

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  logic [DATA_W-1:0] mem_q [DEPTH];
  logic [PTR_W-1:0]  wr_ptr_q;
  logic [PTR_W-1:0]  rd_ptr_q;
  logic [OCC_W-1:0]  count_q;
  logic [OCC_W-1:0]  high_watermark_q;
  logic              push;
  logic              pop;

  function automatic logic [PTR_W-1:0] ptr_next(
    input logic [PTR_W-1:0] ptr
  );
    if (ptr == PTR_W'(DEPTH - 1))
      ptr_next = '0;
    else
      ptr_next = ptr + PTR_W'(1);
  endfunction

  assign full_o           = (count_q == OCC_W'(DEPTH));
  assign empty_o          = (count_q == '0);
  assign m_valid_o        = !empty_o;
  assign s_ready_o        = !full_o || (m_valid_o && m_ready_i);
  assign m_data_o         = mem_q[rd_ptr_q];
  assign occupancy_o      = count_q;
  assign high_watermark_o = high_watermark_q;
  assign push             = s_valid_i && s_ready_o;
  assign pop              = m_valid_o && m_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q         <= '0;
      rd_ptr_q         <= '0;
      count_q          <= '0;
      high_watermark_q <= '0;
    end else begin
      if (push) begin
        mem_q[wr_ptr_q] <= s_data_i;
        wr_ptr_q        <= ptr_next(wr_ptr_q);
      end
      if (pop)
        rd_ptr_q <= ptr_next(rd_ptr_q);

      unique case ({push, pop})
        2'b10: begin
          count_q <= count_q + OCC_W'(1);
          if ((count_q + OCC_W'(1)) > high_watermark_q)
            high_watermark_q <= count_q + OCC_W'(1);
        end
        2'b01: count_q <= count_q - OCC_W'(1);
        default: count_q <= count_q;
      endcase
    end
  end

  initial begin
    if (DEPTH < 2)
      $error("gqav5_sync_fifo requires DEPTH >= 2");
  end
endmodule
