set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]

if {[info exists ::env(GQAV7_Z19P_SELF_CHECK)]} {
  set xci_file [file join $board_root ip_sources ddr4_controller.xci]
  if {![file isfile $xci_file]} {
    error "Missing local MIG descriptor: $xci_file"
  }
  puts "PASS: Z19-P MIG Tcl input resolves locally"
  return
}

if {[llength [get_projects -quiet]] == 0} {
  error "configure_z19p_mig.tcl requires an open project"
}

set mig [get_ips -quiet ddr4_controller]
if {[llength $mig] != 1} {
  error "Expected one ddr4_controller IP, found: $mig"
}

proc configure_mig_property {mig property expected} {
  set actual [get_property $property $mig]
  if {$actual eq $expected} {
    return
  }
  if {[catch {set_property $property $expected $mig} reason]} {
    error "MIG property $property is '$actual', expected '$expected': $reason"
  }
  set actual [get_property $property $mig]
  if {$actual ne $expected} {
    error "Vivado did not apply $property: expected '$expected', got '$actual'"
  }
}

# Values retained from the routed V4.1 Z19-P PL-DDR shell and the board vendor
# design. The migration changes the accelerator fabric clock, not MIG timing.
foreach {property expected} [list \
  CONFIG.C0.DDR4_TimePeriod {833} \
  CONFIG.C0.DDR4_InputClockPeriod {4998} \
  CONFIG.C0.DDR4_MemoryType {Components} \
  CONFIG.C0.DDR4_MemoryPart {MT40A512M16HA-083E} \
  CONFIG.C0.DDR4_DataWidth {64} \
  CONFIG.C0.DDR4_DataMask {DM_NO_DBI} \
  CONFIG.C0.DDR4_Ecc {false} \
  CONFIG.C0.DDR4_AxiSelection {true} \
  CONFIG.C0.DDR4_AxiDataWidth {512} \
  CONFIG.C0.DDR4_AxiAddressWidth {32} \
  CONFIG.C0.DDR4_AxiIDWidth {4} \
  CONFIG.C0.DDR4_AxiNarrowBurst {false}] {
  configure_mig_property $mig $property $expected
}

reset_target all $mig
generate_target all $mig
export_ip_user_files -of_objects $mig -no_script -sync -force -quiet
puts "PASS: configured Z19-P 64-bit PL DDR4 MIG"
