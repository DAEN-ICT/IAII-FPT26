if {$argc != 2} {
  error "Usage: validate_routed_cdc_ram.tcl <routed.dcp> <output_report>"
}

set checkpoint_path [file normalize [lindex $argv 0]]
set report_path [file normalize [lindex $argv 1]]
set script_dir [file dirname [file normalize [info script]]]

open_checkpoint $checkpoint_path
source [file join $script_dir check_z19p_reset_cdc.tcl]
report_drc -checks {AVAL-244 AVAL-245} -file $report_path -force

set mismatched_domain_rams {}
set row_mover_cdc_rams [get_cells -hierarchical -quiet -filter {
  (REF_NAME == RAMB18E2 || REF_NAME == RAMB36E2) &&
  (NAME =~ *i_row_mover/i_*_cdc/memory_q_reg* ||
   NAME =~ *i_v_row_mover/i_*_cdc/memory_q_reg*)
}]
foreach ram_cell $row_mover_cdc_rams {
  set rd_net [get_nets -quiet -of_objects [get_pins -quiet ${ram_cell}/CLKARDCLK]]
  set wr_net [get_nets -quiet -of_objects [get_pins -quiet ${ram_cell}/CLKBWRCLK]]
  set actual_property [get_property CLOCK_DOMAINS $ram_cell]
  set expected_property INDEPENDENT
  if {$rd_net eq $wr_net} {
    set expected_property COMMON
  }
  if {$actual_property ne $expected_property} {
    lappend mismatched_domain_rams $ram_cell
  }
}

if {[llength $mismatched_domain_rams] != 0} {
  error "Found [llength $mismatched_domain_rams] row-mover CDC RAMs whose CLOCK_DOMAINS property does not match the actual clock nets"
}

puts "PASS: routed row-mover CDC RAM attributes match their actual clock nets"
close_design
exit
