module gqav5_output_update_16lane #(
  parameter int unsigned STATE_SLOTS  = 4,
  parameter int unsigned OUTPUT_TILES = 8,
  parameter int unsigned TXN_W        = 16,
  localparam int unsigned STATE_SLOT_W =
      (STATE_SLOTS <= 1) ? 1 : $clog2(STATE_SLOTS),
  localparam int unsigned OUTPUT_TILE_W =
      (OUTPUT_TILES <= 1) ? 1 : $clog2(OUTPUT_TILES),
  localparam int unsigned STATE_DEPTH = STATE_SLOTS * 16 * OUTPUT_TILES,
  localparam int unsigned STATE_ADDR_W =
      (STATE_DEPTH <= 1) ? 1 : $clog2(STATE_DEPTH)
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  logic                     clear_i,

  input  logic                     in_valid_i,
  output logic                     in_ready_o,
`ifdef YOSYS
  input  logic [511:0]             partial_fp32_i,
`else
  input  logic [31:0]              partial_fp32_i [16],
`endif
  input  logic [31:0]              alpha_fp32_i,
  input  logic [31:0]              running_sum_fp32_i,
  input  logic [STATE_SLOT_W-1:0]  state_slot_i,
  input  logic [3:0]               row_index_i,
  input  logic [OUTPUT_TILE_W-1:0] output_tile_i,
  input  logic                     first_context_i,
  input  logic                     last_context_i,
  input  logic [TXN_W-1:0]         txn_id_i,

  output logic                     out_valid_o,
  input  logic                     out_ready_i,
`ifdef YOSYS
  output logic [511:0]             updated_fp32_o,
`else
  output logic [31:0]              updated_fp32_o [16],
`endif
  output logic [31:0]              running_sum_fp32_o,
  output logic [STATE_SLOT_W-1:0]  state_slot_o,
  output logic [3:0]               row_index_o,
  output logic [OUTPUT_TILE_W-1:0] output_tile_o,
  output logic                     first_context_o,
  output logic                     last_context_o,
  output logic [TXN_W-1:0]         txn_id_o,

  output logic [4:0]               accepted_updates_cycle_o,
  output logic [63:0]              accepted_updates_total_o,
  output logic [63:0]              state_write_count_o,
  output logic [63:0]              forwarding_count_o,
  output logic [63:0]              hazard_stall_cycles_o,
  output logic                     protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  typedef struct packed {
    logic [TXN_W-1:0]         txn_id;
    logic [STATE_SLOT_W-1:0]  state_slot;
    logic [3:0]               row_index;
    logic [OUTPUT_TILE_W-1:0] output_tile;
    logic [STATE_ADDR_W-1:0]  state_addr;
    logic                     first_context;
    logic                     last_context;
    logic [31:0]              alpha;
    logic [31:0]              running_sum;
  } update_meta_t;

  (* ram_style = "block" *)
  logic [511:0] output_state_mem_q [STATE_DEPTH];
  logic        output_state_valid_q [STATE_DEPTH];

  logic [2:0]  pipe_valid_q;
  update_meta_t meta_q [3];
  logic [511:0] state_mem_read_packed_q;
  logic [511:0] bypass_state_packed_q;
  logic         use_bypass_q;
  logic [31:0] partial_input_lane [16];
  logic [31:0] partial_q [0:1][16];
  logic [31:0] product_q [16];
  logic [31:0] updated_q [16];
  logic [31:0] product_w [16];
  logic [31:0] updated_w [16];
  logic [511:0] updated_q_packed;
  logic [511:0] updated_w_packed;
  logic [511:0] old_state_packed_w;

  logic [STATE_ADDR_W-1:0] input_state_addr_w;
  logic                    advance;
  logic                    input_fire;
  logic                    q0_address_hazard;
  logic                    forward_from_q1;
  logic                    forward_from_q2;
  logic                    pending_state_valid;

  function automatic logic [STATE_ADDR_W-1:0] form_state_address(
    input logic [STATE_SLOT_W-1:0]  slot,
    input logic [3:0]               row_index,
    input logic [OUTPUT_TILE_W-1:0] output_tile
  );
    begin
      form_state_address =
          (STATE_ADDR_W'(slot) * STATE_ADDR_W'(16 * OUTPUT_TILES)) +
          (STATE_ADDR_W'(row_index) * STATE_ADDR_W'(OUTPUT_TILES)) +
          STATE_ADDR_W'(output_tile);
    end
  endfunction

  assign input_state_addr_w = form_state_address(
      state_slot_i, row_index_i, output_tile_i);
  assign advance            = !pipe_valid_q[2] || out_ready_i;
  assign q0_address_hazard  = pipe_valid_q[0] &&
                              (meta_q[0].state_addr == input_state_addr_w);
  assign forward_from_q1    = pipe_valid_q[1] &&
                              (meta_q[1].state_addr == input_state_addr_w);
  assign forward_from_q2    = pipe_valid_q[2] &&
                              (meta_q[2].state_addr == input_state_addr_w);
  assign pending_state_valid = output_state_valid_q[input_state_addr_w] ||
                               forward_from_q1 || forward_from_q2;
  assign in_ready_o          = advance && !q0_address_hazard;
  assign input_fire          = in_valid_i && in_ready_o;
  assign out_valid_o         = pipe_valid_q[2];
  assign accepted_updates_cycle_o = input_fire ? 5'd16 : 5'd0;
  assign old_state_packed_w  = use_bypass_q ? bypass_state_packed_q
                                             : state_mem_read_packed_q;

  generate
    for (genvar lane = 0; lane < 16; lane++) begin : gen_update_lane
`ifdef YOSYS
      assign partial_input_lane[lane] =
          partial_fp32_i[lane * 32 +: 32];
`else
      assign partial_input_lane[lane] = partial_fp32_i[lane];
`endif

      gqav5_fp32_mul_rne i_scale_old (
        .a_fp32_i      (old_state_packed_w[lane * 32 +: 32]),
        .b_fp32_i      (meta_q[0].alpha),
        .product_fp32_o(product_w[lane])
      );

      gqav5_fp32_add_rne i_add_partial (
        .a_fp32_i  (product_q[lane]),
        .b_fp32_i  (partial_q[1][lane]),
        .sum_fp32_o(updated_w[lane])
      );

`ifdef YOSYS
      assign updated_fp32_o[lane * 32 +: 32] = updated_q[lane];
`else
      assign updated_fp32_o[lane] = updated_q[lane];
`endif
      assign updated_q_packed[lane * 32 +: 32] = updated_q[lane];
      assign updated_w_packed[lane * 32 +: 32] = updated_w[lane];
    end
  endgenerate

  assign running_sum_fp32_o = meta_q[2].running_sum;
  assign state_slot_o       = meta_q[2].state_slot;
  assign row_index_o        = meta_q[2].row_index;
  assign output_tile_o      = meta_q[2].output_tile;
  assign first_context_o    = meta_q[2].first_context;
  assign last_context_o     = meta_q[2].last_context;
  assign txn_id_o           = meta_q[2].txn_id;

  // The output-state payload is qualified by pipe/state-valid metadata.  Keep
  // the memory read as a dedicated synchronous read register; mixing its data
  // assignment with the first-context/RAW-forwarding mux makes synthesis see
  // an asynchronous read port.  The small bypass register samples forwarding
  // data at acceptance, while the 512x512-bit state store remains a block-RAM
  // candidate.
  always_ff @(posedge clk_i) begin
    if (advance && input_fire)
      state_mem_read_packed_q <= output_state_mem_q[input_state_addr_w];
    if (advance && input_fire) begin
      if (first_context_i)
        bypass_state_packed_q <= '0;
      else if (forward_from_q1)
        bypass_state_packed_q <= updated_w_packed;
      else if (forward_from_q2)
        bypass_state_packed_q <= updated_q_packed;
    end
    if (advance && pipe_valid_q[1])
      output_state_mem_q[meta_q[1].state_addr] <= updated_w_packed;

    // Arithmetic pipeline payload is fully qualified by pipe_valid_q.  Keep
    // these 2,048 data bits off the asynchronous reset tree; a bubble or
    // clear only invalidates them and never observes their stale contents.
    if (advance) begin
      if (input_fire) begin
        for (int lane = 0; lane < 16; lane++)
          partial_q[0][lane] <= partial_input_lane[lane];
      end
      for (int lane = 0; lane < 16; lane++) begin
        product_q[lane]    <= product_w[lane];
        partial_q[1][lane] <= partial_q[0][lane];
        updated_q[lane]    <= updated_w[lane];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pipe_valid_q             <= '0;
      use_bypass_q             <= 1'b0;
      accepted_updates_total_o <= '0;
      state_write_count_o      <= '0;
      forwarding_count_o       <= '0;
      hazard_stall_cycles_o    <= '0;
      protocol_error_o         <= 1'b0;
      for (int stage = 0; stage < 3; stage++)
        meta_q[stage] <= '0;
      for (int address = 0; address < STATE_DEPTH; address++)
        output_state_valid_q[address] <= 1'b0;
    end else if (clear_i) begin
      pipe_valid_q         <= '0;
      use_bypass_q         <= 1'b0;
      protocol_error_o     <= 1'b0;
      for (int address = 0; address < STATE_DEPTH; address++)
        output_state_valid_q[address] <= 1'b0;
    end else begin
      if (in_valid_i && q0_address_hazard)
        hazard_stall_cycles_o <= hazard_stall_cycles_o + 64'd1;
      if (input_fire && !first_context_i && !pending_state_valid)
        protocol_error_o <= 1'b1;
      if (advance) begin
        pipe_valid_q[2] <= pipe_valid_q[1];
        pipe_valid_q[1] <= pipe_valid_q[0];
        pipe_valid_q[0] <= input_fire;
        meta_q[2]       <= meta_q[1];
        meta_q[1]       <= meta_q[0];

        if (input_fire) begin
          use_bypass_q              <= first_context_i ||
                                       forward_from_q1 ||
                                       forward_from_q2;
          meta_q[0].txn_id        <= txn_id_i;
          meta_q[0].state_slot    <= state_slot_i;
          meta_q[0].row_index     <= row_index_i;
          meta_q[0].output_tile   <= output_tile_i;
          meta_q[0].state_addr    <= input_state_addr_w;
          meta_q[0].first_context <= first_context_i;
          meta_q[0].last_context  <= last_context_i;
          meta_q[0].alpha         <= alpha_fp32_i;
          meta_q[0].running_sum   <= running_sum_fp32_i;
          accepted_updates_total_o <= accepted_updates_total_o + 64'd16;
          if (!first_context_i && (forward_from_q1 || forward_from_q2))
            forwarding_count_o <= forwarding_count_o + 64'd1;
        end

        if (pipe_valid_q[1]) begin
          output_state_valid_q[meta_q[1].state_addr] <= 1'b1;
          state_write_count_o <= state_write_count_o + 64'd1;
        end
      end
    end
  end

  initial begin
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16) ||
        ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS)))
      $error("output-update STATE_SLOTS must be a power of two in [1,16]");
    if ((OUTPUT_TILES < 1) || (OUTPUT_TILES > 16) ||
        ((OUTPUT_TILES > 1) && ((1 << OUTPUT_TILE_W) != OUTPUT_TILES)))
      $error("output-update OUTPUT_TILES must be a power of two in [1,16]");
  end
endmodule
