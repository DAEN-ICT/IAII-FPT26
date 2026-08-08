set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir .. .. ..]]
set output_dir [file normalize \
  [file join $root_dir vivado output clock_buffer_ooc_235MHz_core_300MHz_dma]]
file mkdir $output_dir

create_project -in_memory -part xczu19eg-ffvc1760-2-i
read_verilog [file join $root_dir rtl DDR gqav7_pl_diff_clock_buffer.v]
synth_design -top gqav7_pl_diff_clock_buffer -part xczu19eg-ffvc1760-2-i

set mmcm_cells [get_cells -hierarchical -quiet -filter {REF_NAME == MMCME4_ADV}]
if {[llength $mmcm_cells] != 2} {
  error "Expected two synthesized MMCME4_ADV cells, found [llength $mmcm_cells]"
}
set core_clock_net [get_nets -quiet -of_objects \
    [get_pins -quiet u_mmcm_core_235m/CLKOUT0]]
set dma_clock_net [get_nets -quiet -of_objects \
    [get_pins -quiet u_mmcm_dma_300m/CLKOUT0]]
if {[llength $core_clock_net] != 1 || [llength $dma_clock_net] != 1} {
  error "Could not resolve both MMCM output nets"
}
if {$core_clock_net eq $dma_clock_net} {
  error "Core and DMA unexpectedly share one MMCM output net"
}

report_utilization -file [file join $output_dir utilization.rpt]
write_checkpoint -force [file join $output_dir synthesized.dcp]
puts "PASS: 235 MHz core and 300 MHz DMA use independent MMCM output nets"
exit
