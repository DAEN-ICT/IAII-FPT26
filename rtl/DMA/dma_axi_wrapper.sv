module dma_axi_wrapper
  import amba_axi_pkg::*;
  import dma_pkg::*;
#(
  parameter int DMA_ID_VAL = 0
)(
  input                 clk,
  input                 rst,
  // CSR DMA I/F
  input   s_axil_mosi_t dma_csr_mosi_i,
  output  s_axil_miso_t dma_csr_miso_o,
  // Master DMA I/F
  output  s_axi_mosi_t  dma_m_mosi_o,
  input   s_axi_miso_t  dma_m_miso_i,
  // Triggers - IRQs
  output  logic         dma_done_o,
  output  logic         dma_error_o
);
  localparam AXI_DATA_WIDTH = `AXI_DATA_WIDTH;

  logic [`DMA_NUM_DESC*$bits(desc_addr_t)-1:0]  dma_desc_src_vec;
  logic [`DMA_NUM_DESC*$bits(desc_addr_t)-1:0]  dma_desc_dst_vec;
  logic [`DMA_NUM_DESC*$bits(desc_num_t)-1:0]   dma_desc_byt_vec;
  logic [`DMA_NUM_DESC-1:0]                     dma_desc_wr_mod;
  logic [`DMA_NUM_DESC-1:0]                     dma_desc_rd_mod;
  logic [`DMA_NUM_DESC-1:0]                     dma_desc_en;

  s_dma_desc_t  [`DMA_NUM_DESC-1:0]             dma_desc;
  s_dma_control_t                               dma_ctrl;
  s_dma_status_t                                dma_stats;
  s_dma_error_t                                 dma_error;

  always_comb begin
    dma_done_o  = dma_stats.done;
    dma_error_o = dma_stats.error;

    if (AXI_DATA_WIDTH == 64) begin
      dma_csr_miso_o.rdata[AXI_DATA_WIDTH-1:(AXI_DATA_WIDTH/2)] = '0;
    end

    // Hook-up Desc. CSR and DMA logic
    for (int i=0; i<`DMA_NUM_DESC; i++) begin : connecting_structs_with_csr
      dma_desc[i].src_addr  = dma_desc_src_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
      dma_desc[i].dst_addr  = dma_desc_dst_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
      dma_desc[i].num_bytes = dma_desc_byt_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
      dma_desc[i].wr_mode   = dma_mode_t'(dma_desc_wr_mod[i]);
      dma_desc[i].rd_mode   = dma_mode_t'(dma_desc_rd_mod[i]);
      dma_desc[i].enable    = dma_desc_en[i];
    end : connecting_structs_with_csr
  end

  dma_csr #(
    .AXI_DATA_WIDTH           (256                    )
  ) u_dma_csr (                                       
    .clk_i                    (clk                    ),
    .rstn_i                   (~rst                   ),

    .axi_awvalid_i            (dma_csr_mosi_i.awvalid),
    .axi_awaddr_i             (dma_csr_mosi_i.awaddr),
    .axi_awid_i               (dma_csr_mosi_i.awid),
    // .axi_awlen_i              (dma_csr_mosi_i.awlen),
    // .axi_awburst_i            (dma_csr_mosi_i.awburst),
    .axi_wvalid_i             (dma_csr_mosi_i.wvalid),
    .axi_wdata_i              (dma_csr_mosi_i.wdata),
    .axi_wstrb_i              (dma_csr_mosi_i.wstrb),
    // .axi_wlast_i              (dma_csr_mosi_i.wlast),
    .axi_bready_i             (dma_csr_mosi_i.bready),
    .axi_arvalid_i            (dma_csr_mosi_i.arvalid),
    .axi_araddr_i             (dma_csr_mosi_i.araddr),
    .axi_arid_i               (dma_csr_mosi_i.arid),
    // .axi_arlen_i              (dma_csr_mosi_i.arlen),
    // .axi_arburst_i            (dma_csr_mosi_i.arburst),
    .axi_rready_i             (dma_csr_mosi_i.rready),
    
    .axi_awready_o            (dma_csr_miso_o.awready),
    .axi_wready_o             (dma_csr_miso_o.wready),
    .axi_bvalid_o             (dma_csr_miso_o.bvalid),
    .axi_bresp_o              (dma_csr_miso_o.bresp),
    .axi_bid_o                (dma_csr_miso_o.bid),
    .axi_arready_o            (dma_csr_miso_o.arready),
    .axi_rvalid_o             (dma_csr_miso_o.rvalid),
    .axi_rdata_o              (dma_csr_miso_o.rdata),
    .axi_rresp_o              (dma_csr_miso_o.rresp),
    .axi_rid_o                (dma_csr_miso_o.rid),
    // .axi_rlast_o              (dma_csr_miso_o.rlast),
    
    .cfg_rd_ctrl_go_o         (dma_ctrl.go),
    .cfg_rd_ctrl_abort_o      (dma_ctrl.abort_req),
    .cfg_rd_ctrl_max_burst_o  (dma_ctrl.max_burst),
    .cfg_rd_desc_src_addr_o   (dma_desc_src_vec),
    .cfg_rd_desc_dst_addr_o   (dma_desc_dst_vec),
    .cfg_rd_desc_num_bytes_o  (dma_desc_byt_vec),
    .cfg_rd_desc_write_mode_o (dma_desc_wr_mod),
    .cfg_rd_desc_read_mode_o  (dma_desc_rd_mod),
    .cfg_rd_desc_enable_o     (dma_desc_en),
    .cfg_wr_status_done_i     (dma_stats.done),
    .cfg_wr_error_trig_i      (dma_stats.error),
    .cfg_wr_error_addr_i      (dma_error.addr),
    .cfg_wr_error_type_i      (dma_error.type_err),
    .cfg_wr_error_src_i       (dma_error.src)
  );

  dma_func_wrapper #(
    .DMA_ID_VAL       (DMA_ID_VAL)
  ) u_dma_func_wrapper (
    .clk              (clk),
    .rst              (rst),
    // From/To CSRs
    .dma_csr_ctrl_i   (dma_ctrl),
    .dma_csr_desc_i   (dma_desc),
    .dma_csr_stats_o  (dma_stats),
    .dma_csr_error_o  (dma_error),
    // Master AXI I/F
    .dma_mosi_o       (dma_m_mosi_o),
    .dma_miso_i       (dma_m_miso_i)
  );
endmodule
