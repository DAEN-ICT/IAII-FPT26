module gqav5_partitioned_qk_row_to_column_feeder #(
  parameter int unsigned TAG_W          = 16,
  parameter int unsigned ROW_PARTITIONS = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic start_valid_i,
  output logic start_ready_o,
  input  logic [TAG_W-1:0] start_tag_i,
  input  logic row_valid_i,
  output logic row_ready_o,
  input  logic [3:0] row_index_i,
  input  logic [255:0] q_row_bf16_i,
  input  logic [255:0] k_partition_row_bf16_i [ROW_PARTITIONS],
  input  logic row_last_i,

  output logic step_valid_o,
  input  logic step_ready_i,
  output logic [15:0] q_column_bf16_o [16],
  output logic [15:0]
      k_partition_column_bf16_o [ROW_PARTITIONS][16],
  output logic [3:0] step_index_o,
  output logic [TAG_W-1:0] step_tag_o,
  output logic done_o,
  output logic [63:0] accepted_row_count_o,
  output logic [63:0] emitted_step_count_o,
  output logic [63:0] completed_tile_count_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // Two reset-free transpose working sets decouple row loading from column
  // emission.  When column 15 retires, its bank may be reserved for the next
  // tile on the same edge; sixteen incoming rows then exactly overlap the
  // sixteen columns emitted from the other bank.
  logic [255:0] q_row_working_q [2][16];
  logic [255:0]
      k_partition_row_working_q [2][ROW_PARTITIONS][16];
  logic [TAG_W-1:0] bank_tag_q [2];
  logic [1:0] bank_ready_q;
  logic load_active_q;
  logic load_bank_q;
  logic [3:0] load_row_index_q;
  logic emit_active_q;
  logic emit_bank_q;
  logic [3:0] emit_column_index_q;
  logic [1:0] bank_free;
  logic selected_emit_bank;
  logic [3:0] selected_emit_column;
  logic selected_start_bank;
  logic retiring_emit_bank;
  logic completing_load_bank;
  logic start_fire;
  logic row_fire;
  logic step_fire;

  always_comb begin
    for (int bank = 0; bank < 2; bank++) begin
      bank_free[bank] = !(load_active_q && load_bank_q == 1'(bank)) &&
                        !bank_ready_q[bank] &&
                        !(emit_active_q && emit_bank_q == 1'(bank));
    end
  end

  assign retiring_emit_bank = emit_active_q && step_ready_i &&
                              emit_column_index_q == 4'd15;
  assign completing_load_bank = load_active_q && row_valid_i &&
                                row_last_i &&
                                load_row_index_q == 4'd15;
  assign selected_start_bank = bank_free[0] ? 1'b0 :
                               (bank_free[1] ? 1'b1 : emit_bank_q);
  assign start_ready_o = (!load_active_q || completing_load_bank) &&
                         ((|bank_free) || retiring_emit_bank);
  assign start_fire = start_valid_i && start_ready_o;
  // If a producer presents the next-tile command together with row 15, retire
  // both atomically.  Backpressure the row when no transpose bank can be
  // reclaimed, so the command and payload can never diverge.
  assign row_ready_o = load_active_q &&
      (!(row_valid_i && row_last_i && start_valid_i) || start_ready_o);
  assign row_fire = row_valid_i && row_ready_o;
  assign selected_emit_bank = emit_active_q ? emit_bank_q :
                              (bank_ready_q[0] ? 1'b0 : 1'b1);
  assign selected_emit_column = emit_active_q
      ? emit_column_index_q : 4'd0;
  assign step_valid_o = emit_active_q || (|bank_ready_q);
  assign step_fire = step_valid_o && step_ready_i;
  assign step_index_o = selected_emit_column;
  assign step_tag_o = bank_tag_q[selected_emit_bank];

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_column_output
      assign q_column_bf16_o[lane] =
          q_row_working_q[selected_emit_bank][lane]
              [selected_emit_column * 16 +: 16];
      for (genvar part = 0; part < ROW_PARTITIONS;
           part++) begin : gen_partition
        assign k_partition_column_bf16_o[part][lane] =
            k_partition_row_working_q[selected_emit_bank][part][lane]
                [selected_emit_column * 16 +: 16];
      end
    end
  endgenerate

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bank_tag_q[0] <= '0;
      bank_tag_q[1] <= '0;
      bank_ready_q <= '0;
      load_active_q <= 1'b0;
      load_bank_q <= 1'b0;
      load_row_index_q <= '0;
      emit_active_q <= 1'b0;
      emit_bank_q <= 1'b0;
      emit_column_index_q <= '0;
      done_o <= 1'b0;
      accepted_row_count_o <= '0;
      emitted_step_count_o <= '0;
      completed_tile_count_o <= '0;
      protocol_error_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      // Standard ready/valid permits the producer to hold valid and payload
      // stable for an arbitrary number of backpressured cycles.  The former
      // row_valid_i && !row_ready_o check incorrectly classified that legal
      // behavior as a protocol fault; the accepted row below remains subject
      // to strict index and last-beat validation.
      if (row_fire) begin
        accepted_row_count_o <= accepted_row_count_o + 64'd1;
        if (row_index_i != load_row_index_q ||
            row_last_i != (load_row_index_q == 4'd15))
          protocol_error_o <= 1'b1;
        if (load_row_index_q == 4'd15) begin
          load_active_q <= 1'b0;
          load_row_index_q <= '0;
          bank_ready_q[load_bank_q] <= 1'b1;
        end else begin
          load_row_index_q <= load_row_index_q + 4'd1;
        end
      end

      // A look-ahead command may retire the current load and reserve the
      // other/reclaimed bank on the same edge.  Keep this assignment after
      // row retirement so the next tile remains active without a bubble.
      if (start_fire) begin
        load_active_q <= 1'b1;
        load_bank_q <= selected_start_bank;
        load_row_index_q <= '0;
        bank_tag_q[selected_start_bank] <= start_tag_i;
      end

      if (step_fire) begin
        emitted_step_count_o <= emitted_step_count_o + 64'd1;
        if (!emit_active_q) begin
          bank_ready_q[selected_emit_bank] <= 1'b0;
          emit_active_q <= 1'b1;
          emit_bank_q <= selected_emit_bank;
          emit_column_index_q <= 4'd1;
        end else if (emit_column_index_q == 4'd15) begin
          emit_active_q <= 1'b0;
          emit_column_index_q <= '0;
          done_o <= 1'b1;
          completed_tile_count_o <= completed_tile_count_o + 64'd1;
        end else begin
          emit_column_index_q <= emit_column_index_q + 4'd1;
        end
      end
    end
  end

  // The feeder FSM is the sole visibility qualifier for this bounded local
  // transpose payload.  Keep both the working set and the registered
  // Q/partitioned-K columns reset-free; with four partitions this avoids a
  // large asynchronous-reset branch at the array boundary.
  always_ff @(posedge clk_i) begin
    if (row_fire) begin
      q_row_working_q[load_bank_q][load_row_index_q] <= q_row_bf16_i;
      for (int part = 0; part < ROW_PARTITIONS; part++)
        k_partition_row_working_q[load_bank_q][part][load_row_index_q] <=
            k_partition_row_bf16_i[part];
    end
  end

  initial begin
    if (ROW_PARTITIONS < 1 || ROW_PARTITIONS > 16 ||
        (16 % ROW_PARTITIONS) != 0)
      $error("partitioned QK feeder ROW_PARTITIONS must divide 16");
  end
endmodule
