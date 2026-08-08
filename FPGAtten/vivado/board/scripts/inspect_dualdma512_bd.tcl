if {[llength $argv] != 1} {
  error "usage: inspect_dualdma512_bd.tcl <GQAv7_z19p.xpr>"
}

open_project [file normalize [lindex $argv 0]]
set bd_file [lindex [get_files -quiet */gqav7_z19p_system.bd] 0]
if {$bd_file eq ""} {
  error "gqav7_z19p_system.bd is missing"
}
open_bd_design $bd_file

proc print_intf_width {path expected} {
  set pin [get_bd_intf_pins -quiet $path]
  if {[llength $pin] != 1} {
    error "missing interface pin $path"
  }
  set width [get_property CONFIG.DATA_WIDTH $pin]
  puts "WIDTH $path=$width"
  if {$width ne $expected} {
    error "$path DATA_WIDTH expected $expected, got $width"
  }
}

print_intf_width gqav7_accelerator_0/M_AXI_MEMORY 256
print_intf_width gqav7_accelerator_0/M_AXI_MEMORY_V 256
print_intf_width data_smartconnect/S00_AXI 256
print_intf_width data_smartconnect/S01_AXI 256
print_intf_width data_smartconnect/M00_AXI 512
print_intf_width pl_ddr4_0/S_AXI_MEMORY 512

set mig [get_ips -quiet ddr4_controller]
set converter [get_ips -quiet ddr_clock_converter]
if {[llength $mig] != 1 || [llength $converter] != 1} {
  error "expected one MIG and one DDR clock converter"
}
set mig_width [get_property CONFIG.C0.DDR4_AxiDataWidth $mig]
set converter_width [get_property CONFIG.DATA_WIDTH $converter]
puts "WIDTH ddr4_controller=$mig_width"
puts "WIDTH ddr_clock_converter=$converter_width"
if {$mig_width ne "512" || $converter_width ne "512"} {
  error "DDR IP width mismatch: MIG=$mig_width converter=$converter_width"
}

validate_bd_design
puts "PASS: dual 256-bit accelerator lanes aggregate into a 512-bit DDR AXI path"
close_project
