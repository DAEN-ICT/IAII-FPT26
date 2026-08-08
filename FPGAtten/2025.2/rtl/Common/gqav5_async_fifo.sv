module gqav5_async_fifo #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned DEPTH = 8,
  localparam int unsigned ADDR_W = $clog2(DEPTH),
  localparam int unsigned PTR_W = ADDR_W + 1
) (
  input  logic wr_clk_i,
  input  logic wr_rst_ni,
  input  logic wr_valid_i,
  output logic wr_ready_o,
  input  logic [WIDTH-1:0] wr_data_i,

  input  logic rd_clk_i,
  input  logic rd_rst_ni,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [WIDTH-1:0] rd_data_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  (* ram_style = "block" *)
  logic [WIDTH-1:0] memory_q [DEPTH];

  logic [PTR_W-1:0] wr_binary_q;
  logic [PTR_W-1:0] wr_gray_q;
  logic [PTR_W-1:0] wr_binary_next;
  logic [PTR_W-1:0] wr_gray_next;
  logic wr_full_q;
  logic wr_full_next;
  logic wr_fire;

  logic [PTR_W-1:0] rd_binary_q;
  logic [PTR_W-1:0] rd_gray_q;
  logic [PTR_W-1:0] rd_binary_next;
  logic [PTR_W-1:0] rd_gray_next;
  logic rd_memory_not_empty;
  logic rd_load;
  logic rd_valid_q;
  logic [WIDTH-1:0] rd_data_q;

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [PTR_W-1:0] rd_gray_wr_sync1_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [PTR_W-1:0] rd_gray_wr_sync2_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [PTR_W-1:0] wr_gray_rd_sync1_q;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [PTR_W-1:0] wr_gray_rd_sync2_q;

  function automatic logic [PTR_W-1:0] binary_to_gray(
      input logic [PTR_W-1:0] value);
    return (value >> 1) ^ value;
  endfunction

  assign wr_ready_o = !wr_full_q;
  assign wr_fire = wr_valid_i && wr_ready_o;
  assign wr_binary_next = wr_binary_q + PTR_W'(wr_fire);
  assign wr_gray_next = binary_to_gray(wr_binary_next);
  assign wr_full_next =
      wr_gray_next ==
      {~rd_gray_wr_sync2_q[PTR_W-1:PTR_W-2],
       rd_gray_wr_sync2_q[PTR_W-3:0]};

  always_ff @(posedge wr_clk_i or negedge wr_rst_ni) begin
    if (!wr_rst_ni) begin
      wr_binary_q <= '0;
      wr_gray_q <= '0;
      wr_full_q <= 1'b0;
    end else begin
      wr_binary_q <= wr_binary_next;
      wr_gray_q <= wr_gray_next;
      wr_full_q <= wr_full_next;
    end
  end

  // The payload RAM is intentionally reset-free.  Resetting the pointers
  // invalidates every stale entry, so gating thousands of payload-bit write
  // enables with wr_rst_ni adds no correctness and creates a chip-wide reset
  // route.  Keeping this write process separate also restores clean
  // simple-dual-port block-RAM inference for the wide store-row FIFO.
  always_ff @(posedge wr_clk_i) begin
    if (wr_fire)
      memory_q[wr_binary_q[ADDR_W-1:0]] <= wr_data_i;
  end

  always_ff @(posedge wr_clk_i or negedge wr_rst_ni) begin
    if (!wr_rst_ni) begin
      rd_gray_wr_sync1_q <= '0;
      rd_gray_wr_sync2_q <= '0;
    end else begin
      rd_gray_wr_sync1_q <= rd_gray_q;
      rd_gray_wr_sync2_q <= rd_gray_wr_sync1_q;
    end
  end

  assign rd_memory_not_empty = rd_gray_q != wr_gray_rd_sync2_q;
  assign rd_load = (!rd_valid_q || rd_ready_i) && rd_memory_not_empty;
  assign rd_binary_next = rd_binary_q + PTR_W'(rd_load);
  assign rd_gray_next = binary_to_gray(rd_binary_next);
  assign rd_valid_o = rd_valid_q;
  assign rd_data_o = rd_data_q;

  always_ff @(posedge rd_clk_i or negedge rd_rst_ni) begin
    if (!rd_rst_ni) begin
      rd_binary_q <= '0;
      rd_gray_q <= '0;
      rd_valid_q <= 1'b0;
      rd_data_q <= '0;
    end else begin
      if (!rd_valid_q || rd_ready_i) begin
        if (rd_memory_not_empty) begin
          rd_data_q <= memory_q[rd_binary_q[ADDR_W-1:0]];
          rd_valid_q <= 1'b1;
        end else begin
          rd_valid_q <= 1'b0;
        end
      end
      rd_binary_q <= rd_binary_next;
      rd_gray_q <= rd_gray_next;
    end
  end

  always_ff @(posedge rd_clk_i or negedge rd_rst_ni) begin
    if (!rd_rst_ni) begin
      wr_gray_rd_sync1_q <= '0;
      wr_gray_rd_sync2_q <= '0;
    end else begin
      wr_gray_rd_sync1_q <= wr_gray_q;
      wr_gray_rd_sync2_q <= wr_gray_rd_sync1_q;
    end
  end

  initial begin
    if (WIDTH < 1)
      $error("gqav5_async_fifo WIDTH must be positive");
    if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0)
      $error("gqav5_async_fifo DEPTH must be a power of two >= 4");
  end
endmodule
