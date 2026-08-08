module gqav5_partitioned_qk_column_stream_adapter #(
  parameter int unsigned TAG_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Q/K tiles are already stored reduction-column-major in the resident
  // cache. One 256-bit word therefore contains all sixteen query/context
  // lanes for one reduction step; no 16x16 FF transpose working set is
  // required at the compute boundary.
  input  logic start_valid_i,
  output logic start_ready_o,
  input  logic [TAG_W-1:0] start_tag_i,
  input  logic column_valid_i,
  output logic column_ready_o,
  input  logic [3:0] column_index_i,
  input  logic [255:0] q_column_word_bf16_i,
  input  logic [255:0]
      k_partition_column_word_bf16_i [ROW_PARTITIONS],
  input  logic column_last_i,

  output logic step_valid_o,
  input  logic step_ready_i,
  // The V7 compute adapter exposes the readiness of an already-active
  // reduction wave separately from its launch-time ready path.  Use that
  // local continuation readiness only to decide whether column 15 can
  // atomically hand ownership to the following tile; the real column
  // handshake below continues to use step_ready_i.
  input  logic retire_ready_i,
  output logic [15:0] q_column_bf16_o [16],
  output logic [15:0]
      k_partition_column_bf16_o [ROW_PARTITIONS][16],
  output logic [3:0] step_index_o,
  output logic [TAG_W-1:0] step_tag_o,
  output logic done_o,
  output logic [63:0] accepted_step_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  logic active_q;
  logic [3:0] expected_column_q;
  logic [TAG_W-1:0] active_tag_q;
  logic retiring_column;
  logic start_fire;
  logic step_fire;
  logic [15:0] accepted_step_count_q [4];
  logic [15:0] completed_tile_count_q [4];
  (* keep = "yes", max_fanout = 16 *) logic [3:0] accepted_increment;
  (* keep = "yes", max_fanout = 16 *) logic [3:0] completed_increment;

  assign retiring_column = active_q && column_valid_i && retire_ready_i &&
                           column_last_i;
  // A next-tile command may be accepted on the same edge as column 15.  The
  // readiness term deliberately excludes the launch/result feedback present
  // in step_ready_i, while retire_ready_i is required to be equivalent for
  // an already-active final column.  This preserves the original zero-cycle
  // tag handoff without a look-ahead tag register.
  assign start_ready_o = !active_q || retiring_column;
  assign start_fire = start_valid_i && start_ready_o;
  assign step_valid_o = active_q && column_valid_i;
  assign step_fire = step_valid_o && step_ready_i;
  // retire_ready_i is required to equal step_ready_i for an active final
  // column (asserted below).  Therefore a same-cycle next start cannot add a
  // further condition to the current column handshake.  Keeping the ready
  // path local cuts next-start scheduling out of the K-cache BRAM enable cone.
  assign column_ready_o = active_q && step_ready_i;
  assign step_index_o = column_index_i;
  assign step_tag_o = active_tag_q;
  assign accepted_step_count_o = {
      accepted_step_count_q[3], accepted_step_count_q[2],
      accepted_step_count_q[1], accepted_step_count_q[0]};
  assign completed_tile_count_o = {
      completed_tile_count_q[3], completed_tile_count_q[2],
      completed_tile_count_q[1], completed_tile_count_q[0]};

  // A monolithic 64-bit performance counter gives its enable 64+ loads,
  // which is enough to recreate a small but avoidable global control net.
  // Four carry-qualified 16-bit slices preserve the exact count while
  // bounding every counter-enable fanout to one local slice.
  assign accepted_increment[0] = step_fire;
  assign accepted_increment[1] = step_fire && &accepted_step_count_q[0];
  assign accepted_increment[2] = step_fire &&
      &accepted_step_count_q[1] && &accepted_step_count_q[0];
  assign accepted_increment[3] = step_fire &&
      &accepted_step_count_q[2] && &accepted_step_count_q[1] &&
      &accepted_step_count_q[0];
  assign completed_increment[0] = step_fire &&
      expected_column_q == 4'd15;
  assign completed_increment[1] = completed_increment[0] &&
      &completed_tile_count_q[0];
  assign completed_increment[2] = completed_increment[0] &&
      &completed_tile_count_q[1] && &completed_tile_count_q[0];
  assign completed_increment[3] = completed_increment[0] &&
      &completed_tile_count_q[2] && &completed_tile_count_q[1] &&
      &completed_tile_count_q[0];

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_lane
      assign q_column_bf16_o[lane] =
          q_column_word_bf16_i[lane * 16 +: 16];
      for (genvar part = 0; part < ROW_PARTITIONS;
           part++) begin : gen_partition
        assign k_partition_column_bf16_o[part][lane] =
            k_partition_column_word_bf16_i[part][lane * 16 +: 16];
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= 1'b0;
      expected_column_q <= '0;
      active_tag_q <= '0;
      done_o <= 1'b0;
      for (int slice = 0; slice < 4; slice++) begin
        accepted_step_count_q[slice] <= '0;
        completed_tile_count_q[slice] <= '0;
      end
      protocol_error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      for (int slice = 0; slice < 4; slice++) begin
        if (accepted_increment[slice])
          accepted_step_count_q[slice] <=
              accepted_step_count_q[slice] + 16'd1;
        if (completed_increment[slice])
          completed_tile_count_q[slice] <=
              completed_tile_count_q[slice] + 16'd1;
      end

      if (step_fire) begin
        if (column_index_i != expected_column_q ||
            column_last_i != (expected_column_q == 4'd15))
          protocol_error_o <= 1'b1;
        if (expected_column_q == 4'd15) begin
          active_q <= 1'b0;
          expected_column_q <= '0;
          done_o <= 1'b1;
        end else begin
          expected_column_q <= expected_column_q + 4'd1;
        end
      end

      // Keep this assignment after retirement so a same-edge look-ahead
      // command owns the stream immediately and column zero has no bubble.
      if (start_fire) begin
        active_q <= 1'b1;
        expected_column_q <= '0;
        active_tag_q <= start_tag_i;
      end
    end
  end

`ifndef SYNTHESIS
  // retire_ready_i exists only to cut the launch/result feedback from the
  // next-start path.  It must never change the actual final-column handshake.
  always_ff @(posedge clk_i) begin
    if (rst_ni && active_q && column_valid_i && column_last_i &&
        (retire_ready_i !== step_ready_i))
      $error("QK column adapter retire/step readiness diverged on column 15");
  end
`endif

  initial begin
    if (ROW_PARTITIONS < 1 || ROW_PARTITIONS > 16 ||
        (16 % ROW_PARTITIONS) != 0)
      $error("partitioned QK column adapter ROW_PARTITIONS must divide 16");
  end
endmodule
