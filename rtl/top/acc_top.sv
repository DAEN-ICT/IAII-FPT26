module acc_top
  import amba_axi_pkg::*;
(
  input  wire          clk_p,
  input  wire          clk_n,
  input  wire          rst_n,
  input  s_axil_mosi_t dma_csr_mosi_i,
  output s_axil_miso_t dma_csr_miso_o,
  output logic [16:0]  c0_ddr4_adr,
  output logic [1:0]   c0_ddr4_ba,
  output logic [0:0]   c0_ddr4_cke,
  output logic [0:0]   c0_ddr4_cs_n,
  inout  wire  [7:0]   c0_ddr4_dm_dbi_n,
  inout  wire  [63:0]  c0_ddr4_dq,
  inout  wire  [7:0]   c0_ddr4_dqs_c,
  inout  wire  [7:0]   c0_ddr4_dqs_t,
  output logic [0:0]   c0_ddr4_odt,
  output logic [0:0]   c0_ddr4_bg,
  output logic         c0_ddr4_reset_n,
  output logic         c0_ddr4_act_n,
  output logic [0:0]   c0_ddr4_ck_c,
  output logic [0:0]   c0_ddr4_ck_t
);

logic         pll_locked;
logic         c0_ddr4_ui_clk;
logic         c0_ddr4_ui_clk_sync_rst;
logic         c0_init_calib_complete;

logic         sys_clk;
logic         sys_clk_ref_raw;
logic         sys_clk_ref;
logic         ddr_sys_rst;
logic         sys_resetn;
logic         sys_resetn_async;
(* ASYNC_REG = "TRUE" *) logic [1:0] sys_resetn_sync;

logic         dbg_clk;
logic [511:0] dbg_bus;

IBUFDS u_sys_clk_ibufds (
  .I (clk_p),
  .IB(clk_n),
  .O (sys_clk_ref_raw)
);

BUFG u_sys_clk_bufg (
  .I(sys_clk_ref_raw),
  .O(sys_clk_ref)
);

clock clock
   (
  // Clock out ports
  .sys_clk(sys_clk),     // output sys_clk
    // Status and control signals
    .resetn(rst_n), // input reset
    .locked(pll_locked),       // output locked
   // Clock in ports
    .clk_in1(sys_clk_ref)    // input clk_in1
);

assign ddr_sys_rst     = ~rst_n | ~pll_locked;
assign sys_resetn_async = rst_n & pll_locked & c0_ddr4_aresetn & c0_init_calib_complete;
assign sys_resetn = sys_resetn_sync[1];

always_ff @(posedge sys_clk or negedge sys_resetn_async) begin
  if (!sys_resetn_async)
    sys_resetn_sync <= 2'b00;
  else
    sys_resetn_sync <= {sys_resetn_sync[0], 1'b1};
end

logic         c0_ddr4_aresetn;

logic         dma_done_o;
logic         dma_error_o;

logic         dma_rst;

s_axi_mosi_t dma_m_mosi;
s_axi_miso_t dma_m_miso;

logic         conv_s_axi_awready;
logic         conv_s_axi_wready;
logic [3:0]   conv_s_axi_bid;
logic [1:0]   conv_s_axi_bresp;
logic         conv_s_axi_bvalid;
logic         conv_s_axi_arready;
logic [3:0]   conv_s_axi_rid;
logic [255:0] conv_s_axi_rdata;
logic [1:0]   conv_s_axi_rresp;
logic         conv_s_axi_rlast;
logic         conv_s_axi_rvalid;

logic [3:0]   c0_ddr4_s_axi_awid;
logic [31:0]  c0_ddr4_s_axi_awaddr;
logic [7:0]   c0_ddr4_s_axi_awlen;
logic [2:0]   c0_ddr4_s_axi_awsize;
logic [1:0]   c0_ddr4_s_axi_awburst;
logic [0:0]   c0_ddr4_s_axi_awlock;
logic [3:0]   c0_ddr4_s_axi_awcache;
logic [2:0]   c0_ddr4_s_axi_awprot;
logic [3:0]   c0_ddr4_s_axi_awqos;
logic         c0_ddr4_s_axi_awvalid;
logic         c0_ddr4_s_axi_awready;
logic [255:0] c0_ddr4_s_axi_wdata;
logic [31:0]  c0_ddr4_s_axi_wstrb;
logic         c0_ddr4_s_axi_wlast;
logic         c0_ddr4_s_axi_wvalid;
logic         c0_ddr4_s_axi_wready;
logic         c0_ddr4_s_axi_bready;
logic [3:0]   c0_ddr4_s_axi_bid;
logic [1:0]   c0_ddr4_s_axi_bresp;
logic         c0_ddr4_s_axi_bvalid;
logic [3:0]   c0_ddr4_s_axi_arid;
logic [31:0]  c0_ddr4_s_axi_araddr;
logic [7:0]   c0_ddr4_s_axi_arlen;
logic [2:0]   c0_ddr4_s_axi_arsize;
logic [1:0]   c0_ddr4_s_axi_arburst;
logic [0:0]   c0_ddr4_s_axi_arlock;
logic [3:0]   c0_ddr4_s_axi_arcache;
logic [2:0]   c0_ddr4_s_axi_arprot;
logic [3:0]   c0_ddr4_s_axi_arqos;
logic         c0_ddr4_s_axi_arvalid;
logic         c0_ddr4_s_axi_arready;
logic         c0_ddr4_s_axi_rready;
logic         c0_ddr4_s_axi_rlast;
logic         c0_ddr4_s_axi_rvalid;
logic [1:0]   c0_ddr4_s_axi_rresp;
logic [3:0]   c0_ddr4_s_axi_rid;
logic [255:0] c0_ddr4_s_axi_rdata;

logic [3:0]   conv_m_axi_awregion;
logic [3:0]   conv_m_axi_arregion;

always_comb begin
  dma_m_miso = '0;
  dma_m_miso.awready = conv_s_axi_awready;
  dma_m_miso.wready  = conv_s_axi_wready;
  dma_m_miso.bid     = axi_tid_t'(conv_s_axi_bid);
  dma_m_miso.bresp   = axi_resp_t'(conv_s_axi_bresp);
  dma_m_miso.bvalid  = conv_s_axi_bvalid;
  dma_m_miso.arready = conv_s_axi_arready;
  dma_m_miso.rid     = axi_tid_t'(conv_s_axi_rid);
  dma_m_miso.rdata   = conv_s_axi_rdata;
  dma_m_miso.rresp   = axi_resp_t'(conv_s_axi_rresp);
  dma_m_miso.rlast   = conv_s_axi_rlast;
  dma_m_miso.rvalid  = conv_s_axi_rvalid;
end

assign dma_rst = ~sys_resetn;

always_ff @(posedge c0_ddr4_ui_clk or posedge ddr_sys_rst) begin
  if (ddr_sys_rst)
    c0_ddr4_aresetn <= 1'b0;
  else
    c0_ddr4_aresetn <= ~c0_ddr4_ui_clk_sync_rst;
end

dma_axi_wrapper #(
  .DMA_ID_VAL(0)
) u_dma_axi_wrapper (
  .clk            (sys_clk),
  .rst            (dma_rst),
  .dma_csr_mosi_i (dma_csr_mosi_i),
  .dma_csr_miso_o (dma_csr_miso_o),
  .dma_m_mosi_o   (dma_m_mosi),
  .dma_m_miso_i   (dma_m_miso),
  .dma_done_o     (dma_done_o),
  .dma_error_o    (dma_error_o)
);

ddr_clock_converter u_ddr_clock_converter (
  .s_axi_aclk   (sys_clk),
  .s_axi_aresetn(sys_resetn),
  .s_axi_awid   (dma_m_mosi.awid),
  .s_axi_awaddr (dma_m_mosi.awaddr),
  .s_axi_awlen  (dma_m_mosi.awlen),
  .s_axi_awsize (dma_m_mosi.awsize),
  .s_axi_awburst(dma_m_mosi.awburst),
  .s_axi_awlock (dma_m_mosi.awlock),
  .s_axi_awcache(dma_m_mosi.awcache),
  .s_axi_awprot (dma_m_mosi.awprot),
  .s_axi_awregion(dma_m_mosi.awregion),
  .s_axi_awqos  (dma_m_mosi.awqos),
  .s_axi_awvalid(dma_m_mosi.awvalid),
  .s_axi_awready(conv_s_axi_awready),
  .s_axi_wdata  (dma_m_mosi.wdata),
  .s_axi_wstrb  (dma_m_mosi.wstrb),
  .s_axi_wlast  (dma_m_mosi.wlast),
  .s_axi_wvalid (dma_m_mosi.wvalid),
  .s_axi_wready (conv_s_axi_wready),
  .s_axi_bid    (conv_s_axi_bid),
  .s_axi_bresp  (conv_s_axi_bresp),
  .s_axi_bvalid (conv_s_axi_bvalid),
  .s_axi_bready (dma_m_mosi.bready),
  .s_axi_arid   (dma_m_mosi.arid),
  .s_axi_araddr (dma_m_mosi.araddr),
  .s_axi_arlen  (dma_m_mosi.arlen),
  .s_axi_arsize (dma_m_mosi.arsize),
  .s_axi_arburst(dma_m_mosi.arburst),
  .s_axi_arlock (dma_m_mosi.arlock),
  .s_axi_arcache(dma_m_mosi.arcache),
  .s_axi_arprot (dma_m_mosi.arprot),
  .s_axi_arregion(dma_m_mosi.arregion),
  .s_axi_arqos  (dma_m_mosi.arqos),
  .s_axi_arvalid(dma_m_mosi.arvalid),
  .s_axi_arready(conv_s_axi_arready),
  .s_axi_rid    (conv_s_axi_rid),
  .s_axi_rdata  (conv_s_axi_rdata),
  .s_axi_rresp  (conv_s_axi_rresp),
  .s_axi_rlast  (conv_s_axi_rlast),
  .s_axi_rvalid (conv_s_axi_rvalid),
  .s_axi_rready (dma_m_mosi.rready),
  .m_axi_aclk   (c0_ddr4_ui_clk),
  .m_axi_aresetn(c0_ddr4_aresetn),
  .m_axi_awid   (c0_ddr4_s_axi_awid),
  .m_axi_awaddr (c0_ddr4_s_axi_awaddr),
  .m_axi_awlen  (c0_ddr4_s_axi_awlen),
  .m_axi_awsize (c0_ddr4_s_axi_awsize),
  .m_axi_awburst(c0_ddr4_s_axi_awburst),
  .m_axi_awlock (c0_ddr4_s_axi_awlock),
  .m_axi_awcache(c0_ddr4_s_axi_awcache),
  .m_axi_awprot (c0_ddr4_s_axi_awprot),
  .m_axi_awregion(conv_m_axi_awregion),
  .m_axi_awqos  (c0_ddr4_s_axi_awqos),
  .m_axi_awvalid(c0_ddr4_s_axi_awvalid),
  .m_axi_awready(c0_ddr4_s_axi_awready),
  .m_axi_wdata  (c0_ddr4_s_axi_wdata),
  .m_axi_wstrb  (c0_ddr4_s_axi_wstrb),
  .m_axi_wlast  (c0_ddr4_s_axi_wlast),
  .m_axi_wvalid (c0_ddr4_s_axi_wvalid),
  .m_axi_wready (c0_ddr4_s_axi_wready),
  .m_axi_bid    (c0_ddr4_s_axi_bid),
  .m_axi_bresp  (c0_ddr4_s_axi_bresp),
  .m_axi_bvalid (c0_ddr4_s_axi_bvalid),
  .m_axi_bready (c0_ddr4_s_axi_bready),
  .m_axi_arid   (c0_ddr4_s_axi_arid),
  .m_axi_araddr (c0_ddr4_s_axi_araddr),
  .m_axi_arlen  (c0_ddr4_s_axi_arlen),
  .m_axi_arsize (c0_ddr4_s_axi_arsize),
  .m_axi_arburst(c0_ddr4_s_axi_arburst),
  .m_axi_arlock (c0_ddr4_s_axi_arlock),
  .m_axi_arcache(c0_ddr4_s_axi_arcache),
  .m_axi_arprot (c0_ddr4_s_axi_arprot),
  .m_axi_arregion(conv_m_axi_arregion),
  .m_axi_arqos  (c0_ddr4_s_axi_arqos),
  .m_axi_arvalid(c0_ddr4_s_axi_arvalid),
  .m_axi_arready(c0_ddr4_s_axi_arready),
  .m_axi_rid    (c0_ddr4_s_axi_rid),
  .m_axi_rdata  (c0_ddr4_s_axi_rdata),
  .m_axi_rresp  (c0_ddr4_s_axi_rresp),
  .m_axi_rlast  (c0_ddr4_s_axi_rlast),
  .m_axi_rvalid (c0_ddr4_s_axi_rvalid),
  .m_axi_rready (c0_ddr4_s_axi_rready)
);

ddr4_controller u_ddr4_controller (
  .c0_init_calib_complete(c0_init_calib_complete),
  .dbg_clk                (dbg_clk),
  .c0_sys_clk_i           (sys_clk_ref_raw),
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
