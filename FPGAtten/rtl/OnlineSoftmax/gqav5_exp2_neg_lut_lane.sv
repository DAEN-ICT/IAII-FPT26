module gqav5_exp2_neg_lut_lane #(
  parameter bit CHECK_SENTINEL = 1'b0
) (
  input  logic        clk_i,
  input  logic [31:0] x_fp32_i,
  output logic [15:0] y_bf16_o,
  output logic [31:0] y_fp32_o,
  output logic        rom_sentinel_ok_o
);
`ifndef YOSYS
  timeunit 1ns;
  timeprecision 1ps;
`endif

  // One physical copy per lane gives every lookup a local synchronous read
  // port. The registered read is required for block-ROM inference on Xilinx
  // devices and avoids a 17-way asynchronous LUT-ROM/mux fabric. The legacy
  // BF16 image is exactly RNE(FP32) at every address, so hardware stores only
  // FP32 and derives BF16 locally instead of consuming a second RAMB per lane.
  // V5.6 expands the domain from [0,16) to [0,32) at the same 1/128 grid.
  // The extra 34 RAMB36 blocks across 17 lanes avoid dropping thousands of
  // individually-small but collectively-relevant terms in 8K prefill.
  (* rom_style = "block" *) logic [31:0] fp32_rom [0:4095];

  logic [11:0] address_w;
  logic [11:0] address_q;
  logic        is_nan_w;
  logic        force_zero_w;
  logic        force_one_w;
  logic [31:0] rom_fp32_q;
  logic        is_nan_address_q;
  logic        force_zero_address_q;
  logic        force_one_address_q;
  logic        is_nan_q;
  logic        force_zero_q;
  logic        force_one_q;

  function automatic logic [11:0] magnitude_times_128_index(
    input logic [30:0] value
  );
    logic [23:0] significand;
    logic [12:0] rounded_index;
    begin
      significand = {1'b1, value[22:0]};

      // The scaled online-softmax argument is clamped to the exp2 ROM domain
      // [0,32).  The previous generic variable shift synthesized a barrel
      // shifter plus a wide rounding carry chain on every lane.  Only biased
      // exponents 119..131 can produce a non-saturated 12-bit index, so use
      // fixed shifts selected by the exponent.  This is bit-exact with
      // round(abs(x)*128) and leaves the ROM issue rate at one lookup/cycle.
      unique case (value[30:23])
        8'd119: rounded_index =
            13'(({8'd0, significand} + 32'h0080_0000) >> 24);
        8'd120: rounded_index =
            13'(({8'd0, significand} + 32'h0040_0000) >> 23);
        8'd121: rounded_index =
            13'(({8'd0, significand} + 32'h0020_0000) >> 22);
        8'd122: rounded_index =
            13'(({8'd0, significand} + 32'h0010_0000) >> 21);
        8'd123: rounded_index =
            13'(({8'd0, significand} + 32'h0008_0000) >> 20);
        8'd124: rounded_index =
            13'(({8'd0, significand} + 32'h0004_0000) >> 19);
        8'd125: rounded_index =
            13'(({8'd0, significand} + 32'h0002_0000) >> 18);
        8'd126: rounded_index =
            13'(({8'd0, significand} + 32'h0001_0000) >> 17);
        8'd127: rounded_index =
            13'(({8'd0, significand} + 32'h0000_8000) >> 16);
        8'd128: rounded_index =
            13'(({8'd0, significand} + 32'h0000_4000) >> 15);
        8'd129: rounded_index =
            13'(({8'd0, significand} + 32'h0000_2000) >> 14);
        8'd130: rounded_index =
            13'(({8'd0, significand} + 32'h0000_1000) >> 13);
        8'd131: rounded_index =
            13'(({8'd0, significand} + 32'h0000_0800) >> 12);
        default: begin
          if ((value[30:23] == 0) || (value[30:23] <= 8'd118))
            rounded_index = 13'd0;
          else
            rounded_index = 13'h1000;
        end
      endcase

      magnitude_times_128_index = rounded_index[12]
          ? 12'hfff : rounded_index[11:0];
    end
  endfunction

  function automatic logic [15:0] fp32_to_bf16_rne(
    input logic [31:0] value
  );
    logic is_nan;
    logic round_up;
    begin
      is_nan = (value[30:23] == 8'hff) && (value[22:0] != 23'd0);
      round_up = (value[15:0] > 16'h8000) ||
                 ((value[15:0] == 16'h8000) && value[16]);
      if (is_nan)
        fp32_to_bf16_rne = {value[31], 8'hff, 1'b1, value[21:16]};
      else
        fp32_to_bf16_rne = value[31:16] + 16'(round_up);
    end
  endfunction

  always_comb begin
    address_w    = magnitude_times_128_index(x_fp32_i[30:0]);
    is_nan_w     = (x_fp32_i[30:23] == 8'hff) &&
                   (x_fp32_i[22:0] != '0);
    force_one_w  = !x_fp32_i[31] || (x_fp32_i[30:0] == '0);
    force_zero_w = x_fp32_i[31] &&
                   ((x_fp32_i[30:23] == 8'hff) ||
                   ((address_w == 12'hfff) &&
                     (x_fp32_i[30:23] >= 8'd132)));
  end

  always_ff @(posedge clk_i) begin
    // Keep the exponent/rounding cone local to the scale result and register
    // the ROM address before crossing to the replicated block RAM.  The
    // previous direct scale-register -> BRAM-address path was dominated by
    // long routing at 250 MHz.  This extra stage preserves one lookup/cycle.
    address_q            <= address_w;
    is_nan_address_q     <= is_nan_w;
    force_zero_address_q <= force_zero_w;
    force_one_address_q  <= force_one_w;

    rom_fp32_q   <= fp32_rom[address_q];
    is_nan_q     <= is_nan_address_q;
    force_zero_q <= force_zero_address_q;
    force_one_q  <= force_one_address_q;
  end

  always_comb begin
    if (is_nan_q) begin
      y_fp32_o = 32'h7fc0_0000;
    end else if (force_zero_q) begin
      y_fp32_o = 32'h0000_0000;
    end else if (force_one_q) begin
      y_fp32_o = 32'h3f80_0000;
    end else begin
      y_fp32_o = rom_fp32_q;
    end
  end

  assign y_bf16_o = fp32_to_bf16_rne(y_fp32_o);

  generate
    if (CHECK_SENTINEL) begin : gen_sentinel
      // Hash checks protect every copied image before synthesis. This retained
      // constant sentinel additionally prevents an absent/all-zero image from
      // silently passing simulation and implementation integration.
      assign rom_sentinel_ok_o = (fp32_rom[0] == 32'h3f80_0000) &&
                                 (fp32_rom[128] == 32'h3f00_0000);
    end else begin : gen_no_sentinel
      assign rom_sentinel_ok_o = 1'b1;
    end
  endgenerate

  initial begin
`ifdef SYNTHESIS
    $readmemh("exp2_neg_fp32_lut_4096.mem", fp32_rom);
`else
    $readmemh("rtl/OnlineSoftmax/rom/exp2_neg_fp32_lut_4096.mem", fp32_rom);
`endif
  end
endmodule
