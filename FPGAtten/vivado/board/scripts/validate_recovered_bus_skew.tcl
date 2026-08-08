# Report and validate bus-skew constraints from a routed checkpoint.
#
# Usage:
#   vivado -mode batch -notrace -source validate_recovered_bus_skew.tcl \
#     -tclargs <routed.dcp> <report.rpt>

if {$argc != 2} {
  error "Usage: validate_recovered_bus_skew.tcl <routed.dcp> <report.rpt>"
}
if {[version -short] ne "2024.2"} {
  error "This check requires Vivado 2024.2, running [version -short]"
}

set input_dcp [file normalize [lindex $argv 0]]
set report_file [file normalize [lindex $argv 1]]
if {![file isfile $input_dcp]} {
  error "Routed checkpoint does not exist: $input_dcp"
}
file mkdir [file dirname $report_file]

open_checkpoint $input_dcp
set bus_skew_status [report_bus_skew -return_string -file $report_file]
if {[string first "Slack (VIOLATED)" $bus_skew_status] >= 0} {
  error "Recovered checkpoint has a bus-skew violation"
}

puts "PASS: recovered checkpoint bus-skew constraints are met"
puts "REPORT=$report_file"
close_design
exit
