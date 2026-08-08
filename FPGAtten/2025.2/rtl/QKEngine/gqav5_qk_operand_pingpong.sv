module gqav5_qk_operand_pingpong #(
  parameter int unsigned TAG_W = 16
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic q_fill_valid_i,
  output logic q_fill_ready_o,
  input  logic [TAG_W-1:0] q_fill_tag_i,
  output logic q_fill_bank_o,
  input  logic q_fill_row_valid_i,
  output logic q_fill_row_ready_o,
  input  logic [3:0] q_fill_row_addr_i,
  input  logic [255:0] q_fill_row_data_i,
  input  logic q_fill_row_last_i,

  input  logic k_fill_valid_i,
  output logic k_fill_ready_o,
  input  logic [TAG_W-1:0] k_fill_tag_i,
  output logic k_fill_bank_o,
  input  logic k_fill_row_valid_i,
  output logic k_fill_row_ready_o,
  input  logic [3:0] k_fill_row_addr_i,
  input  logic [255:0] k_fill_row_data_i,
  input  logic k_fill_row_last_i,

  output logic step_valid_o,
  input  logic step_ready_i,
  output logic [15:0] q_column_bf16_o [16],
  output logic [15:0] k_column_bf16_o [16],
  output logic [3:0] step_index_o,
  output logic [TAG_W-1:0] step_tag_o,
  output logic tile_done_o,

  output gqav5_pkg::gqav5_bank_state_e q_bank_state_o [2],
  output gqav5_pkg::gqav5_bank_state_e k_bank_state_o [2],
  output logic [63:0] bram_pair_read_count_o,
  output logic [63:0] prefetch_compute_overlap_cycle_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  logic q_fill_active;
  logic k_fill_active;
  logic q_compute_offer_valid;
  logic k_compute_offer_valid;
  logic q_compute_offer_ready;
  logic k_compute_offer_ready;
  logic q_compute_offer_bank;
  logic k_compute_offer_bank;
  logic [TAG_W-1:0] q_compute_offer_tag;
  logic [TAG_W-1:0] k_compute_offer_tag;
  logic q_compute_active;
  logic k_compute_active;
  logic q_compute_bank;
  logic k_compute_bank;
  logic [TAG_W-1:0] q_compute_tag;
  logic [TAG_W-1:0] k_compute_tag;
  logic q_read_addr_valid;
  logic k_read_addr_valid;
  logic q_read_addr_ready;
  logic k_read_addr_ready;
  logic [3:0] read_issue_addr_q;
  logic all_reads_issued_q;
  logic q_read_data_valid;
  logic k_read_data_valid;
  logic q_read_data_ready;
  logic k_read_data_ready;
  logic [3:0] q_read_data_addr;
  logic [3:0] k_read_data_addr;
  logic [255:0] q_read_data;
  logic [255:0] k_read_data;
  logic q_compute_done;
  logic k_compute_done;
  logic q_buffer_error;
  logic k_buffer_error;
  logic [63:0] q_fill_stall_cycles;
  logic [63:0] q_read_stall_cycles;
  logic [63:0] k_fill_stall_cycles;
  logic [63:0] k_read_stall_cycles;

  logic feeder_start_valid;
  logic feeder_start_ready;
  logic feeder_row_valid;
  logic feeder_row_ready;
  logic feeder_done;
  logic feeder_error;
  logic [63:0] feeder_rows;
  logic [63:0] feeder_steps;
  logic [63:0] feeder_tiles;
  logic pair_offer_match;
  logic pair_start_fire;
  logic pair_read_active;
  logic pair_read_issue_fire;
  logic pair_data_valid;
  logic pair_data_fire;
  logic last_pair_data;
  logic local_protocol_error_q;

  assign pair_offer_match = q_compute_offer_tag == k_compute_offer_tag;
  assign feeder_start_valid = q_compute_offer_valid &&
      k_compute_offer_valid && pair_offer_match;
  assign q_compute_offer_ready = feeder_start_ready &&
      k_compute_offer_valid && pair_offer_match;
  assign k_compute_offer_ready = feeder_start_ready &&
      q_compute_offer_valid && pair_offer_match;
  assign pair_start_fire = feeder_start_valid && feeder_start_ready;

  assign pair_read_active = q_compute_active && k_compute_active;
  // Gate valid with both ready so neither BRAM can accept a lone request.
  assign q_read_addr_valid = pair_read_active && !all_reads_issued_q &&
      q_read_addr_ready && k_read_addr_ready;
  assign k_read_addr_valid = q_read_addr_valid;
  assign pair_read_issue_fire = q_read_addr_valid;

  assign pair_data_valid = q_read_data_valid && k_read_data_valid;
  assign feeder_row_valid = pair_data_valid;
  assign q_read_data_ready = feeder_row_ready && k_read_data_valid;
  assign k_read_data_ready = feeder_row_ready && q_read_data_valid;
  assign pair_data_fire = pair_data_valid && feeder_row_ready;
  assign last_pair_data = pair_data_fire &&
      (q_read_data_addr == 4'd15) && (k_read_data_addr == 4'd15);
  assign q_compute_done = last_pair_data;
  assign k_compute_done = last_pair_data;

  gqav5_linear_row_pingpong #(
    .DATA_W(256),
    .DEPTH (16),
    .TAG_W (TAG_W)
  ) i_q_buffer (
    .clk_i,
    .rst_ni,
    .fill_valid_i          (q_fill_valid_i),
    .fill_ready_o          (q_fill_ready_o),
    .fill_tag_i            (q_fill_tag_i),
    .fill_active_o         (q_fill_active),
    .fill_bank_o           (q_fill_bank_o),
    .fill_row_valid_i      (q_fill_row_valid_i),
    .fill_row_ready_o      (q_fill_row_ready_o),
    .fill_row_addr_i       (q_fill_row_addr_i),
    .fill_row_data_i       (q_fill_row_data_i),
    .fill_row_last_i       (q_fill_row_last_i),
    .compute_offer_valid_o (q_compute_offer_valid),
    .compute_offer_ready_i (q_compute_offer_ready),
    .compute_offer_bank_o  (q_compute_offer_bank),
    .compute_offer_tag_o   (q_compute_offer_tag),
    .compute_active_o      (q_compute_active),
    .compute_bank_o        (q_compute_bank),
    .compute_tag_o         (q_compute_tag),
    .read_addr_valid_i     (q_read_addr_valid),
    .read_addr_ready_o     (q_read_addr_ready),
    .read_addr_i           (read_issue_addr_q),
    .read_data_valid_o     (q_read_data_valid),
    .read_data_ready_i     (q_read_data_ready),
    .read_data_addr_o      (q_read_data_addr),
    .read_data_o           (q_read_data),
    .compute_done_i        (q_compute_done),
    .bank_state_o          (q_bank_state_o),
    .fill_stall_cycle_count_o(q_fill_stall_cycles),
    .read_stall_cycle_count_o(q_read_stall_cycles),
    .protocol_error_o      (q_buffer_error)
  );

  gqav5_linear_row_pingpong #(
    .DATA_W(256),
    .DEPTH (16),
    .TAG_W (TAG_W)
  ) i_k_buffer (
    .clk_i,
    .rst_ni,
    .fill_valid_i          (k_fill_valid_i),
    .fill_ready_o          (k_fill_ready_o),
    .fill_tag_i            (k_fill_tag_i),
    .fill_active_o         (k_fill_active),
    .fill_bank_o           (k_fill_bank_o),
    .fill_row_valid_i      (k_fill_row_valid_i),
    .fill_row_ready_o      (k_fill_row_ready_o),
    .fill_row_addr_i       (k_fill_row_addr_i),
    .fill_row_data_i       (k_fill_row_data_i),
    .fill_row_last_i       (k_fill_row_last_i),
    .compute_offer_valid_o (k_compute_offer_valid),
    .compute_offer_ready_i (k_compute_offer_ready),
    .compute_offer_bank_o  (k_compute_offer_bank),
    .compute_offer_tag_o   (k_compute_offer_tag),
    .compute_active_o      (k_compute_active),
    .compute_bank_o        (k_compute_bank),
    .compute_tag_o         (k_compute_tag),
    .read_addr_valid_i     (k_read_addr_valid),
    .read_addr_ready_o     (k_read_addr_ready),
    .read_addr_i           (read_issue_addr_q),
    .read_data_valid_o     (k_read_data_valid),
    .read_data_ready_i     (k_read_data_ready),
    .read_data_addr_o      (k_read_data_addr),
    .read_data_o           (k_read_data),
    .compute_done_i        (k_compute_done),
    .bank_state_o          (k_bank_state_o),
    .fill_stall_cycle_count_o(k_fill_stall_cycles),
    .read_stall_cycle_count_o(k_read_stall_cycles),
    .protocol_error_o      (k_buffer_error)
  );

  gqav5_qk_row_to_column_feeder #(.TAG_W(TAG_W)) i_feeder (
    .clk_i,
    .rst_ni,
    .start_valid_i       (feeder_start_valid),
    .start_ready_o       (feeder_start_ready),
    .start_tag_i         (q_compute_offer_tag),
    .row_valid_i         (feeder_row_valid),
    .row_ready_o         (feeder_row_ready),
    .row_index_i         (q_read_data_addr),
    .q_row_bf16_i        (q_read_data),
    .k_row_bf16_i        (k_read_data),
    .row_last_i          (last_pair_data),
    .step_valid_o,
    .step_ready_i,
    .q_column_bf16_o,
    .k_column_bf16_o,
    .step_index_o,
    .step_tag_o,
    .done_o              (feeder_done),
    .accepted_row_count_o(feeder_rows),
    .emitted_step_count_o(feeder_steps),
    .completed_tile_count_o(feeder_tiles),
    .protocol_error_o    (feeder_error)
  );

  assign tile_done_o = feeder_done;
  assign completed_tile_count_o = feeder_tiles;
  assign protocol_error_o = q_buffer_error || k_buffer_error ||
      feeder_error || local_protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_issue_addr_q                      <= '0;
      all_reads_issued_q                     <= 1'b0;
      bram_pair_read_count_o                 <= '0;
      prefetch_compute_overlap_cycle_count_o <= '0;
      local_protocol_error_q                 <= 1'b0;
    end else begin
      if (pair_start_fire) begin
        read_issue_addr_q  <= '0;
        all_reads_issued_q <= 1'b0;
      end

      if (pair_read_issue_fire) begin
        bram_pair_read_count_o <= bram_pair_read_count_o + 64'd1;
        if (read_issue_addr_q == 4'd15) begin
          all_reads_issued_q <= 1'b1;
        end else begin
          read_issue_addr_q <= read_issue_addr_q + 4'd1;
        end
      end

      if ((q_fill_active || k_fill_active) &&
          (pair_read_active || step_valid_o))
        prefetch_compute_overlap_cycle_count_o <=
            prefetch_compute_overlap_cycle_count_o + 64'd1;

      if (q_compute_offer_valid && k_compute_offer_valid &&
          !pair_offer_match)
        local_protocol_error_q <= 1'b1;
      if (q_compute_active != k_compute_active)
        local_protocol_error_q <= 1'b1;
      if (pair_data_valid && (q_read_data_addr != k_read_data_addr))
        local_protocol_error_q <= 1'b1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    q_compute_offer_bank, k_compute_offer_bank,
    q_compute_bank, k_compute_bank, q_compute_tag, k_compute_tag,
    q_fill_stall_cycles, q_read_stall_cycles,
    k_fill_stall_cycles, k_read_stall_cycles,
    feeder_rows, feeder_steps
  };
endmodule
