`timescale 1ns/1ps
// V7 iteration of the proven V5 Z19-P differential-clock wrapper.
// The board supplies one 200 MHz differential reference.  MIG remains on
// that native clock.  Independent UltraScale+ MMCMs generate 235 MHz for the
// accelerator core and 300 MHz for DMA.  The separate MMCM roots preserve the
// proven V5 split-domain architecture and keep async-FIFO RAMs unambiguously
// CLOCK_DOMAINS=INDEPENDENT while allowing DMA to match the native 300 MHz MIG
// AXI UI rate without tightening the compute domain.
module gqav7_pl_diff_clock_buffer (
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock_rtl:1.0 CLK_IN CLK_P" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK_IN, FREQ_HZ 200000000" *)
  input  wire clk_p,
  (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock_rtl:1.0 CLK_IN CLK_N" *)
  input  wire clk_n,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_200_o CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_200_o, FREQ_HZ 200000000" *)
  output wire clk_200_o,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_fabric_o CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_fabric_o, FREQ_HZ 235000000" *)
  output wire clk_fabric_o,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_dma_o CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_dma_o, FREQ_HZ 300000000" *)
  output wire clk_dma_o,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 clock_locked_o RST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clock_locked_o, POLARITY ACTIVE_HIGH" *)
  output wire clock_locked_o
);

  wire clk_ibuf;
  // Preserve the proven hierarchy identifiers.  The actual frequency is
  // defined by the MMCM parameters below.
  wire clk_core_235_unbuf;
  wire clk_dma_300_unbuf;
  wire clk_core_feedback;
  wire clk_core_feedback_buf;
  wire clk_dma_feedback;
  wire clk_dma_feedback_buf;
  wire core_locked;
  wire dma_locked;

  IBUFDS #(
    .IBUF_LOW_PWR("FALSE")
  ) u_ibufds (
    .I (clk_p),
    .IB(clk_n),
    .O (clk_ibuf)
  );

  BUFG u_bufg_mig_200m (
    .I(clk_ibuf),
    .O(clk_200_o)
  );

  BUFG u_bufg_core_mmcm_feedback (
    .I(clk_core_feedback),
    .O(clk_core_feedback_buf)
  );

  MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(11.750),
    .CLKIN1_PERIOD(5.000),
    .CLKOUT0_DIVIDE_F(5.000),
    .DIVCLK_DIVIDE(2),
    .STARTUP_WAIT("FALSE")
  ) u_mmcm_core_235m (
    .CLKIN1(clk_ibuf),
    .CLKFBIN(clk_core_feedback_buf),
    .RST(1'b0),
    .PWRDWN(1'b0),
    .CLKFBOUT(clk_core_feedback),
    .CLKOUT0(clk_core_235_unbuf),
    .LOCKED(core_locked)
  );

  BUFG u_bufg_dma_mmcm_feedback (
    .I(clk_dma_feedback),
    .O(clk_dma_feedback_buf)
  );

  MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(6.000),
    .CLKIN1_PERIOD(5.000),
    .CLKOUT0_DIVIDE_F(4.000),
    .DIVCLK_DIVIDE(1),
    .STARTUP_WAIT("FALSE")
  ) u_mmcm_dma_300m (
    .CLKIN1(clk_ibuf),
    .CLKFBIN(clk_dma_feedback_buf),
    .RST(1'b0),
    .PWRDWN(1'b0),
    .CLKFBOUT(clk_dma_feedback),
    .CLKOUT0(clk_dma_300_unbuf),
    .LOCKED(dma_locked)
  );

  BUFG u_bufg_core_235m (
    .I(clk_core_235_unbuf),
    .O(clk_fabric_o)
  );

  BUFG u_bufg_dma_300m (
    .I(clk_dma_300_unbuf),
    .O(clk_dma_o)
  );

  assign clock_locked_o = core_locked && dma_locked;

endmodule
