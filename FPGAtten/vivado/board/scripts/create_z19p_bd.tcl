set script_dir [file normalize [file dirname [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
set preset_file [file join $project_root vivado board presets z19p_ps_factory_preset.tcl]

proc latest_ipdef {pattern} {
  set matches [lsort -dictionary [get_ipdefs -all -quiet $pattern]]
  if {[llength $matches] == 0} {
    error "Vivado IP is unavailable: $pattern"
  }
  return [lindex $matches end]
}

proc require_one {objects description} {
  if {[llength $objects] != 1} {
    error "Expected one $description, found [llength $objects]: $objects"
  }
  return [lindex $objects 0]
}

if {[info exists ::env(GQAV7_Z19P_SELF_CHECK)]} {
  if {![file isfile $preset_file]} {
    error "Missing Z19-P PS preset: $preset_file"
  }
  source $preset_file
  set properties [z19p_ps_factory_properties]
  if {[llength $properties] < 100} {
    error "Z19-P PS preset is unexpectedly incomplete"
  }
  puts "PASS: Z19-P BD Tcl preset resolves locally"
  return
}

if {[llength [get_projects -quiet]] == 0} {
  error "create_z19p_bd.tcl requires an open project"
}
if {![file isfile $preset_file]} {
  error "Missing Z19-P PS preset: $preset_file"
}
source $preset_file

set design_name gqav7_z19p_system
if {[llength [get_bd_designs -quiet $design_name]] != 0} {
  error "Block design already exists in the fresh project: $design_name"
}
create_bd_design $design_name
current_bd_design $design_name

set ps [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:zynq_ultra_ps_e:*] zynq_ultra_ps_e_0]
apply_z19_ps_preset $ps
if {![info exists ::z19_ps_preset_verified] || !$::z19_ps_preset_verified} {
  error "Z19-P PS preset did not mark itself verified"
}
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {1} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__IRQ0 {1}] $ps

set clk_buf [create_bd_cell -type module \
  -reference gqav7_pl_diff_clock_buffer pl_clock_buffer]
set reset_ctl [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:proc_sys_reset:*] reset_core_235m]
set dma_reset_ctl [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:proc_sys_reset:*] reset_dma_300m]
set clock_ready [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:xlconstant:*] clock_ready]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $clock_ready

set control_smc [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:smartconnect:*] control_smartconnect]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] \
  $control_smc
set data_smc [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:smartconnect:*] data_smartconnect]
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] \
  $data_smc
set data_reset_gate [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:util_vector_logic:*] data_reset_gate]
set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] $data_reset_gate
set irq_concat [create_bd_cell -type ip \
  -vlnv [latest_ipdef xilinx.com:ip:xlconcat:*] accelerator_irq_concat]
set_property CONFIG.NUM_PORTS {1} $irq_concat

set gqa [create_bd_cell -type module \
  -reference gqav5_vivado_ip_top gqav7_accelerator_0]
set ddr [create_bd_cell -type module \
  -reference gqav5_pl_ddr4_axi_wrapper pl_ddr4_0]
set rebase [create_bd_cell -type module \
  -reference gqav5_ps_pl_ddr_axi_rebase ps_pl_ddr_rebase_0]
set_property CONFIG.CPU_WINDOW_BASE {0x00B0000000} $rebase

set pl_clk [create_bd_intf_port -mode Slave \
  -vlnv xilinx.com:interface:diff_clock_rtl:1.0 PL_CLK0]
set_property CONFIG.FREQ_HZ {200000000} $pl_clk
connect_bd_intf_net $pl_clk [get_bd_intf_pins $clk_buf/CLK_IN]

connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] \
  [get_bd_intf_pins $control_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $control_smc/M00_AXI] \
  [get_bd_intf_pins $gqa/S_AXI_CONTROL]
connect_bd_intf_net [get_bd_intf_pins $gqa/M_AXI_MEMORY] \
  [get_bd_intf_pins $data_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $gqa/M_AXI_MEMORY_V] \
  [get_bd_intf_pins $data_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM1_FPD] \
  [get_bd_intf_pins $rebase/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $rebase/M_AXI] \
  [get_bd_intf_pins $data_smc/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins $data_smc/M00_AXI] \
  [get_bd_intf_pins $ddr/S_AXI_MEMORY]

foreach pin [list \
  $ps/maxihpm0_fpd_aclk $control_smc/aclk $gqa/aclk] {
  connect_bd_net [get_bd_pins $clk_buf/clk_fabric_o] [get_bd_pins $pin]
}
foreach pin [list \
  $ps/maxihpm1_fpd_aclk $data_smc/aclk $gqa/dma_aclk \
  $ddr/aclk $rebase/aclk] {
  connect_bd_net [get_bd_pins $clk_buf/clk_dma_o] [get_bd_pins $pin]
}
connect_bd_net [get_bd_pins $clk_buf/clk_fabric_o] \
  [get_bd_pins $reset_ctl/slowest_sync_clk]
connect_bd_net [get_bd_pins $clk_buf/clk_dma_o] \
  [get_bd_pins $dma_reset_ctl/slowest_sync_clk]
connect_bd_net [get_bd_pins $clk_buf/clk_200_o] [get_bd_pins $ddr/sys_clk_i]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $reset_ctl/ext_reset_in]
connect_bd_net [get_bd_pins $ps/pl_resetn0] \
  [get_bd_pins $dma_reset_ctl/ext_reset_in]
connect_bd_net [get_bd_pins $clk_buf/clock_locked_o] \
  [get_bd_pins $reset_ctl/dcm_locked]
connect_bd_net [get_bd_pins $clk_buf/clock_locked_o] \
  [get_bd_pins $dma_reset_ctl/dcm_locked]

connect_bd_net [get_bd_pins $reset_ctl/peripheral_aresetn] \
  [get_bd_pins $control_smc/aresetn]
connect_bd_net [get_bd_pins $reset_ctl/peripheral_aresetn] [get_bd_pins $gqa/aresetn]
connect_bd_net [get_bd_pins $dma_reset_ctl/peripheral_aresetn] \
  [get_bd_pins $gqa/dma_aresetn]
connect_bd_net [get_bd_pins $dma_reset_ctl/peripheral_aresetn] \
  [get_bd_pins $ddr/aresetn]
connect_bd_net [get_bd_pins $dma_reset_ctl/peripheral_aresetn] \
  [get_bd_pins $rebase/aresetn]
connect_bd_net [get_bd_pins $dma_reset_ctl/peripheral_aresetn] \
  [get_bd_pins $data_reset_gate/Op1]
connect_bd_net [get_bd_pins $ddr/ddr_ready_o] [get_bd_pins $data_reset_gate/Op2]
connect_bd_net [get_bd_pins $data_reset_gate/Res] [get_bd_pins $data_smc/aresetn]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $ddr/rst_n]
connect_bd_net [get_bd_pins $clock_ready/dout] [get_bd_pins $ddr/clk_locked]

connect_bd_net [get_bd_pins $gqa/irq] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $ps/pl_ps_irq0]

foreach interface_name {DDR FIXED_IO} {
  set interface_pin [get_bd_intf_pins -quiet $ps/$interface_name]
  if {[llength $interface_pin] == 1} {
    set interface_port [make_bd_intf_pins_external $interface_pin]
    set_property name $interface_name $interface_port
  }
}

foreach pin_name {
  c0_ddr4_adr c0_ddr4_ba c0_ddr4_cke c0_ddr4_cs_n
  c0_ddr4_dm_dbi_n c0_ddr4_dq c0_ddr4_dqs_c c0_ddr4_dqs_t
  c0_ddr4_odt c0_ddr4_bg c0_ddr4_reset_n c0_ddr4_act_n
  c0_ddr4_ck_c c0_ddr4_ck_t
} {
  set physical_pin [require_one [get_bd_pins -quiet $ddr/$pin_name] \
    "PL DDR4 physical pin $pin_name"]
  make_bd_pins_external $physical_pin
  set physical_net [require_one [get_bd_nets -quiet -of_objects $physical_pin] \
    "PL DDR4 physical net $pin_name"]
  set external_port [require_one [get_bd_ports -quiet -of_objects $physical_net] \
    "PL DDR4 external port $pin_name"]
  set_property name $pin_name $external_port
}

set ps_space [require_one [get_bd_addr_spaces -quiet $ps/Data] "PS data address space"]
set gqa_csr_seg [require_one [get_bd_addr_segs -quiet $gqa/S_AXI_CONTROL/*] \
  "GQAv7 CSR segment"]
set ddr_seg [require_one [get_bd_addr_segs -quiet $ddr/S_AXI_MEMORY/*] \
  "PL DDR segment"]
set gqa_space [require_one [get_bd_addr_spaces -quiet $gqa/M_AXI_MEMORY] \
  "GQAv7 memory address space"]
set gqa_v_space [require_one [get_bd_addr_spaces -quiet $gqa/M_AXI_MEMORY_V] \
  "GQAv7 V memory address space"]
set rebase_slave_seg [require_one [get_bd_addr_segs -quiet $rebase/S_AXI/*] \
  "PS PL-DDR rebase slave segment"]
set rebase_space [require_one [get_bd_addr_spaces -quiet $rebase/M_AXI] \
  "PS PL-DDR rebase address space"]

create_bd_addr_seg -range 4K -offset 0xA0010000 \
  $ps_space $gqa_csr_seg SEG_GQAV7_CSR
create_bd_addr_seg -range 256M -offset 0xB0000000 \
  $ps_space $rebase_slave_seg SEG_PS_PL_DDR_WINDOW
create_bd_addr_seg -range 256M -offset 0x00000000 \
  $rebase_space $ddr_seg SEG_PS_REBASE_PL_DDR
create_bd_addr_seg -range 2G -offset 0x00000000 \
  $gqa_space $ddr_seg SEG_GQAV7_PL_DDR
create_bd_addr_seg -range 2G -offset 0x00000000 \
  $gqa_v_space $ddr_seg SEG_GQAV7_V_PL_DDR

assign_bd_address -quiet
validate_bd_design
save_bd_design

set design_file [require_one [get_files -quiet */${design_name}.bd] \
  "$design_name block design file"]
generate_target all $design_file
# Fresh projects do not have the block-design OOC runs until they are
# explicitly created.  The release build resets the accelerator module-
# reference run to guarantee that the bitstream contains the current RTL.
create_ip_run $design_file
set wrapper_file [make_wrapper -files $design_file -top]
add_files -fileset sources_1 -norecurse $wrapper_file
set_property top ${design_name}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "PASS: created GQAv7 Z19-P PS/PL-DDR block design"
puts "GQAv7 CSR: 0xA0010000/4K"
puts "PS PL-DDR: 0xB0000000/256M; GQAv7 PL-DDR: 0x00000000/2G"
