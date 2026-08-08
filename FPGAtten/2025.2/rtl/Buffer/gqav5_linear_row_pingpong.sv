module gqav5_linear_row_pingpong #(
  parameter int unsigned DATA_W = 256,
  parameter int unsigned DEPTH  = 16,
  parameter int unsigned TAG_W  = 16,
  localparam int unsigned ADDR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic fill_valid_i,
  output logic fill_ready_o,
  input  logic [TAG_W-1:0] fill_tag_i,
  output logic fill_active_o,
  output logic fill_bank_o,
  input  logic fill_row_valid_i,
  output logic fill_row_ready_o,
  input  logic [ADDR_W-1:0] fill_row_addr_i,
  input  logic [DATA_W-1:0] fill_row_data_i,
  input  logic fill_row_last_i,

  output logic compute_offer_valid_o,
  input  logic compute_offer_ready_i,
  output logic compute_offer_bank_o,
  output logic [TAG_W-1:0] compute_offer_tag_o,
  output logic compute_active_o,
  output logic compute_bank_o,
  output logic [TAG_W-1:0] compute_tag_o,
  input  logic read_addr_valid_i,
  output logic read_addr_ready_o,
  input  logic [ADDR_W-1:0] read_addr_i,
  output logic read_data_valid_o,
  input  logic read_data_ready_i,
  output logic [ADDR_W-1:0] read_data_addr_o,
  output logic [DATA_W-1:0] read_data_o,
  input  logic compute_done_i,

`ifdef YOSYS
  output logic [3:0]                    bank_state_o,
`else
  output gqav5_pkg::gqav5_bank_state_e bank_state_o [2],
`endif
  output logic [63:0] fill_stall_cycle_count_o,
  output logic [63:0] read_stall_cycle_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

`ifndef YOSYS
  import gqav5_pkg::*;
`endif

  // The data array is deliberately linear-addressed and is never reset. The
  // two owner states, rather than per-row valid FFs, decide whether data may be
  // consumed. Vivado can therefore infer true block RAM instead of a large
  // resettable FF snapshot.
  logic owner_fill_ready;
  logic owner_fill_bank;
  logic owner_compute_valid;
  logic owner_compute_bank;
  logic [TAG_W-1:0] owner_compute_tag;
  logic owner_protocol_error;
  logic fill_begin_fire;
  logic fill_row_fire;
  logic fill_done;
  logic fill_done_bank;
  logic compute_offer_fire;
  logic owner_compute_done;
  logic compute_done_bank;
  logic read_addr_fire;
  logic read_data_fire;
  logic fill_active_q;
  logic fill_bank_q;
  logic [ADDR_W-1:0] fill_expected_addr_q;
  logic compute_active_q;
  logic compute_bank_q;
  // Replicate the registered bank select at 32-bit output boundaries.  A
  // single select driving the full 256-bit BRAM output mux was replicated by
  // Vivado into three 86-load nets; four 64-bit copies still routed to 73
  // loads because of control/mux overhead. Eight explicit local copies keep
  // the physical control boundary below 64 without changing storage/latency.
  (* keep = "true", max_fanout = 48 *)
  logic [7:0] compute_bank_select_q;
  logic [TAG_W-1:0] compute_tag_q;
  logic read_data_valid_q;
  logic [ADDR_W-1:0] read_data_addr_q;
  logic [DATA_W-1:0] read_data_bank_q [2];
  // Match the 32-bit physical memory slices with independent local write
  // enables.  A single inferred 256-bit RAM enable otherwise fans out to all
  // 64 byte-enable pins of one ping-pong bank (plus control users), narrowly
  // missing the <=64 physical boundary even though timing is positive.
  (* keep = "true", max_fanout = 16 *)
  logic [15:0] fill_bank_write_enable;
  logic [15:0] fill_stall_count_q [4];
  logic [15:0] read_stall_count_q [4];
  (* keep = "true", max_fanout = 16 *) logic [3:0] fill_stall_increment;
  (* keep = "true", max_fanout = 16 *) logic [3:0] read_stall_increment;
  logic local_protocol_error_q;
  logic fill_row_is_final;
  logic compute_done_legal;

  assign fill_ready_o = owner_fill_ready && !fill_active_q;
  assign fill_begin_fire = fill_valid_i && fill_ready_o;
  assign fill_active_o = fill_active_q;
  assign fill_bank_o = fill_active_q ? fill_bank_q : owner_fill_bank;
  assign fill_row_ready_o = fill_active_q;
  assign fill_row_fire = fill_row_valid_i && fill_row_ready_o;
  assign fill_row_is_final = fill_row_addr_i == ADDR_W'(DEPTH - 1);
  assign fill_done = fill_row_fire && fill_row_last_i && fill_row_is_final;
  assign fill_done_bank = fill_bank_q;

  assign compute_offer_valid_o = owner_compute_valid && !compute_active_q;
  assign compute_offer_bank_o = owner_compute_bank;
  assign compute_offer_tag_o = owner_compute_tag;
  assign compute_offer_fire = compute_offer_valid_o && compute_offer_ready_i;
  assign compute_active_o = compute_active_q;
  assign compute_bank_o = compute_bank_q;
  assign compute_tag_o = compute_tag_q;

  assign read_addr_ready_o = compute_active_q &&
      (!read_data_valid_q || read_data_ready_i) && !compute_done_i;
  assign read_addr_fire = read_addr_valid_i && read_addr_ready_o;
  assign read_data_valid_o = read_data_valid_q;
  assign read_data_addr_o = read_data_addr_q;
  generate
    for (genvar slice = 0; slice < 8; slice++) begin : gen_read_output_slice
      assign read_data_o[slice * 32 +: 32] =
          read_data_bank_q[compute_bank_select_q[slice]][slice * 32 +: 32];
    end
  endgenerate
  assign read_data_fire = read_data_valid_q && read_data_ready_i;
  assign compute_done_legal = compute_active_q && !read_addr_fire &&
      (!read_data_valid_q || read_data_ready_i);
  assign owner_compute_done = compute_done_i && compute_done_legal;
  assign compute_done_bank = compute_bank_q;
  assign protocol_error_o = owner_protocol_error || local_protocol_error_q;
  assign fill_stall_cycle_count_o = {
      fill_stall_count_q[3], fill_stall_count_q[2],
      fill_stall_count_q[1], fill_stall_count_q[0]};
  assign read_stall_cycle_count_o = {
      read_stall_count_q[3], read_stall_count_q[2],
      read_stall_count_q[1], read_stall_count_q[0]};

  assign fill_stall_increment[0] = fill_valid_i && !fill_ready_o;
  assign fill_stall_increment[1] = fill_stall_increment[0] &&
      &fill_stall_count_q[0];
  assign fill_stall_increment[2] = fill_stall_increment[0] &&
      &fill_stall_count_q[1] && &fill_stall_count_q[0];
  assign fill_stall_increment[3] = fill_stall_increment[0] &&
      &fill_stall_count_q[2] && &fill_stall_count_q[1] &&
      &fill_stall_count_q[0];
  assign read_stall_increment[0] = read_addr_valid_i && !read_addr_ready_o;
  assign read_stall_increment[1] = read_stall_increment[0] &&
      &read_stall_count_q[0];
  assign read_stall_increment[2] = read_stall_increment[0] &&
      &read_stall_count_q[1] && &read_stall_count_q[0];
  assign read_stall_increment[3] = read_stall_increment[0] &&
      &read_stall_count_q[2] && &read_stall_count_q[1] &&
      &read_stall_count_q[0];

  // Keep each ping-pong bank as an independent linear memory.  A packed
  // [bank][address] array with variable bank selection made Vivado build the
  // payload from FFs even with ram_style="block".  The explicit generate
  // boundary gives every bank one write port and one synchronous read port,
  // which matches the native simple-dual-port BRAM template.  The wide 256b
  // row is implemented by parallel RAMB slices, not by resettable snapshots.
  generate
    for (genvar bank = 0; bank < 2; bank++) begin : gen_payload_bank
      for (genvar slice = 0; slice < 8; slice++) begin : gen_payload_slice
        (* ram_style = "block" *) logic [31:0] row_mem_q [DEPTH];
        assign fill_bank_write_enable[bank * 8 + slice] =
            fill_row_fire && fill_bank_q == 1'(bank);

        always_ff @(posedge clk_i) begin
          if (fill_bank_write_enable[bank * 8 + slice])
            row_mem_q[fill_row_addr_i] <=
                fill_row_data_i[slice * 32 +: 32];
          if (read_addr_fire && compute_bank_q == 1'(bank))
            read_data_bank_q[bank][slice * 32 +: 32] <=
                row_mem_q[read_addr_i];
        end
      end
    end
  endgenerate

  gqav5_pingpong_owner #(
    .BANKS(2),
    .TAG_W(TAG_W)
  ) i_owner (
    .clk_i,
    .rst_ni,
    .fill_valid_i       (fill_valid_i && !fill_active_q),
    .fill_ready_o       (owner_fill_ready),
    .fill_tag_i,
    .fill_bank_o        (owner_fill_bank),
    .fill_done_i        (fill_done),
    .fill_done_bank_i   (fill_done_bank),
    .compute_valid_o    (owner_compute_valid),
    .compute_ready_i    (compute_offer_ready_i && !compute_active_q),
    .compute_bank_o     (owner_compute_bank),
    .compute_tag_o      (owner_compute_tag),
    .compute_done_i     (owner_compute_done),
    .compute_done_bank_i(compute_done_bank),
    .bank_state_o,
    .protocol_error_o   (owner_protocol_error)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fill_active_q             <= 1'b0;
      fill_bank_q               <= 1'b0;
      fill_expected_addr_q      <= '0;
      compute_active_q          <= 1'b0;
      compute_bank_q            <= 1'b0;
      compute_bank_select_q     <= '0;
      compute_tag_q             <= '0;
      read_data_valid_q         <= 1'b0;
      read_data_addr_q          <= '0;
      for (int slice = 0; slice < 4; slice++) begin
        fill_stall_count_q[slice] <= '0;
        read_stall_count_q[slice] <= '0;
      end
      local_protocol_error_q    <= 1'b0;
    end else begin
      for (int slice = 0; slice < 4; slice++) begin
        if (fill_stall_increment[slice])
          fill_stall_count_q[slice] <= fill_stall_count_q[slice] + 16'd1;
        if (read_stall_increment[slice])
          read_stall_count_q[slice] <= read_stall_count_q[slice] + 16'd1;
      end

      if (fill_begin_fire) begin
        fill_active_q        <= 1'b1;
        fill_bank_q          <= owner_fill_bank;
        fill_expected_addr_q <= '0;
      end

      if (fill_row_fire) begin
        if (fill_row_addr_i != fill_expected_addr_q)
          local_protocol_error_q <= 1'b1;
        if (fill_row_last_i != fill_row_is_final)
          local_protocol_error_q <= 1'b1;
        if (fill_done) begin
          fill_active_q <= 1'b0;
        end else begin
          fill_expected_addr_q <= fill_expected_addr_q + ADDR_W'(1);
        end
      end

      if (compute_offer_fire) begin
        compute_active_q <= 1'b1;
        compute_bank_q   <= owner_compute_bank;
        compute_bank_select_q <= {8{owner_compute_bank}};
        compute_tag_q    <= owner_compute_tag;
      end

      if (read_addr_fire) begin
        read_data_addr_q  <= read_addr_i;
        read_data_valid_q <= 1'b1;
      end else if (read_data_fire) begin
        read_data_valid_q <= 1'b0;
      end

      if (compute_done_i) begin
        if (compute_done_legal) begin
          compute_active_q  <= 1'b0;
          read_data_valid_q <= 1'b0;
        end else begin
          local_protocol_error_q <= 1'b1;
        end
      end
    end
  end

  initial begin
    if (DATA_W < 16)
      $error("DATA_W must contain at least one BF16 element");
    if (DEPTH < 2)
      $error("DEPTH must be >= 2 for a useful ping-pong row buffer");
  end
endmodule
