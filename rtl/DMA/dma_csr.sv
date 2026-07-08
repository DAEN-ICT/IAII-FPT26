module dma_csr 
  import amba_axi_pkg::*;
  import dma_pkg::*;
# (
    parameter AXI_DATA_WIDTH = 64    
)(
    input  logic                            clk_i,
    input  logic                            rstn_i,

    // AXI Interface
    input  logic                            axi_awvalid_i   ,
    input  logic [31:0]                     axi_awaddr_i    ,
    input  logic [3:0]                      axi_awid_i      ,
    input  logic [7:0]                      axi_awlen_i     ,
    input  logic [1:0]                      axi_awburst_i   ,
    input  logic                            axi_wvalid_i    ,
    input  logic [AXI_DATA_WIDTH-1:0]       axi_wdata_i     ,
    input  logic [AXI_DATA_WIDTH/8-1:0]     axi_wstrb_i     ,
    input  logic                            axi_wlast_i     ,
    input  logic                            axi_bready_i    ,
    input  logic                            axi_arvalid_i   ,
    input  logic [31:0]                     axi_araddr_i    ,
    input  logic [3:0]                      axi_arid_i      ,
    input  logic [7:0]                      axi_arlen_i     ,
    input  logic [1:0]                      axi_arburst_i   ,
    input  logic                            axi_rready_i    ,

    output logic                            axi_awready_o   ,
    output logic                            axi_wready_o    ,
    output logic                            axi_bvalid_o    ,
    output axi_resp_t                       axi_bresp_o     ,
    output logic [3:0]                      axi_bid_o       ,
    output logic                            axi_arready_o   ,
    output logic                            axi_rvalid_o    ,
    output logic [AXI_DATA_WIDTH-1:0]       axi_rdata_o     ,
    output axi_resp_t                       axi_rresp_o     ,
    output logic [3:0]                      axi_rid_o       ,
    output logic                            axi_rlast_o     ,

    // Config Register Interface
    output logic                            cfg_rd_ctrl_go_o,
    output logic                            cfg_rd_ctrl_abort_o,
    output logic [7:0]                      cfg_rd_ctrl_max_burst_o,
    output logic [`DMA_NUM_DESC-1:0][31:0]  cfg_rd_desc_src_addr_o,
    output logic [`DMA_NUM_DESC-1:0][31:0]  cfg_rd_desc_dst_addr_o,
    output logic [`DMA_NUM_DESC-1:0][31:0]  cfg_rd_desc_num_bytes_o,
    output logic [`DMA_NUM_DESC-1:0]        cfg_rd_desc_write_mode_o,
    output logic [`DMA_NUM_DESC-1:0]        cfg_rd_desc_read_mode_o,
    output logic [`DMA_NUM_DESC-1:0]        cfg_rd_desc_enable_o,

    input  logic                            cfg_wr_status_done_i,
    input  logic [31:0]                     cfg_wr_error_addr_i,
    input  logic                            cfg_wr_error_type_i,
    input  logic                            cfg_wr_error_src_i,
    input  logic                            cfg_wr_error_trig_i
);

// Config Register Interface
logic [11:0]                    axi2cfg_offset_w;
logic                           axi2cfg_wen_w;
logic [AXI_DATA_WIDTH-1:0]      axi2cfg_wdata_w;
logic [AXI_DATA_WIDTH-1:0]      axi2cfg_rdata_w;

// Config Register Definition
logic                    [31:0] cfg_reg_ctrl_q;
logic                    [31:0] cfg_reg_status_q;
logic                    [31:0] cfg_reg_error_addr_q;
logic                    [31:0] cfg_reg_error_status_q;

logic [`DMA_NUM_DESC-1:0][31:0] cfg_reg_desc_src_addr_q;
logic [`DMA_NUM_DESC-1:0][31:0] cfg_reg_desc_dst_addr_q;
logic [`DMA_NUM_DESC-1:0][31:0] cfg_reg_desc_num_bytes_q;
logic [`DMA_NUM_DESC-1:0]       cfg_reg_desc_write_mode_q;
logic [`DMA_NUM_DESC-1:0]       cfg_reg_desc_read_mode_q;
logic [`DMA_NUM_DESC-1:0]       cfg_reg_desc_enable_q;

// ------------------------------------------------------------------------------
// AXI to Config Register Interface
// ------------------------------------------------------------------------------
axi_to_cfgreg #(
    .AXI_DATA_WIDTH(AXI_DATA_WIDTH)
) u_axi_to_cfgreg (
    .clk_i                          (clk_i),
    .rstn_i                         (rstn_i),
    .axi_awvalid_i                  (axi_awvalid_i),
    .axi_awaddr_i                   (axi_awaddr_i),
    .axi_awid_i                     (axi_awid_i),
    .axi_awlen_i                    (axi_awlen_i),
    .axi_awburst_i                  (axi_awburst_i),
    .axi_wvalid_i                   (axi_wvalid_i),
    .axi_wdata_i                    (axi_wdata_i),
    .axi_wstrb_i                    (axi_wstrb_i),
    .axi_wlast_i                    (axi_wlast_i),
    .axi_bready_i                   (axi_bready_i),
    .axi_arvalid_i                  (axi_arvalid_i),
    .axi_araddr_i                   (axi_araddr_i),
    .axi_arid_i                     (axi_arid_i),
    .axi_arlen_i                    (axi_arlen_i),
    .axi_arburst_i                  (axi_arburst_i),
    .axi_rready_i                   (axi_rready_i),

    .axi_awready_o                  (axi_awready_o),
    .axi_wready_o                   (axi_wready_o),
    .axi_bvalid_o                   (axi_bvalid_o),
    .axi_bresp_o                    (axi_bresp_o),
    .axi_bid_o                      (axi_bid_o),
    .axi_arready_o                  (axi_arready_o),
    .axi_rvalid_o                   (axi_rvalid_o),
    .axi_rdata_o                    (axi_rdata_o),
    .axi_rresp_o                    (axi_rresp_o),
    .axi_rid_o                      (axi_rid_o),
    .axi_rlast_o                    (axi_rlast_o),

    // Config Register Interface
    .config_offset_o                (axi2cfg_offset_w),
    .config_wen_o                   (axi2cfg_wen_w),
    .config_wdata_o                 (axi2cfg_wdata_w),
    .config_rdata_i                 (axi2cfg_rdata_w)
);

// ------------------------------------------------------------------------------
// Config Register Write
// ------------------------------------------------------------------------------
always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) begin
        cfg_reg_ctrl_q              <= '0;
        cfg_reg_desc_src_addr_q     <= '0;
        cfg_reg_desc_dst_addr_q     <= '0;
        cfg_reg_desc_num_bytes_q    <= '0;
        cfg_reg_desc_write_mode_q   <= '0;
        cfg_reg_desc_read_mode_q    <= '0;
        cfg_reg_desc_enable_q       <= '0;
        cfg_reg_status_q            <= '0;
        cfg_reg_error_addr_q        <= '0;
        cfg_reg_error_status_q      <= '0;
    end else begin
        cfg_reg_ctrl_q              <= cfg_reg_ctrl_q;
        cfg_reg_desc_src_addr_q     <= cfg_reg_desc_src_addr_q;
        cfg_reg_desc_dst_addr_q     <= cfg_reg_desc_dst_addr_q;
        cfg_reg_desc_num_bytes_q    <= cfg_reg_desc_num_bytes_q;
        cfg_reg_desc_write_mode_q   <= cfg_reg_desc_write_mode_q;
        cfg_reg_desc_read_mode_q    <= cfg_reg_desc_read_mode_q;
        cfg_reg_desc_enable_q       <= cfg_reg_desc_enable_q;
        cfg_reg_status_q            <= cfg_reg_status_q;
        cfg_reg_error_addr_q        <= cfg_reg_error_addr_q;
        cfg_reg_error_status_q      <= cfg_reg_error_status_q;

        // AXI write
        if (axi2cfg_wen_w) begin
            case (axi2cfg_offset_w)
                12'h000: begin
                    cfg_reg_ctrl_q[0]               <= axi2cfg_wdata_w[0];
                    cfg_reg_ctrl_q[1]               <= axi2cfg_wdata_w[1];
                    cfg_reg_ctrl_q[9:2]             <= axi2cfg_wdata_w[9:2];
                    // clear done & error & err_trig bits
                    cfg_reg_status_q[16]            <= '0;
                    cfg_reg_status_q[17]            <= '0;
                    cfg_reg_error_status_q[2]       <= '0;
                end
                12'h020: begin
                    cfg_reg_desc_src_addr_q[0]      <= axi2cfg_wdata_w;
                end
                12'h028: begin
                    cfg_reg_desc_src_addr_q[1]      <= axi2cfg_wdata_w;
                end
                12'h030: begin
                    cfg_reg_desc_dst_addr_q[0]      <= axi2cfg_wdata_w;
                end
                12'h038: begin
                    cfg_reg_desc_dst_addr_q[1]      <= axi2cfg_wdata_w;
                end
                12'h040: begin
                    cfg_reg_desc_num_bytes_q[0]     <= axi2cfg_wdata_w;
                end
                12'h048: begin
                    cfg_reg_desc_num_bytes_q[1]     <= axi2cfg_wdata_w;
                end
                12'h050: begin
                    cfg_reg_desc_write_mode_q[0]    <= axi2cfg_wdata_w[0];
                    cfg_reg_desc_read_mode_q[0]     <= axi2cfg_wdata_w[1];
                    cfg_reg_desc_enable_q[0]        <= axi2cfg_wdata_w[2];
                end
                12'h058: begin
                    cfg_reg_desc_write_mode_q[1]    <= axi2cfg_wdata_w[0];
                    cfg_reg_desc_read_mode_q[1]     <= axi2cfg_wdata_w[1];
                    cfg_reg_desc_enable_q[1]        <= axi2cfg_wdata_w[2];
                end
            endcase
        end

        // internal write
        // ? for axi, they're read only
        if (cfg_wr_status_done_i) begin
            cfg_reg_status_q[16]        <= '1;
        end
        if (cfg_wr_error_trig_i) begin
            cfg_reg_status_q[17]        <= '1;
            cfg_reg_error_addr_q        <= cfg_wr_error_addr_i;
            cfg_reg_error_status_q[0]   <= cfg_wr_error_type_i;
            cfg_reg_error_status_q[1]   <= cfg_wr_error_src_i;
            cfg_reg_error_status_q[2]   <= '1;
        end
    end
end

// ------------------------------------------------------------------------------
// Config Register Read
// ------------------------------------------------------------------------------
// AXI read
always @(*) begin
    case (axi2cfg_offset_w)
        12'h000: begin
            axi2cfg_rdata_w = cfg_reg_ctrl_q;
        end
        12'h008: begin
            axi2cfg_rdata_w = cfg_reg_status_q;
        end
        12'h010: begin
            axi2cfg_rdata_w = cfg_reg_error_addr_q;
        end
        12'h018: begin
            axi2cfg_rdata_w = cfg_reg_error_status_q;
        end
        12'h020: begin
            axi2cfg_rdata_w = cfg_reg_desc_src_addr_q[0];
        end
        12'h028: begin
            axi2cfg_rdata_w = cfg_reg_desc_src_addr_q[1];
        end
        12'h030: begin
            axi2cfg_rdata_w = cfg_reg_desc_dst_addr_q[0];
        end
        12'h038: begin
            axi2cfg_rdata_w = cfg_reg_desc_dst_addr_q[1];
        end
        12'h040: begin
            axi2cfg_rdata_w = cfg_reg_desc_num_bytes_q[0];
        end
        12'h048: begin
            axi2cfg_rdata_w = cfg_reg_desc_num_bytes_q[1];
        end
        12'h050: begin
            axi2cfg_rdata_w = {29'h0, cfg_reg_desc_enable_q[0],
                                      cfg_reg_desc_read_mode_q[0],
                                      cfg_reg_desc_write_mode_q[0]};
        end
        12'h058: begin
            axi2cfg_rdata_w = {29'h0, cfg_reg_desc_enable_q[1],
                                      cfg_reg_desc_read_mode_q[1],
                                      cfg_reg_desc_write_mode_q[1]};
        end
    endcase 
end

// internal read
assign cfg_rd_ctrl_go_o               = cfg_reg_ctrl_q[0];
assign cfg_rd_ctrl_abort_o            = cfg_reg_ctrl_q[1];
assign cfg_rd_ctrl_max_burst_o        = cfg_reg_ctrl_q[9:2];
assign cfg_rd_desc_src_addr_o         = cfg_reg_desc_src_addr_q;
assign cfg_rd_desc_dst_addr_o         = cfg_reg_desc_dst_addr_q;
assign cfg_rd_desc_num_bytes_o        = cfg_reg_desc_num_bytes_q;
assign cfg_rd_desc_write_mode_o       = cfg_reg_desc_write_mode_q;
assign cfg_rd_desc_read_mode_o        = cfg_reg_desc_read_mode_q;
assign cfg_rd_desc_enable_o           = cfg_reg_desc_enable_q;

endmodule