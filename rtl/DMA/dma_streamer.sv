module dma_streamer
  import amba_axi_pkg::*;
  import dma_pkg::*;
#(
  parameter bit STREAMER_TYPE_WR = 0 // 0 - Read, 1 - Write
) (
  input                                     clk,
  input                                     rst,

  // csr control
  input   s_dma_desc_t [`DMA_NUM_DESC-1:0]  dma_csr_desc_i,
  input                                     dma_csr_abort_i,
  input   maxb_t                            dma_csr_maxb_i,

  // fsm control/rsp
  input   s_dma_str_in_t                    dma_fsm_ctrl_i,
  output  s_dma_str_out_t                   dma_fsm_rsp_o,

  // streamer to axi_if req/rsp
  output  s_dma_axi_req_t                   dma_axi_req_o,
  input   s_dma_axi_resp_t                  dma_axi_resp_i
);
  localparam AXI_BUS_BYTES = (`DMA_DATA_WIDTH/8);
  localparam max_txn_width = $clog2(`DMA_MAX_BEAT_BURST*(`DMA_DATA_WIDTH/8));

  dma_sm_t    streamer_state_q,      streamer_state_d;
  axi_addr_t  streamer_req_addr_q,   streamer_req_addr_d;
  desc_num_t  streamer_remain_byte_q,  streamer_remain_byte_d;
  dma_mode_t  streamer_req_mode_q,    streamer_req_mode_d;

  typedef logic [max_txn_width:0] max_bytes_t;

  s_dma_axi_req_t streamer_req_axi_q, streamer_req_axi_d;
  max_bytes_t     streamer_req_byte;

  logic streamer_remain_byte_0_q, streamer_remain_byte_0_d;
  logic streamer_req_is_burst;
  logic [5:0] streamer_req_byte_unalign;
  logic       streamer_abort_resolving;

  function automatic axi_wr_strb_t get_strb(logic [4:0] addr, logic [5:0] bytes);
    axi_wr_strb_t strobe;

    strobe = '0;

    // generate strobe with (bytes) bits valid
    for (int i = 0; i < (`DMA_DATA_WIDTH/8); i++) begin
      if (i < bytes) begin
        strobe[i] = 1'b1;
      end else begin
        strobe[i] = 1'b0;
      end
    end

    // shift strobe to align with the address
    strobe = strobe << addr[$clog2(`DMA_DATA_WIDTH/8)-1:0];

    // if (`DMA_DATA_WIDTH == 64) begin
    //   /* verilator lint_off WIDTH */
    //   case (bytes)
    //     'd1:  strobe = 'b0000_0001;
    //     'd2:  strobe = 'b0000_0011;
    //     'd3:  strobe = 'b0000_0111;
    //     'd4:  strobe = 'b0000_1111;
    //     'd5:  strobe = 'b0001_1111;
    //     'd6:  strobe = 'b0011_1111;
    //     'd7:  strobe = 'b0111_1111;
    //     default:  strobe = '0;
    //   endcase
    //   /* verilator lint_on WIDTH */
    // end
    // else begin
    //   case (bytes)
    //     'd1:  strobe = 'b0001;
    //     'd2:  strobe = 'b0011;
    //     'd3:  strobe = 'b0111;
    //     'd4:  strobe = 'b1111;
    //     default:  strobe = '0;
    //   endcase
    // end

    // if (`DMA_EN_UNALIGNED) begin
    //   for (logic [3:0] i=0; i<8; i++) begin
    //     if (addr == i[2:0]) begin
    //       strobe = strobe << i;
    //     end
    //   end
    // end
    return strobe;
  endfunction

  function automatic logic [5:0] calc_bytes_from_start_addr(axi_addr_t addr);
    if (`DMA_DATA_WIDTH == 32) begin
      return (6'd4 - {4'b00,addr[1:0]});
    end
    else if (`DMA_DATA_WIDTH == 64) begin
      return (6'd8 - {3'b0,addr[2:0]});
    end
    else if (`DMA_DATA_WIDTH == 256) begin
      return (6'd32 - {1'b0,addr[4:0]});
    end
  endfunction

  function automatic axi_addr_t aligned_addr(axi_addr_t addr);
    if (`DMA_DATA_WIDTH == 32) begin
      return {addr[`DMA_ADDR_WIDTH-1:2],2'b00};
    end
    else if (`DMA_DATA_WIDTH == 64) begin
      return {addr[`DMA_ADDR_WIDTH-1:3],3'b000};
    end
    else if (`DMA_DATA_WIDTH == 256) begin
      return {addr[`DMA_ADDR_WIDTH-1:5],5'b000};
    end
  endfunction

  function automatic logic check_fixed_burst_axlen(dma_mode_t mode, logic [8:0] alen_plus_1);
    // for FIXED burst, alen+1 must <= 16
    if (mode == DMA_MODE_FIXED) begin
      return (alen_plus_1 <= 16);
    end
    else begin
      return 1;
    end
  endfunction

  function automatic logic is_aligned(axi_addr_t addr);
    if (`DMA_DATA_WIDTH == 32) begin
      return (addr[1:0] == '0);
    end
    else if (`DMA_DATA_WIDTH == 64) begin
      return (addr[2:0] == '0);
    end
    else if (`DMA_DATA_WIDTH == 256) begin
      return (addr[4:0] == '0);
    end
  endfunction

  function automatic logic enough_for_burst(desc_num_t bytes);
    if (`DMA_DATA_WIDTH == 32) begin
      return (bytes >= 'd4);
    end
    else if (`DMA_DATA_WIDTH == 64) begin
      return (bytes >= 'd8);
    end
    else if (`DMA_DATA_WIDTH == 256) begin
      return (bytes >= 'd32);
    end
  endfunction

  function automatic logic check_burst_in_4K(axi_addr_t base_addr, axi_addr_t end_addr);
    // Overflow Memory Space
    if (end_addr[`DMA_ADDR_WIDTH-1:12] < base_addr[`DMA_ADDR_WIDTH-1:12]) begin
      return 0;
    end
    else if (end_addr[`DMA_ADDR_WIDTH-1:12] > base_addr[`DMA_ADDR_WIDTH-1:12]) begin
      // Base + burst fits exactly 4KB boundary, no problem
      if (end_addr[11:0] == '0) begin
        return 1;
      // Overflow 4K Boundary
      end else begin
        return 0;
      end
    end
    // No leakage
    else begin
        return 1;
    end
  endfunction

  // function automatic axi_alen_t calc_largest_alen(axi_addr_t addr, desc_num_t bytes);
  //   axi_alen_t alen = 0;
  //   axi_addr_t req_end_addr;
  //   desc_num_t req_bytes;

  //   // check every possible alen from max to 1, and select the largest one
  //   for (int i=`DMA_MAX_BEAT_BURST; i>0; i = i-8) begin // i-8: reduce mux size
  //     req_end_addr = addr+(i*AXI_BUS_BYTES);
  //     req_bytes = (i*AXI_BUS_BYTES);

  //     if (
  //         // have enough bytes for this alen
  //         (bytes >= req_bytes) &&
  //         // less or equal than the max burst configured in CSR
  //         ((`DMA_MAX_BURST_EN == 1) ? ((i-'d1) <= dma_csr_maxb_i) : 1'b1) &&
  //         // for FIXED burst, alen+1 must <= 16
  //         ((`DMA_MAX_BEAT_BURST > 16) ? check_fixed_burst_axlen(streamer_req_mode_q, i[8:0]) :
  //                                       1'b1) &&
  //         // doesn't cross 4K boundary
  //         (check_burst_in_4K(addr, req_end_addr))
  //        ) begin
  //         alen = axi_alen_t'(i-1);
  //         return alen;
  //       end
  //   end
  // endfunction

    function automatic axi_alen_t calc_largest_alen(axi_addr_t addr, desc_num_t bytes);
    axi_alen_t alen = 0;
    axi_addr_t req_end_addr;
    desc_num_t req_bytes;

    // check every possible alen from max to 8, and select the largest one
    for (int i=`DMA_MAX_BEAT_BURST; i>8; i = i-8) begin // i-8: reduce mux size
      req_end_addr = addr+(i*AXI_BUS_BYTES);
      req_bytes = (i*AXI_BUS_BYTES);

      if (
          // have enough bytes for this alen
          (bytes >= req_bytes) &&
          // less or equal than the max burst configured in CSR
          ((`DMA_MAX_BURST_EN == 1) ? ((i-'d1) <= dma_csr_maxb_i) : 1'b1) &&
          // for FIXED burst, alen+1 must <= 16
          ((`DMA_MAX_BEAT_BURST > 16) ? check_fixed_burst_axlen(streamer_req_mode_q, i[8:0]) :
                                        1'b1) &&
          // doesn't cross 4K boundary
          (check_burst_in_4K(addr, req_end_addr))
         ) begin
          alen = axi_alen_t'(i-1);
          return alen;
        end
    end

    // check every possible alen from 8 to 1, and select the largest one
    for (int i=8; i>0; i = i-1) begin
      req_end_addr = addr+(i*AXI_BUS_BYTES);
      req_bytes = (i*AXI_BUS_BYTES);

      if (
          // have enough bytes for this alen
          (bytes >= req_bytes) &&
          // less or equal than the max burst configured in CSR
          ((`DMA_MAX_BURST_EN == 1) ? ((i-'d1) <= dma_csr_maxb_i) : 1'b1) &&
          // for FIXED burst, alen+1 must <= 16
          ((`DMA_MAX_BEAT_BURST > 16) ? check_fixed_burst_axlen(streamer_req_mode_q, i[8:0]) :
                                        1'b1) &&
          // doesn't cross 4K boundary
          (check_burst_in_4K(addr, req_end_addr))
         ) begin
          alen = axi_alen_t'(i-1);
          return alen;
        end
    end
  endfunction

  // ------------------------------------------------------------------------------
  // FSM
  // ------------------------------------------------------------------------------
  always_ff @ (posedge clk) begin
    if (rst) begin
      streamer_state_q <= dma_sm_t'('0);
    end
    else begin
      streamer_state_q <= streamer_state_d;
    end
  end

  always_comb begin : streamer_dma_ctrl
    case (streamer_state_q)
      DMA_ST_SM_IDLE: begin
        // start running
        if (dma_fsm_ctrl_i.valid) begin
          streamer_state_d = DMA_ST_SM_RUN;
        end else begin
          streamer_state_d = DMA_ST_SM_IDLE;
        end
      end
      DMA_ST_SM_RUN: begin
        if (dma_csr_abort_i) begin
          // abort resolving
          if (streamer_abort_resolving) begin
            streamer_state_d = DMA_ST_SM_RUN;
          // abort done
          end else begin
            streamer_state_d = DMA_ST_SM_IDLE;
          end
        end
        else begin
          // generate req
          if (streamer_remain_byte_q > 0) begin
            streamer_state_d = DMA_ST_SM_RUN;
          // wait last req done
          end else if (streamer_remain_byte_0_q && ~dma_axi_resp_i.ready) begin
            streamer_state_d = DMA_ST_SM_RUN;
          // req done
          end else begin
            streamer_state_d = DMA_ST_SM_IDLE;
          end
        end
      end
    endcase
  end : streamer_dma_ctrl

  assign dma_fsm_rsp_o.done = (streamer_state_q == DMA_ST_SM_RUN) && (streamer_state_d == DMA_ST_SM_IDLE);

  // ------------------------------------------------------------------------------
  // Generate Req
  // ------------------------------------------------------------------------------
  assign dma_axi_req_o = streamer_req_axi_q;

  always_ff @ (posedge clk) begin
    if (rst) begin
      streamer_req_mode_q       <= dma_mode_t'('0);
      streamer_req_addr_q       <= axi_addr_t'('0);
      streamer_remain_byte_q    <= desc_num_t'('0);
      streamer_remain_byte_0_q  <= '0;
      streamer_req_axi_q        <= '0;
    end
    else begin
      streamer_req_mode_q       <= streamer_req_mode_d;
      streamer_req_addr_q       <= streamer_req_addr_d;
      streamer_remain_byte_q    <= streamer_remain_byte_d;
      streamer_remain_byte_0_q  <= streamer_remain_byte_0_d;
      streamer_req_axi_q        <= streamer_req_axi_d;
    end
  end

  wire streamer_req_axi_d_valid =streamer_req_axi_d.valid;
  always_comb begin : burst_calc
    streamer_req_mode_d       = streamer_req_mode_q;
    streamer_req_axi_d        = streamer_req_axi_q;
    streamer_req_addr_d       = streamer_req_addr_q;
    streamer_remain_byte_d    = streamer_remain_byte_q;
    streamer_remain_byte_0_d  = streamer_remain_byte_0_q;

    streamer_req_byte         = max_bytes_t'('0);
    streamer_abort_resolving  = '0;
    streamer_req_is_burst     = '0;
    streamer_req_byte_unalign = '0;

    // Initialize Stream operation
    if ((streamer_state_q == DMA_ST_SM_IDLE) && (streamer_state_d == DMA_ST_SM_RUN)) begin
      streamer_remain_byte_d = dma_csr_desc_i[dma_fsm_ctrl_i.idx].num_bytes;

      if (STREAMER_TYPE_WR) begin
        // write
        streamer_req_addr_d  = dma_csr_desc_i[dma_fsm_ctrl_i.idx].dst_addr;
        streamer_req_mode_d  = dma_csr_desc_i[dma_fsm_ctrl_i.idx].wr_mode;
      end else begin
        // read
        streamer_req_addr_d  = dma_csr_desc_i[dma_fsm_ctrl_i.idx].src_addr;
        streamer_req_mode_d  = dma_csr_desc_i[dma_fsm_ctrl_i.idx].rd_mode;
      end
    end

    // Burst computation
    if (streamer_state_q == DMA_ST_SM_RUN) begin
      if (~dma_csr_abort_i) begin
        // Send the request when:
        // - Request not sent yet (First request)
        // - Next one
        // - Not the last one
        if ((~streamer_req_axi_q.valid || (streamer_req_axi_q.valid && dma_axi_resp_i.ready)) && ~streamer_remain_byte_0_q) begin
          streamer_req_axi_d.valid = '1;
          streamer_req_axi_d.addr  = aligned_addr(streamer_req_addr_q); // addr: align with AXI bus width
          streamer_req_axi_d.size  = AXI_BYTES_32;                      // size: equal to AXI bus width (256 for now)
          streamer_req_axi_d.mode  = dma_mode_t'(streamer_req_mode_q);

          // 1. best case. req_addr is aligned with AXI bus width, and left bytes > AXI bus width
          if (is_aligned(streamer_req_addr_q) && enough_for_burst(streamer_remain_byte_q)) begin
            // req as much beat-burst as possible, every beat-burst must > AXI bus width
            streamer_req_axi_d.alen = calc_largest_alen(streamer_req_addr_q, streamer_remain_byte_q);
            streamer_req_axi_d.strb = '1;
            streamer_req_is_burst   = '1;
          end else begin
            if (`DMA_EN_UNALIGNED) begin
              // 2. first unaligned req. req_addr is unaligned, and left bytes > AXI bus width
              if (enough_for_burst(streamer_remain_byte_q)) begin
                // only req one-beat-burst
                streamer_req_axi_d.alen   = axi_alen_t'('0);
                // only req bytes starting from unaligned-addr
                streamer_req_byte_unalign = calc_bytes_from_start_addr(streamer_req_addr_q);
                // get strb to mask invalid req bytes
                streamer_req_axi_d.strb   = get_strb(streamer_req_addr_q[4:0], streamer_req_byte_unalign);
              // 3. last req. req_addr is aligned, but left bytes < AXI bus width
              end else if (is_aligned(streamer_req_addr_q)) begin
                // only req one-beat-burst
                streamer_req_axi_d.alen   = axi_alen_t'('0);
                // only req remaining bytes
                streamer_req_byte_unalign = {1'd0, streamer_remain_byte_q[4:0]};
                // get strb to mask invalid req bytes
                streamer_req_axi_d.strb   = get_strb('d0, streamer_req_byte_unalign);
              // 4. small req. req_addr is unaligned, and left bytes < AXI bus width
              end else begin
                // only req one-beat-burst
                streamer_req_axi_d.alen   = axi_alen_t'('0);
                // only req remaining bytes
                streamer_req_byte_unalign = {1'd0, streamer_remain_byte_q[4:0]};
                // get strb to mask invalid req bytes
                streamer_req_axi_d.strb   = get_strb(streamer_req_addr_q[4:0], streamer_req_byte_unalign);
              end
            end else begin
              streamer_req_byte_unalign   = {1'd0, streamer_remain_byte_q[4:0]};
              streamer_req_axi_d.strb     = get_strb('d0, streamer_req_byte_unalign);
            end
          end

          streamer_req_byte         = streamer_req_is_burst ? max_bytes_t'((streamer_req_axi_d.alen+8'd1)*AXI_BUS_BYTES) :
                                                              max_bytes_t'(streamer_req_byte_unalign);
          streamer_remain_byte_d    = streamer_remain_byte_q - desc_num_t'(streamer_req_byte);
          streamer_remain_byte_0_d  = streamer_remain_byte_d == '0;

          if (streamer_req_mode_q == DMA_MODE_FIXED) begin
            // fixed mode: keep same addr
            streamer_req_addr_d = streamer_req_addr_q;
          end else begin
            // incr mode: increase address
            streamer_req_addr_d = streamer_req_addr_q + axi_addr_t'(streamer_req_byte);
          end
        end
        else if (streamer_remain_byte_0_q && dma_axi_resp_i.ready) begin
          streamer_req_axi_d = s_dma_axi_req_t'('0);
          streamer_remain_byte_0_d = 1'b0;
        end
      // dma abort
      end else begin
        // if have valid req, need to wait handshake
        if (streamer_req_axi_q.valid && ~dma_axi_resp_i.ready) begin
          streamer_abort_resolving = 'b1;
        end else begin
          streamer_req_axi_d = s_dma_axi_req_t'('0);
        end
      end
    end
  end : burst_calc

endmodule
