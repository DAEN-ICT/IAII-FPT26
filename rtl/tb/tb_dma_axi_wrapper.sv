module tb_dma_axi_wrapper
  import amba_axi_pkg::*;
  import dma_pkg::*;
;
  localparam int AXI_ADDR_W                     = $bits(axi_addr_t);
  localparam int AXI_DATA_W                     = $bits(axi_data_t);
  localparam int AXI_STRB_W                     = AXI_DATA_W / 8;
  localparam BURST_LEN                        = 'd191;
  localparam EPOCH                            = 20;
  localparam TEST_SIZE                        = 5;
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
  // note : if number of byte to transfer is less than brust lenth, error occurs
  int test_len [0:4] = '{256, 512, 1024, 2048, 4096};
  // signal definitions
  logic clk;
  logic rst;
  always #5 clk = ~clk;  // 100MHz
  // AXI-Lite
  s_axil_mosi_t dma_csr_mosi_i;
  s_axil_miso_t dma_csr_miso_o;
  // AXI
  s_axi_mosi_t dma_m_mosi_o;
  s_axi_miso_t dma_m_miso_i;
  // iqr
  logic dma_done_o;
  logic dma_error_o;
  logic mem_bvalid;

  logic error;
  logic [2:0]  progress;

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

  dma_axi_wrapper #(
    .DMA_ID_VAL(0)
  ) dut (
    .clk(clk),
    .rst(rst),
    .dma_csr_mosi_i(dma_csr_mosi_i),
    .dma_csr_miso_o(dma_csr_miso_o),
    .dma_m_mosi_o(dma_m_mosi_o),
    .dma_m_miso_i(dma_m_miso_i),
    .dma_done_o(dma_done_o),
    .dma_error_o(dma_error_o)
  );

  axi_mem_model #(
      // .MEM_SIZE(2**20),     // 8MB memory，actually multiply 2**3
      .MEM_SIZE(2**29),     // 4GB memory
      .AXI_DATA_W(AXI_DATA_W),     // 32-bit data bus
      .AXI_ADDR_W(AXI_ADDR_W)      // 32-bit address
    ) mem_inst (
       .clk(clk)
      ,.resetn(~rst)
      // AXI4 Write Address Channel
      ,.awid            (dma_m_mosi_o.awid        )
      ,.awaddr          (dma_m_mosi_o.awaddr      )
      ,.awlen           (dma_m_mosi_o.awlen       )
      ,.awsize          (dma_m_mosi_o.awsize      )
      ,.awburst         (dma_m_mosi_o.awburst     )
      ,.awvalid         (dma_m_mosi_o.awvalid     )
      ,.awready         (dma_m_miso_i.awready     )
      // AXI4 Write Data Channel
      ,.wdata           (dma_m_mosi_o.wdata       )
      ,.wstrb           (dma_m_mosi_o.wstrb       )
      ,.wlast           (dma_m_mosi_o.wlast       )
      ,.wvalid          (dma_m_mosi_o.wvalid      )
      ,.wready          (dma_m_miso_i.wready      )
      // AXI4 Write Response Channel
      ,.bid             (dma_m_miso_i.bid         )
      ,.bresp           (dma_m_miso_i.bresp       )
      // ,.bvalid          (dma_m_miso_i.bvalid      )
      ,.bvalid          (mem_bvalid      )
      ,.bready          (dma_m_mosi_o.bready      )
      // AXI4 Read Address Channel
      ,.arid            (dma_m_mosi_o.arid        )
      ,.araddr          (dma_m_mosi_o.araddr      )
      ,.arlen           (dma_m_mosi_o.arlen       )
      ,.arsize          (dma_m_mosi_o.arsize      )
      ,.arburst         (dma_m_mosi_o.arburst     )
      ,.arvalid         (dma_m_mosi_o.arvalid     )
      ,.arready         (dma_m_miso_i.arready     )
      // AXI4 Read Data Channel
      ,.rid             (dma_m_miso_i.rid         )
      ,.rdata           (dma_m_miso_i.rdata       )
      ,.rresp           (dma_m_miso_i.rresp       )
      ,.rlast           (dma_m_miso_i.rlast       )
      ,.rvalid          (dma_m_miso_i.rvalid      )
      ,.rready          (dma_m_mosi_o.rready      )
    );
    assign dma_m_miso_i.bvalid = mem_bvalid;

  task automatic run_test(input string test_name);
    $display("Starting test: %s", test_name);
    case(test_name)
      "test_dma_csrs":test_dma_csrs();
      "test_dma_single_desc": test_dma_single_desc();
      "test_dma_full_desc": test_dma_full_desc();
      "test_dma_error": test_dma_error();
      "test_dma_abort": test_dma_abort();
      "test_dma_modes": test_dma_modes();
      "test_dma_trans_byte": test_dma_trans_byte();
      default: $error("Unknown test case");
    endcase
    $display("\n[PASS] Test %s completed\n", test_name);
  endtask

  initial begin
    clk = 0;
    rst = 1;
    dma_csr_mosi_i = '0;
    #20 
    rst = 0;  
    progress = 0;
//    run_test("test_dma_trans_byte");
     run_test("test_dma_csrs");
    progress = 1;
    run_test("test_dma_single_desc");  
    progress = 2;
    run_test("test_dma_full_desc");  
    progress = 3;
//    run_test("test_dma_abort");  
    progress = 4;
//    run_test("test_dma_modes");  
    progress = 5;
    run_test("test_dma_error");  

    $display("====================="); 
    $display("         PASS        "); 
    $display("====================="); 
    $finish;
  end

  task automatic axi_lite_write(input logic [31:0] addr, input logic [31:0] data);
    dma_csr_mosi_i.awaddr = addr;
    dma_csr_mosi_i.awvalid = 1;
    wait(dma_csr_miso_o.awready);
    dma_csr_mosi_i.wdata = data;
    dma_csr_mosi_i.wvalid = 1;
    wait(dma_csr_miso_o.wready);
    @(posedge clk);
    dma_csr_mosi_i.awvalid = 0;
    dma_csr_mosi_i.wvalid = 0;
    wait(dma_csr_miso_o.bvalid);
    dma_csr_mosi_i.bready = 1;
    @(posedge clk);
    dma_csr_mosi_i.bready = 0;
  endtask

  task automatic axi_lite_read(input logic [31:0] addr, output logic [31:0] data);
    dma_csr_mosi_i.araddr  = addr;         
    dma_csr_mosi_i.arvalid = 1'b1;        
    wait(dma_csr_miso_o.arready);     
    @(posedge clk);                       
    dma_csr_mosi_i.arvalid = 1'b0; 
    dma_csr_mosi_i.rready = 1'b1;      
    wait(dma_csr_miso_o.rvalid);     
    data = dma_csr_miso_o.rdata;
    @(posedge clk);
    dma_csr_mosi_i.rready = 1'b0; 
  endtask

  task automatic config_dma_desc(
    input int desc_idx,
    input logic [31:0] src_addr,
    input logic [31:0] dst_addr,
    input int num_bytes,
    input dma_mode_t mode
  );
    
    logic [31:0] desc_base = 32'h0 + desc_idx * 8;
    axi_lite_write(desc_base + 32'h20, src_addr);  
    axi_lite_write(desc_base + 32'h30, dst_addr);   
    axi_lite_write(desc_base + 32'h40, num_bytes);   
    axi_lite_write(desc_base + 32'h50, mode);
  endtask

task automatic config_dma_ctrl(
    input dma_ctrl_t dma_ctrl, 
    input logic [7:0] axi_burst
);
    logic [9:0] ctrl_word; 

    ctrl_word[0]   = (dma_ctrl == DMA_ON)    ? 1'b1 : 1'b0;
    ctrl_word[1]   = (dma_ctrl == DMA_ABORT) ? 1'b1 : 1'b0;
    ctrl_word[9:2] = axi_burst - 'h1;
  
    axi_lite_write(32'h0000, {22'h0, ctrl_word}); 
endtask
    
//-------------------------------------------------------------
// test task group
//-------------------------------------------------------------
  task test_dma_csrs();
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
    automatic int error_count = 0;
    for(int epoch = 0; epoch < EPOCH; epoch++) begin
      foreach (test_vectors[i]) begin
        //desc1
        axi_lite_write(32'h0 + test_vectors[i].addr_offset, test_vectors[i].data);
        axi_lite_read(32'h0 + test_vectors[i].addr_offset, csr_rdata);
        if (csr_rdata !== test_vectors[i].data) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch =%d", 
                    test_vectors[i].addr_offset, 
                    test_vectors[i].data, 
                    csr_rdata,epoch);
        end
        #10;
        //desc2
        axi_lite_write(32'h8 + test_vectors[i].addr_offset, test_vectors[i].data);
        axi_lite_read(32'h8 + test_vectors[i].addr_offset, csr_rdata);
        if (csr_rdata !== test_vectors[i].data) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch =%d", 
                    test_vectors[i].addr_offset + 32'h8, 
                    test_vectors[i].data, 
                    csr_rdata,epoch);
        end
        #10;
        //control register
        axi_lite_write(32'h0000, 32'h00fc);
        axi_lite_read(32'h0000, csr_rdata);
        if (csr_rdata !== 32'h00fc) begin
            error_count++;
            $error("[Test Fail] Addr=0x%0h: Expected=0x%0h, Actual=0x%0h, Epoch =%d", 
                    32'h0000, 32'h00fc, csr_rdata,epoch);
        end
      end
      if(error_count)$finish();
      else error_count = 0;
    end
  endtask

  task test_dma_single_desc();
    for(int epoch = 0; epoch < EPOCH; epoch++) begin
      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W; i++)
        mem_inst.mem[TEST_ADDR0/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};

      config_dma_desc(0, TEST_ADDR0, TEST_ADDR1, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      config_dma_ctrl(DMA_ON,BURST_LEN);

      wait_for_irq(error);
      if (error) begin
        $error("[Test Fail] test_dma_single_desc fail, epoch = %d",epoch + 1);
        $finish();
      end else begin
        check_data(TEST_ADDR0, TEST_ADDR1, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_ctrl(DMA_OFF,BURST_LEN);
      end
      // reset memory
      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W; i++)
        mem_inst.mem[TEST_ADDR1/AXI_STRB_W + i] = 'b0;
    end
  endtask

  task test_dma_trans_byte();
    int byte_num;
    for(byte_num = 32'd92; ;byte_num += AXI_DATA_W) begin
    // for(byte_num = 32'd92; ;byte_num += 1) begin // minimum step size test
      for (int i=0; i<byte_num/AXI_STRB_W; i++)
        mem_inst.mem[TEST_ADDR0/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};

      config_dma_desc(0, TEST_ADDR0, TEST_ADDR1, byte_num, DMA_ON_RIWI);
      config_dma_ctrl(DMA_ON,BURST_LEN);

      wait_for_irq(error);
      if (error) begin
        $display("[Test End] max transfer data = %d B",byte_num);
        $finish();
      end else begin
        check_data(TEST_ADDR0, TEST_ADDR1, byte_num, DMA_ON_RIWI);
        config_dma_ctrl(DMA_OFF,BURST_LEN);
      end
      // reset memory
      for (int i=0; i<byte_num/AXI_STRB_W; i++)
        mem_inst.mem[TEST_ADDR1/AXI_STRB_W + i] = 'b0;

      //  $display("[Test Running] transfer data = %d KB",byte_num / 1024);
       $display("[Test Running] transfer data = %d B",byte_num);
    end
  endtask

  task test_dma_full_desc();
    for(int epoch = 0; epoch < EPOCH; epoch++) begin
       for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W*4; i++)
         mem_inst.mem[TEST_ADDR2/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};

      config_dma_desc(0, TEST_ADDR2, TEST_ADDR3, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      config_dma_desc(1, TEST_ADDR2 + ADDR_BIAS, TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      config_dma_ctrl(DMA_ON,BURST_LEN);
      
      wait_for_irq(error);  // channel 0 done
      if (error) begin
        $error("[Test Fail] test_dma_full_desc fail, epoch = %d",epoch + 1);
        $finish();
      end else begin
        check_data(TEST_ADDR2, TEST_ADDR3, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        check_data(TEST_ADDR2 + ADDR_BIAS,TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
        config_dma_desc(1, TEST_ADDR2 + ADDR_BIAS, TEST_ADDR3 + ADDR_BIAS, test_len[epoch % TEST_SIZE], DMA_OFF_RIWI);
        config_dma_ctrl(DMA_OFF,BURST_LEN);
      end

      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W*4; i++)
         mem_inst.mem[TEST_ADDR3/AXI_STRB_W + i] = 'b0;
    end
  endtask

  task test_dma_abort();
   automatic int error_count = 0;
   for(int epoch = 0; epoch < EPOCH; epoch++) begin
      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W*4; i++)
        mem_inst.mem[TEST_ADDR4/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};

      config_dma_desc(0, TEST_ADDR4, TEST_ADDR5, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      config_dma_ctrl(DMA_ON,BURST_LEN);
      #($urandom_range(30,80))
      config_dma_ctrl(DMA_ABORT,BURST_LEN);
      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W; i++) begin
        if (mem_inst.mem[TEST_ADDR5/AXI_STRB_W+i] !== mem_inst.mem[TEST_ADDR4/AXI_STRB_W+i]) begin
          $display("Data mismatch @%h: Exp=%h, Act=%h, epoch=%d", 
                TEST_ADDR5+i*AXI_STRB_W, mem_inst.mem[TEST_ADDR4/AXI_STRB_W+i], 
                mem_inst.mem[TEST_ADDR5/AXI_STRB_W+i],epoch + 1);
          error_count ++;
        end
      end
      // -----------------restart dma-----------------
      // axi_lite_write(32'h0000, 32'h3fd); //10'b11_1111_1101,max brust length 256,go on dma
      // wait_for_irq(error);
      // if (error) begin
      //   $error("[Test Fail] test_dma_abort fail, epoch = %d",epoch + 1);
      //   $finish();
      // end else begin
      //   check_data(TEST_ADDR4, TEST_ADDR5, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      // end
      // ---------------------------------------------
      config_dma_ctrl(DMA_OFF,BURST_LEN);
      if(error_count == 0)begin
        $display("[Test Fail] test_dma_abort fail, epoch=%d",epoch + 1);
        $finish();
      end

      for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W*4; i++)
        mem_inst.mem[TEST_ADDR5/AXI_STRB_W + i] = 'b0;
      error_count = 0;
   end
  endtask

    task test_dma_modes();
      dma_mode_t mode;
      for(int epoch = 0; epoch < EPOCH; epoch++) begin
        for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W; i++)
          mem_inst.mem[TEST_ADDR8/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};

        mode = (epoch % 4 == 0) ? DMA_ON_RIWI :
               (epoch % 4 == 1) ? DMA_ON_RFWI :
               (epoch % 4 == 2) ? DMA_ON_RIWF :
               (epoch % 4 == 3) ? DMA_ON_RFWF : DMA_ON_RIWI;
        config_dma_desc(0, TEST_ADDR8, TEST_ADDR9, test_len[epoch % TEST_SIZE], mode);
        config_dma_ctrl(DMA_ON,BURST_LEN);

        wait_for_irq(error);
        if (error) begin
          $error("[Test Fail] dma_test_modes fail,epoch=%d",epoch + 1);
          $finish();
        end else begin
          check_data(TEST_ADDR8, TEST_ADDR9, test_len[epoch % TEST_SIZE], mode);
          config_dma_ctrl(DMA_OFF,BURST_LEN);
        end

        for (int i=0; i<test_len[epoch % TEST_SIZE]/AXI_STRB_W; i++)
          mem_inst.mem[TEST_ADDR9/AXI_STRB_W + i] = 'b0;
      end
  endtask

  task automatic test_dma_error();
    for(int epoch = 0; epoch < EPOCH; epoch++) begin
      logic [1:0]  error_type = $urandom % 2;     // 0:read error 1:write error

      for (int i=0; i<test_len[epoch % TEST_SIZE] /AXI_STRB_W*4; i++)
          mem_inst.mem[TEST_ADDR6/AXI_STRB_W + i] = i % {AXI_DATA_W{1'b1}};
          
      config_dma_desc(0, TEST_ADDR6, TEST_ADDR7, test_len[epoch % TEST_SIZE], DMA_ON_RIWI);
      config_dma_ctrl(DMA_ON,BURST_LEN);
  
      if (error_type == 0) begin
        #($urandom_range(80,120));
        force dma_m_miso_i.rresp = AXI_SLVERR;
      end else begin
        @(posedge dma_m_miso_i.rlast);   
        #($urandom_range(0,20));
        force dma_m_miso_i.bresp = AXI_SLVERR;
      end

      wait_for_irq(error);   

      if (error) begin
          check_error_status(); 
      end else begin
          $error("[Test Fail] test_dma_error fail, epoch=%d, error type=%d",epoch + 1,error_type);
          $finish();
      end

      release dma_m_miso_i.rresp;
      release dma_m_miso_i.bresp;
      config_dma_ctrl(DMA_OFF,BURST_LEN);

      for (int i=0; i<test_len[epoch % TEST_SIZE] /AXI_STRB_W*4; i++)
          mem_inst.mem[TEST_ADDR7/AXI_STRB_W + i] = 'b0;
    end
  endtask

  task wait_for_irq(output logic err);
    fork
      begin : timeout
        #1000000 $error("IRQ timeout!");
        // #1000000000 $error("IRQ timeout!");
          err = 1'b1;
        disable irq_mon;
      end
      begin : irq_mon
        wait (dma_done_o || dma_error_o);
        err = dma_error_o;
        disable timeout;
      end
    join
  endtask

  task check_data(input logic [31:0] src, dst, input int len, input dma_mode_t mode);
    if(mode == DMA_ON_RIWI) begin
      for (int i=0; i<len/AXI_STRB_W; i++) begin
        if (mem_inst.mem[dst/AXI_STRB_W+i] !== mem_inst.mem[src/AXI_STRB_W+i]) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", 
                dst+i*AXI_STRB_W, mem_inst.mem[src/AXI_STRB_W+i], mem_inst.mem[dst/AXI_STRB_W+i]);
          $finish();
        end
      end
    end else if(mode == DMA_ON_RFWI) begin
      for (int i=0; i<len/AXI_STRB_W; i++) begin
        if (mem_inst.mem[dst/AXI_STRB_W+i] !== mem_inst.mem[src/AXI_STRB_W]) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", 
                dst+i*AXI_STRB_W, mem_inst.mem[src/AXI_STRB_W], mem_inst.mem[dst/AXI_STRB_W+i]);
          $finish();
        end
      end
    end else if(mode == DMA_ON_RIWF) begin // only the last src data is checked
        if (mem_inst.mem[dst/AXI_STRB_W] !== mem_inst.mem[src/AXI_STRB_W+len/AXI_STRB_W-1]) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", 
                dst, mem_inst.mem[src/AXI_STRB_W+len/AXI_STRB_W-1], mem_inst.mem[dst/AXI_STRB_W]);
          $finish();
        end
    end else if(mode == DMA_ON_RFWF)begin
        if (mem_inst.mem[dst/AXI_STRB_W] !== mem_inst.mem[src/AXI_STRB_W]) begin
          $error("Data mismatch @%h: Exp=%h, Act=%h", 
                dst, mem_inst.mem[src/AXI_STRB_W], mem_inst.mem[dst/AXI_STRB_W]);
          $finish();
        end
    end else begin
      $error("Unknown mode!");
      $finish();
    end
    
  endtask

  task check_error_status();
    logic [31:0] error_addr;
    logic [31:0] error_stats;
    axi_lite_read(32'h10,error_addr);
    axi_lite_read(32'h18,error_stats);
    $display("error address:%h , error status: %b",error_addr,error_stats[2:0]);
  endtask

  // 规则：错误中断需更新CSR
  assert property (@(posedge dma_error_o) 
    ##1 (dut.dma_stats.error && dut.dma_error.addr != 0)
  ) else $error("Error IRQ without status update!");
  // supported by Synopsys Verdi
  // initial begin
  //     $fsdbDumpfile("wave.fsdb");
  //     $fsdbDumpvars(0, tb_dma_axi_wrapper);
  //     $fsdbDumpMDA();
  // end
endmodule
