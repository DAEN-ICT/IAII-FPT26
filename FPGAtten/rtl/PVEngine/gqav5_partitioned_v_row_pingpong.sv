module gqav5_partitioned_v_row_pingpong #(
  parameter int unsigned TAG_W      = 16,
  parameter int unsigned PARTITIONS = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic fill_valid_i,
  output logic fill_ready_o,
  input  logic fill_broadcast_i,
  input  logic [1:0] fill_partition_i,
  input  logic [TAG_W-1:0] fill_tag_i,
  output logic fill_bank_o,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [3:0] fill_row_addr_i,
  input  logic [255:0] fill_row_data_i,
  input  logic fill_row_last_i,

  // Resident-cache fast path. One local command supplies all four V
  // partitions in parallel and bypasses the serial compatibility fills.
  input  logic fast_start_valid_i,
  output logic fast_start_ready_o,
  input  logic [TAG_W-1:0] fast_start_tag_i,
  input  logic fast_row_valid_i,
  output logic fast_row_ready_o,
  input  logic [3:0] fast_row_index_i,
  input  logic [255:0] fast_v_partition_row_bf16_i [PARTITIONS],
  input  logic fast_row_last_i,

  output logic v_row_valid_o,
  input  logic v_row_ready_i,
  output logic [15:0] v_partition_row_bf16_o [PARTITIONS][16],
  output logic [3:0] v_row_index_o,
  output logic [TAG_W-1:0] v_tile_tag_o,
  output logic v_row_last_o,
  output logic tile_done_o,

  output gqav5_pkg::gqav5_bank_state_e bank_state_o [PARTITIONS][2],
  output logic [63:0] bram_read_count_o,
  output logic [63:0] fill_compute_overlap_cycle_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
  timeunit 1ns;
  timeprecision 1ps;

  logic fill_ready [PARTITIONS];
  logic fill_active [PARTITIONS];
  logic fill_bank [PARTITIONS];
  logic fill_row_ready [PARTITIONS];
  logic offer_valid [PARTITIONS];
  logic offer_ready [PARTITIONS];
  logic offer_bank [PARTITIONS];
  logic [TAG_W-1:0] offer_tag [PARTITIONS];
  logic compute_active [PARTITIONS];
  logic compute_bank [PARTITIONS];
  logic [TAG_W-1:0] compute_tag [PARTITIONS];
  logic read_addr_valid [PARTITIONS];
  logic read_addr_ready [PARTITIONS];
  logic read_data_valid [PARTITIONS];
  logic read_data_ready [PARTITIONS];
  logic [3:0] read_data_addr [PARTITIONS];
  logic [255:0] read_data [PARTITIONS];
  logic compute_done [PARTITIONS];
  logic buffer_error [PARTITIONS];
  logic [63:0] fill_stalls [PARTITIONS];
  logic [63:0] read_stalls [PARTITIONS];

  logic [1:0] fill_partition_q;
  logic fill_broadcast_q;
  logic any_fill_active, all_offer_valid, all_offer_match;
  logic all_fill_ready, all_fill_row_ready;
  logic all_compute_active, any_compute_active, all_read_addr_ready;
  logic all_read_data_valid;
  logic group_offer_fire, read_issue_fire, row_fire;
  logic fast_start_fire, fast_row_fire;
  logic [3:0] read_issue_addr_q;
  logic all_reads_issued_q;
  logic fast_active_q;
  logic [TAG_W-1:0] fast_tag_q;
  logic [3:0] fast_expected_row_q;
  logic local_error_q;

  always_comb begin
    any_fill_active = 1'b0;
    all_offer_valid = 1'b1;
    all_offer_match = 1'b1;
    all_compute_active = 1'b1;
    any_compute_active = 1'b0;
    all_read_addr_ready = 1'b1;
    all_read_data_valid = 1'b1;
    all_fill_ready = 1'b1;
    all_fill_row_ready = 1'b1;
    for (int part = 0; part < PARTITIONS; part++) begin
      any_fill_active |= fill_active[part];
      all_offer_valid &= offer_valid[part];
      all_offer_match &= offer_tag[part] == offer_tag[0];
      all_compute_active &= compute_active[part];
      any_compute_active |= compute_active[part];
      all_read_addr_ready &= read_addr_ready[part];
      all_read_data_valid &= read_data_valid[part];
      all_fill_ready &= fill_ready[part];
      all_fill_row_ready &= fill_row_ready[part];
    end
  end

  assign fill_ready_o = fill_broadcast_i
      ? all_fill_ready : fill_ready[fill_partition_i];
  assign fill_bank_o = fill_broadcast_i
      ? fill_bank[0] : (any_fill_active
      ? fill_bank[fill_partition_q] : fill_bank[fill_partition_i]);
  assign fill_row_ready_o = fill_broadcast_q
      ? all_fill_row_ready : fill_row_ready[fill_partition_q];
  assign fast_start_ready_o = !fast_active_q && !any_compute_active &&
                              !all_offer_valid;
  assign fast_start_fire = fast_start_valid_i && fast_start_ready_o;
  assign group_offer_fire = !fast_active_q && !fast_start_valid_i &&
                            all_offer_valid && all_offer_match;

  generate
    for (genvar part = 0; part < PARTITIONS; part++) begin : gen_control
      assign offer_ready[part] = !fast_active_q && !fast_start_valid_i &&
                                 all_offer_valid && all_offer_match;
      assign read_addr_valid[part] = !fast_active_q && all_compute_active &&
          !all_reads_issued_q && all_read_addr_ready;
      assign read_data_ready[part] = !fast_active_q && v_row_ready_i &&
          all_read_data_valid;
      // A resident fast-path completion does not own any compatibility
      // ping-pong bank.  Do not forward that pulse into idle bank FSMs.
      assign compute_done[part] = tile_done_o && !fast_active_q;
      for (genvar lane = 0; lane < 16; lane++) begin : gen_lane
        assign v_partition_row_bf16_o[part][lane] = fast_active_q
            ? fast_v_partition_row_bf16_i[part][lane * 16 +: 16]
            : read_data[part][lane * 16 +: 16];
      end
    end
  endgenerate

  assign read_issue_fire = read_addr_valid[0];
  assign v_row_valid_o = fast_active_q ? fast_row_valid_i
                                       : all_read_data_valid;
  assign fast_row_ready_o = fast_active_q && v_row_ready_i;
  assign fast_row_fire = fast_row_valid_i && fast_row_ready_o;
  assign v_row_index_o = fast_active_q ? fast_row_index_i
                                       : read_data_addr[0];
  assign v_tile_tag_o = fast_active_q ? fast_tag_q : compute_tag[0];
  assign v_row_last_o = fast_active_q ? fast_row_last_i
                                      : (v_row_index_o == 4'd15);
  assign row_fire = v_row_valid_o && v_row_ready_i;
  assign tile_done_o = row_fire && v_row_last_o;

  generate
    for (genvar part = 0; part < PARTITIONS; part++) begin : gen_buffer
      gqav5_linear_row_pingpong #(
        .DATA_W(256), .DEPTH(16), .TAG_W(TAG_W)
      ) i_buffer (
        .clk_i, .rst_ni,
        .fill_valid_i(fill_valid_i &&
                      (fill_broadcast_i ||
                       (fill_partition_i == 2'(part)))),
        .fill_ready_o(fill_ready[part]), .fill_tag_i(fill_tag_i),
        .fill_active_o(fill_active[part]), .fill_bank_o(fill_bank[part]),
        .fill_row_valid_i(fill_row_valid_i &&
                          (fill_broadcast_q ||
                           (fill_partition_q == 2'(part)))),
        .fill_row_ready_o(fill_row_ready[part]),
        .fill_row_addr_i(fill_row_addr_i),
        .fill_row_data_i(fill_row_data_i),
        .fill_row_last_i(fill_row_last_i),
        .compute_offer_valid_o(offer_valid[part]),
        .compute_offer_ready_i(offer_ready[part]),
        .compute_offer_bank_o(offer_bank[part]),
        .compute_offer_tag_o(offer_tag[part]),
        .compute_active_o(compute_active[part]),
        .compute_bank_o(compute_bank[part]),
        .compute_tag_o(compute_tag[part]),
        .read_addr_valid_i(read_addr_valid[part]),
        .read_addr_ready_o(read_addr_ready[part]),
        .read_addr_i(read_issue_addr_q),
        .read_data_valid_o(read_data_valid[part]),
        .read_data_ready_i(read_data_ready[part]),
        .read_data_addr_o(read_data_addr[part]),
        .read_data_o(read_data[part]),
        .compute_done_i(compute_done[part]),
        .bank_state_o(bank_state_o[part]),
        .fill_stall_cycle_count_o(fill_stalls[part]),
        .read_stall_cycle_count_o(read_stalls[part]),
        .protocol_error_o(buffer_error[part])
      );
    end
  endgenerate

  always_comb begin
    protocol_error_o = local_error_q;
    for (int part = 0; part < PARTITIONS; part++)
      protocol_error_o |= buffer_error[part];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_partition_q <= '0;
      fill_broadcast_q <= 1'b0;
      read_issue_addr_q <= '0;
      all_reads_issued_q <= 1'b0;
      fast_active_q <= 1'b0;
      fast_tag_q <= '0;
      fast_expected_row_q <= '0;
      bram_read_count_o <= '0;
      fill_compute_overlap_cycle_count_o <= '0;
      completed_tile_count_o <= '0;
      local_error_q <= 1'b0;
    end else begin
      if (fill_valid_i && fill_ready_o) begin
        fill_partition_q <= fill_partition_i;
        fill_broadcast_q <= fill_broadcast_i;
      end
      if (group_offer_fire) begin
        read_issue_addr_q <= '0;
        all_reads_issued_q <= 1'b0;
      end
      if (fast_start_fire) begin
        fast_active_q <= 1'b1;
        fast_tag_q <= fast_start_tag_i;
        fast_expected_row_q <= '0;
      end
      if (read_issue_fire || fast_row_fire) begin
        bram_read_count_o <= bram_read_count_o + 64'(PARTITIONS);
      end
      if (read_issue_fire) begin
        if (read_issue_addr_q == 4'd15)
          all_reads_issued_q <= 1'b1;
        else
          read_issue_addr_q <= read_issue_addr_q + 4'd1;
      end
      if (any_fill_active && all_compute_active)
        fill_compute_overlap_cycle_count_o <=
            fill_compute_overlap_cycle_count_o + 64'd1;
      if (tile_done_o)
        completed_tile_count_o <= completed_tile_count_o + 64'd1;
      if (fast_row_fire) begin
        if (fast_row_index_i != fast_expected_row_q ||
            fast_row_last_i != (fast_expected_row_q == 4'd15))
          local_error_q <= 1'b1;
        if (fast_row_last_i) begin
          fast_active_q <= 1'b0;
          fast_expected_row_q <= '0;
        end else begin
          fast_expected_row_q <= fast_expected_row_q + 4'd1;
        end
      end

      if (all_offer_valid && !all_offer_match)
        local_error_q <= 1'b1;
      if (any_compute_active != all_compute_active)
        local_error_q <= 1'b1;
      if (fill_row_valid_i && any_fill_active &&
          !fill_broadcast_q && fill_partition_i != fill_partition_q)
        local_error_q <= 1'b1;
      if (fill_valid_i && fill_broadcast_i && all_fill_ready) begin
        for (int part = 1; part < PARTITIONS; part++)
          if (fill_bank[part] != fill_bank[0])
            local_error_q <= 1'b1;
      end
      if (v_row_valid_o && !fast_active_q) begin
        for (int part = 1; part < PARTITIONS; part++)
          if (read_data_addr[part] != read_data_addr[0] ||
              compute_tag[part] != compute_tag[0])
            local_error_q <= 1'b1;
      end
    end
  end

  logic unused_status;
  assign unused_status = ^{
    offer_bank[0], compute_bank[0], fill_stalls[0], read_stalls[0]
  };

  initial begin
    if (PARTITIONS != 4)
      $error("partitioned V buffer currently requires four banks");
  end
endmodule
