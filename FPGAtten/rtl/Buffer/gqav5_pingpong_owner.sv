module gqav5_pingpong_owner #(
  parameter int unsigned BANKS  = 2,
  parameter int unsigned TAG_W  = 16,
  localparam int unsigned BANK_W = (BANKS <= 1) ? 1 : $clog2(BANKS)
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  input  logic                              fill_valid_i,
  output logic                              fill_ready_o,
  input  logic [TAG_W-1:0]                  fill_tag_i,
  output logic [BANK_W-1:0]                 fill_bank_o,
  input  logic                              fill_done_i,
  input  logic [BANK_W-1:0]                 fill_done_bank_i,

  output logic                              compute_valid_o,
  input  logic                              compute_ready_i,
  output logic [BANK_W-1:0]                 compute_bank_o,
  output logic [TAG_W-1:0]                  compute_tag_o,
  input  logic                              compute_done_i,
  input  logic [BANK_W-1:0]                 compute_done_bank_i,

`ifdef YOSYS
  output logic [(2*BANKS)-1:0]               bank_state_o,
`else
  output gqav5_pkg::gqav5_bank_state_e       bank_state_o [BANKS],
`endif
  output logic                              protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

`ifdef YOSYS
  typedef enum logic [1:0] {
    GQAV5_BANK_FREE,
    GQAV5_BANK_FILLING,
    GQAV5_BANK_READY,
    GQAV5_BANK_COMPUTING
  } gqav5_bank_state_e;
`else
  import gqav5_pkg::*;
`endif

  gqav5_bank_state_e state_q [BANKS];
  logic [TAG_W-1:0] tag_q [BANKS];
  logic             free_found;
  logic             ready_found;

  always_comb begin
    free_found      = 1'b0;
    fill_ready_o    = 1'b0;
    fill_bank_o     = '0;
    ready_found     = 1'b0;
    compute_valid_o = 1'b0;
    compute_bank_o  = '0;
    compute_tag_o   = '0;

    for (int unsigned bank = 0; bank < BANKS; bank++) begin
      if (!free_found && state_q[bank] == GQAV5_BANK_FREE) begin
        free_found   = 1'b1;
        fill_ready_o = 1'b1;
        fill_bank_o  = BANK_W'(bank);
      end
      if (!ready_found && state_q[bank] == GQAV5_BANK_READY) begin
        ready_found     = 1'b1;
        compute_valid_o = 1'b1;
        compute_bank_o  = BANK_W'(bank);
        compute_tag_o   = tag_q[bank];
      end
    end
  end

  generate
    for (genvar bank = 0; bank < BANKS; bank++) begin : gen_state_output
`ifdef YOSYS
      assign bank_state_o[bank * 2 +: 2] = state_q[bank];
`else
      assign bank_state_o[bank] = state_q[bank];
`endif
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      protocol_error_o <= 1'b0;
      for (int unsigned bank = 0; bank < BANKS; bank++) begin
        state_q[bank] <= GQAV5_BANK_FREE;
        tag_q[bank]   <= '0;
      end
    end else begin
      if (fill_valid_i && fill_ready_o) begin
        state_q[fill_bank_o] <= GQAV5_BANK_FILLING;
        tag_q[fill_bank_o]   <= fill_tag_i;
      end

      if (fill_done_i) begin
        if (int'(fill_done_bank_i) < BANKS &&
            state_q[fill_done_bank_i] == GQAV5_BANK_FILLING)
          state_q[fill_done_bank_i] <= GQAV5_BANK_READY;
        else
          protocol_error_o <= 1'b1;
      end

      if (compute_valid_o && compute_ready_i)
        state_q[compute_bank_o] <= GQAV5_BANK_COMPUTING;

      if (compute_done_i) begin
        if (int'(compute_done_bank_i) < BANKS &&
            state_q[compute_done_bank_i] == GQAV5_BANK_COMPUTING)
          state_q[compute_done_bank_i] <= GQAV5_BANK_FREE;
        else
          protocol_error_o <= 1'b1;
      end
    end
  end

  initial begin
    if (BANKS < 2)
      $error("gqav5_pingpong_owner requires BANKS >= 2");
  end
endmodule
