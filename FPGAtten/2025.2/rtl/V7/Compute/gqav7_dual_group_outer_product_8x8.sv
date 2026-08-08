module gqav7_dual_group_outer_product_8x8 #(
  parameter int unsigned CONTEXTS = 8,
  localparam int unsigned CONTEXT_W =
      (CONTEXTS <= 1) ? 1 : $clog2(CONTEXTS)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic valid_i,
  output logic ready_o,
  input  logic [CONTEXT_W-1:0] context_i,
  input  logic first_i,
  input  logic last_i,
  input  logic [7:0] row_valid_i,
  input  logic [7:0] col_valid_i,
  input  logic [15:0] a_bf16_i [8],
  input  logic [15:0] b_group_bf16_i [2][8],

  output logic result_valid_o,
  input  logic result_ready_i,
  output logic [CONTEXT_W-1:0] result_context_o,
  output logic [2:0] result_row_o,
  output logic [31:0] result_data_o [8],
  output logic result_last_o,

  output logic [63:0] accepted_macs_o,
  output logic protocol_error_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  localparam int unsigned MUL_LATENCY = 3;
  localparam int unsigned ADD_LATENCY = 5;
  localparam int unsigned TOTAL_LATENCY = MUL_LATENCY + ADD_LATENCY;
  localparam int unsigned PRODUCT_TAG_STAGE = MUL_LATENCY - 1;

  logic [31:0] accumulator_compute_read [8][8];
  logic [31:0] accumulator_result_read [8][8];
  logic context_busy_q [CONTEXTS];
  logic result_pending_q [CONTEXTS];
  logic [TOTAL_LATENCY-1:0] retire_valid_q;
  logic [CONTEXT_W-1:0] retire_context_q [TOTAL_LATENCY];
  logic retire_last_q [TOTAL_LATENCY];
  logic retire_first_q [TOTAL_LATENCY];
  logic [7:0] retire_row_valid_q [TOTAL_LATENCY];
  logic [7:0] retire_col_valid_q [TOTAL_LATENCY];

  logic [31:0] product [8][8];
  logic product_valid [8][8];
  logic [31:0] add_input_a [8][8];
  logic [31:0] add_result [8][8];
  logic add_valid [8][8];
  logic accept;
  logic retire;
  logic [6:0] accepted_macs_cycle;

  logic result_active_q;
  logic [CONTEXT_W-1:0] result_context_q;
  // Each row owns a local result-RAM address copy.  The eight copies are
  // deliberately kept separate so a single small context register does not
  // have to drive every distributed-RAM address pin in the 8x8 array.
  (* keep = "true", max_fanout = 32 *)
  logic [CONTEXT_W-1:0] result_context_row_q [8];
  logic [2:0] result_row_q;

  assign ready_o =
      ((!context_busy_q[context_i]) ||
       (retire &&
        (retire_context_q[TOTAL_LATENCY-1] == context_i) &&
        !retire_last_q[TOTAL_LATENCY-1])) &&
      !result_pending_q[context_i];
  assign accept = valid_i && ready_o;
  assign retire = retire_valid_q[TOTAL_LATENCY-1];
  assign result_valid_o = result_active_q;
  assign result_context_o = result_context_q;
  assign result_row_o = result_row_q;
  assign result_last_o = result_active_q && (result_row_q == 3'd7);

  always_comb begin
    accepted_macs_cycle = '0;
    for (int row = 0; row < 8; row++) begin
      if (row_valid_i[row])
        accepted_macs_cycle =
            accepted_macs_cycle + 7'($countones(col_valid_i));
    end
  end

  always_comb begin
    for (int col = 0; col < 8; col++)
      result_data_o[col] =
          accumulator_result_read[result_row_q][col];
  end

  generate
    for (genvar row = 0; row < 8; row++) begin : gen_row
      localparam int unsigned GROUP_INDEX = row / 4;
      // Preserve the existing pipeline alignment while localizing the RAM
      // addresses to one arithmetic row.  At a clock edge these registers
      // take the same values that the corresponding shared pipeline stages
      // take, but their physical fanout is limited to the eight lanes below.
      (* keep = "true", max_fanout = 32 *)
      logic [CONTEXT_W-1:0] accumulator_compute_context_q;
      (* keep = "true", max_fanout = 32 *)
      logic [CONTEXT_W-1:0] accumulator_write_context_q;
      (* keep = "true", max_fanout = 32 *)
      logic accumulator_write_first_q;

      always_ff @(posedge clk_i) begin
        accumulator_compute_context_q <=
            retire_context_q[PRODUCT_TAG_STAGE-1];
        accumulator_write_context_q <=
            retire_context_q[TOTAL_LATENCY-2];
        accumulator_write_first_q <=
            retire_first_q[TOTAL_LATENCY-2];
      end

      for (genvar col = 0; col < 8; col++) begin : gen_col
        // The recurrence and result-drain paths need independent asynchronous
        // accumulator reads.  Keep two small, local distributed-RAM mirrors
        // per arithmetic lane and write them together at retirement.  This
        // replaces the wide context register matrix and prevents the compute
        // context and result context from becoming global data mux controls.
        (* ram_style = "distributed", rw_addr_collision = "no" *)
        logic [31:0] accumulator_compute_ram_q [CONTEXTS];
        (* ram_style = "distributed", rw_addr_collision = "no" *)
        logic [31:0] accumulator_result_ram_q [CONTEXTS];

        assign accumulator_compute_read[row][col] =
            accumulator_compute_ram_q[accumulator_compute_context_q];
        assign accumulator_result_read[row][col] =
            accumulator_result_ram_q[result_context_row_q[row]];

        always_ff @(posedge clk_i) begin
          if (retire) begin
            if (retire_row_valid_q[TOTAL_LATENCY-1][row] &&
                retire_col_valid_q[TOTAL_LATENCY-1][col]) begin
              accumulator_compute_ram_q[
                accumulator_write_context_q
              ] <= add_result[row][col];
              accumulator_result_ram_q[
                accumulator_write_context_q
              ] <= add_result[row][col];
            end else if (accumulator_write_first_q) begin
              accumulator_compute_ram_q[
                accumulator_write_context_q
              ] <= '0;
              accumulator_result_ram_q[
                accumulator_write_context_q
              ] <= '0;
            end
          end
        end

        gqav7_bf16_mul_fp32_pipe i_multiply (
          .clk_i,
          .rst_ni,
          .valid_i(accept),
          .a_bf16_i(a_bf16_i[row]),
          .b_bf16_i(b_group_bf16_i[GROUP_INDEX][col]),
          .valid_o(product_valid[row][col]),
          .product_fp32_o(product[row][col])
        );

        assign add_input_a[row][col] =
            retire_first_q[PRODUCT_TAG_STAGE]
            ? 32'h0000_0000
            : accumulator_compute_read[row][col];

        gqav7_fp32_add_rne_pipe i_accumulate (
          .clk_i,
          .rst_ni,
          .advance_i(1'b1),
          .valid_i(product_valid[row][col]),
          .a_fp32_i(add_input_a[row][col]),
          .b_fp32_i(product[row][col]),
          .valid_o(add_valid[row][col]),
          .sum_fp32_o(add_result[row][col])
        );
      end
    end
  endgenerate

  // Retirement tags are payload owned exclusively by retire_valid_q.  Shift
  // them every cycle instead of holding them behind rst_ni; otherwise the
  // synchronous reset condition becomes a high-fanout CE on every replicated
  // tag register in the arithmetic array.  Stale tag values remain invisible
  // while retire_valid_q is clear.
  always_ff @(posedge clk_i) begin : p_retire_payload
    retire_context_q[0] <= context_i;
    retire_first_q[0] <= first_i;
    retire_last_q[0] <= last_i;
    retire_row_valid_q[0] <= row_valid_i;
    retire_col_valid_q[0] <= col_valid_i;
    for (int stage = 1; stage < TOTAL_LATENCY; stage++) begin
      retire_context_q[stage] <= retire_context_q[stage-1];
      retire_first_q[stage] <= retire_first_q[stage-1];
      retire_last_q[stage] <= retire_last_q[stage-1];
      retire_row_valid_q[stage] <= retire_row_valid_q[stage-1];
      retire_col_valid_q[stage] <= retire_col_valid_q[stage-1];
    end
  end

  always_ff @(posedge clk_i) begin : p_control
    if (!rst_ni) begin
      retire_valid_q <= '0;
      accepted_macs_o <= '0;
      protocol_error_o <= 1'b0;
      result_active_q <= 1'b0;
      result_context_q <= '0;
      result_row_q <= '0;
      for (int row = 0; row < 8; row++)
        result_context_row_q[row] <= '0;
      for (int ctx = 0; ctx < CONTEXTS; ctx++) begin
        context_busy_q[ctx] <= 1'b0;
        result_pending_q[ctx] <= 1'b0;
      end
    end else begin
      retire_valid_q[0] <= accept;
      for (int stage = 1; stage < TOTAL_LATENCY; stage++)
        retire_valid_q[stage] <= retire_valid_q[stage-1];

      if (accept) begin
        context_busy_q[context_i] <= 1'b1;
        accepted_macs_o <= accepted_macs_o + 64'(accepted_macs_cycle);
      end

      if (retire) begin
        context_busy_q[retire_context_q[TOTAL_LATENCY-1]] <= 1'b0;
        if (retire_last_q[TOTAL_LATENCY-1]) begin
          result_pending_q[retire_context_q[TOTAL_LATENCY-1]] <= 1'b1;
        end
      end

      // A recurrence context may be re-issued on the same edge that its
      // previous value retires. The new product reaches the adder later and
      // therefore observes the accumulator value written by this retirement.
      if (accept)
        context_busy_q[context_i] <= 1'b1;

      if (!result_active_q) begin
        // Nonblocking assignments from a forward loop resolve to the final
        // matching context.  Scan downward so the retained assignment is the
        // lowest pending context: with two tile-context banks this preserves
        // tile order while one tile's result RAM drains beside the next tile's
        // MAC recurrence.
        for (int ctx = CONTEXTS - 1; ctx >= 0; ctx--) begin
          if (result_pending_q[ctx] && !result_active_q) begin
            result_active_q <= 1'b1;
            result_context_q <= CONTEXT_W'(ctx);
            for (int row = 0; row < 8; row++)
              result_context_row_q[row] <= CONTEXT_W'(ctx);
            result_row_q <= '0;
          end
        end
      end else if (result_ready_i) begin
        if (result_row_q == 3'd7) begin
          result_active_q <= 1'b0;
          result_pending_q[result_context_q] <= 1'b0;
          result_row_q <= '0;
        end else begin
          result_row_q <= result_row_q + 3'd1;
        end
      end

      if (retire && !add_valid[0][0])
        protocol_error_o <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  // Every arithmetic lane receives the same valid pipeline by construction.
  // Keep divergence checking in simulation instead of building a 64-input
  // hardware error cone into the routed compute array.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int row = 0; row < 8; row++)
        for (int col = 0; col < 8; col++)
          if (add_valid[row][col] != add_valid[0][0])
            $error("V7 dual-group add-valid lanes diverged");
    end
  end
`endif

  initial begin
    if (CONTEXTS < TOTAL_LATENCY)
      $error("CONTEXTS must cover the complete MAC recurrence latency");
  end
endmodule
