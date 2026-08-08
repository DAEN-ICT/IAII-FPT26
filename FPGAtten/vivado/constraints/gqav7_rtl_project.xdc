create_clock -name core_clk -period 4.255319 [get_ports aclk]
create_clock -name dma_clk -period 3.333333 [get_ports dma_aclk]
set_clock_uncertainty 0.200 [get_clocks core_clk]
set_clock_uncertainty 0.200 [get_clocks dma_clk]
set_clock_groups -asynchronous -group [get_clocks core_clk] \
  -group [get_clocks dma_clk]
set_false_path -from [get_ports aresetn]
