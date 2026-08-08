module gqav5_partitioned_qk_operand_pingpong #(
  parameter int unsigned TAG_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4
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
  input  logic k_fill_broadcast_i,
  input  logic [1:0] k_fill_partition_i,
  input  logic [TAG_W-1:0] k_fill_tag_i,
  output logic k_fill_bank_o,
  input  logic k_fill_row_valid_i,
  output logic k_fill_row_ready_o,
  input  logic [3:0] k_fill_row_addr_i,
  input  logic [255:0] k_fill_row_data_i,
  input  logic k_fill_row_last_i,

  // Resident-cache fast path.  A packed 16Q/4KV wave supplies one Q row and
  // four independent K rows per cycle directly to the dual transpose banks,
  // bypassing the compatibility row ping-pongs and their serial K fills.
  input  logic fast_start_valid_i,
  output logic fast_start_ready_o,
  input  logic [TAG_W-1:0] fast_start_tag_i,
  input  logic fast_row_valid_i,
  output logic fast_row_ready_o,
  input  logic [3:0] fast_row_index_i,
  input  logic [255:0] fast_q_row_bf16_i,
  input  logic [255:0]
      fast_k_partition_row_bf16_i [ROW_PARTITIONS],
  input  logic fast_row_last_i,

  output logic step_valid_o,
  input  logic step_ready_i,
  output logic [15:0] q_column_bf16_o [16],
  output logic [15:0]
      k_partition_column_bf16_o [ROW_PARTITIONS][16],
  output logic [3:0] step_index_o,
  output logic [TAG_W-1:0] step_tag_o,
  output logic tile_done_o,

  output gqav5_pkg::gqav5_bank_state_e q_bank_state_o [2],
  output gqav5_pkg::gqav5_bank_state_e
      k_bank_state_o [ROW_PARTITIONS][2],
  output logic [63:0] bram_read_count_o,
  output logic [63:0] prefetch_compute_overlap_cycle_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  import gqav5_pkg::*;

  logic q_fill_active;
  logic q_offer_valid, q_offer_ready, q_offer_bank;
  logic [TAG_W-1:0] q_offer_tag;
  logic q_compute_active, q_compute_bank;
  logic [TAG_W-1:0] q_compute_tag;
  logic q_read_addr_valid, q_read_addr_ready;
  logic q_read_data_valid, q_read_data_ready;
  logic [3:0] q_read_data_addr;
  logic [255:0] q_read_data;
  logic q_compute_done, q_buffer_error;
  logic [63:0] q_fill_stalls, q_read_stalls;

  logic k_fill_ready [ROW_PARTITIONS];
  logic k_fill_active [ROW_PARTITIONS];
  logic k_fill_bank [ROW_PARTITIONS];
  logic k_fill_row_ready [ROW_PARTITIONS];
  logic k_offer_valid [ROW_PARTITIONS];
  logic k_offer_ready [ROW_PARTITIONS];
  logic k_offer_bank [ROW_PARTITIONS];
  logic [TAG_W-1:0] k_offer_tag [ROW_PARTITIONS];
  logic k_compute_active [ROW_PARTITIONS];
  logic k_compute_bank [ROW_PARTITIONS];
  logic [TAG_W-1:0] k_compute_tag [ROW_PARTITIONS];
  logic k_read_addr_valid [ROW_PARTITIONS];
  logic k_read_addr_ready [ROW_PARTITIONS];
  logic k_read_data_valid [ROW_PARTITIONS];
  logic k_read_data_ready [ROW_PARTITIONS];
  logic [3:0] k_read_data_addr [ROW_PARTITIONS];
  logic [255:0] k_read_data [ROW_PARTITIONS];
  logic k_compute_done [ROW_PARTITIONS];
  logic k_buffer_error [ROW_PARTITIONS];
  logic [63:0] k_fill_stalls [ROW_PARTITIONS];
  logic [63:0] k_read_stalls [ROW_PARTITIONS];

  logic [1:0] k_fill_partition_q;
  logic k_fill_broadcast_q;
  logic any_k_fill_active;
  logic all_k_fill_ready, all_k_fill_row_ready;
  logic all_k_offer_valid, all_offer_match;
  logic all_k_compute_active, all_read_addr_ready;
  logic all_k_read_data_valid;
  logic buffered_feeder_start_valid;
  logic feeder_start_valid, feeder_start_ready, feeder_start_fire;
  logic [TAG_W-1:0] feeder_start_tag;
  logic feeder_row_valid, feeder_row_ready;
  logic [3:0] feeder_row_index;
  logic [255:0] feeder_q_row;
  logic [255:0] feeder_k_partition_row [ROW_PARTITIONS];
  logic feeder_row_last;
  logic feeder_done, feeder_error;
  logic [63:0] feeder_rows, feeder_steps, feeder_tiles;
  logic pair_read_active, pair_read_issue_fire;
  logic pair_data_valid, pair_data_fire, last_pair_data;
  logic [3:0] read_issue_addr_q;
  logic all_reads_issued_q;
  logic fast_active_q;
  logic fast_start_eligible;
  logic fast_start_fire;
  logic fast_row_fire;
  logic local_error_q;

  always_comb begin
    any_k_fill_active = 1'b0;
    all_k_offer_valid = 1'b1;
    all_offer_match = 1'b1;
    all_k_compute_active = 1'b1;
    all_read_addr_ready = 1'b1;
    all_k_read_data_valid = 1'b1;
    all_k_fill_ready = 1'b1;
    all_k_fill_row_ready = 1'b1;
    for (int part = 0; part < ROW_PARTITIONS; part++) begin
      any_k_fill_active |= k_fill_active[part];
      all_k_offer_valid &= k_offer_valid[part];
      all_offer_match &= k_offer_tag[part] == q_offer_tag;
      all_k_compute_active &= k_compute_active[part];
      all_read_addr_ready &= k_read_addr_ready[part];
      all_k_read_data_valid &= k_read_data_valid[part];
      all_k_fill_ready &= k_fill_ready[part];
      all_k_fill_row_ready &= k_fill_row_ready[part];
    end
  end

  assign k_fill_ready_o = k_fill_broadcast_i
      ? all_k_fill_ready : k_fill_ready[k_fill_partition_i];
  assign k_fill_bank_o = k_fill_broadcast_i
      ? k_fill_bank[0] : (any_k_fill_active
      ? k_fill_bank[k_fill_partition_q]
      : k_fill_bank[k_fill_partition_i]);
  assign k_fill_row_ready_o = k_fill_broadcast_q
      ? all_k_fill_row_ready : k_fill_row_ready[k_fill_partition_q];

  assign buffered_feeder_start_valid = q_offer_valid && all_k_offer_valid &&
                                       all_offer_match;
  assign fast_start_eligible = !fast_active_q ||
      (fast_row_valid_i && fast_row_last_i);
  assign fast_start_ready_o = feeder_start_ready && fast_start_eligible;
  assign fast_start_fire = fast_start_valid_i && fast_start_ready_o;
  assign feeder_start_valid = (fast_start_valid_i && fast_start_eligible) ||
      (!fast_active_q && !fast_start_valid_i &&
       buffered_feeder_start_valid);
  assign feeder_start_tag = (fast_start_valid_i && fast_start_eligible)
      ? fast_start_tag_i : q_offer_tag;
  assign feeder_start_fire = feeder_start_valid && feeder_start_ready;
  assign q_offer_ready = !fast_active_q && !fast_start_valid_i &&
                         feeder_start_ready && all_k_offer_valid &&
                         all_offer_match;
  generate
    for (genvar part = 0; part < ROW_PARTITIONS; part++) begin : gen_ready
      assign k_offer_ready[part] = !fast_active_q && !fast_start_valid_i &&
                                   feeder_start_ready && q_offer_valid &&
                                   all_k_offer_valid && all_offer_match;
    end
  endgenerate

  assign pair_read_active = !fast_active_q && q_compute_active &&
                            all_k_compute_active;
  assign q_read_addr_valid = pair_read_active && !all_reads_issued_q &&
                             q_read_addr_ready && all_read_addr_ready;
  assign pair_read_issue_fire = q_read_addr_valid;
  assign pair_data_valid = q_read_data_valid && all_k_read_data_valid;
  assign feeder_row_valid = fast_active_q
      ? fast_row_valid_i : pair_data_valid;
  assign feeder_row_index = fast_active_q
      ? fast_row_index_i : q_read_data_addr;
  assign feeder_q_row = fast_active_q ? fast_q_row_bf16_i : q_read_data;
  assign feeder_row_last = fast_active_q
      ? fast_row_last_i : (q_read_data_addr == 4'd15);
  always_comb begin
    for (int part = 0; part < ROW_PARTITIONS; part++)
      feeder_k_partition_row[part] = fast_active_q
          ? fast_k_partition_row_bf16_i[part] : k_read_data[part];
  end
  assign fast_row_ready_o = fast_active_q && feeder_row_ready;
  assign fast_row_fire = fast_row_valid_i && fast_row_ready_o;
  assign q_read_data_ready = !fast_active_q && feeder_row_ready &&
                             all_k_read_data_valid;
  assign pair_data_fire = pair_data_valid && feeder_row_ready;
  assign last_pair_data = pair_data_fire &&
                          (q_read_data_addr == 4'd15);
  assign q_compute_done = last_pair_data;
  generate
    for (genvar part = 0; part < ROW_PARTITIONS; part++) begin : gen_pair
      assign k_read_addr_valid[part] = q_read_addr_valid;
      assign k_read_data_ready[part] = !fast_active_q && feeder_row_ready &&
          q_read_data_valid && all_k_read_data_valid;
      assign k_compute_done[part] = last_pair_data;
    end
  endgenerate

  gqav5_linear_row_pingpong #(
    .DATA_W(256), .DEPTH(16), .TAG_W(TAG_W)
  ) i_q_buffer (
    .clk_i, .rst_ni,
    .fill_valid_i(q_fill_valid_i), .fill_ready_o(q_fill_ready_o),
    .fill_tag_i(q_fill_tag_i), .fill_active_o(q_fill_active),
    .fill_bank_o(q_fill_bank_o),
    .fill_row_valid_i(q_fill_row_valid_i),
    .fill_row_ready_o(q_fill_row_ready_o),
    .fill_row_addr_i(q_fill_row_addr_i),
    .fill_row_data_i(q_fill_row_data_i),
    .fill_row_last_i(q_fill_row_last_i),
    .compute_offer_valid_o(q_offer_valid),
    .compute_offer_ready_i(q_offer_ready),
    .compute_offer_bank_o(q_offer_bank),
    .compute_offer_tag_o(q_offer_tag),
    .compute_active_o(q_compute_active),
    .compute_bank_o(q_compute_bank), .compute_tag_o(q_compute_tag),
    .read_addr_valid_i(q_read_addr_valid),
    .read_addr_ready_o(q_read_addr_ready),
    .read_addr_i(read_issue_addr_q),
    .read_data_valid_o(q_read_data_valid),
    .read_data_ready_i(q_read_data_ready),
    .read_data_addr_o(q_read_data_addr), .read_data_o(q_read_data),
    .compute_done_i(q_compute_done), .bank_state_o(q_bank_state_o),
    .fill_stall_cycle_count_o(q_fill_stalls),
    .read_stall_cycle_count_o(q_read_stalls),
    .protocol_error_o(q_buffer_error)
  );

  generate
    for (genvar part = 0; part < ROW_PARTITIONS; part++) begin : gen_k_buffer
      gqav5_linear_row_pingpong #(
        .DATA_W(256), .DEPTH(16), .TAG_W(TAG_W)
      ) i_k_buffer (
        .clk_i, .rst_ni,
        .fill_valid_i(k_fill_valid_i &&
                      (k_fill_broadcast_i ||
                       (k_fill_partition_i == 2'(part)))),
        .fill_ready_o(k_fill_ready[part]), .fill_tag_i(k_fill_tag_i),
        .fill_active_o(k_fill_active[part]),
        .fill_bank_o(k_fill_bank[part]),
        .fill_row_valid_i(k_fill_row_valid_i &&
                          (k_fill_broadcast_q ||
                           (k_fill_partition_q == 2'(part)))),
        .fill_row_ready_o(k_fill_row_ready[part]),
        .fill_row_addr_i(k_fill_row_addr_i),
        .fill_row_data_i(k_fill_row_data_i),
        .fill_row_last_i(k_fill_row_last_i),
        .compute_offer_valid_o(k_offer_valid[part]),
        .compute_offer_ready_i(k_offer_ready[part]),
        .compute_offer_bank_o(k_offer_bank[part]),
        .compute_offer_tag_o(k_offer_tag[part]),
        .compute_active_o(k_compute_active[part]),
        .compute_bank_o(k_compute_bank[part]),
        .compute_tag_o(k_compute_tag[part]),
        .read_addr_valid_i(k_read_addr_valid[part]),
        .read_addr_ready_o(k_read_addr_ready[part]),
        .read_addr_i(read_issue_addr_q),
        .read_data_valid_o(k_read_data_valid[part]),
        .read_data_ready_i(k_read_data_ready[part]),
        .read_data_addr_o(k_read_data_addr[part]),
        .read_data_o(k_read_data[part]),
        .compute_done_i(k_compute_done[part]),
        .bank_state_o(k_bank_state_o[part]),
        .fill_stall_cycle_count_o(k_fill_stalls[part]),
        .read_stall_cycle_count_o(k_read_stalls[part]),
        .protocol_error_o(k_buffer_error[part])
      );
    end
  endgenerate

  gqav5_partitioned_qk_row_to_column_feeder #(
    .TAG_W(TAG_W), .ROW_PARTITIONS(ROW_PARTITIONS)
  ) i_feeder (
    .clk_i, .rst_ni,
    .start_valid_i(feeder_start_valid),
    .start_ready_o(feeder_start_ready), .start_tag_i(feeder_start_tag),
    .row_valid_i(feeder_row_valid), .row_ready_o(feeder_row_ready),
    .row_index_i(feeder_row_index), .q_row_bf16_i(feeder_q_row),
    .k_partition_row_bf16_i(feeder_k_partition_row),
    .row_last_i(feeder_row_last), .step_valid_o, .step_ready_i,
    .q_column_bf16_o, .k_partition_column_bf16_o,
    .step_index_o, .step_tag_o, .done_o(feeder_done),
    .accepted_row_count_o(feeder_rows),
    .emitted_step_count_o(feeder_steps),
    .completed_tile_count_o(feeder_tiles),
    .protocol_error_o(feeder_error)
  );

  assign tile_done_o = feeder_done;
  assign completed_tile_count_o = feeder_tiles;
  always_comb begin
    protocol_error_o = q_buffer_error || feeder_error || local_error_q;
    for (int part = 0; part < ROW_PARTITIONS; part++)
      protocol_error_o |= k_buffer_error[part];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      k_fill_partition_q <= '0;
      k_fill_broadcast_q <= 1'b0;
      read_issue_addr_q <= '0;
      all_reads_issued_q <= 1'b0;
      fast_active_q <= 1'b0;
      bram_read_count_o <= '0;
      prefetch_compute_overlap_cycle_count_o <= '0;
      local_error_q <= 1'b0;
    end else begin
      if (k_fill_valid_i && k_fill_ready_o) begin
        k_fill_partition_q <= k_fill_partition_i;
        k_fill_broadcast_q <= k_fill_broadcast_i;
      end
      if (feeder_start_fire && !fast_start_fire) begin
        read_issue_addr_q <= '0;
        all_reads_issued_q <= 1'b0;
      end
      if (fast_row_fire && fast_row_last_i && !fast_start_fire)
        fast_active_q <= 1'b0;
      if (fast_start_fire)
        fast_active_q <= 1'b1;
      if (pair_read_issue_fire) begin
        bram_read_count_o <= bram_read_count_o +
                             64'(ROW_PARTITIONS + 1);
        if (read_issue_addr_q == 4'd15)
          all_reads_issued_q <= 1'b1;
        else
          read_issue_addr_q <= read_issue_addr_q + 4'd1;
      end
      if ((q_fill_active || any_k_fill_active) &&
          (pair_read_active || step_valid_o))
        prefetch_compute_overlap_cycle_count_o <=
            prefetch_compute_overlap_cycle_count_o + 64'd1;

      if (q_offer_valid && all_k_offer_valid && !all_offer_match)
        local_error_q <= 1'b1;
      if (q_compute_active != all_k_compute_active)
        local_error_q <= 1'b1;
      if (k_fill_row_valid_i && any_k_fill_active &&
          !k_fill_broadcast_q &&
          (k_fill_partition_i != k_fill_partition_q))
        local_error_q <= 1'b1;
      if (k_fill_valid_i && k_fill_broadcast_i && all_k_fill_ready) begin
        for (int part = 1; part < ROW_PARTITIONS; part++)
          if (k_fill_bank[part] != k_fill_bank[0])
            local_error_q <= 1'b1;
      end
      if (pair_data_valid) begin
        for (int part = 0; part < ROW_PARTITIONS; part++)
          if (k_read_data_addr[part] != q_read_data_addr)
            local_error_q <= 1'b1;
      end
      if (fast_start_valid_i && buffered_feeder_start_valid)
        local_error_q <= 1'b1;
    end
  end

  logic unused_status;
  assign unused_status = ^{
    q_offer_bank, q_compute_bank, q_compute_tag,
    q_fill_stalls, q_read_stalls, feeder_rows, feeder_steps,
    k_offer_bank[0], k_compute_bank[0], k_compute_tag[0],
    k_fill_stalls[0], k_read_stalls[0]
  };

  initial begin
    if (ROW_PARTITIONS != 4)
      $error("partitioned QK operand currently requires four K banks");
  end
endmodule
