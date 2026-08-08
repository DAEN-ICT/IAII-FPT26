# Explore several post-route physical-optimization directives from the same
# routed checkpoint, retain the best legal result, and export signed hardware
# only when both setup and hold timing pass.
#
# Usage:
#   vivado -mode batch -notrace -source recover_routed_timing.tcl \
#     -tclargs <routed.dcp> <output_dir>

if {$argc != 2} {
  error "Usage: recover_routed_timing.tcl <routed.dcp> <output_dir>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set report_dir [file join $output_dir reports]
if {[info exists ::env(GQAV7_MAX_THREADS)]} {
  set requested_threads $::env(GQAV7_MAX_THREADS)
  if {![string is integer -strict $requested_threads] ||
      ($requested_threads < 1)} {
    error "GQAV7_MAX_THREADS must be a positive integer"
  }
  set_param general.maxThreads $requested_threads
  puts "RECOVERY_THREADS max=$requested_threads"
}
if {![file isfile $input_dcp]} {
  error "Routed checkpoint does not exist: $input_dcp"
}
file mkdir $output_dir
file mkdir $report_dir

proc timing_value {delay_type property} {
  set paths [get_timing_paths -quiet -delay_type $delay_type \
    -max_paths 1 -nworst 1]
  if {[llength $paths] == 0} {
    return "NA"
  }
  return [get_property $property [lindex $paths 0]]
}

proc safe_name {text} {
  return [string map {" " "_" "/" "_" "\\" "_" ":" "_"} $text]
}

set directives {
  AggressiveExplore
  Explore
  AlternateReplication
}
if {[info exists ::env(GQAV7_RECOVERY_DIRECTIVES)]} {
  set directives $::env(GQAV7_RECOVERY_DIRECTIVES)
  if {[llength $directives] == 0} {
    error "GQAV7_RECOVERY_DIRECTIVES must contain at least one directive"
  }
}
set best_slack -1000.0
set best_hold -1000.0
set best_directive ""
set best_dcp ""

foreach directive $directives {
  puts "RECOVERY_BEGIN directive=$directive"
  open_checkpoint $input_dcp
  phys_opt_design -directive $directive

  set setup_slack [timing_value max SLACK]
  set hold_slack [timing_value min SLACK]
  set candidate_name [safe_name $directive]
  set candidate_dcp [file join $output_dir \
    "gqav7_z19p_system_wrapper_${candidate_name}.dcp"]
  report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir \
      "report_timing_summary_${candidate_name}.rpt"]
  report_timing -delay_type max -max_paths 20 -nworst 1 -path_type full \
    -file [file join $report_dir \
      "report_timing_setup_top20_${candidate_name}.rpt"]
  write_checkpoint -force $candidate_dcp

  puts "RECOVERY_RESULT directive=$directive WNS_NS=$setup_slack WHS_NS=$hold_slack"
  if {[string is double -strict $setup_slack] &&
      [string is double -strict $hold_slack] &&
      ($hold_slack >= 0.0) && ($setup_slack > $best_slack)} {
    set best_slack $setup_slack
    set best_hold $hold_slack
    set best_directive $directive
    set best_dcp $candidate_dcp
  }
  close_design
}

if {$best_dcp eq ""} {
  error "No post-route recovery candidate preserved nonnegative hold timing"
}

open_checkpoint $best_dcp
report_drc -file [file join $report_dir report_drc_best.rpt]
report_route_status -file [file join $report_dir report_route_status_best.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir report_utilization_best.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir report_congestion_best.rpt]

set metrics [open [file join $report_dir recovery_metrics.kv] w]
puts $metrics "INPUT_DCP=$input_dcp"
puts $metrics "BEST_DIRECTIVE=$best_directive"
puts $metrics "WNS_NS=$best_slack"
puts $metrics "WHS_NS=$best_hold"
puts $metrics "BEST_DCP=$best_dcp"
close $metrics

if {$best_slack < 0.0} {
  error "Post-route recovery did not meet setup timing; best directive=$best_directive WNS=$best_slack ns"
}

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == "Error"}]
if {[llength $drc_errors] != 0} {
  error "Recovered design has [llength $drc_errors] DRC errors"
}

set bit_file [file join $output_dir FPGAtten_2025_2_z19p.bit]
set xsa_file [file join $output_dir FPGAtten_2025_2_z19p.xsa]
write_bitstream -force $bit_file
write_hw_platform -fixed -include_bit -force -file $xsa_file
puts "PASS: post-route timing recovery and hardware export completed"
puts "BEST_DIRECTIVE=$best_directive"
puts "WNS_NS=$best_slack"
puts "WHS_NS=$best_hold"
puts "BITSTREAM=$bit_file"
puts "XSA=$xsa_file"
close_design
exit
