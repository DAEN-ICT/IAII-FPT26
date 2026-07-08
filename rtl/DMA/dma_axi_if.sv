`include "dma_pkg.svh"

module dma_axi_if
  import amba_axi_pkg::*;
  import dma_pkg::*;
#(
  parameter int DMA_ID_VAL = 0
)(
  input                     clk,
  input                     rst,
  // From/To Streamers
  input   s_dma_axi_req_t   dma_streamer_rd_req_i,
  output  s_dma_axi_resp_t  dma_streamer_rd_rsp_o,
  input   s_dma_axi_req_t   dma_streamer_wr_req_i,
  output  s_dma_axi_resp_t  dma_streamer_wr_rsp_o,
  // Master AXI I/F
  output  s_axi_mosi_t      dma_mosi_o,
  input   s_axi_miso_t      dma_miso_i,
  // From/To FIFOs interface
  output  s_dma_fifo_req_t  dma_fifo_req_o,
  input   s_dma_fifo_resp_t dma_fifo_resp_i,
  // From/To DMA FSM
  input                     dma_csr_abort_i,
  input                     dma_fsm_active_i,
  input                     dma_fsm_clear_i,
  output  s_dma_error_t     dma_fsm_err_o,
  output  logic             dma_axi_outsding_pend_o
);
  pend_rd_t     axi_outstanding_rd_cnt_q, axi_outstanding_rd_cnt_d;
  pend_wr_t     axi_outstanding_wr_cnt_q, axi_outstanding_wr_cnt_d;
  axi_wr_strb_t rd_txn_last_strb;
  logic         axi_ar_handshaked;
  logic         axi_aw_handshaked;
  logic         axi_r_handshaked_last;
  logic         axi_b_handshaked;
  logic         axi_rd_rsp_err;
  logic         axi_wr_rsp_err;
  axi_addr_t    rd_txn_addr;
  axi_addr_t    wr_txn_addr;
  logic         err_lock_ff, next_err_lock;
  logic         axi_w_handshaked_last;
  logic         wr_lock_ff, next_wr_lock;
  logic         axi_w_handshaked;
  logic         streamer_wr_req_fifo_empty;
  logic         axi_aw_handshake_pending_q, axi_aw_handshake_pending_d;

  logic         streamer_wr_req_fifo_push;
  s_wr_req_t    streamer_wr_req_fifo_push_info, streamer_wr_req_fifo_pop_info;
  logic         streamer_wr_req_fifo_pop;
  axi_alen_t    axi_w_burst_beat_cnt_q, axi_w_burst_beat_cnt_d;

  s_dma_error_t dma_error_ff, next_dma_error;

  function automatic axi_data_t apply_strb(axi_data_t data, axi_wr_strb_t mask);
    axi_data_t out_data;
    for (int i=0; i<$bits(axi_wr_strb_t); i++) begin
      if (mask[i] == 1'b1) begin
        out_data[(8*i)+:8] = data[(8*i)+:8];
      end
      else begin
        out_data[(8*i)+:8] = 8'd0;
      end
    end
    return out_data;
  endfunction

  // ------------------------------------------------------------------------------
  // Streamer Req Buffer
  // ------------------------------------------------------------------------------
  // Buffer of wr streamer req information
  // need to store wr req, before read wdata from fifo
  always @(*) begin
    // push
    if (dma_streamer_wr_req_i.valid) begin
      streamer_wr_req_fifo_push   = ~wr_lock_ff;
      streamer_wr_req_fifo_push_info.alen  = dma_streamer_wr_req_i.alen;
      streamer_wr_req_fifo_push_info.wstrb = dma_streamer_wr_req_i.strb;
    end else begin
      streamer_wr_req_fifo_push  = 1'b0;
      streamer_wr_req_fifo_push_info = s_wr_req_t'('0);
    end

    // pop
    streamer_wr_req_fifo_pop = axi_w_handshaked_last;
  end

  dma_fifo #(
    .DEPTH  (`DMA_WR_OUTSDING_FIFO_DEPTH), // ? individual fifo depth
    .WIDTH  ($bits(s_wr_req_t))
  ) u_fifo_wr_req (
    .clk    (clk),
    .rst    (rst),

    .write_i(streamer_wr_req_fifo_push),
    .data_i (streamer_wr_req_fifo_push_info),

    .read_i (streamer_wr_req_fifo_pop),
    .data_o (streamer_wr_req_fifo_pop_info),

    .full_o (),
    .empty_o(streamer_wr_req_fifo_empty),
    .error_o(),
    .ocup_o (),
    .clear_i(1'b0),
    .free_o ()
  );

  // Buffer of rd streamer req strb
  // it's used to mask R channel rsp data, for unaligned start/end addr read
  dma_fifo #(
    .DEPTH  (`DMA_RD_OUTSDING_FIFO_DEPTH),
    .WIDTH  ($bits(axi_wr_strb_t))
  ) u_fifo_rd_strb (
    .clk    (clk),
    .rst    (rst),

    .write_i(axi_ar_handshaked),
    .data_i (dma_streamer_rd_req_i.strb),

    .read_i (axi_r_handshaked_last),
    .data_o (rd_txn_last_strb),

    .full_o (),
    .empty_o(),
    .error_o(),
    .ocup_o (),
    .clear_i(1'b0),
    .free_o ()
  );

  // Buffer of wr/rd streamer req addr
  // it's used in case of error, need to rsp err_addr to CSR
  dma_fifo #(
    .DEPTH  (`DMA_RD_OUTSDING_FIFO_DEPTH),
    .WIDTH  (`DMA_ADDR_WIDTH)
  ) u_fifo_rd_addr (
    .clk    (clk),
    .rst    (rst),

    .write_i(axi_ar_handshaked),
    .data_i (dma_streamer_rd_req_i.addr),

    .read_i (axi_r_handshaked_last),
    .data_o (rd_txn_addr),

    .full_o (),
    .empty_o(),
    .error_o(),
    .ocup_o (),
    .clear_i(1'b0),
    .free_o ()
  );

  dma_fifo #(
    .DEPTH  (`DMA_WR_OUTSDING_FIFO_DEPTH),
    .WIDTH  (`DMA_ADDR_WIDTH)
  ) u_fifo_wr_addr (
    .clk    (clk),
    .rst    (rst),

    .write_i(axi_aw_handshaked),
    .data_i (dma_streamer_wr_req_i.addr),

    .read_i (axi_b_handshaked),
    .data_o (wr_txn_addr),

    .full_o (),
    .empty_o(),
    .error_o(),
    .ocup_o (),
    .clear_i(1'b0),
    .free_o ()
  );

  // ------------------------------------------------------------------------------
  // handshaked
  // ------------------------------------------------------------------------------
  // AXI handshake
  assign axi_ar_handshaked     = dma_mosi_o.arvalid & dma_miso_i.arready;
  assign axi_r_handshaked_last = dma_miso_i.rvalid  & dma_mosi_o.rready &
                                 dma_miso_i.rlast;

  assign axi_aw_handshaked     = dma_mosi_o.awvalid & dma_miso_i.awready;
  assign axi_w_handshaked      = dma_mosi_o.wvalid  & dma_miso_i.wready;
  assign axi_w_handshaked_last = dma_mosi_o.wvalid  & dma_miso_i.wready &
                                 dma_mosi_o.wlast;
  assign axi_b_handshaked      = dma_miso_i.bvalid  & dma_mosi_o.bready;

  // awvalid raised, but not hanshaked yet
  always_ff @ (posedge clk) begin
    if (rst) begin
      axi_aw_handshake_pending_q <= 1'b0;
    end else begin
      axi_aw_handshake_pending_q <= axi_aw_handshake_pending_d;
    end
  end

  always @(*) begin
    axi_aw_handshake_pending_d = axi_aw_handshake_pending_q;

    if (dma_fsm_active_i & dma_mosi_o.awvalid) begin
      axi_aw_handshake_pending_d = ~dma_miso_i.awready; 
    end
  end
  // assign axi_aw_handshake_pending_d  = dma_fsm_active_i & dma_mosi_o.awvalid & ~dma_miso_i.awready; 

  // handshake with streamer, when AXI handshaked
  always @(*) begin
    dma_streamer_rd_rsp_o       = s_dma_axi_resp_t'('0);
    dma_streamer_wr_rsp_o       = s_dma_axi_resp_t'('0);

    dma_streamer_rd_rsp_o.ready = dma_fsm_active_i &
                                  dma_mosi_o.arvalid & dma_miso_i.arready;
    dma_streamer_wr_rsp_o.ready = dma_fsm_active_i &
                                  dma_mosi_o.awvalid & dma_miso_i.awready;
  end

  // ------------------------------------------------------------------------------
  // Req Counter
  // ------------------------------------------------------------------------------
  // AXI outstanding counter
  assign dma_axi_outsding_pend_o = (|axi_outstanding_rd_cnt_q) || (|axi_outstanding_wr_cnt_q);

  always_ff @ (posedge clk) begin
    if (rst) begin
      axi_outstanding_rd_cnt_q     <= pend_rd_t'('0);
      axi_outstanding_wr_cnt_q     <= pend_rd_t'('0);
    end else begin
      axi_outstanding_rd_cnt_q     <= axi_outstanding_rd_cnt_d;
      axi_outstanding_wr_cnt_q     <= axi_outstanding_wr_cnt_d;
    end
  end

  always @(*) begin
    if (dma_fsm_active_i) begin
      if (axi_ar_handshaked || axi_r_handshaked_last) begin
        axi_outstanding_rd_cnt_d = axi_outstanding_rd_cnt_q + (axi_ar_handshaked     ? 'd1 : 'd0)
                                                            - (axi_r_handshaked_last ? 'd1 : 'd0);
      end else begin
        axi_outstanding_rd_cnt_d = axi_outstanding_rd_cnt_q;
      end

      if (axi_aw_handshaked || axi_b_handshaked) begin
        axi_outstanding_wr_cnt_d = axi_outstanding_wr_cnt_q + (axi_aw_handshaked ? 'd1 : 'd0)
                                                            - (axi_b_handshaked  ? 'd1 : 'd0);
      end else begin
        axi_outstanding_wr_cnt_d = axi_outstanding_wr_cnt_q;
      end
    end else begin
      axi_outstanding_rd_cnt_d = 'd0;
      axi_outstanding_wr_cnt_d = 'd0;
    end
  end

  // AXI W channel burst counter
  always_ff @ (posedge clk) begin
    if (rst) begin
      axi_w_burst_beat_cnt_q   <= '0;
    end else begin
      axi_w_burst_beat_cnt_q   <= axi_w_burst_beat_cnt_d;
    end
  end

  always @(*) begin
    axi_w_burst_beat_cnt_d = axi_w_burst_beat_cnt_q;

    // increase in each beat of the burst
    if (axi_w_handshaked) begin
      axi_w_burst_beat_cnt_d = axi_w_burst_beat_cnt_q + 'd1;
    end

    // clear in last beat of the burst
    if (axi_w_handshaked_last) begin
      axi_w_burst_beat_cnt_d = axi_alen_t'('0);
    end
  end

  // ------------------------------------------------------------------------------
  // AXI Req
  // ------------------------------------------------------------------------------
wire dma_streamer_wr_req_i_valid = dma_streamer_wr_req_i.valid;
wire  dma_fifo_resp_i_empty = dma_fifo_resp_i.empty;
  always_comb begin : axi4_master
    dma_mosi_o     = s_axi_mosi_t'('0);
    dma_fifo_req_o = s_dma_fifo_req_t'('0);
    axi_rd_rsp_err = 1'b0;
    axi_wr_rsp_err = 1'b0;

    if (dma_fsm_active_i) begin
      // AXI AR channel
      // arvalid: streamer req valid, and outstanding fifo not full
      dma_mosi_o.arvalid = dma_streamer_rd_req_i.valid &
                           (axi_outstanding_rd_cnt_q < `DMA_RD_OUTSDING_FIFO_DEPTH);
      if (dma_mosi_o.arvalid) begin
        dma_mosi_o.araddr  = dma_streamer_rd_req_i.addr;
        dma_mosi_o.arlen   = dma_streamer_rd_req_i.alen;
        dma_mosi_o.arsize  = dma_streamer_rd_req_i.size;
        dma_mosi_o.arburst = (dma_streamer_rd_req_i.mode == DMA_MODE_INCR) ? AXI_INCR : AXI_FIXED;
      end
      dma_mosi_o.arprot = AXI_NONSECURE;
      dma_mosi_o.arid   = axi_tid_t'(DMA_ID_VAL);

      // AXI R channel
      // rready: abort, or fifo not full
      dma_mosi_o.rready = (~dma_fifo_resp_i.full || dma_csr_abort_i);
      // write rsp data to fifo
      if (dma_miso_i.rvalid & dma_mosi_o.rready) begin
        // ignore rsp data in case of abort
        dma_fifo_req_o.wr      = ~dma_csr_abort_i;
        // use strb to mask rsp data
        dma_fifo_req_o.data_wr = apply_strb(dma_miso_i.rdata, rd_txn_last_strb);
        // rsp error
        // if (dma_miso_i.rlast && dma_mosi_o.rready) begin
        if (dma_miso_i.rvalid && dma_mosi_o.rready) begin
          axi_rd_rsp_err = (dma_miso_i.rresp == AXI_SLVERR) ||
                           (dma_miso_i.rresp == AXI_DECERR);
        end
      end

      // AXI AW channel
      // Send a write txn based on the following conditions:
      // 1- We have a request coming from the streamer - ...valid
      // 2- ...and we have something to send in the data phase ...~empty
      // 3- (OR) we have an abort request, so we can ignore the DMA_FIFO
      // 4- Or we have started a AXI req, but not yet handshaked
      // 5- if (we have enough buffer space to record addr in case of err - `DMA_WR_OUTSDING_FIFO_DEPTH)
      //    We could potentially put awvalid back to low if dma_fifo gets empty
      //    while we are waiting for awready from the slave
      dma_mosi_o.awvalid = ((dma_streamer_wr_req_i.valid & (~dma_fifo_resp_i.empty | dma_csr_abort_i)) |
                            (axi_aw_handshake_pending_q)) &
                           (axi_outstanding_wr_cnt_q < `DMA_WR_OUTSDING_FIFO_DEPTH);
      if (dma_mosi_o.awvalid) begin
        dma_mosi_o.awaddr           = dma_streamer_wr_req_i.addr;
        dma_mosi_o.awlen            = dma_streamer_wr_req_i.alen;
        dma_mosi_o.awsize           = dma_streamer_wr_req_i.size;
        dma_mosi_o.awburst          = (dma_streamer_wr_req_i.mode == DMA_MODE_INCR) ? AXI_INCR : AXI_FIXED;
      end
      dma_mosi_o.awprot = AXI_NONSECURE;
      dma_mosi_o.awid   = axi_tid_t'(DMA_ID_VAL);

      // AXI W channel
      if (~streamer_wr_req_fifo_empty & (~dma_fifo_resp_i.empty | dma_csr_abort_i)) begin
        dma_mosi_o.wvalid = 1'b1;
        dma_fifo_req_o.rd = dma_csr_abort_i ? 1'b0 : dma_miso_i.wready; // Ignore fifo content in case of abort
        dma_mosi_o.wdata  = dma_fifo_resp_i.data_rd;
        dma_mosi_o.wstrb  = streamer_wr_req_fifo_pop_info.wstrb;
        dma_mosi_o.wlast  = (axi_w_burst_beat_cnt_q == streamer_wr_req_fifo_pop_info.alen);
      end

      // AXI B channel
      dma_mosi_o.bready = 1'b1;
      if (dma_miso_i.bvalid) begin
        axi_wr_rsp_err = (dma_miso_i.bresp == AXI_SLVERR) ||
                         (dma_miso_i.bresp == AXI_DECERR);
      end
    end
  end : axi4_master

  // ------------------------------------------------------------------------------
  // AXI error
  // ------------------------------------------------------------------------------
  assign dma_fsm_err_o = dma_error_ff;

  always_ff @ (posedge clk) begin
    if (rst) begin
      dma_error_ff      <= s_dma_error_t'('0);
      err_lock_ff       <= 1'b0;
      wr_lock_ff        <= 1'b0;
    end
    else begin
      dma_error_ff      <= next_dma_error;
      err_lock_ff       <= next_err_lock;
      wr_lock_ff        <= next_wr_lock;
    end
  end

  always_comb begin
    next_dma_error  = dma_error_ff;
    next_err_lock   = err_lock_ff;

    if (~dma_fsm_active_i) begin
      next_err_lock   = 1'b0;
    end else begin
      next_err_lock = axi_rd_rsp_err || axi_wr_rsp_err;
    end

    if (~err_lock_ff) begin
      if (axi_rd_rsp_err) begin
        next_dma_error.valid    = 1'b1;
        next_dma_error.type_err = DMA_ERR_OPE;
        next_dma_error.src      = DMA_ERR_RD;
        next_dma_error.addr     = rd_txn_addr;
      end
      else if (axi_wr_rsp_err) begin
        next_dma_error.valid    = 1'b1;
        next_dma_error.type_err = DMA_ERR_OPE;
        next_dma_error.src      = DMA_ERR_WR;
        next_dma_error.addr     = wr_txn_addr;
      end
    end

    if (dma_fsm_clear_i) begin
      next_dma_error = s_dma_error_t'('0);
      next_wr_lock   = 1'b0;
    end

    next_wr_lock = wr_lock_ff;
    if (dma_streamer_wr_req_i.valid) begin
      next_wr_lock = ~dma_streamer_wr_rsp_o.ready;
    end

    if (axi_aw_handshaked) begin
      next_wr_lock = 1'b0;
    end

  end

// `ifndef NO_ASSERTIONS
//     default clocking axi4_clk @(posedge clk); endclocking

//     // keep axi_req valid before handshake
//     property valid_before_handshake(valid, ready);
//        valid && !ready |-> ##1 valid;
//     endproperty // valid_before_handshake

//     // keep axi_req information stable before handshake
//     property stable_before_handshake(valid, ready, control);
//       valid && !ready |-> ##1 $stable(control);
//     endproperty // stable_before_handshake

//     axi4_arvalid_arready : assert property(disable iff (rst) valid_before_handshake  (dma_mosi_o.arvalid, dma_miso_i.arready))
//                            else $error("Violation AXI4: Once ARVALID is asserted it must remain asserted until the handshake");
//     axi4_arvalid_araddr  : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.arvalid, dma_miso_i.arready, dma_mosi_o.araddr))
//                            else $error("Violation AXI4: Once the master has asserted ARVALID, data and control information from master must remain stable [ADDR] until ARREADY is asserted");
//     axi4_arvalid_arlen   : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.arvalid, dma_miso_i.arready, dma_mosi_o.arlen))
//                            else $error("Violation AXI4: Once the master has asserted ARVALID, data and control information from master must remain stable [ALEN] until ARREADY is asserted");
//     axi4_arvalid_arsize  : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.arvalid, dma_miso_i.arready, dma_mosi_o.arsize))
//                            else $error("Violation AXI4: Once the master has asserted ARVALID, data and control information from master must remain stable [ASIZE] until ARREADY is asserted");
//     axi4_arvalid_arburst : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.arvalid, dma_miso_i.arready, dma_mosi_o.arburst))
//                            else $error("Violation AXI4: Once the master has asserted ARVALID, data and control information from master must remain stable [ABURST] until ARREADY is asserted");

//     axi4_awvalid_awready : assert property(disable iff (rst) valid_before_handshake  (dma_mosi_o.awvalid, dma_miso_i.awready))
//                            else $error("Violation AXI4: Once AWVALID is asserted it must remain asserted until the handshake");
//     axi4_awvalid_awaddr  : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.awvalid, dma_miso_i.awready, dma_mosi_o.awaddr))
//                            else $error("Violation AXI4: Once the master has asserted AWVALID, data and control information from master must remain stable [ADDR] until AWREADY is asserted");
//     axi4_awvalid_awlen   : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.awvalid, dma_miso_i.awready, dma_mosi_o.awlen))
//                            else $error("Violation AXI4: Once the master has asserted AWVALID, data and control information from master must remain stable [ALEN] until AWREADY is asserted");
//     axi4_awvalid_awsize  : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.awvalid, dma_miso_i.awready, dma_mosi_o.awsize))
//                            else $error("Violation AXI4: Once the master has asserted AWVALID, data and control information from master must remain stable [ASIZE] until AWREADY is asserted");
//     axi4_awvalid_awburst : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.awvalid, dma_miso_i.awready, dma_mosi_o.awburst))
//                            else $error("Violation AXI4: Once the master has asserted AWVALID, data and control information from master must remain stable [ABURST] until AWREADY is asserted");

//     axi4_wvalid_wready   : assert property(disable iff (rst) valid_before_handshake  (dma_mosi_o.wvalid, dma_miso_i.wready))
//                            else $error("Violation AXI4: Once WVALID is asserted it must remain asserted until the handshake");
//     axi4_wvalid_wdata    : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.wvalid, dma_miso_i.wready, dma_mosi_o.wdata))
//                            else $error("Violation AXI4: Once the master has asserted WVALID, data and control information from master must remain stable [DATA] until WREADY is asserted");
//     axi4_wvalid_wstrb    : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.wvalid, dma_miso_i.wready, dma_mosi_o.wstrb))
//                            else $error("Violation AXI4: Once the master has asserted WVALID, data and control information from master must remain stable [WSTRB] until WREADY is asserted");
//     axi4_wvalid_wlast    : assert property(disable iff (rst) stable_before_handshake (dma_mosi_o.wvalid, dma_miso_i.wready, dma_mosi_o.wlast))
//                            else $error("Violation AXI4: Once the master has asserted WVALID, data and control information from master must remain stable [WLAST] until WREADY is asserted");

//     axi4_bvalid_bready   : assert property(disable iff (rst) valid_before_handshake  (dma_miso_i.bvalid, dma_mosi_o.bready))
//                            else $error("Violation AXI4: Once BVALID is asserted it must remain asserted until the handshake");
//     axi4_bvalid_bresp    : assert property(disable iff (rst) stable_before_handshake (dma_miso_i.bvalid, dma_mosi_o.bready, dma_miso_i.bresp))
//                            else $error("Violation AXI4: Once the slave has asserted BVALID, data and control information from slave must remain stable [RESP] until BREADY is asserted");

//     axi4_rvalid_rready   : assert property(disable iff (rst) valid_before_handshake  (dma_miso_i.rvalid, dma_mosi_o.rready))
//                            else $error("Violation AXI4: Once RVALID is asserted it must remain asserted until the handshake");
//     axi4_rvalid_rdata    : assert property(disable iff (rst) stable_before_handshake (dma_miso_i.rvalid, dma_mosi_o.rready, dma_miso_i.rdata))
//                            else $error("Violation AXI4: Once the slave has asserted RVALID, data and control information from slave must remain stable [DATA] until RREADY is asserted");
//     axi4_rvalid_rlast    : assert property(disable iff (rst) stable_before_handshake (dma_miso_i.rvalid, dma_mosi_o.rready, dma_miso_i.rlast))
//                            else $error("Violation AXI4: Once the slave has asserted RVALID, data and control information from slave must remain stable [RLAST] until RREADY is asserted");
// `endif
endmodule
