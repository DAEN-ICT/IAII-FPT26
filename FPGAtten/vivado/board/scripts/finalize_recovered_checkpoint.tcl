# Validate a recovered routed checkpoint and export the final bitstream/XSA.
#
# Usage:
#   vivado -mode batch -notrace -source finalize_recovered_checkpoint.tcl \
#     -tclargs <recovered.dcp> <output_dir>

if {$argc != 2} {
  error "Usage: finalize_recovered_checkpoint.tcl <recovered.dcp> <output_dir>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set report_dir [file join $output_dir reports]
if {![file isfile $input_dcp]} {
  error "Recovered checkpoint does not exist: $input_dcp"
}
file mkdir $output_dir
file mkdir $report_dir

proc worst_slack {delay_type} {
  set paths [get_timing_paths -quiet -delay_type $delay_type \
    -max_paths 1 -nworst 1]
  if {[llength $paths] == 0} {
    return "NA"
  }
  return [get_property SLACK [lindex $paths 0]]
}

open_checkpoint $input_dcp

set setup_slack [worst_slack max]
set hold_slack [worst_slack min]
puts "FINALIZE_TIMING WNS_NS=$setup_slack WHS_NS=$hold_slack"
if {![string is double -strict $setup_slack] ||
    ![string is double -strict $hold_slack] ||
    ($setup_slack < 0.0) || ($hold_slack < 0.0)} {
  error "Recovered checkpoint does not meet timing"
}

report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir report_timing_summary_final.rpt]
report_timing -delay_type max -max_paths 50 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_setup_top50_final.rpt]
set bus_skew_status [report_bus_skew -return_string \
  -file [file join $report_dir report_bus_skew_final.rpt]]
report_drc -file [file join $report_dir report_drc_final.rpt]
report_route_status -file [file join $report_dir report_route_status_final.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir report_utilization_final.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir report_congestion_final.rpt]

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == "Error"}]
if {[llength $drc_errors] != 0} {
  error "Recovered checkpoint has [llength $drc_errors] DRC errors"
}

if {[string first "Slack (VIOLATED)" $bus_skew_status] >= 0} {
  error "Recovered checkpoint has a bus-skew violation"
}

set route_status [report_route_status -return_string]
if {![regexp -nocase \
    {# of nets with routing errors\.*[ \t]*:[ \t]*0[ \t]*:} \
    $route_status]} {
  error "Recovered checkpoint has routing errors"
}

set metrics [open [file join $report_dir final_metrics.kv] w]
puts $metrics "INPUT_DCP=$input_dcp"
puts $metrics "WNS_NS=$setup_slack"
puts $metrics "WHS_NS=$hold_slack"
puts $metrics "DRC_ERROR_COUNT=[llength $drc_errors]"
close $metrics

set bit_file [file join $output_dir GQAv7_z19p.bit]
set xsa_file [file join $output_dir GQAv7_z19p.xsa]
write_bitstream -force $bit_file
write_hw_platform -fixed -include_bit -force -file $xsa_file

puts "PASS: recovered checkpoint finalized"
puts "WNS_NS=$setup_slack"
puts "WHS_NS=$hold_slack"
puts "BITSTREAM=$bit_file"
puts "XSA=$xsa_file"
close_design
exit
