module gqav5_v_row_pingpong #(
  parameter int unsigned TAG_W = 16
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic fill_valid_i,
  output logic fill_ready_o,
  input  logic [TAG_W-1:0] fill_tag_i,
  output logic fill_bank_o,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [3:0] fill_row_addr_i,
  input  logic [255:0] fill_row_data_i,
  input  logic fill_row_last_i,

  output logic v_row_valid_o,
  input  logic v_row_ready_i,
  output logic [15:0] v_row_bf16_o [16],
  output logic [3:0] v_row_index_o,
  output logic [TAG_W-1:0] v_tile_tag_o,
  output logic v_row_last_o,
  output logic tile_done_o,

  output gqav5_pkg::gqav5_bank_state_e bank_state_o [2],
  output logic [63:0] bram_read_count_o,
  output logic [63:0] fill_compute_overlap_cycle_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  logic fill_active;
  logic compute_offer_valid;
  logic compute_offer_ready;
  logic compute_offer_bank;
  logic [TAG_W-1:0] compute_offer_tag;
  logic compute_active;
  logic compute_bank;
  logic [TAG_W-1:0] compute_tag;
  logic read_addr_valid;
  logic read_addr_ready;
  logic [3:0] read_issue_addr_q;
  logic all_reads_issued_q;
  logic read_data_valid;
  logic read_data_ready;
  logic [3:0] read_data_addr;
  logic [255:0] read_data;
  logic compute_done;
  logic buffer_error;
  logic [63:0] fill_stall_cycles;
  logic [63:0] read_stall_cycles;
  logic offer_fire;
  logic read_issue_fire;
  logic v_row_fire;

  assign compute_offer_ready = 1'b1;
  assign offer_fire = compute_offer_valid && compute_offer_ready;
  assign read_addr_valid = compute_active && !all_reads_issued_q &&
      read_addr_ready;
  assign read_issue_fire = read_addr_valid;
  assign v_row_valid_o = read_data_valid;
  assign read_data_ready = v_row_ready_i;
  assign v_row_index_o = read_data_addr;
  assign v_tile_tag_o = compute_tag;
  assign v_row_last_o = read_data_addr == 4'd15;
  assign v_row_fire = v_row_valid_o && v_row_ready_i;
  assign compute_done = v_row_fire && v_row_last_o;
  assign tile_done_o = compute_done;

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_v_lane
      assign v_row_bf16_o[lane] = read_data[lane * 16 +: 16];
    end
  endgenerate

  gqav5_linear_row_pingpong #(
    .DATA_W(256),
    .DEPTH (16),
    .TAG_W (TAG_W)
  ) i_buffer (
    .clk_i,
    .rst_ni,
    .fill_valid_i,
    .fill_ready_o,
    .fill_tag_i,
    .fill_active_o         (fill_active),
    .fill_bank_o,
    .fill_row_valid_i,
    .fill_row_ready_o,
    .fill_row_addr_i,
    .fill_row_data_i,
    .fill_row_last_i,
    .compute_offer_valid_o (compute_offer_valid),
    .compute_offer_ready_i (compute_offer_ready),
    .compute_offer_bank_o  (compute_offer_bank),
    .compute_offer_tag_o   (compute_offer_tag),
    .compute_active_o      (compute_active),
    .compute_bank_o        (compute_bank),
    .compute_tag_o         (compute_tag),
    .read_addr_valid_i     (read_addr_valid),
    .read_addr_ready_o     (read_addr_ready),
    .read_addr_i           (read_issue_addr_q),
    .read_data_valid_o     (read_data_valid),
    .read_data_ready_i     (read_data_ready),
    .read_data_addr_o      (read_data_addr),
    .read_data_o           (read_data),
    .compute_done_i        (compute_done),
    .bank_state_o,
    .fill_stall_cycle_count_o(fill_stall_cycles),
    .read_stall_cycle_count_o(read_stall_cycles),
    .protocol_error_o      (buffer_error)
  );

  assign protocol_error_o = buffer_error;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_issue_addr_q                  <= '0;
      all_reads_issued_q                 <= 1'b0;
      bram_read_count_o                  <= '0;
      fill_compute_overlap_cycle_count_o <= '0;
      completed_tile_count_o             <= '0;
    end else begin
      if (offer_fire) begin
        read_issue_addr_q  <= '0;
        all_reads_issued_q <= 1'b0;
      end
      if (read_issue_fire) begin
        bram_read_count_o <= bram_read_count_o + 64'd1;
        if (read_issue_addr_q == 4'd15) begin
          all_reads_issued_q <= 1'b1;
        end else begin
          read_issue_addr_q <= read_issue_addr_q + 4'd1;
        end
      end
      if (fill_active && compute_active)
        fill_compute_overlap_cycle_count_o <=
            fill_compute_overlap_cycle_count_o + 64'd1;
      if (compute_done)
        completed_tile_count_o <= completed_tile_count_o + 64'd1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    compute_offer_bank, compute_offer_tag, compute_bank,
    fill_stall_cycles, read_stall_cycles
  };
endmodule
