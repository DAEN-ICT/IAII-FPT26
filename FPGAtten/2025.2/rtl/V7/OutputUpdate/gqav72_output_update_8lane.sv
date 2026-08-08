module gqav72_output_update_8lane #(
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
  input  logic [255:0]             partial_fp32_i,
`else
  input  logic [31:0]              partial_fp32_i [8],
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
  output logic [255:0]             updated_fp32_o,
`else
  output logic [31:0]              updated_fp32_o [8],
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

  localparam int unsigned MUL_STAGES = 3;
  localparam int unsigned ADD_STAGES = 5;
  localparam int unsigned STATE_MEM_BANKS = 8;
  localparam int unsigned STATE_MEM_BANK_W = 256 / STATE_MEM_BANKS;
  localparam int unsigned SOURCE_SELECT_SLICES = 4;
  localparam int unsigned SOURCE_SELECT_SLICE_W =
      32 / SOURCE_SELECT_SLICES;

  typedef struct packed {
    logic [TXN_W-1:0]         txn_id;
    logic [STATE_SLOT_W-1:0]  state_slot;
    logic [3:0]               row_index;
    logic [OUTPUT_TILE_W-1:0] output_tile;
    logic [STATE_ADDR_W-1:0]  state_addr;
    logic                     first_context;
    logic                     last_context;
    logic [31:0]              running_sum;
  } update_meta_t;

  logic         output_state_valid_q [STATE_DEPTH];

  logic [STATE_MEM_BANK_W-1:0]
      state_mem_read_bank_q [STATE_MEM_BANKS];
  // Keep the forwarding payload physically lane-local.  Each lane samples
  // the retiring add result whenever the elastic pipeline advances; the
  // source-valid metadata decides whether that sample is observed.  This
  // removes the former 512-bit data-dependent CE tree while still freezing
  // the payload under output backpressure.
  (* keep = "true", dont_touch = "true" *)
  logic [31:0]  bypass_state_lane_q [8];
  logic         source_zero_q;
  logic         source_forward_q;
  logic         lane_advance_local [8];
  logic         front_capture_local [8];
  logic         operand_valid_local [8];
  logic         product_alternate_local [8];
  logic         product_alternate_slice_local [8][SOURCE_SELECT_SLICES];
  logic         product_zero_local [8];
  logic         product_zero_slice_local [8][SOURCE_SELECT_SLICES];
  logic         state_mem_read_enable;
  logic         state_mem_write_enable;
  logic         state_mem_read_enable_local [STATE_MEM_BANKS];
  logic         state_mem_write_enable_local [STATE_MEM_BANKS];
  logic         front_valid_q;
  logic         front_pending_state_valid_q;
  update_meta_t front_meta_q;
  // Preserve one alpha register per lane.  Without these attributes Vivado
  // merges the identical copies and recreates the long 32-multiplier route.
  (* keep = "true", dont_touch = "true" *)
  logic [31:0]  front_alpha_q [8];
  logic [31:0]  partial_input_lane [8];
  logic [31:0]  front_partial_q [8];

  // One reset-free operand boundary per lane breaks the synchronous BRAM
  // output -> 24x24 DSP path without changing the steady-state issue rate.
  // The alpha copies are protected because otherwise synthesis can merge the
  // identical lane registers and recreate a broad multiplier-input net.
  logic [31:0]  operand_state_q [8];
  logic [31:0]  operand_alternate_q [8];
  (* keep = "true", dont_touch = "true" *)
  logic [31:0]  operand_alpha_q [8];
  logic [31:0]  operand_partial_q [8];
  logic         operand_valid_q;
  logic         operand_use_alternate_q;
  logic         operand_use_zero_q;
  update_meta_t operand_meta_q;

  logic [MUL_STAGES-1:0] mul_valid_q;
  logic [MUL_STAGES-1:0] mul_use_alternate_q;
  logic [MUL_STAGES-1:0] mul_use_zero_q;
  update_meta_t           mul_meta_q [MUL_STAGES];
  logic [31:0]            mul_partial_q [MUL_STAGES][8];
  logic [31:0]            product_w [8];
  logic                   product_valid_w [8];
  logic [31:0]            state_product_w [8];
  logic                   state_product_valid_w [8];
  logic [31:0]            alternate_product_w [8];
  logic                   alternate_product_valid_w [8];
  logic [31:0]            zero_product_w [8];
  logic                   zero_product_valid_w [8];

  logic [ADD_STAGES-1:0] add_valid_q;
  update_meta_t           add_meta_q [ADD_STAGES];
  logic [31:0]            updated_w [8];
  logic                   updated_valid_w [8];
  logic [255:0]           updated_w_packed;

  logic [STATE_ADDR_W-1:0] input_state_addr_w;
  logic                    arith_rst_ni;
  logic                    advance;
  logic                    input_fire;
  logic                    address_hazard;
  logic                    forward_from_output;
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
  assign arith_rst_ni = rst_ni && !clear_i;
  assign advance = !add_valid_q[ADD_STAGES-1] || out_ready_i;
  // Speculative reads are invisible unless front_valid_q is set.  Freezing
  // only with the arithmetic pipeline removes input-valid/address/hazard from
  // the block-RAM enable while preserving backpressure alignment.
  assign state_mem_read_enable = advance;
  assign state_mem_write_enable =
      advance && add_valid_q[ADD_STAGES-1];
  assign forward_from_output = add_valid_q[ADD_STAGES-1] &&
      (add_meta_q[ADD_STAGES-1].state_addr == input_state_addr_w);
  assign pending_state_valid = output_state_valid_q[input_state_addr_w] ||
                               forward_from_output;
  assign in_ready_o = rst_ni && !clear_i &&
                      advance && !address_hazard;
  assign input_fire = in_valid_i && in_ready_o;
  assign out_valid_o = add_valid_q[ADD_STAGES-1];
  assign accepted_updates_cycle_o = input_fire ? 5'd8 : 5'd0;
  always_comb begin
    address_hazard = front_valid_q &&
        (front_meta_q.state_addr == input_state_addr_w);
    address_hazard |= operand_valid_q &&
        (operand_meta_q.state_addr == input_state_addr_w);
    for (int stage = 0; stage < MUL_STAGES; stage++)
      address_hazard |= mul_valid_q[stage] &&
          (mul_meta_q[stage].state_addr == input_state_addr_w);
    // The final add stage can be forwarded at the acceptance edge. Earlier
    // stages have no committed FP32 value and must retain conservative RAW
    // protection.
    for (int stage = 0; stage < ADD_STAGES - 1; stage++)
      address_hazard |= add_valid_q[stage] &&
          (add_meta_q[stage].state_addr == input_state_addr_w);
  end

  generate
    // Eight independent 32-bit lane banks serve one logical 8x8 output tile.
    // OUTPUT_TILES doubles to sixteen at the V7.2 integration boundary, so
    // the total architectural state capacity is preserved while arithmetic
    // width and local routing are halved.
    for (genvar state_bank = 0;
         state_bank < STATE_MEM_BANKS;
         state_bank++) begin : gen_state_mem_bank
      (* ram_style = "block" *)
      logic [STATE_MEM_BANK_W-1:0] bank_mem_q [STATE_DEPTH];

      gqav5_local_control_buffer i_read_enable_buffer (
        .in_i (state_mem_read_enable),
        .out_o(state_mem_read_enable_local[state_bank])
      );
      gqav5_local_control_buffer i_write_enable_buffer (
        .in_i (state_mem_write_enable),
        .out_o(state_mem_write_enable_local[state_bank])
      );

      always_ff @(posedge clk_i) begin
        if (state_mem_read_enable_local[state_bank])
          state_mem_read_bank_q[state_bank] <=
              bank_mem_q[input_state_addr_w];
        if (state_mem_write_enable_local[state_bank])
          bank_mem_q[add_meta_q[ADD_STAGES-1].state_addr] <=
              updated_w_packed[
                  state_bank * STATE_MEM_BANK_W +: STATE_MEM_BANK_W];
      end
    end

    for (genvar lane = 0; lane < 8; lane++) begin : gen_update_lane
      // Replicate the broad elastic controls at each arithmetic lane.  The
      // local advance freezes the operand, multiplier, add and forwarding
      // payload together, so backpressure cannot disturb their alignment.
      gqav5_local_control_buffer i_lane_advance_buffer (
        .in_i (advance),
        .out_o(lane_advance_local[lane])
      );
      gqav5_local_control_buffer i_front_capture_buffer (
        .in_i (input_fire),
        .out_o(front_capture_local[lane])
      );
      gqav5_local_control_buffer i_operand_valid_buffer (
        .in_i (operand_valid_q),
        .out_o(operand_valid_local[lane])
      );

      // Capture the retiring result on every advancing edge.  A forwarding
      // transaction accepted on that edge reaches the operand boundary on
      // the following advancing edge and therefore observes this old bypass
      // value through nonblocking-assignment semantics.  When stalled, both
      // bypass and operand registers hold together.
      always_ff @(posedge clk_i) begin
        if (front_capture_local[lane]) begin
          front_partial_q[lane] <= partial_input_lane[lane];
          front_alpha_q[lane]   <= alpha_fp32_i;
        end

        if (lane_advance_local[lane]) begin
          bypass_state_lane_q[lane] <= updated_w[lane];
          operand_state_q[lane] <= state_mem_read_bank_q[lane];
          operand_alternate_q[lane] <= bypass_state_lane_q[lane];
          operand_alpha_q[lane] <= front_alpha_q[lane];
          operand_partial_q[lane] <= front_partial_q[lane];

          mul_partial_q[0][lane] <= operand_partial_q[lane];
          for (int stage = 1; stage < MUL_STAGES; stage++)
            mul_partial_q[stage][lane] <=
                mul_partial_q[stage-1][lane];
        end
      end

      // Source selection is delayed with the multiplier metadata and applied
      // only after all three registered products.  State RAM, bypass and the
      // IEEE zero path therefore enter separate multiplier cones without a
      // source-select LUT ahead of any DSP.
      for (genvar source_slice = 0;
           source_slice < SOURCE_SELECT_SLICES;
           source_slice++) begin : gen_source_select_slice
        gqav5_local_control_buffer i_product_alternate_slice_buffer (
          .in_i (product_alternate_local[lane]),
          .out_o(product_alternate_slice_local[lane][source_slice])
        );
        gqav5_local_control_buffer i_product_zero_slice_buffer (
          .in_i (product_zero_local[lane]),
          .out_o(product_zero_slice_local[lane][source_slice])
        );
        assign product_w[lane][
            source_slice * SOURCE_SELECT_SLICE_W +:
            SOURCE_SELECT_SLICE_W] =
            product_zero_slice_local[lane][source_slice]
                ? zero_product_w[lane][
                    source_slice * SOURCE_SELECT_SLICE_W +:
                    SOURCE_SELECT_SLICE_W]
                : (product_alternate_slice_local[lane][source_slice]
                    ? alternate_product_w[lane][
                        source_slice * SOURCE_SELECT_SLICE_W +:
                        SOURCE_SELECT_SLICE_W]
                    : state_product_w[lane][
                        source_slice * SOURCE_SELECT_SLICE_W +:
                        SOURCE_SELECT_SLICE_W]);
      end

      gqav5_local_control_buffer i_product_alternate_buffer (
        .in_i (mul_use_alternate_q[MUL_STAGES-1]),
        .out_o(product_alternate_local[lane])
      );
      gqav5_local_control_buffer i_product_zero_buffer (
        .in_i (mul_use_zero_q[MUL_STAGES-1]),
        .out_o(product_zero_local[lane])
      );

`ifdef YOSYS
      assign partial_input_lane[lane] =
          partial_fp32_i[lane * 32 +: 32];
`else
      assign partial_input_lane[lane] = partial_fp32_i[lane];
`endif

      // The state-RAM path feeds a dedicated multiplier without a source mux.
      // Zero/forward cases use a parallel multiplier and select only after the
      // registered products.  This keeps the three-cycle multiply contract
      // while removing the RAMB36-DOUT -> source-select -> DSP critical arc.
      gqav7_fp32_mul_rne_pipe i_scale_state (
        .clk_i,
        .rst_ni        (arith_rst_ni),
        .advance_i     (lane_advance_local[lane]),
        .valid_i       (operand_valid_local[lane]),
        .a_fp32_i      (operand_state_q[lane]),
        .b_fp32_i      (operand_alpha_q[lane]),
        .valid_o       (state_product_valid_w[lane]),
        .product_fp32_o(state_product_w[lane])
      );

      gqav7_fp32_mul_rne_pipe i_scale_alternate (
        .clk_i,
        .rst_ni        (arith_rst_ni),
        .advance_i     (lane_advance_local[lane]),
        .valid_i       (operand_valid_local[lane]),
        .a_fp32_i      (operand_alternate_q[lane]),
        .b_fp32_i      (operand_alpha_q[lane]),
        .valid_o       (alternate_product_valid_w[lane]),
        .product_fp32_o(alternate_product_w[lane])
      );

      // Reuse the proven FP32 multiplier for the first-context zero source.
      // A literal zero result would not preserve signed-zero and 0*Inf/NaN
      // behavior, while the constant significand lets synthesis remove the
      // unnecessary general multiplier hardware where possible.
      gqav7_fp32_mul_rne_pipe i_scale_zero (
        .clk_i,
        .rst_ni        (arith_rst_ni),
        .advance_i     (lane_advance_local[lane]),
        .valid_i       (operand_valid_local[lane]),
        .a_fp32_i      (32'h0000_0000),
        .b_fp32_i      (operand_alpha_q[lane]),
        .valid_o       (zero_product_valid_w[lane]),
        .product_fp32_o(zero_product_w[lane])
      );
      assign product_valid_w[lane] = state_product_valid_w[lane];

      gqav7_fp32_add_rne_pipe i_add_partial (
        .clk_i,
        .rst_ni    (arith_rst_ni),
        .advance_i (lane_advance_local[lane]),
        .valid_i   (product_valid_w[lane]),
        .a_fp32_i  (product_w[lane]),
        .b_fp32_i  (mul_partial_q[MUL_STAGES-1][lane]),
        .valid_o   (updated_valid_w[lane]),
        .sum_fp32_o(updated_w[lane])
      );

`ifdef YOSYS
      assign updated_fp32_o[lane * 32 +: 32] = updated_w[lane];
`else
      assign updated_fp32_o[lane] = updated_w[lane];
`endif
      assign updated_w_packed[lane * 32 +: 32] = updated_w[lane];
    end
  endgenerate

  assign running_sum_fp32_o = add_meta_q[ADD_STAGES-1].running_sum;
  assign state_slot_o       = add_meta_q[ADD_STAGES-1].state_slot;
  assign row_index_o        = add_meta_q[ADD_STAGES-1].row_index;
  assign output_tile_o      = add_meta_q[ADD_STAGES-1].output_tile;
  assign first_context_o    = add_meta_q[ADD_STAGES-1].first_context;
  assign last_context_o     = add_meta_q[ADD_STAGES-1].last_context;
  assign txn_id_o           = add_meta_q[ADD_STAGES-1].txn_id;

  // Preserve the proven V5 synchronous BRAM read boundary. A first-context
  // update selects zero through source_zero_q, while a same-address update
  // accepted as the final prior value consumes the lane-local retiring
  // sample.  Wide payload remains reset-free and is qualified only by valid
  // metadata.
  always_ff @(posedge clk_i) begin
    // Arithmetic payload is qualified by the valid pipelines. Keep the wide
    // data registers reset-free to avoid a global reset tree across all lanes.
    if (advance) begin
      if (input_fire) begin
        front_meta_q.txn_id        <= txn_id_i;
        front_meta_q.state_slot    <= state_slot_i;
        front_meta_q.row_index     <= row_index_i;
        front_meta_q.output_tile   <= output_tile_i;
        front_meta_q.state_addr    <= input_state_addr_w;
        front_meta_q.first_context <= first_context_i;
        front_meta_q.last_context  <= last_context_i;
        front_meta_q.running_sum   <= running_sum_fp32_i;
        front_pending_state_valid_q <= pending_state_valid;
      end

      // Metadata is qualified exclusively by the resettable valid pipeline.
      // Keeping it out of the asynchronous-reset process lets the multiplier
      // input and the per-stage metadata registers pack locally around their
      // arithmetic lanes instead of extending the global reset tree.
      operand_meta_q <= front_meta_q;
      mul_meta_q[0] <= operand_meta_q;
      for (int stage = 1; stage < MUL_STAGES; stage++)
        mul_meta_q[stage] <= mul_meta_q[stage-1];
      add_meta_q[0] <= mul_meta_q[MUL_STAGES-1];
      for (int stage = 1; stage < ADD_STAGES; stage++)
        add_meta_q[stage] <= add_meta_q[stage-1];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      front_valid_q             <= 1'b0;
      operand_valid_q           <= 1'b0;
      operand_use_alternate_q   <= 1'b0;
      operand_use_zero_q        <= 1'b0;
      mul_valid_q               <= '0;
      mul_use_alternate_q       <= '0;
      mul_use_zero_q            <= '0;
      add_valid_q               <= '0;
      source_zero_q             <= 1'b0;
      source_forward_q          <= 1'b0;
      accepted_updates_total_o  <= '0;
      state_write_count_o       <= '0;
      forwarding_count_o        <= '0;
      hazard_stall_cycles_o     <= '0;
      protocol_error_o          <= 1'b0;
      for (int address = 0; address < STATE_DEPTH; address++) begin
`ifdef VERILATOR
        output_state_valid_q[address] = 1'b0;
`else
        output_state_valid_q[address] <= 1'b0;
`endif
      end
    end else if (clear_i) begin
      front_valid_q         <= 1'b0;
      operand_valid_q       <= 1'b0;
      operand_use_alternate_q <= 1'b0;
      operand_use_zero_q    <= 1'b0;
      mul_valid_q           <= '0;
      mul_use_alternate_q   <= '0;
      mul_use_zero_q        <= '0;
      add_valid_q           <= '0;
      source_zero_q         <= 1'b0;
      source_forward_q      <= 1'b0;
      protocol_error_o      <= 1'b0;
      for (int address = 0; address < STATE_DEPTH; address++) begin
`ifdef VERILATOR
        output_state_valid_q[address] = 1'b0;
`else
        output_state_valid_q[address] <= 1'b0;
`endif
      end
    end else begin
      if (in_valid_i && address_hazard)
        hazard_stall_cycles_o <= hazard_stall_cycles_o + 64'd1;
      // Check the state-valid contract from the registered front boundary.
      // This removes the final-bank-valid -> protocol-error combinational
      // path from the performance-critical acceptance edge.
      if (front_valid_q && !front_meta_q.first_context &&
          !front_pending_state_valid_q)
        protocol_error_o <= 1'b1;

      if (advance) begin
        front_valid_q <= input_fire;
        operand_valid_q <= front_valid_q;
        operand_use_alternate_q <= source_forward_q;
        operand_use_zero_q <= source_zero_q;
        mul_valid_q[0] <= operand_valid_q;
        mul_use_alternate_q[0] <= operand_use_alternate_q;
        mul_use_zero_q[0] <= operand_use_zero_q;
        for (int stage = 1; stage < MUL_STAGES; stage++)
          mul_valid_q[stage] <= mul_valid_q[stage-1];
        for (int stage = 1; stage < MUL_STAGES; stage++)
          mul_use_alternate_q[stage] <=
              mul_use_alternate_q[stage-1];
        for (int stage = 1; stage < MUL_STAGES; stage++)
          mul_use_zero_q[stage] <= mul_use_zero_q[stage-1];
        add_valid_q[0] <= mul_valid_q[MUL_STAGES-1];
        for (int stage = 1; stage < ADD_STAGES; stage++)
          add_valid_q[stage] <= add_valid_q[stage-1];

        if (input_fire) begin
          source_zero_q <= first_context_i;
          source_forward_q <= !first_context_i && forward_from_output;
          accepted_updates_total_o
              <= accepted_updates_total_o + 64'd8;
          if (!first_context_i && forward_from_output)
            forwarding_count_o <= forwarding_count_o + 64'd1;
        end

        if (add_valid_q[ADD_STAGES-1]) begin
          output_state_valid_q[
              add_meta_q[ADD_STAGES-1].state_addr] <= 1'b1;
          state_write_count_o <= state_write_count_o + 64'd1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni && !clear_i && advance) begin
      for (int lane = 1; lane < 8; lane++) begin
        if (product_valid_w[lane] != product_valid_w[0])
          $error("V7.2 8-lane output-update multiplier valid lanes diverged");
        if (updated_valid_w[lane] != updated_valid_w[0])
          $error("V7.2 8-lane output-update adder valid lanes diverged");
      end
      for (int lane = 0; lane < 8; lane++) begin
        if (state_product_valid_w[lane] !=
            alternate_product_valid_w[lane])
          $error("V7.2 8-lane output-update parallel multiplier valids diverged");
        if (state_product_valid_w[lane] != zero_product_valid_w[lane])
          $error("V7.2 8-lane output-update zero multiplier valid diverged");
      end
      if (product_valid_w[0] != mul_valid_q[MUL_STAGES-1])
        $error("V7.2 8-lane output-update multiplier metadata misaligned");
      if (updated_valid_w[0] != add_valid_q[ADD_STAGES-1])
        $error("V7.2 8-lane output-update adder metadata misaligned");
      if (source_zero_q && source_forward_q)
        $error("V7.2 8-lane output-update state sources are not one-hot");
    end
  end
`endif

  initial begin
    if ((STATE_SLOTS < 1) || (STATE_SLOTS > 16) ||
        ((STATE_SLOTS > 1) && ((1 << STATE_SLOT_W) != STATE_SLOTS)))
      $error("V7.2 8-lane output-update STATE_SLOTS must be a power of two in [1,16]");
    if ((OUTPUT_TILES < 1) || (OUTPUT_TILES > 16) ||
        ((OUTPUT_TILES > 1) && ((1 << OUTPUT_TILE_W) != OUTPUT_TILES)))
      $error("V7.2 8-lane output-update OUTPUT_TILES must be a power of two in [1,16]");
  end
endmodule
