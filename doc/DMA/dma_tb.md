# DMA TEST

### 基本介绍

基于sv编写的DMA测试平台，进行基本的功能测试，其基本特性有：

- 通过AXI LITE总线配置DMA CSR，通过 AXI FULL与内存交互
- 包含一个AXI接口的内存模型，支持突发传输中的INCR/FIX传输模式
- 可配置的测试轮数、测试内存地址以及传输字节数、AXI突发传输数量

目前包含如下测试函数：

|          名称          |                    基本功能                     |                             说明                             |
| :--------------------: | :---------------------------------------------: | :----------------------------------------------------------: |
|    test_dma_csrs()     |    对DMA两个描述符的CSR进行基本的读、写测试     |       错误、状态相关寄存器仅支持读，因而未进行读写测试       |
| test_dma_single_desc() |       对DMA的单个描述符进行基本的传输测试       |         测试流程：配置DMA描述符->传输数据->校验数据          |
|  test_dma_full_desc()  | 对DMA的所有描述符进行基本的传输测试，此处为两个 |         测试流程：配置DMA描述符->传输数据->校验数据          |
|    test_dma_abort()    |             对DMA的传输中断进行测试             | 测试流程：配置DMA描述符->中断传输->校验是否传输完毕->关闭传输。此测验与后一测验(可自行搭配)联合检验传输中断后的重新传输是否正常 |
|    test_dma_modes()    |              测试DMA传输的各个模式              |              分别包含读、写地址的自增、固定模式              |
|    test_dma_error()    |                DMA的错误注入检验                |      测试DMA在AXI传输发生错误时是否能捕获错误并触发中断      |
| test_dma_trans_byte()  |              测试DMA最大传输数据量              |                                                              |

### 已知问题

测试中存在的问题：

- 当传输被连续中断大于两次时，后一次传输会出现异常。表现为DMA进对内存进行读操作而不发起写操作，DMA不会捕捉这一错误。同时DMA不支持传输中断后继续上一次传输，否则传输错误，即在传输被中断后只能进行新的传输。

### TODO

- 目前DMA错误注入仅支持传输数据错误注入，不支持DMA CSR配置时错误注入。

### 修正

- DMA在测试时出现先前的字节数配置小于AXI突发传输字节数、AXI BURST与传输字节数不对齐的错误是由于dma_streamer中关于alen长度计算有误导致的。

  ```systemverilog
    function automatic axi_alen_t calc_largest_alen(axi_addr_t addr, desc_num_t bytes);
      axi_alen_t alen = 0;
      axi_addr_t req_end_addr;
      desc_num_t req_bytes;
  
      // check every possible alen from max to 1, and select the largest one
      for (int i=`DMA_MAX_BEAT_BURST; i>0; i = i-8) begin // i-8: reduce mux size
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
  ```

  当需要传输的字节数满足以下条件，会导致alen没有被正确赋值，从而出现不定态，导致错误：

  1. 需要传输的字节数大于AXI_BUS_BYTES，即至少需要进行一次长度为2(alen为1)的突发传输。
  2. 经过若干次BURST传输后剩余的传输字节数小于8*AXI_BUS_BYTES。

  经过修订，在alen - 1 < 8后使得alen下降的步长减小为1，即可保证所有的剩余字节数都能找到一个适合的alen(若原本的传输字节数小于AXI_BUS_BYTES则不会触发突发传输)，同时也避免了过多的多路选择器消耗。

  现在DMA可以进行任意的传输字节数以及突发传输长度的配置了。

- 经过修订，DMA可以传输理论上限的数据，即4GB的数据。此前触发错误是由于过长的传输时间(实际在100MHZ下完成4GB的数据传输需要花费约1400ms)错误触发了超时检查。在修改了超时检查后DMA可以完成指定的数据传输。
