module dma_func_wrapper
  import amba_axi_pkg::*;
  import dma_pkg::*;
#(
  parameter int DMA_ID_VAL = 0
)(
  input                                     clk,
  input                                     rst,
  // From/To CSRs
  input   s_dma_control_t                   dma_csr_ctrl_i,
  input   s_dma_desc_t [`DMA_NUM_DESC-1:0]  dma_csr_desc_i,
  output  s_dma_error_t                     dma_csr_error_o,
  output  s_dma_status_t                    dma_csr_stats_o,
  // Master AXI I/F
  output  s_axi_mosi_t                      dma_mosi_o,
  input   s_axi_miso_t                      dma_miso_i
);
  s_dma_str_in_t    dma_rd_stream_in;
  s_dma_str_out_t   dma_rd_stream_out;
  s_dma_str_in_t    dma_wr_stream_in;
  s_dma_str_out_t   dma_wr_stream_out;
  s_dma_axi_req_t   dma_streamer_rd_req;
  s_dma_axi_resp_t  dma_streamer_rd_rsp;
  s_dma_axi_req_t   dma_streamer_wr_req;
  s_dma_axi_resp_t  dma_streamer_wr_rsp;
  s_dma_fifo_req_t  dma_fifo_req;
  s_dma_fifo_resp_t dma_fifo_resp;
  s_dma_error_t     dma_fsm_err;
  logic             dma_axi_outsding_pend;
  logic             dma_fsm_clear;
  logic             dma_fsm_active;

  dma_fsm u_dma_fsm(
    .clk                      (clk),
    .rst                      (rst),

    // csr control
    .dma_ctrl_i               (dma_csr_ctrl_i),
    .dma_desc_i               (dma_csr_desc_i),
    .dma_stats_o              (dma_csr_stats_o),
    .dma_error_o              (dma_csr_error_o),

    // fsm to streamer control/rsp
    .dma_stream_rd_o          (dma_rd_stream_in),
    .dma_stream_rd_i          (dma_rd_stream_out),
    .dma_stream_wr_o          (dma_wr_stream_in),
    .dma_stream_wr_i          (dma_wr_stream_out),

    // fsm to axi_if control/rsp
    .dma_fsm_active_o         (dma_fsm_active),
    .dma_fsm_clear_o          (dma_fsm_clear),
    .axi_txn_err_i            (dma_fsm_err),
    .dma_axi_outsding_pend_i  (dma_axi_outsding_pend)
  );

  dma_streamer #(
    .STREAMER_TYPE_WR(0)
  ) u_dma_rd_streamer (
    .clk              (clk),
    .rst              (rst),

    // csr control
    .dma_csr_desc_i   (dma_csr_desc_i),
    .dma_csr_abort_i  (dma_csr_ctrl_i.abort_req),
    .dma_csr_maxb_i   (dma_csr_ctrl_i.max_burst),
    
    // fsm control/rsp
    .dma_fsm_ctrl_i   (dma_rd_stream_in), // it's used to select csr descriptor idx
    .dma_fsm_rsp_o    (dma_rd_stream_out),

    // streamer to axi_if req/rsp
    .dma_axi_req_o    (dma_streamer_rd_req),
    .dma_axi_resp_i   (dma_streamer_rd_rsp)
  );

  dma_streamer #(
    .STREAMER_TYPE_WR(1)
  ) u_dma_wr_streamer (
    .clk              (clk),
    .rst              (rst),
    
    // csr control
    .dma_csr_desc_i   (dma_csr_desc_i),
    .dma_csr_abort_i  (dma_csr_ctrl_i.abort_req),
    .dma_csr_maxb_i   (dma_csr_ctrl_i.max_burst),

    // fsm control/rsp
    .dma_fsm_ctrl_i   (dma_wr_stream_in),
    .dma_fsm_rsp_o    (dma_wr_stream_out),

    // streamer to axi_if req/rsp
    .dma_axi_req_o    (dma_streamer_wr_req),
    .dma_axi_resp_i   (dma_streamer_wr_rsp)
  );

  dma_fifo #(
    .DEPTH                  (`DMA_FIFO_DEPTH),
    .WIDTH                  (`DMA_DATA_WIDTH)
  ) u_dma_fifo(
    .clk                    (clk),
    .rst                    (rst),
    .clear_i                (dma_fsm_clear),
    .write_i                (dma_fifo_req.wr),
    .read_i                 (dma_fifo_req.rd),
    .data_i                 (dma_fifo_req.data_wr),
    .data_o                 (dma_fifo_resp.data_rd),
    .error_o                (),
    .full_o                 (dma_fifo_resp.full),
    .empty_o                (dma_fifo_resp.empty),
    .ocup_o                 (dma_fifo_resp.ocup),
    .free_o                 (dma_fifo_resp.space)
  );

  dma_axi_if #(
    .DMA_ID_VAL             (DMA_ID_VAL)
  ) u_dma_axi_if (
    .clk                    (clk),
    .rst                    (rst),

    // fsm to axi_if control/rsp
    .dma_csr_abort_i        (dma_csr_ctrl_i.abort_req),
    .dma_fsm_active_i       (dma_fsm_active),
    .dma_fsm_clear_i        (dma_fsm_clear),
    .dma_fsm_err_o          (dma_fsm_err),
    .dma_axi_outsding_pend_o(dma_axi_outsding_pend),

    // streamer to axi_if req/rsp
    .dma_streamer_rd_req_i  (dma_streamer_rd_req),
    .dma_streamer_rd_rsp_o  (dma_streamer_rd_rsp),
    .dma_streamer_wr_req_i  (dma_streamer_wr_req),
    .dma_streamer_wr_rsp_o  (dma_streamer_wr_rsp),

    // AXI interface
    .dma_mosi_o             (dma_mosi_o),
    .dma_miso_i             (dma_miso_i),

    // FIFO interface
    .dma_fifo_req_o         (dma_fifo_req),
    .dma_fifo_resp_i        (dma_fifo_resp)
  );
endmodule

