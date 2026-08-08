# Verify that the competition host has the exact Vivado release, device and
# catalog IP needed to rebuild FPGAtten.  This script does not create a project.

if {[version -short] ne "2025.2"} {
  error "FPGAtten requires Vivado 2025.2, running [version -short]"
}

set required_part xczu19eg-ffvc1760-2-i
set matched_parts [get_parts -quiet $required_part]
if {[llength $matched_parts] != 1} {
  error "Required device support is missing: $required_part"
}
puts "FPGATTEN_2025_2_PART=[get_property NAME [lindex $matched_parts 0]]"

create_project -in_memory -part $required_part
update_ip_catalog

set required_ip_patterns {
  xilinx.com:ip:clk_wiz:*
  xilinx.com:ip:ddr4:*
  xilinx.com:ip:axi_clock_converter:*
  xilinx.com:ip:zynq_ultra_ps_e:*
  xilinx.com:ip:smartconnect:*
  xilinx.com:ip:proc_sys_reset:*
  xilinx.com:ip:xlconstant:*
  xilinx.com:ip:xlconcat:*
  xilinx.com:ip:util_vector_logic:*
}
foreach ip_pattern $required_ip_patterns {
  set matches [get_ipdefs -all -quiet $ip_pattern]
  if {[llength $matches] == 0} {
    error "Required Vivado IP is unavailable: $ip_pattern"
  }
  set selected [lindex [lsort -dictionary $matches] end]
  puts "FPGATTEN_2025_2_IPDEF pattern=$ip_pattern selected=$selected"
}

puts "FPGATTEN_2025_2_VIVADO=[version -short]"
puts "FPGATTEN_2025_2_ENVIRONMENT_PASS=1"
close_project
exit
