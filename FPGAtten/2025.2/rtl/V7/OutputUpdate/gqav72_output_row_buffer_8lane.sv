module gqav72_output_row_buffer_8lane #(
  parameter int unsigned OUTPUT_TILES = 16,
  localparam int unsigned OUTPUT_TILE_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES),
  localparam int unsigned DEPTH = OUTPUT_TILES * 16,
  localparam int unsigned ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic                     write_valid_i,
  output logic                     write_ready_o,
  input  logic [OUTPUT_TILE_W-1:0] write_output_tile_i,
  input  logic [3:0]               write_row_index_i,
  input  logic [31:0]              write_data_fp32_i [8],
  input  logic                     read_valid_i,
  output logic                     read_ready_o,
  input  logic [OUTPUT_TILE_W-1:0] read_output_tile_i,
  input  logic [3:0]               read_row_index_i,
  output logic                     out_valid_o,
  input  logic                     out_ready_i,
  output logic [OUTPUT_TILE_W-1:0] out_output_tile_o,
  output logic [3:0]               out_row_index_o,
  output logic [31:0]              out_data_fp32_o [8],
  output logic [63:0]              write_count_o,
  output logic [63:0]              read_count_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  (* ram_style = "block", rw_addr_collision = "no" *)
  logic [255:0] row_mem_q [DEPTH];
  logic out_valid_q;
  logic [OUTPUT_TILE_W-1:0] out_output_tile_q;
  logic [3:0] out_row_index_q;
  logic [255:0] out_data_packed_q;
  logic [255:0] write_data_packed;
  logic [ADDR_W-1:0] write_addr;
  logic [ADDR_W-1:0] read_addr;
  logic read_fire;

  function automatic logic [ADDR_W-1:0] form_address(
    input logic [OUTPUT_TILE_W-1:0] output_tile,
    input logic [3:0] row_index
  );
    form_address = (ADDR_W'(output_tile) * ADDR_W'(16)) +
                   ADDR_W'(row_index);
  endfunction

  assign write_addr = form_address(write_output_tile_i, write_row_index_i);
  assign read_addr = form_address(read_output_tile_i, read_row_index_i);
  assign write_ready_o = 1'b1;
  assign read_ready_o = !out_valid_q || out_ready_i;
  assign read_fire = read_valid_i && read_ready_o;
  assign out_valid_o = out_valid_q;
  assign out_output_tile_o = out_output_tile_q;
  assign out_row_index_o = out_row_index_q;

  for (genvar lane = 0; lane < 8; lane++) begin : gen_lane
    assign write_data_packed[lane*32 +: 32] = write_data_fp32_i[lane];
    assign out_data_fp32_o[lane] = out_data_packed_q[lane*32 +: 32];
  end

  always_ff @(posedge clk_i) begin
    if (write_valid_i)
      row_mem_q[write_addr] <= write_data_packed;
    if (read_fire)
      out_data_packed_q <= row_mem_q[read_addr];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_q <= 1'b0;
      out_output_tile_q <= '0;
      out_row_index_q <= '0;
      write_count_o <= '0;
      read_count_o <= '0;
    end else begin
      if (write_valid_i)
        write_count_o <= write_count_o + 64'd1;
      if (read_ready_o) begin
        out_valid_q <= read_valid_i;
        if (read_fire) begin
          out_output_tile_q <= read_output_tile_i;
          out_row_index_q <= read_row_index_i;
          read_count_o <= read_count_o + 64'd1;
        end
      end
    end
  end

  initial begin
    if ((OUTPUT_TILES < 1) || (OUTPUT_TILES > 16) ||
        ((OUTPUT_TILES > 1) && ((1 << OUTPUT_TILE_W) != OUTPUT_TILES)))
      $error("V7.2 output row buffer requires power-of-two OUTPUT_TILES in [1,16]");
  end
endmodule
