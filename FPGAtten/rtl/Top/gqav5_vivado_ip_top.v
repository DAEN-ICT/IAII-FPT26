`timescale 1ns/1ps
// Verilog-2001 Vivado IP Integrator module-reference shell. It carries only canonical interface metadata
// and one-to-one port adaptation; all control, buffering and data movement
// remain inside gqav5_axi_accelerator_top.
module gqav5_vivado_ip_top (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI_CONTROL, ASSOCIATED_RESET aresetn, FREQ_HZ 235000000" *)
  input  wire aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
  input  wire aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dma_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME dma_aclk, ASSOCIATED_BUSIF M_AXI_MEMORY:M_AXI_MEMORY_V, ASSOCIATED_RESET dma_aresetn, FREQ_HZ 300000000" *)
  input  wire dma_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dma_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME dma_aresetn, POLARITY ACTIVE_LOW" *)
  input  wire dma_aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq, SENSITIVITY LEVEL_HIGH" *)
  output wire irq,
  output wire busy,
  output wire done,
  output wire error,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWADDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_CONTROL, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12, FREQ_HZ 235000000" *)
  input  wire [11:0] s_axi_control_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWPROT" *)
  input  wire [2:0] s_axi_control_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWVALID" *)
  input  wire s_axi_control_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWREADY" *)
  output wire s_axi_control_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WDATA" *)
  input  wire [31:0] s_axi_control_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WSTRB" *)
  input  wire [3:0] s_axi_control_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WVALID" *)
  input  wire s_axi_control_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WREADY" *)
  output wire s_axi_control_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BRESP" *)
  output wire [1:0] s_axi_control_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BVALID" *)
  output wire s_axi_control_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BREADY" *)
  input  wire s_axi_control_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARADDR" *)
  input  wire [11:0] s_axi_control_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARPROT" *)
  input  wire [2:0] s_axi_control_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARVALID" *)
  input  wire s_axi_control_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARREADY" *)
  output wire s_axi_control_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RDATA" *)
  output wire [31:0] s_axi_control_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RRESP" *)
  output wire [1:0] s_axi_control_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RVALID" *)
  output wire s_axi_control_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RREADY" *)
  input  wire s_axi_control_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWID" *)
  output wire [3:0] m_axi_memory_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWADDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_MEMORY, PROTOCOL AXI4, DATA_WIDTH 256, ADDR_WIDTH 32, ID_WIDTH 4, MAX_BURST_LENGTH 256, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 1, FREQ_HZ 300000000" *)
  output wire [31:0] m_axi_memory_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWLEN" *)
  output wire [7:0] m_axi_memory_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWSIZE" *)
  output wire [2:0] m_axi_memory_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWBURST" *)
  output wire [1:0] m_axi_memory_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWLOCK" *)
  output wire m_axi_memory_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWCACHE" *)
  output wire [3:0] m_axi_memory_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWPROT" *)
  output wire [2:0] m_axi_memory_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWQOS" *)
  output wire [3:0] m_axi_memory_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWREGION" *)
  output wire [3:0] m_axi_memory_awregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWVALID" *)
  output wire m_axi_memory_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY AWREADY" *)
  input  wire m_axi_memory_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY WDATA" *)
  output wire [255:0] m_axi_memory_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY WSTRB" *)
  output wire [31:0] m_axi_memory_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY WLAST" *)
  output wire m_axi_memory_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY WVALID" *)
  output wire m_axi_memory_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY WREADY" *)
  input  wire m_axi_memory_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY BID" *)
  input  wire [3:0] m_axi_memory_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY BRESP" *)
  input  wire [1:0] m_axi_memory_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY BVALID" *)
  input  wire m_axi_memory_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY BREADY" *)
  output wire m_axi_memory_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARID" *)
  output wire [3:0] m_axi_memory_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARADDR" *)
  output wire [31:0] m_axi_memory_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARLEN" *)
  output wire [7:0] m_axi_memory_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARSIZE" *)
  output wire [2:0] m_axi_memory_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARBURST" *)
  output wire [1:0] m_axi_memory_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARLOCK" *)
  output wire m_axi_memory_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARCACHE" *)
  output wire [3:0] m_axi_memory_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARPROT" *)
  output wire [2:0] m_axi_memory_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARQOS" *)
  output wire [3:0] m_axi_memory_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARREGION" *)
  output wire [3:0] m_axi_memory_arregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARVALID" *)
  output wire m_axi_memory_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY ARREADY" *)
  input  wire m_axi_memory_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RID" *)
  input  wire [3:0] m_axi_memory_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RDATA" *)
  input  wire [255:0] m_axi_memory_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RRESP" *)
  input  wire [1:0] m_axi_memory_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RLAST" *)
  input  wire m_axi_memory_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RVALID" *)
  input  wire m_axi_memory_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY RREADY" *)
  output wire m_axi_memory_rready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWID" *)
  output wire [3:0] m_axi_memory_v_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWADDR" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_MEMORY_V, PROTOCOL AXI4, DATA_WIDTH 256, ADDR_WIDTH 32, ID_WIDTH 4, MAX_BURST_LENGTH 256, NUM_READ_OUTSTANDING 8, NUM_WRITE_OUTSTANDING 1, FREQ_HZ 300000000" *)
  output wire [31:0] m_axi_memory_v_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWLEN" *)
  output wire [7:0] m_axi_memory_v_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWSIZE" *)
  output wire [2:0] m_axi_memory_v_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWBURST" *)
  output wire [1:0] m_axi_memory_v_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWLOCK" *)
  output wire m_axi_memory_v_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWCACHE" *)
  output wire [3:0] m_axi_memory_v_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWPROT" *)
  output wire [2:0] m_axi_memory_v_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWQOS" *)
  output wire [3:0] m_axi_memory_v_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWREGION" *)
  output wire [3:0] m_axi_memory_v_awregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWVALID" *)
  output wire m_axi_memory_v_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V AWREADY" *)
  input wire m_axi_memory_v_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V WDATA" *)
  output wire [255:0] m_axi_memory_v_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V WSTRB" *)
  output wire [31:0] m_axi_memory_v_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V WLAST" *)
  output wire m_axi_memory_v_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V WVALID" *)
  output wire m_axi_memory_v_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V WREADY" *)
  input wire m_axi_memory_v_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V BID" *)
  input wire [3:0] m_axi_memory_v_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V BRESP" *)
  input wire [1:0] m_axi_memory_v_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V BVALID" *)
  input wire m_axi_memory_v_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V BREADY" *)
  output wire m_axi_memory_v_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARID" *)
  output wire [3:0] m_axi_memory_v_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARADDR" *)
  output wire [31:0] m_axi_memory_v_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARLEN" *)
  output wire [7:0] m_axi_memory_v_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARSIZE" *)
  output wire [2:0] m_axi_memory_v_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARBURST" *)
  output wire [1:0] m_axi_memory_v_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARLOCK" *)
  output wire m_axi_memory_v_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARCACHE" *)
  output wire [3:0] m_axi_memory_v_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARPROT" *)
  output wire [2:0] m_axi_memory_v_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARQOS" *)
  output wire [3:0] m_axi_memory_v_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARREGION" *)
  output wire [3:0] m_axi_memory_v_arregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARVALID" *)
  output wire m_axi_memory_v_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V ARREADY" *)
  input wire m_axi_memory_v_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RID" *)
  input wire [3:0] m_axi_memory_v_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RDATA" *)
  input wire [255:0] m_axi_memory_v_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RRESP" *)
  input wire [1:0] m_axi_memory_v_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RLAST" *)
  input wire m_axi_memory_v_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RVALID" *)
  input wire m_axi_memory_v_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_MEMORY_V RREADY" *)
  output wire m_axi_memory_v_rready
);

  gqav5_axi_accelerator_top u_accelerator (
    .clk_i                         (aclk),
    .rst_ni                        (aresetn),
    .dma_clk_i                     (dma_aclk),
    .dma_rst_ni                    (dma_aresetn),
    .interrupt_o                   (irq),
    .busy_o                        (busy),
    .done_o                        (done),
    .error_o                       (error),
    .s_axil_awaddr_i               (s_axi_control_awaddr),
    .s_axil_awprot_i               (s_axi_control_awprot),
    .s_axil_awvalid_i              (s_axi_control_awvalid),
    .s_axil_awready_o              (s_axi_control_awready),
    .s_axil_wdata_i                (s_axi_control_wdata),
    .s_axil_wstrb_i                (s_axi_control_wstrb),
    .s_axil_wvalid_i               (s_axi_control_wvalid),
    .s_axil_wready_o               (s_axi_control_wready),
    .s_axil_bresp_o                (s_axi_control_bresp),
    .s_axil_bvalid_o               (s_axi_control_bvalid),
    .s_axil_bready_i               (s_axi_control_bready),
    .s_axil_araddr_i               (s_axi_control_araddr),
    .s_axil_arprot_i               (s_axi_control_arprot),
    .s_axil_arvalid_i              (s_axi_control_arvalid),
    .s_axil_arready_o              (s_axi_control_arready),
    .s_axil_rdata_o                (s_axi_control_rdata),
    .s_axil_rresp_o                (s_axi_control_rresp),
    .s_axil_rvalid_o               (s_axi_control_rvalid),
    .s_axil_rready_i               (s_axi_control_rready),
    .m_axi_awid_o                  (m_axi_memory_awid),
    .m_axi_awaddr_o                (m_axi_memory_awaddr),
    .m_axi_awlen_o                 (m_axi_memory_awlen),
    .m_axi_awsize_o                (m_axi_memory_awsize),
    .m_axi_awburst_o               (m_axi_memory_awburst),
    .m_axi_awlock_o                (m_axi_memory_awlock),
    .m_axi_awcache_o               (m_axi_memory_awcache),
    .m_axi_awprot_o                (m_axi_memory_awprot),
    .m_axi_awqos_o                 (m_axi_memory_awqos),
    .m_axi_awregion_o              (m_axi_memory_awregion),
    .m_axi_awvalid_o               (m_axi_memory_awvalid),
    .m_axi_awready_i               (m_axi_memory_awready),
    .m_axi_wdata_o                 (m_axi_memory_wdata),
    .m_axi_wstrb_o                 (m_axi_memory_wstrb),
    .m_axi_wlast_o                 (m_axi_memory_wlast),
    .m_axi_wvalid_o                (m_axi_memory_wvalid),
    .m_axi_wready_i                (m_axi_memory_wready),
    .m_axi_bid_i                   (m_axi_memory_bid),
    .m_axi_bresp_i                 (m_axi_memory_bresp),
    .m_axi_bvalid_i                (m_axi_memory_bvalid),
    .m_axi_bready_o                (m_axi_memory_bready),
    .m_axi_arid_o                  (m_axi_memory_arid),
    .m_axi_araddr_o                (m_axi_memory_araddr),
    .m_axi_arlen_o                 (m_axi_memory_arlen),
    .m_axi_arsize_o                (m_axi_memory_arsize),
    .m_axi_arburst_o               (m_axi_memory_arburst),
    .m_axi_arlock_o                (m_axi_memory_arlock),
    .m_axi_arcache_o               (m_axi_memory_arcache),
    .m_axi_arprot_o                (m_axi_memory_arprot),
    .m_axi_arqos_o                 (m_axi_memory_arqos),
    .m_axi_arregion_o              (m_axi_memory_arregion),
    .m_axi_arvalid_o               (m_axi_memory_arvalid),
    .m_axi_arready_i               (m_axi_memory_arready),
    .m_axi_rid_i                   (m_axi_memory_rid),
    .m_axi_rdata_i                 (m_axi_memory_rdata),
    .m_axi_rresp_i                 (m_axi_memory_rresp),
    .m_axi_rlast_i                 (m_axi_memory_rlast),
    .m_axi_rvalid_i                (m_axi_memory_rvalid),
    .m_axi_rready_o                (m_axi_memory_rready),
    .m_axi_v_awid_o                (m_axi_memory_v_awid),
    .m_axi_v_awaddr_o              (m_axi_memory_v_awaddr),
    .m_axi_v_awlen_o               (m_axi_memory_v_awlen),
    .m_axi_v_awsize_o              (m_axi_memory_v_awsize),
    .m_axi_v_awburst_o             (m_axi_memory_v_awburst),
    .m_axi_v_awlock_o              (m_axi_memory_v_awlock),
    .m_axi_v_awcache_o             (m_axi_memory_v_awcache),
    .m_axi_v_awprot_o              (m_axi_memory_v_awprot),
    .m_axi_v_awqos_o               (m_axi_memory_v_awqos),
    .m_axi_v_awregion_o            (m_axi_memory_v_awregion),
    .m_axi_v_awvalid_o             (m_axi_memory_v_awvalid),
    .m_axi_v_awready_i             (m_axi_memory_v_awready),
    .m_axi_v_wdata_o               (m_axi_memory_v_wdata),
    .m_axi_v_wstrb_o               (m_axi_memory_v_wstrb),
    .m_axi_v_wlast_o               (m_axi_memory_v_wlast),
    .m_axi_v_wvalid_o              (m_axi_memory_v_wvalid),
    .m_axi_v_wready_i              (m_axi_memory_v_wready),
    .m_axi_v_bid_i                 (m_axi_memory_v_bid),
    .m_axi_v_bresp_i               (m_axi_memory_v_bresp),
    .m_axi_v_bvalid_i              (m_axi_memory_v_bvalid),
    .m_axi_v_bready_o              (m_axi_memory_v_bready),
    .m_axi_v_arid_o                (m_axi_memory_v_arid),
    .m_axi_v_araddr_o              (m_axi_memory_v_araddr),
    .m_axi_v_arlen_o               (m_axi_memory_v_arlen),
    .m_axi_v_arsize_o              (m_axi_memory_v_arsize),
    .m_axi_v_arburst_o             (m_axi_memory_v_arburst),
    .m_axi_v_arlock_o              (m_axi_memory_v_arlock),
    .m_axi_v_arcache_o             (m_axi_memory_v_arcache),
    .m_axi_v_arprot_o              (m_axi_memory_v_arprot),
    .m_axi_v_arqos_o               (m_axi_memory_v_arqos),
    .m_axi_v_arregion_o            (m_axi_memory_v_arregion),
    .m_axi_v_arvalid_o             (m_axi_memory_v_arvalid),
    .m_axi_v_arready_i             (m_axi_memory_v_arready),
    .m_axi_v_rid_i                 (m_axi_memory_v_rid),
    .m_axi_v_rdata_i               (m_axi_memory_v_rdata),
    .m_axi_v_rresp_i               (m_axi_memory_v_rresp),
    .m_axi_v_rlast_i               (m_axi_memory_v_rlast),
    .m_axi_v_rvalid_i              (m_axi_memory_v_rvalid),
    .m_axi_v_rready_o              (m_axi_memory_v_rready)
  );
endmodule
