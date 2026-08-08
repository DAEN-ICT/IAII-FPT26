`timescale 1ns/1ps
// Verilog-2001 module-reference wrapper migrated from the provisional V4.1 Z19-P board wrapper. The MIG-side
// topology is unchanged; only the V5 module name and 50 MHz fabric metadata
// differ from the 25 MHz source revision.
module gqav5_pl_ddr4_axi_wrapper (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI_MEMORY, ASSOCIATED_RESET aresetn, FREQ_HZ 300000000" *)
  input  wire         aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 sys_clk_i CLK" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME sys_clk_i, FREQ_HZ 200000000" *)
  (* CLOCK_BUFFER_TYPE = "NONE" *)
  input  wire         sys_clk_i,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
  input  wire         aresetn,
  input  wire         rst_n,
  input  wire         clk_locked,

  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWID" *)
  (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_MEMORY, PROTOCOL AXI4, DATA_WIDTH 512, ADDR_WIDTH 32, ID_WIDTH 4, MAX_BURST_LENGTH 256, NUM_READ_OUTSTANDING 16, NUM_WRITE_OUTSTANDING 4, FREQ_HZ 300000000" *)
  input  wire [3:0]   s_axi_memory_awid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWADDR" *)
  input  wire [31:0]  s_axi_memory_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWLEN" *)
  input  wire [7:0]   s_axi_memory_awlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWSIZE" *)
  input  wire [2:0]   s_axi_memory_awsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWBURST" *)
  input  wire [1:0]   s_axi_memory_awburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWLOCK" *)
  input  wire         s_axi_memory_awlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWCACHE" *)
  input  wire [3:0]   s_axi_memory_awcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWPROT" *)
  input  wire [2:0]   s_axi_memory_awprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWQOS" *)
  input  wire [3:0]   s_axi_memory_awqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWREGION" *)
  input  wire [3:0]   s_axi_memory_awregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWVALID" *)
  input  wire         s_axi_memory_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY AWREADY" *)
  output wire         s_axi_memory_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY WDATA" *)
  input  wire [511:0] s_axi_memory_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY WSTRB" *)
  input  wire [63:0]  s_axi_memory_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY WLAST" *)
  input  wire         s_axi_memory_wlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY WVALID" *)
  input  wire         s_axi_memory_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY WREADY" *)
  output wire         s_axi_memory_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY BID" *)
  output wire [3:0]   s_axi_memory_bid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY BRESP" *)
  output wire [1:0]   s_axi_memory_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY BVALID" *)
  output wire         s_axi_memory_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY BREADY" *)
  input  wire         s_axi_memory_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARID" *)
  input  wire [3:0]   s_axi_memory_arid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARADDR" *)
  input  wire [31:0]  s_axi_memory_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARLEN" *)
  input  wire [7:0]   s_axi_memory_arlen,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARSIZE" *)
  input  wire [2:0]   s_axi_memory_arsize,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARBURST" *)
  input  wire [1:0]   s_axi_memory_arburst,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARLOCK" *)
  input  wire         s_axi_memory_arlock,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARCACHE" *)
  input  wire [3:0]   s_axi_memory_arcache,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARPROT" *)
  input  wire [2:0]   s_axi_memory_arprot,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARQOS" *)
  input  wire [3:0]   s_axi_memory_arqos,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARREGION" *)
  input  wire [3:0]   s_axi_memory_arregion,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARVALID" *)
  input  wire         s_axi_memory_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY ARREADY" *)
  output wire         s_axi_memory_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RID" *)
  output wire [3:0]   s_axi_memory_rid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RDATA" *)
  output wire [511:0] s_axi_memory_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RRESP" *)
  output wire [1:0]   s_axi_memory_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RLAST" *)
  output wire         s_axi_memory_rlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RVALID" *)
  output wire         s_axi_memory_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_MEMORY RREADY" *)
  input  wire         s_axi_memory_rready,

  output wire [16:0]  c0_ddr4_adr,
  output wire [1:0]   c0_ddr4_ba,
  output wire [0:0]   c0_ddr4_cke,
  output wire [0:0]   c0_ddr4_cs_n,
  inout  wire  [7:0]   c0_ddr4_dm_dbi_n,
  inout  wire  [63:0]  c0_ddr4_dq,
  inout  wire  [7:0]   c0_ddr4_dqs_c,
  inout  wire  [7:0]   c0_ddr4_dqs_t,
  output wire [0:0]   c0_ddr4_odt,
  output wire [0:0]   c0_ddr4_bg,
  output wire         c0_ddr4_reset_n,
  output wire         c0_ddr4_act_n,
  output wire [0:0]   c0_ddr4_ck_c,
  output wire [0:0]   c0_ddr4_ck_t,

  output wire         ddr_ready_o,
  output wire         ddr_calib_complete_o
);

  wire         c0_ddr4_ui_clk;
  wire         c0_ddr4_ui_clk_sync_rst;
  wire         c0_init_calib_complete;
  reg          c0_ddr4_aresetn;
  wire         ddr_sys_rst;
  wire         sys_resetn_async;
  wire         sys_resetn;
  (* ASYNC_REG = "TRUE" *) reg [1:0] sys_resetn_sync;
  wire         dbg_clk;
  wire [511:0] dbg_bus;

  wire [3:0]   c0_ddr4_s_axi_awid;
  wire [31:0]  c0_ddr4_s_axi_awaddr;
  wire [7:0]   c0_ddr4_s_axi_awlen;
  wire [2:0]   c0_ddr4_s_axi_awsize;
  wire [1:0]   c0_ddr4_s_axi_awburst;
  wire [0:0]   c0_ddr4_s_axi_awlock;
  wire [3:0]   c0_ddr4_s_axi_awcache;
  wire [2:0]   c0_ddr4_s_axi_awprot;
  wire [3:0]   c0_ddr4_s_axi_awqos;
  wire         c0_ddr4_s_axi_awvalid;
  wire         c0_ddr4_s_axi_awready;
  wire [511:0] c0_ddr4_s_axi_wdata;
  wire [63:0]  c0_ddr4_s_axi_wstrb;
  wire         c0_ddr4_s_axi_wlast;
  wire         c0_ddr4_s_axi_wvalid;
  wire         c0_ddr4_s_axi_wready;
  wire         c0_ddr4_s_axi_bready;
  wire [3:0]   c0_ddr4_s_axi_bid;
  wire [1:0]   c0_ddr4_s_axi_bresp;
  wire         c0_ddr4_s_axi_bvalid;
  wire [3:0]   c0_ddr4_s_axi_arid;
  wire [31:0]  c0_ddr4_s_axi_araddr;
  wire [7:0]   c0_ddr4_s_axi_arlen;
  wire [2:0]   c0_ddr4_s_axi_arsize;
  wire [1:0]   c0_ddr4_s_axi_arburst;
  wire [0:0]   c0_ddr4_s_axi_arlock;
  wire [3:0]   c0_ddr4_s_axi_arcache;
  wire [2:0]   c0_ddr4_s_axi_arprot;
  wire [3:0]   c0_ddr4_s_axi_arqos;
  wire         c0_ddr4_s_axi_arvalid;
  wire         c0_ddr4_s_axi_arready;
  wire         c0_ddr4_s_axi_rready;
  wire         c0_ddr4_s_axi_rlast;
  wire         c0_ddr4_s_axi_rvalid;
  wire [1:0]   c0_ddr4_s_axi_rresp;
  wire [3:0]   c0_ddr4_s_axi_rid;
  wire [511:0] c0_ddr4_s_axi_rdata;
  wire [3:0]   unused_awregion;
  wire [3:0]   unused_arregion;

  assign ddr_sys_rst      = ~rst_n | ~clk_locked;
  assign sys_resetn_async = rst_n & clk_locked & aresetn
                            & c0_ddr4_aresetn & c0_init_calib_complete;
  assign sys_resetn       = sys_resetn_sync[1];
  assign ddr_ready_o      = sys_resetn;
  assign ddr_calib_complete_o = c0_init_calib_complete;

  always @(posedge aclk or negedge sys_resetn_async) begin
    if (!sys_resetn_async)
      sys_resetn_sync <= 2'b00;
    else
      sys_resetn_sync <= {sys_resetn_sync[0], 1'b1};
  end

  always @(posedge c0_ddr4_ui_clk or posedge ddr_sys_rst) begin
    if (ddr_sys_rst)
      c0_ddr4_aresetn <= 1'b0;
    else
      c0_ddr4_aresetn <= ~c0_ddr4_ui_clk_sync_rst;
  end

  ddr_clock_converter u_ddr_clock_converter (
    .s_axi_aclk    (aclk),
    .s_axi_aresetn (sys_resetn),
    .s_axi_awid    (s_axi_memory_awid),
    .s_axi_awaddr  (s_axi_memory_awaddr),
    .s_axi_awlen   (s_axi_memory_awlen),
    .s_axi_awsize  (s_axi_memory_awsize),
    .s_axi_awburst (s_axi_memory_awburst),
    .s_axi_awlock  (s_axi_memory_awlock),
    .s_axi_awcache (s_axi_memory_awcache),
    .s_axi_awprot  (s_axi_memory_awprot),
    .s_axi_awregion(s_axi_memory_awregion),
    .s_axi_awqos   (s_axi_memory_awqos),
    .s_axi_awvalid (s_axi_memory_awvalid),
    .s_axi_awready (s_axi_memory_awready),
    .s_axi_wdata   (s_axi_memory_wdata),
    .s_axi_wstrb   (s_axi_memory_wstrb),
    .s_axi_wlast   (s_axi_memory_wlast),
    .s_axi_wvalid  (s_axi_memory_wvalid),
    .s_axi_wready  (s_axi_memory_wready),
    .s_axi_bid     (s_axi_memory_bid),
    .s_axi_bresp   (s_axi_memory_bresp),
    .s_axi_bvalid  (s_axi_memory_bvalid),
    .s_axi_bready  (s_axi_memory_bready),
    .s_axi_arid    (s_axi_memory_arid),
    .s_axi_araddr  (s_axi_memory_araddr),
    .s_axi_arlen   (s_axi_memory_arlen),
    .s_axi_arsize  (s_axi_memory_arsize),
    .s_axi_arburst (s_axi_memory_arburst),
    .s_axi_arlock  (s_axi_memory_arlock),
    .s_axi_arcache (s_axi_memory_arcache),
    .s_axi_arprot  (s_axi_memory_arprot),
    .s_axi_arregion(s_axi_memory_arregion),
    .s_axi_arqos   (s_axi_memory_arqos),
    .s_axi_arvalid (s_axi_memory_arvalid),
    .s_axi_arready (s_axi_memory_arready),
    .s_axi_rid     (s_axi_memory_rid),
    .s_axi_rdata   (s_axi_memory_rdata),
    .s_axi_rresp   (s_axi_memory_rresp),
    .s_axi_rlast   (s_axi_memory_rlast),
    .s_axi_rvalid  (s_axi_memory_rvalid),
    .s_axi_rready  (s_axi_memory_rready),
    .m_axi_aclk    (c0_ddr4_ui_clk),
    .m_axi_aresetn (c0_ddr4_aresetn),
    .m_axi_awid    (c0_ddr4_s_axi_awid),
    .m_axi_awaddr  (c0_ddr4_s_axi_awaddr),
    .m_axi_awlen   (c0_ddr4_s_axi_awlen),
    .m_axi_awsize  (c0_ddr4_s_axi_awsize),
    .m_axi_awburst (c0_ddr4_s_axi_awburst),
    .m_axi_awlock  (c0_ddr4_s_axi_awlock),
    .m_axi_awcache (c0_ddr4_s_axi_awcache),
    .m_axi_awprot  (c0_ddr4_s_axi_awprot),
    .m_axi_awregion(unused_awregion),
    .m_axi_awqos   (c0_ddr4_s_axi_awqos),
    .m_axi_awvalid (c0_ddr4_s_axi_awvalid),
    .m_axi_awready (c0_ddr4_s_axi_awready),
    .m_axi_wdata   (c0_ddr4_s_axi_wdata),
    .m_axi_wstrb   (c0_ddr4_s_axi_wstrb),
    .m_axi_wlast   (c0_ddr4_s_axi_wlast),
    .m_axi_wvalid  (c0_ddr4_s_axi_wvalid),
    .m_axi_wready  (c0_ddr4_s_axi_wready),
    .m_axi_bid     (c0_ddr4_s_axi_bid),
    .m_axi_bresp   (c0_ddr4_s_axi_bresp),
    .m_axi_bvalid  (c0_ddr4_s_axi_bvalid),
    .m_axi_bready  (c0_ddr4_s_axi_bready),
    .m_axi_arid    (c0_ddr4_s_axi_arid),
    .m_axi_araddr  (c0_ddr4_s_axi_araddr),
    .m_axi_arlen   (c0_ddr4_s_axi_arlen),
    .m_axi_arsize  (c0_ddr4_s_axi_arsize),
    .m_axi_arburst (c0_ddr4_s_axi_arburst),
    .m_axi_arlock  (c0_ddr4_s_axi_arlock),
    .m_axi_arcache (c0_ddr4_s_axi_arcache),
    .m_axi_arprot  (c0_ddr4_s_axi_arprot),
    .m_axi_arregion(unused_arregion),
    .m_axi_arqos   (c0_ddr4_s_axi_arqos),
    .m_axi_arvalid (c0_ddr4_s_axi_arvalid),
    .m_axi_arready (c0_ddr4_s_axi_arready),
    .m_axi_rid     (c0_ddr4_s_axi_rid),
    .m_axi_rdata   (c0_ddr4_s_axi_rdata),
    .m_axi_rresp   (c0_ddr4_s_axi_rresp),
    .m_axi_rlast   (c0_ddr4_s_axi_rlast),
    .m_axi_rvalid  (c0_ddr4_s_axi_rvalid),
    .m_axi_rready  (c0_ddr4_s_axi_rready)
  );

  ddr4_controller u_ddr4_controller (
    .c0_init_calib_complete(c0_init_calib_complete),
    .dbg_clk                (dbg_clk),
    .c0_sys_clk_i           (sys_clk_i),
    .dbg_bus                (dbg_bus),
    .c0_ddr4_adr            (c0_ddr4_adr),
    .c0_ddr4_ba             (c0_ddr4_ba),
    .c0_ddr4_cke            (c0_ddr4_cke),
    .c0_ddr4_cs_n           (c0_ddr4_cs_n),
    .c0_ddr4_dm_dbi_n       (c0_ddr4_dm_dbi_n),
    .c0_ddr4_dq             (c0_ddr4_dq),
    .c0_ddr4_dqs_c          (c0_ddr4_dqs_c),
    .c0_ddr4_dqs_t          (c0_ddr4_dqs_t),
    .c0_ddr4_odt            (c0_ddr4_odt),
    .c0_ddr4_bg             (c0_ddr4_bg),
    .c0_ddr4_reset_n        (c0_ddr4_reset_n),
    .c0_ddr4_act_n          (c0_ddr4_act_n),
    .c0_ddr4_ck_c           (c0_ddr4_ck_c),
    .c0_ddr4_ck_t           (c0_ddr4_ck_t),
    .c0_ddr4_ui_clk         (c0_ddr4_ui_clk),
    .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
    .c0_ddr4_aresetn        (c0_ddr4_aresetn),
    .c0_ddr4_s_axi_awid     (c0_ddr4_s_axi_awid),
    .c0_ddr4_s_axi_awaddr   (c0_ddr4_s_axi_awaddr),
    .c0_ddr4_s_axi_awlen    (c0_ddr4_s_axi_awlen),
    .c0_ddr4_s_axi_awsize   (c0_ddr4_s_axi_awsize),
    .c0_ddr4_s_axi_awburst  (c0_ddr4_s_axi_awburst),
    .c0_ddr4_s_axi_awlock   (c0_ddr4_s_axi_awlock),
    .c0_ddr4_s_axi_awcache  (c0_ddr4_s_axi_awcache),
    .c0_ddr4_s_axi_awprot   (c0_ddr4_s_axi_awprot),
    .c0_ddr4_s_axi_awqos    (c0_ddr4_s_axi_awqos),
    .c0_ddr4_s_axi_awvalid  (c0_ddr4_s_axi_awvalid),
    .c0_ddr4_s_axi_awready  (c0_ddr4_s_axi_awready),
    .c0_ddr4_s_axi_wdata    (c0_ddr4_s_axi_wdata),
    .c0_ddr4_s_axi_wstrb    (c0_ddr4_s_axi_wstrb),
    .c0_ddr4_s_axi_wlast    (c0_ddr4_s_axi_wlast),
    .c0_ddr4_s_axi_wvalid   (c0_ddr4_s_axi_wvalid),
    .c0_ddr4_s_axi_wready   (c0_ddr4_s_axi_wready),
    .c0_ddr4_s_axi_bready   (c0_ddr4_s_axi_bready),
    .c0_ddr4_s_axi_bid      (c0_ddr4_s_axi_bid),
    .c0_ddr4_s_axi_bresp    (c0_ddr4_s_axi_bresp),
    .c0_ddr4_s_axi_bvalid   (c0_ddr4_s_axi_bvalid),
    .c0_ddr4_s_axi_arid     (c0_ddr4_s_axi_arid),
    .c0_ddr4_s_axi_araddr   (c0_ddr4_s_axi_araddr),
    .c0_ddr4_s_axi_arlen    (c0_ddr4_s_axi_arlen),
    .c0_ddr4_s_axi_arsize   (c0_ddr4_s_axi_arsize),
    .c0_ddr4_s_axi_arburst  (c0_ddr4_s_axi_arburst),
    .c0_ddr4_s_axi_arlock   (c0_ddr4_s_axi_arlock),
    .c0_ddr4_s_axi_arcache  (c0_ddr4_s_axi_arcache),
    .c0_ddr4_s_axi_arprot   (c0_ddr4_s_axi_arprot),
    .c0_ddr4_s_axi_arqos    (c0_ddr4_s_axi_arqos),
    .c0_ddr4_s_axi_arvalid  (c0_ddr4_s_axi_arvalid),
    .c0_ddr4_s_axi_arready  (c0_ddr4_s_axi_arready),
    .c0_ddr4_s_axi_rready   (c0_ddr4_s_axi_rready),
    .c0_ddr4_s_axi_rlast    (c0_ddr4_s_axi_rlast),
    .c0_ddr4_s_axi_rvalid   (c0_ddr4_s_axi_rvalid),
    .c0_ddr4_s_axi_rresp    (c0_ddr4_s_axi_rresp),
    .c0_ddr4_s_axi_rid      (c0_ddr4_s_axi_rid),
    .c0_ddr4_s_axi_rdata    (c0_ddr4_s_axi_rdata),
    .sys_rst                (ddr_sys_rst)
  );

endmodule
