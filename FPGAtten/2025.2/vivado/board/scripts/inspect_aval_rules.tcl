if {$argc != 2} {
  error "Usage: inspect_aval_rules.tcl <checkpoint.dcp> <report.txt>"
}

set checkpoint_path [file normalize [lindex $argv 0]]
set report_path [file normalize [lindex $argv 1]]

open_checkpoint $checkpoint_path
set report_file [open $report_path w]
foreach check_name {AVAL-244 AVAL-245} {
  set check [get_drc_checks -quiet $check_name]
  puts $report_file "=== $check_name ==="
  if {[llength $check] == 0} {
    puts $report_file "not found"
    continue
  }
  foreach property_name [lsort [list_property $check]] {
    set property_value [get_property -quiet $property_name $check]
    puts $report_file "$property_name=$property_value"
  }
}
close $report_file
report_drc -checks {AVAL-244 AVAL-245} -file "${report_path}.drc" -force
close_design
exit
