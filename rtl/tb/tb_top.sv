`timescale 1ns/1ps

module tb_top
  import amba_axi_pkg::*;
  import dma_pkg::*;
  import arch_package::*;
;
  localparam int  AXI_ADDR_W               = $bits(axi_addr_t);
  localparam int  AXI_DATA_W               = $bits(axi_data_t);
  localparam int  AXI_STRB_W               = AXI_DATA_W / 8;
  localparam int  AXI_TIMEOUT_CYCLES       = 10000;
  localparam time IRQ_TIMEOUT              = 5_000_000ns;
  localparam real DIFF_CLK_PERIOD_NS       = 5.0;
  localparam real DIFF_CLK_HALF_PERIOD_NS  = DIFF_CLK_PERIOD_NS / 2.0;
  localparam int  BURST_LEN                = 'd191;
  localparam int  EPOCH                    = 20;
  localparam int  TEST_SIZE                = 5;
  localparam bit  ENABLE_DDR_PRELOAD       = 1'b1;

  localparam int  DDR_ADDR_W               = 17;
  localparam int  DQ_WIDTH                 = 64;
  localparam int  DQS_WIDTH                = 8;
  localparam int  DM_WIDTH                 = 8;
  localparam int  DRAM_WIDTH               = 16;
  localparam int  NUM_PHYSICAL_PARTS       = DQ_WIDTH / DRAM_WIDTH;
  localparam bit  RANK_WIDTH               = 1;
  localparam bit  CS_WIDTH                 = 1;
  localparam bit  ODT_WIDTH                = 1;
  localparam string CA_MIRROR              = "OFF";

  localparam logic [2:0] MRS               = 3'b000;
  localparam logic [2:0] REF               = 3'b001;
  localparam logic [2:0] PRE               = 3'b010;
  localparam logic [2:0] ACT               = 3'b011;
  localparam logic [2:0] WR                = 3'b100;
  localparam logic [2:0] RD                = 3'b101;
  localparam logic [2:0] ZQC               = 3'b110;
  localparam logic [2:0] NOP               = 3'b111;

  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR0 = 'h0000_0000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR1 = 'h0000_1000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR2 = 'h0000_2000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR3 = 'h0000_3000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR4 = 'h0000_4000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR5 = 'h0000_5000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR6 = 'h0000_6000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR7 = 'h0000_7000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR8 = 'h0000_8000;
  localparam logic [AXI_ADDR_W-1:0] TEST_ADDR9 = 'h0000_9000;
  localparam logic [AXI_ADDR_W-1:0] ADDR_BIAS  = 'h0000_0400;

    typedef enum logic [2:0] {
    DMA_OFF_RIWI, // Read Mode INCR , Write Mode INCR
    DMA_OFF_RIWF, // Read Mode INCR , Write Mode FIXED
    DMA_OFF_RFWI, // Read Mode FIXED , Write Mode INCR
    DMA_OFF_RFWF, // Read Mode FIXED , Write Mode FIXED
    DMA_ON_RIWI,
    DMA_ON_RIWF,
    DMA_ON_RFWI,
    DMA_ON_RFWF
  } dma_mode_t;

  typedef enum logic [1:0]{
    DMA_OFF   ,
    DMA_ON    ,
    DMA_ABORT ,
    DMA_RESERV
  } dma_ctrl_t;

  parameter UTYPE_density CONFIGURED_DENSITY = _8G;

  int test_len [0:4] = '{256, 512, 1024, 2048, 4096};

  logic clk_p;
  logic clk_n;
  logic rst;
  bit   en_model;
  tri   model_enable = en_model;

  s_axil_mosi_t dma_csr_mosi_i;
  s_axil_miso_t dma_csr_miso_o;

  logic [16:0] c0_ddr4_adr;
  logic [1:0]  c0_ddr4_ba;
  logic [0:0]  c0_ddr4_cke;
  logic [0:0]  c0_ddr4_cs_n;
  tri   [7:0]  c0_ddr4_dm_dbi_n;
  tri   [63:0] c0_ddr4_dq;
  tri   [7:0]  c0_ddr4_dqs_c;
  tri   [7:0]  c0_ddr4_dqs_t;
  logic [0:0]  c0_ddr4_odt;
  logic [0:0]  c0_ddr4_bg;
  logic        c0_ddr4_reset_n;
  logic        c0_ddr4_act_n;
  logic [0:0]  c0_ddr4_ck_c;
  logic [0:0]  c0_ddr4_ck_t;

  logic [DDR_ADDR_W-1:0] c0_ddr4_adr_sdram;
  logic [1:0]            c0_ddr4_ba_sdram;
  logic [0:0]            c0_ddr4_bg_sdram;
  logic [DDR_ADDR_W-1:0] ddr4_addrmod;
  logic [31:0]           cmd_name;
  logic [2:0]            progress;
  logic                  error;
  logic                  preload_warned;
  logic                  check_warned;
  logic                  tb_ddr_axi_owned;

  axi_data_t shadow_mem [longint unsigned];

  logic [3:0]     tb_ddr_awid;
  logic [31:0]    tb_ddr_awaddr;
  logic [7:0]     tb_ddr_awlen;
  logic [2:0]     tb_ddr_awsize;
  logic [1:0]     tb_ddr_awburst;
  logic           tb_ddr_awlock;
  logic [3:0]     tb_ddr_awcache;
  logic [2:0]     tb_ddr_awprot;
  logic [3:0]     tb_ddr_awqos;
  logic           tb_ddr_awvalid;
  logic [255:0]   tb_ddr_wdata;
  logic [31:0]    tb_ddr_wstrb;
  logic           tb_ddr_wlast;
  logic           tb_ddr_wvalid;
  logic           tb_ddr_bready;
  logic [3:0]     tb_ddr_arid;
  logic [31:0]    tb_ddr_araddr;
  logic [7:0]     tb_ddr_arlen;
  logic [2:0]     tb_ddr_arsize;
  logic [1:0]     tb_ddr_arburst;
  logic           tb_ddr_arlock;
  logic [3:0]     tb_ddr_arcache;
  logic [2:0]     tb_ddr_arprot;
  logic [3:0]     tb_ddr_arqos;
  logic           tb_ddr_arvalid;
  logic           tb_ddr_rready;

  wire tb_sys_clk   = dut.sys_clk;
  wire tb_sys_rst_n = dut.sys_resetn;
  wire tb_axi_clk   = dut.c0_ddr4_ui_clk;
  wire tb_axi_rst_n = dut.c0_ddr4_aresetn;

  always #(DIFF_CLK_HALF_PERIOD_NS) clk_p = ~clk_p;
  assign clk_n = ~clk_p;

  acc_top dut (
    .clk_p          (clk_p),
    .clk_n          (clk_n),
    .rst_n          (~rst),
    .dma_csr_mosi_i (dma_csr_mosi_i),
    .dma_csr_miso_o (dma_csr_miso_o),
    .c0_ddr4_adr    (c0_ddr4_adr),
    .c0_ddr4_ba     (c0_ddr4_ba),
    .c0_ddr4_cke    (c0_ddr4_cke),
    .c0_ddr4_cs_n   (c0_ddr4_cs_n),
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),
    .c0_ddr4_dq     (c0_ddr4_dq),
    .c0_ddr4_dqs_c  (c0_ddr4_dqs_c),
    .c0_ddr4_dqs_t  (c0_ddr4_dqs_t),
    .c0_ddr4_odt    (c0_ddr4_odt),
    .c0_ddr4_bg     (c0_ddr4_bg),
    .c0_ddr4_reset_n(c0_ddr4_reset_n),
    .c0_ddr4_act_n  (c0_ddr4_act_n),
    .c0_ddr4_ck_c   (c0_ddr4_ck_c),
    .c0_ddr4_ck_t   (c0_ddr4_ck_t)
  );

  always_comb begin
    c0_ddr4_adr_sdram = c0_ddr4_adr;
    c0_ddr4_ba_sdram  = c0_ddr4_ba;
    c0_ddr4_bg_sdram  = c0_ddr4_bg;
  end

  always_comb begin
    if (c0_ddr4_cs_n == '1) begin
      cmd_name = "DSEL";
    end else if (c0_ddr4_act_n) begin
      casez (c0_ddr4_adr_sdram[16:14]) 
        MRS:     cmd_name = "MRS";
        REF:     cmd_name = "REF";
        PRE:     cmd_name = "PRE";
        WR:      cmd_name = "WR";
        RD:      cmd_name = "RD";
        ZQC:     cmd_name = "ZQC";
        NOP:     cmd_name = "NOP";
        default: cmd_name = "***";
      endcase
    end else begin
      cmd_name = "ACT";
    end
  end

  always_comb begin
    if (c0_ddr4_act_n) begin
      casez (c0_ddr4_adr_sdram[16:14])
        WR, RD: ddr4_addrmod = c0_ddr4_adr_sdram & 18'h1C7FF;
        default: ddr4_addrmod = c0_ddr4_adr_sdram;
      endcase
    end else begin
      ddr4_addrmod = c0_ddr4_adr_sdram;
    end
  end

  generate
    genvar part;
    genvar dq_idx;
    DDR4_if #(.CONFIGURED_DQ_BITS(16)) iDDR4[0:NUM_PHYSICAL_PARTS-1]();

    for (part = 0; part < NUM_PHYSICAL_PARTS; part++) begin : gen_ddr4_model
      ddr4_model #(
        .CONFIGURED_DQ_BITS(16),
        .CONFIGURED_DENSITY(CONFIGURED_DENSITY)
      ) u_ddr4_model (
        .model_enable(model_enable),
        .iDDR4       (iDDR4[part])
      );

      for (dq_idx = 0; dq_idx < 16; dq_idx++) begin : gen_dq
        `ifdef XILINX_SIMULATOR
        short bidi_dq(iDDR4[part].DQ[dq_idx], c0_ddr4_dq[dq_idx + part * 16]);
        `else
        tran bidi_dq(iDDR4[part].DQ[dq_idx], c0_ddr4_dq[dq_idx + part * 16]);
        `endif
      end

      `ifdef XILINX_SIMULATOR
      short bidi_dqs_t0(iDDR4[part].DQS_t[0], c0_ddr4_dqs_t[part * 2]);
      short bidi_dqs_c0(iDDR4[part].DQS_c[0], c0_ddr4_dqs_c[part * 2]);
      short bidi_dm0   (iDDR4[part].DM_n[0],  c0_ddr4_dm_dbi_n[part * 2]);
      short bidi_dqs_t1(iDDR4[part].DQS_t[1], c0_ddr4_dqs_t[part * 2 + 1]);
      short bidi_dqs_c1(iDDR4[part].DQS_c[1], c0_ddr4_dqs_c[part * 2 + 1]);
      short bidi_dm1   (iDDR4[part].DM_n[1],  c0_ddr4_dm_dbi_n[part * 2 + 1]);
      `else
      tran bidi_dqs_t0(iDDR4[part].DQS_t[0], c0_ddr4_dqs_t[part * 2]);
      tran bidi_dqs_c0(iDDR4[part].DQS_c[0], c0_ddr4_dqs_c[part * 2]);
      tran bidi_dm0   (iDDR4[part].DM_n[0],  c0_ddr4_dm_dbi_n[part * 2]);
      tran bidi_dqs_t1(iDDR4[part].DQS_t[1], c0_ddr4_dqs_t[part * 2 + 1]);
      tran bidi_dqs_c1(iDDR4[part].DQS_c[1], c0_ddr4_dqs_c[part * 2 + 1]);
      tran bidi_dm1   (iDDR4[part].DM_n[1],  c0_ddr4_dm_dbi_n[part * 2 + 1]);
      `endif

      assign iDDR4[part].CK         = {c0_ddr4_ck_t[0], c0_ddr4_ck_c[0]};
      assign iDDR4[part].ACT_n      = c0_ddr4_act_n;
      assign iDDR4[part].RAS_n_A16  = ddr4_addrmod[16];
      assign iDDR4[part].CAS_n_A15  = ddr4_addrmod[15];
      assign iDDR4[part].WE_n_A14   = ddr4_addrmod[14];
      assign iDDR4[part].CKE        = c0_ddr4_cke[0];
      assign iDDR4[part].ODT        = c0_ddr4_odt[0];
      assign iDDR4[part].BG         = c0_ddr4_bg_sdram;
      assign iDDR4[part].BA         = c0_ddr4_ba_sdram;
      assign iDDR4[part].ADDR_17    = 1'b0;
      assign iDDR4[part].ADDR       = ddr4_addrmod[13:0];
      assign iDDR4[part].CS_n       = c0_ddr4_cs_n[0];
      assign iDDR4[part].RESET_n    = c0_ddr4_reset_n;
      assign iDDR4[part].PARITY     = 1'b0;
      assign iDDR4[part].TEN        = 1'b0;
      assign iDDR4[part].ZQ         = 1'b1;
      assign iDDR4[part].PWR        = 1'b1;
      assign iDDR4[part].VREF_CA    = 1'b1;
      assign iDDR4[part].VREF_DQ    = 1'b1;
    end
  endgenerate

  function automatic int unsigned word_index(input logic [AXI_ADDR_W-1:0] addr);
    return int'(addr / AXI_STRB_W);
  endfunction

  function automatic int calc_beats(input int num_bytes);
    return (num_bytes + AXI_STRB_W - 1) / AXI_STRB_W;
  endfunction

  function automatic axi_data_t shadow_get(input longint unsigned idx);
    if (shadow_mem.exists(idx)) begin
      return shadow_mem[idx];
    end
    return '0;
  endfunction

  task automatic ddr_axi_master_idle;
    begin
      tb_ddr_awid    = '0;
      tb_ddr_awaddr  = '0;
      tb_ddr_awlen   = '0;
      tb_ddr_awsize  = AXI_BYTES_32;
      tb_ddr_awburst = AXI_INCR;
      tb_ddr_awlock  = 1'b0;
      tb_ddr_awcache = 4'b0011;
      tb_ddr_awprot  = axi_prot_t'(3'b000);
      tb_ddr_awqos   = '0;
      tb_ddr_awvalid = 1'b0;
      tb_ddr_wdata   = '0;
      tb_ddr_wstrb   = '0;
      tb_ddr_wlast   = 1'b0;
      tb_ddr_wvalid  = 1'b0;
      tb_ddr_bready  = 1'b0;
      tb_ddr_arid    = '0;
      tb_ddr_araddr  = '0;
      tb_ddr_arlen   = '0;
      tb_ddr_arsize  = AXI_BYTES_32;
      tb_ddr_arburst = AXI_INCR;
      tb_ddr_arlock  = 1'b0;
      tb_ddr_arcache = 4'b0011;
      tb_ddr_arprot  = axi_prot_t'(3'b000);
      tb_ddr_arqos   = '0;
      tb_ddr_arvalid = 1'b0;
      tb_ddr_rready  = 1'b0;
    end
  endtask

  task automatic ddr_axi_takeover;
    begin
      if (!ENABLE_DDR_PRELOAD) begin
        if (!preload_warned) begin
          $display("[TB] DDR preload via MIG AXI takeover disabled");
          preload_warned = 1'b1;
        end
        return;
      end

      if (tb_ddr_axi_owned) begin
        return;
      end

      wait (tb_axi_rst_n === 1'b1);
      ddr_axi_master_idle();

      force dut.c0_ddr4_s_axi_awid    = tb_ddr_awid;
      force dut.c0_ddr4_s_axi_awaddr  = tb_ddr_awaddr;
      force dut.c0_ddr4_s_axi_awlen   = tb_ddr_awlen;
      force dut.c0_ddr4_s_axi_awsize  = tb_ddr_awsize;
      force dut.c0_ddr4_s_axi_awburst = tb_ddr_awburst;
      force dut.c0_ddr4_s_axi_awlock  = tb_ddr_awlock;
      force dut.c0_ddr4_s_axi_awcache = tb_ddr_awcache;
      force dut.c0_ddr4_s_axi_awprot  = tb_ddr_awprot;
      force dut.c0_ddr4_s_axi_awqos   = tb_ddr_awqos;
      force dut.c0_ddr4_s_axi_awvalid = tb_ddr_awvalid;
      force dut.c0_ddr4_s_axi_wdata   = tb_ddr_wdata;
      force dut.c0_ddr4_s_axi_wstrb   = tb_ddr_wstrb;
      force dut.c0_ddr4_s_axi_wlast   = tb_ddr_wlast;
      force dut.c0_ddr4_s_axi_wvalid  = tb_ddr_wvalid;
      force dut.c0_ddr4_s_axi_bready  = tb_ddr_bready;
      force dut.c0_ddr4_s_axi_arid    = tb_ddr_arid;
      force dut.c0_ddr4_s_axi_araddr  = tb_ddr_araddr;
      force dut.c0_ddr4_s_axi_arlen   = tb_ddr_arlen;
      force dut.c0_ddr4_s_axi_arsize  = tb_ddr_arsize;
      force dut.c0_ddr4_s_axi_arburst = tb_ddr_arburst;
      force dut.c0_ddr4_s_axi_arlock  = tb_ddr_arlock;
      force dut.c0_ddr4_s_axi_arcache = tb_ddr_arcache;
      force dut.c0_ddr4_s_axi_arprot  = tb_ddr_arprot;
      force dut.c0_ddr4_s_axi_arqos   = tb_ddr_arqos;
      force dut.c0_ddr4_s_axi_arvalid = tb_ddr_arvalid;
      force dut.c0_ddr4_s_axi_rready  = tb_ddr_rready;

      tb_ddr_axi_owned = 1'b1;
      @(posedge tb_axi_clk);
    end
  endtask

  task automatic ddr_axi_release;
    begin
      if (!tb_ddr_axi_owned) begin
        return;
      end

      ddr_axi_master_idle();
      @(posedge tb_axi_clk);
      release dut.c0_ddr4_s_axi_awid;
      release dut.c0_ddr4_s_axi_awaddr;
      release dut.c0_ddr4_s_axi_awlen;
      release dut.c0_ddr4_s_axi_awsize;
      release dut.c0_ddr4_s_axi_awburst;
      release dut.c0_ddr4_s_axi_awlock;
      release dut.c0_ddr4_s_axi_awcache;
      release dut.c0_ddr4_s_axi_awprot;
      release dut.c0_ddr4_s_axi_awqos;
      release dut.c0_ddr4_s_axi_awvalid;
      release dut.c0_ddr4_s_axi_wdata;
      release dut.c0_ddr4_s_axi_wstrb;
      release dut.c0_ddr4_s_axi_wlast;
      release dut.c0_ddr4_s_axi_wvalid;
      release dut.c0_ddr4_s_axi_bready;
      release dut.c0_ddr4_s_axi_arid;
      release dut.c0_ddr4_s_axi_araddr;
      release dut.c0_ddr4_s_axi_arlen;
      release dut.c0_ddr4_s_axi_arsize;
      release dut.c0_ddr4_s_axi_arburst;
      release dut.c0_ddr4_s_axi_arlock;
      release dut.c0_ddr4_s_axi_arcache;
      release dut.c0_ddr4_s_axi_arprot;
      release dut.c0_ddr4_s_axi_arqos;
      release dut.c0_ddr4_s_axi_arvalid;
      release dut.c0_ddr4_s_axi_rready;
      tb_ddr_axi_owned = 1'b0;
    end
  endtask

  task ddr_axi_write_word(
    input logic [AXI_ADDR_W-1:0] addr,
    input axi_data_t             data
  );
    bit local_acquire;
    bit aw_done;
    bit w_done;
    int timeout;
    begin
      local_acquire = !tb_ddr_axi_owned;
      ddr_axi_takeover();

      tb_ddr_awid    = '0;
      tb_ddr_awaddr  = addr;
      tb_ddr_awlen   = '0;
      tb_ddr_awsize  = AXI_BYTES_32;
      tb_ddr_awburst = AXI_INCR;
      tb_ddr_awlock  = 1'b0;
      tb_ddr_awcache = 4'b0011;
      tb_ddr_awprot  = axi_prot_t'(3'b000);
      tb_ddr_awqos   = '0;
      tb_ddr_awvalid = 1'b1;
      tb_ddr_wdata   = data;
      tb_ddr_wstrb   = '1;
      tb_ddr_wlast   = 1'b1;
      tb_ddr_wvalid  = 1'b1;
      tb_ddr_bready  = 1'b0;

      aw_done = 1'b0;
      w_done  = 1'b0;
      timeout = 0;
      while (!(aw_done && w_done)) begin
        @(posedge tb_axi_clk);
        if (!aw_done && dut.c0_ddr4_s_axi_awready) begin
          tb_ddr_awvalid = 1'b0;
          aw_done = 1'b1;
        end
        if (!w_done && dut.c0_ddr4_s_axi_wready) begin
          tb_ddr_wvalid = 1'b0;
          tb_ddr_wlast  = 1'b0;
          w_done = 1'b1;
        end
        timeout++;
        if (timeout > AXI_TIMEOUT_CYCLES) begin
          $error("DDR AXI write address/data handshake timeout @%h", addr);
          $finish;
        end
      end

      tb_ddr_bready = 1'b1;
      timeout = 0;
      while (!dut.c0_ddr4_s_axi_bvalid) begin
        @(posedge tb_axi_clk);
        timeout++;
        if (timeout > AXI_TIMEOUT_CYCLES) begin
          $error("DDR AXI write response timeout @%h", addr);
          $finish;
        end
      end

      if (dut.c0_ddr4_s_axi_bresp inside {AXI_SLVERR, AXI_DECERR}) begin
        $error("DDR AXI write response error @%h: %0d", addr, dut.c0_ddr4_s_axi_bresp);
        $finish;
      end

      @(posedge tb_axi_clk);
      tb_ddr_bready = 1'b0;
      shadow_mem[word_index(addr)] = data;
      if (local_acquire) begin
        ddr_axi_release();
      end
    end
  endtask

  task ddr_axi_read_word(
    input  logic [AXI_ADDR_W-1:0] addr,
    output axi_data_t             data
  );
    bit local_acquire;
    int timeout;
    begin
      local_acquire = !tb_ddr_axi_owned;
      ddr_axi_takeover();

      tb_ddr_arid    = '0;
      tb_ddr_araddr  = addr;
      tb_ddr_arlen   = '0;
      tb_ddr_arsize  = AXI_BYTES_32;
      tb_ddr_arburst = AXI_INCR;
      tb_ddr_arlock  = 1'b0;
      tb_ddr_arcache = 4'b0011;
      tb_ddr_arprot  = axi_prot_t'(3'b000);
      tb_ddr_arqos   = '0;
      tb_ddr_arvalid = 1'b1;
      tb_ddr_rready  = 1'b0;

      timeout = 0;
      while (!dut.c0_ddr4_s_axi_arready) begin
        @(posedge tb_axi_clk);
        timeout++;
        if (timeout > AXI_TIMEOUT_CYCLES) begin
          $error("DDR AXI read address handshake timeout @%h", addr);
          $finish;
        end
      end

      @(posedge tb_axi_clk);
      tb_ddr_arvalid = 1'b0;
      tb_ddr_rready  = 1'b1;

      timeout = 0;
      while (!dut.c0_ddr4_s_axi_rvalid) begin
        @(posedge tb_axi_clk);
        timeout++;
        if (timeout > AXI_TIMEOUT_CYCLES) begin
          $error("DDR AXI read data timeout @%h", addr);
          $finish;
        end
      end

      data = dut.c0_ddr4_s_axi_rdata;
      if (dut.c0_ddr4_s_axi_rresp inside {AXI_SLVERR, AXI_DECERR}) begin
        $error("DDR AXI read response error @%h: %0d", addr, dut.c0_ddr4_s_axi_rresp);
        $finish;
      end

      @(posedge tb_axi_clk);
      tb_ddr_rready = 1'b0;
      if (local_acquire) begin
        ddr_axi_release();
      end
    end
  endtask

  task automatic preload_region(
    input logic [AXI_ADDR_W-1:0] base_addr,
    input int                    num_bytes
  );
    int       beats;
    axi_data_t word_data;
    begin
      beats = calc_beats(num_bytes);
      ddr_axi_takeover();
      for (int i = 0; i < beats; i++) begin
        word_data = axi_data_t'(i);
        ddr_axi_write_word(base_addr + i * AXI_STRB_W, word_data);
      end
      ddr_axi_release();
    end
  endtask

  task automatic clear_region(
    input logic [AXI_ADDR_W-1:0] base_addr,
    input int                    num_bytes
  );
    int beats;
    begin
      beats = calc_beats(num_bytes);
      ddr_axi_takeover();
      for (int i = 0; i < beats; i++) begin
        ddr_axi_write_word(base_addr + i * AXI_STRB_W, '0);
      end
      ddr_axi_release();
    end
  endtask

  task automatic run_test(input string test_name);
    $display("Starting test: %s", test_name);
    case (test_name)
      "test_dma_csrs":        test_dma_csrs();
      "test_dma_single_desc": test_dma_single_desc();
      "test_dma_full_desc":   test_dma_full_desc();
      "test_dma_error":       test_dma_error();
      "test_dma_abort":       test_dma_abort();
      "test_dma_modes":       test_dma_modes();
      "test_dma_trans_byte":  test_dma_trans_byte();
      default: $error("Unknown test case");
    endcase
    $display("\n[PASS] Test %s completed\n", test_name);
  endtask

  initial begin
    clk_p = 1'b0;
    rst = 1'b1;
    en_model = 1'b0;
    preload_warned = 1'b0;
    check_warned = 1'b0;
    tb_ddr_axi_owned = 1'b0;
    dma_csr_mosi_i = '0;
    dma_csr_mosi_i.wstrb = '1;
    ddr_axi_master_idle();

    #200;
    en_model = 1'b1;
    #200;
    rst = 1'b0;

    wait (dut.c0_init_calib_complete === 1'b1);
    wait (tb_axi_rst_n === 1'b1);
    wait (tb_sys_rst_n === 1'b1);
    repeat (16) @(posedge tb_sys_clk);

    progress = 0;
    run_test("test_dma_csrs");
    progress = 1;
    run_test("test_dma_single_desc");
    progress = 2;
    run_test("test_dma_full_desc");
    progress = 3;
    run_test("test_dma_modes");
    progress = 4;
    // run_test("test_dma_abort");
    // run_test("test_dma_error");

    $display("=====================");
    $display("         PASS        ");
    $display("=====================");
    $finish;
  end

  task automatic axi_lite_write(input logic [31:0] addr, input logic [31:0] data);
    begin
      dma_csr_mosi_i.awid    = '0;
      dma_csr_mosi_i.awaddr  = addr;
      dma_csr_mosi_i.awprot  = axi_prot_t'(3'b000);
      dma_csr_mosi_i.awvalid = 1'b1;
      wait (dma_csr_miso_o.awready);

      dma_csr_mosi_i.wdata   = '0;
      dma_csr_mosi_i.wdata[31:0] = data;
      dma_csr_mosi_i.wstrb   = '1;
      dma_csr_mosi_i.wvalid  = 1'b1;
      wait (dma_csr_miso_o.wready);
      @(posedge tb_sys_clk);

      dma_csr_mosi_i.awvalid = 1'b0;
      dma_csr_mosi_i.wvalid  = 1'b0;
      wait (dma_csr_miso_o.bvalid);
      dma_csr_mosi_i.bready = 1'b1;
      @(posedge tb_sys_clk);
      dma_csr_mosi_i.bready = 1'b0;
    end
  endtask

  task automatic axi_lite_read(input logic [31:0] addr, output logic [31:0] data);
    begin
      dma_csr_mosi_i.arid    = '0;
      dma_csr_mosi_i.araddr  = addr;
      dma_csr_mosi_i.arprot  = axi_prot_t'(3'b000);
      dma_csr_mosi_i.arvalid = 1'b1;
      wait (dma_csr_miso_o.arready);
      @(posedge tb_sys_clk);
      dma_csr_mosi_i.arvalid = 1'b0;

      dma_csr_mosi_i.rready = 1'b1;
      wait (dma_csr_miso_o.rvalid);
      data = dma_csr_miso_o.rdata[31:0];
      @(posedge tb_sys_clk);
      dma_csr_mosi_i.rready = 1'b0;
    end
  endtask

  task automatic config_dma_desc(
    input int                  desc_idx,
    input logic [31:0]         src_addr,
    input logic [31:0]         dst_addr,
    input int                  num_bytes,
    input dma_mode_t           mode
  );
    logic [31:0] desc_base;
    begin
      desc_base = 32'h0 + desc_idx * 8;
      axi_lite_write(desc_base + 32'h20, src_addr);
      axi_lite_write(desc_base + 32'h30, dst_addr);
      axi_lite_write(desc_base + 32'h40, num_bytes);
      axi_lite_write(desc_base + 32'h50, mode);
    end
  endtask

  task automatic config_dma_ctrl(
    input dma_ctrl_t dma_ctrl,
    input logic [7:0] axi_burst
  );
    logic [9:0] ctrl_word;
    begin
      ctrl_word[0]   = (dma_ctrl == DMA_ON);
      ctrl_word[1]   = (dma_ctrl == DMA_ABORT);
      ctrl_word[9:2] = axi_burst - 'h1;
      axi_lite_write(32'h0000, {22'h0, ctrl_word});
    end
  endtask

  task automatic test_dma_csrs;
    typedef struct {
      logic [31:0] addr_offset;
      logic [31:0] data;
    } test_vector_t;

    automatic test_vector_t test_vectors[] = '{
      test_vector_t'{addr_offset:32'h20, data:32'h1234},
      test_vector_t'{addr_offset:32'h30, data:32'hcdef},
      test_vector_t'{addr_offset:32'h40, data:32'haaaa},
      test_vector_t'{addr_offset:32'h50, data:DMA_OFF_RFWF}
    };

    logic [31:0] csr_rdata;
    int error_count;
    begin
      error_count = 0;
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        foreach (test_vectors[i]) begin
          axi_lite_write(32'h0 + test_vectors[i].addr_offset, test_vectors[i].data);
          axi_lite_read(32'h0 + test_vectors[i].addr_offset, csr_rdata);
          if (csr_rdata !== test_vectors[i].data) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch=%0d",
                   test_vectors[i].addr_offset, test_vectors[i].data, csr_rdata, epoch);
          end

          axi_lite_write(32'h8 + test_vectors[i].addr_offset, test_vectors[i].data);
          axi_lite_read(32'h8 + test_vectors[i].addr_offset, csr_rdata);
          if (csr_rdata !== test_vectors[i].data) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch=%0d",
                   test_vectors[i].addr_offset + 32'h8, test_vectors[i].data, csr_rdata, epoch);
          end

          axi_lite_write(32'h0000, 32'h00fc);
          axi_lite_read(32'h0000, csr_rdata);
          if (csr_rdata !== 32'h00fc) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch=%0d",
                   32'h0000, 32'h00fc, csr_rdata, epoch);
          end
        end
      end
      if (error_count) begin
        $finish;
      end
    end
  endtask

  task automatic test_dma_single_desc;
    begin
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        preload_region(TEST_ADDR0, test_len[epoch % TEST_SIZE]);

        config_dma_desc(0, TEST_ADDR0, TEST_ADDR1, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_ON, BURST_LEN);

        wait_for_irq(error);
        if (error) begin
          $error("[Test Fail] test_dma_single_desc fail, epoch=%0d", epoch + 1);
          $finish;
        end

        check_data(TEST_ADDR0, TEST_ADDR1, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_OFF, BURST_LEN);
        clear_region(TEST_ADDR1, test_len[epoch % TEST_SIZE]);
      end
    end
  endtask

  task automatic test_dma_trans_byte;
    int byte_num;
    begin
      for (byte_num = 32'd92; ; byte_num += AXI_DATA_W) begin
        preload_region(TEST_ADDR0, byte_num);

        config_dma_desc(0, TEST_ADDR0, TEST_ADDR1, byte_num, DMA_ON_RIWI);
        config_dma_ctrl(DMA_ON, BURST_LEN);

        wait_for_irq(error);
        if (error) begin
          $display("[Test End] max transfer data = %0d B", byte_num);
          $finish;
        end

        check_data(TEST_ADDR0, TEST_ADDR1, byte_num, DMA_ON_RIWI);
        config_dma_ctrl(DMA_OFF, BURST_LEN);
        clear_region(TEST_ADDR1, byte_num);
        $display("[Test Running] transfer data = %0d B", byte_num);
      end
    end
  endtask

  task automatic test_dma_full_desc;
    begin
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        preload_region(TEST_ADDR2, test_len[epoch % TEST_SIZE] * 4);

        config_dma_desc(0, TEST_ADDR2, TEST_ADDR3, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_desc(1, TEST_ADDR2 + ADDR_BIAS, TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_ON, BURST_LEN);

        wait_for_irq(error);
        if (error) begin
          $error("[Test Fail] test_dma_full_desc fail, epoch=%0d", epoch + 1);
          $finish;
        end

        check_data(TEST_ADDR2, TEST_ADDR3, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        check_data(TEST_ADDR2 + ADDR_BIAS, TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_desc(1, TEST_ADDR2 + ADDR_BIAS, TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_OFF_RIWI);
        config_dma_ctrl(DMA_OFF, BURST_LEN);
        clear_region(TEST_ADDR3, test_len[epoch % TEST_SIZE] * 4);
      end
    end
  endtask

  task automatic test_dma_abort;
    int error_count;
    axi_data_t src_word;
    axi_data_t dst_word;
    begin
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        error_count = 0;
        preload_region(TEST_ADDR4, test_len[epoch % TEST_SIZE] * 4);

        config_dma_desc(0, TEST_ADDR4, TEST_ADDR5, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_ON, BURST_LEN);
        #($urandom_range(30, 80));
        config_dma_ctrl(DMA_ABORT, BURST_LEN);

        ddr_axi_takeover();
        for (int i = 0; i < calc_beats(test_len[epoch % TEST_SIZE]); i++) begin
          ddr_axi_read_word(TEST_ADDR4 + i * AXI_STRB_W, src_word);
          ddr_axi_read_word(TEST_ADDR5 + i * AXI_STRB_W, dst_word);
          if (dst_word !== src_word) begin
            error_count++;
          end
        end
        ddr_axi_release();

        config_dma_ctrl(DMA_OFF, BURST_LEN);
        if (error_count == 0) begin
          $display("[Test Fail] test_dma_abort fail, epoch=%0d", epoch + 1);
          $finish;
        end
        clear_region(TEST_ADDR5, test_len[epoch % TEST_SIZE] * 4);
      end
    end
  endtask

  task automatic test_dma_modes;
    dma_mode_t mode;
    begin
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        preload_region(TEST_ADDR8, test_len[epoch % TEST_SIZE]);

        mode = (epoch % 4 == 0) ? DMA_ON_RIWI :
               (epoch % 4 == 1) ? DMA_ON_RFWI :
               (epoch % 4 == 2) ? DMA_ON_RIWF :
                                  DMA_ON_RFWF;

        config_dma_desc(0, TEST_ADDR8, TEST_ADDR9, test_len[epoch % TEST_SIZE], mode);
        config_dma_ctrl(DMA_ON, BURST_LEN);

        wait_for_irq(error);
        if (error) begin
          $error("[Test Fail] dma_test_modes fail, epoch=%0d", epoch + 1);
          $finish;
        end

        check_data(TEST_ADDR8, TEST_ADDR9, test_len[epoch % TEST_SIZE], mode);
        config_dma_ctrl(DMA_OFF, BURST_LEN);
        clear_region(TEST_ADDR9, test_len[epoch % TEST_SIZE]);
      end
    end
  endtask

  task automatic test_dma_error;
    logic [1:0] error_type;
    begin
      for (int epoch = 0; epoch < EPOCH; epoch++) begin
        error_type = $urandom % 2;
        preload_region(TEST_ADDR6, test_len[epoch % TEST_SIZE] * 4);

        config_dma_desc(0, TEST_ADDR6, TEST_ADDR7, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_ON, BURST_LEN);

        if (error_type == 0) begin
          #($urandom_range(80, 120));
          force dut.c0_ddr4_s_axi_rresp = AXI_SLVERR;
        end else begin
          @(posedge dut.c0_ddr4_s_axi_rlast);
          #($urandom_range(0, 20));
          force dut.c0_ddr4_s_axi_bresp = AXI_SLVERR;
        end

        wait_for_irq(error);
        if (error) begin
          check_error_status();
        end else begin
          $error("[Test Fail] test_dma_error fail, epoch=%0d, error type=%0d", epoch + 1, error_type);
          $finish;
        end

        release dut.c0_ddr4_s_axi_rresp;
        release dut.c0_ddr4_s_axi_bresp;
        config_dma_ctrl(DMA_OFF, BURST_LEN);
        clear_region(TEST_ADDR7, test_len[epoch % TEST_SIZE] * 4);
      end
    end
  endtask

  task automatic wait_for_irq(output logic err);
    begin
      fork
        begin : timeout
          #(IRQ_TIMEOUT);
          $error("IRQ timeout!");
          err = 1'b1;
          disable irq_mon;
        end
        begin : irq_mon
          wait (dut.dma_done_o || dut.dma_error_o);
          err = dut.dma_error_o;
          disable timeout;
        end
      join
    end
  endtask

  task automatic check_data(
    input logic [31:0] src,
    input logic [31:0] dst,
    input int          len,
    input dma_mode_t   mode
  );
    int        beats;
    axi_data_t actual_word;
    axi_data_t expected_word;
    begin
      if (!ENABLE_DDR_PRELOAD) begin
        if (!check_warned) begin
          $display("[TB] Skip DDR data check because preload/readback path is disabled");
          check_warned = 1'b1;
        end
        return;
      end

      beats = calc_beats(len);
      ddr_axi_takeover();

      if (mode == DMA_ON_RIWI) begin
        for (int i = 0; i < beats; i++) begin
          expected_word = shadow_get(word_index(src) + i);
          ddr_axi_read_word(dst + i * AXI_STRB_W, actual_word);
          if (actual_word !== expected_word) begin
            $error("Data mismatch @%h: Exp=%h, Act=%h",
                   dst + i * AXI_STRB_W, expected_word, actual_word);
            $finish;
          end
        end
      end else if (mode == DMA_ON_RFWI) begin
        expected_word = shadow_get(word_index(src));
        for (int i = 0; i < beats; i++) begin
          ddr_axi_read_word(dst + i * AXI_STRB_W, actual_word);
          if (actual_word !== expected_word) begin
            $error("Data mismatch @%h: Exp=%h, Act=%h",
                   dst + i * AXI_STRB_W, expected_word, actual_word);
            $finish;
          end
        end
      end else if (mode == DMA_ON_RIWF) begin
        expected_word = shadow_get(word_index(src) + beats - 1);
        ddr_axi_read_word(dst, actual_word);
        if (actual_word !== expected_word) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", dst, expected_word, actual_word);
          $finish;
        end
      end else if (mode == DMA_ON_RFWF) begin
        expected_word = shadow_get(word_index(src));
        ddr_axi_read_word(dst, actual_word);
        if (actual_word !== expected_word) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", dst, expected_word, actual_word);
          $finish;
        end
      end else begin
        $error("Unknown mode!");
        $finish;
      end

      ddr_axi_release();
    end
  endtask

  task automatic check_error_status;
    logic [31:0] error_addr;
    logic [31:0] error_stats;
    begin
      axi_lite_read(32'h10, error_addr);
      axi_lite_read(32'h18, error_stats);
      $display("error address:%h , error status:%b", error_addr, error_stats[2:0]);
    end
  endtask

  assert property (@(posedge dut.dma_error_o)
    ##1 (dut.u_dma_axi_wrapper.dma_stats.error && dut.u_dma_axi_wrapper.dma_error.addr != 0)
  ) else $error("Error IRQ without status update!");

endmodule

`ifdef XILINX_SIMULATOR
module short(in1, in1);
inout in1;
endmodule
`endif
