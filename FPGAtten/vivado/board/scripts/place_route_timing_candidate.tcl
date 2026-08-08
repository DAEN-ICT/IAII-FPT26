# Build and sign-check one alternate placed/routed candidate from an existing
# post-opt checkpoint.  The flow never changes RTL, XDC, block designs, or IP.
#
# Usage:
#   vivado -mode batch -notrace \
#     -source place_route_timing_candidate.tcl -tclargs \
#     <place_directive> <input_opt.dcp> <output_dir> \
#     <core_mhz> <dma_mhz>

if {$argc != 5} {
  error "Usage: place_route_timing_candidate.tcl <place_directive> <input_opt.dcp> <output_dir> <core_mhz> <dma_mhz>"
}

set place_directive [lindex $argv 0]
set input_dcp [file normalize [lindex $argv 1]]
set output_dir [file normalize [lindex $argv 2]]
set core_frequency_mhz [lindex $argv 3]
set dma_frequency_mhz [lindex $argv 4]
set report_dir [file join $output_dir reports]
set legal_place_directives {
  Explore
  ExtraNetDelay_high
  ExtraNetDelay_low
  ExtraPostPlacementOpt
  AltSpreadLogic_high
  AltSpreadLogic_medium
  AltSpreadLogic_low
}

if {[lsearch -exact $legal_place_directives $place_directive] < 0} {
  error "Unsupported place directive '$place_directive'"
}
if {![file isfile $input_dcp]} {
  error "Input checkpoint does not exist: $input_dcp"
}
foreach {name value} [list CORE_MHZ $core_frequency_mhz DMA_MHZ $dma_frequency_mhz] {
  if {![string is double -strict $value] || $value <= 0.0} {
    error "$name must be a positive number"
  }
}
if {[file exists $output_dir] &&
    [llength [glob -nocomplain -directory $output_dir *]] != 0} {
  error "Refusing to mix with a nonempty candidate directory: $output_dir"
}

set requested_threads 2
if {[info exists ::env(GQAV7_MAX_THREADS)]} {
  set requested_threads $::env(GQAV7_MAX_THREADS)
}
if {![string is integer -strict $requested_threads] ||
    $requested_threads < 1} {
  error "GQAV7_MAX_THREADS must be a positive integer"
}
set_param general.maxThreads $requested_threads
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

proc negative_setup_metrics {} {
  set paths [get_timing_paths -quiet -delay_type max -max_paths 1000000 \
    -nworst 1 -slack_lesser_than 0.0]
  set tns 0.0
  foreach path $paths {
    set tns [expr {$tns + [get_property SLACK $path]}]
  }
  return [list [llength $paths] $tns]
}

proc require_clock_period {pattern expected_period_ns tolerance_ns} {
  set clocks [get_clocks -quiet -filter "NAME =~ $pattern"]
  if {[llength $clocks] != 1} {
    error "Expected one implemented clock matching $pattern, found: $clocks"
  }
  set period [get_property PERIOD [lindex $clocks 0]]
  if {![string is double -strict $period] ||
      abs(double($period) - double($expected_period_ns)) > $tolerance_ns} {
    error "Clock $pattern period mismatch: actual=$period expected=$expected_period_ns"
  }
  return [list [get_property NAME [lindex $clocks 0]] $period]
}

proc primitive_count {pattern} {
  return [llength [get_cells -quiet -hierarchical \
    -filter "REF_NAME =~ $pattern"]]
}

proc write_metrics {path values} {
  set handle [open $path w]
  foreach {key value} $values {
    puts $handle "$key=$value"
  }
  close $handle
}

open_checkpoint $input_dcp
set core_period_ns [expr {1000.0 / double($core_frequency_mhz)}]
set dma_period_ns [expr {1000.0 / double($dma_frequency_mhz)}]
lassign [require_clock_period {clk_core_*_unbuf} $core_period_ns 0.002] \
  core_clock_name implemented_core_period_ns
lassign [require_clock_period {clk_dma_*_unbuf} $dma_period_ns 0.002] \
  dma_clock_name implemented_dma_period_ns

puts "TIMING_CANDIDATE_BEGIN directive=$place_directive threads=$requested_threads input=$input_dcp"
puts "TIMING_CANDIDATE_CLOCKS core=$core_clock_name/$implemented_core_period_ns dma=$dma_clock_name/$implemented_dma_period_ns"

place_design -directive $place_directive
set placed_dcp [file join $output_dir \
  gqav7_z19p_system_wrapper_candidate_placed.dcp]
write_checkpoint -force $placed_dcp
report_timing_summary -delay_type min_max \
  -file [file join $report_dir report_timing_summary_placed.rpt]
puts "TIMING_CANDIDATE_PLACED WNS_NS=[worst_slack max] WHS_NS=[worst_slack min]"

phys_opt_design -directive Explore
set physopt_dcp [file join $output_dir \
  gqav7_z19p_system_wrapper_candidate_physopt.dcp]
write_checkpoint -force $physopt_dcp
report_timing_summary -delay_type min_max \
  -file [file join $report_dir report_timing_summary_physopt.rpt]
puts "TIMING_CANDIDATE_PHYSOPT WNS_NS=[worst_slack max] WHS_NS=[worst_slack min]"

route_design -directive Explore -tns_cleanup
set routed_dcp [file join $output_dir \
  gqav7_z19p_system_wrapper_candidate_routed.dcp]
write_checkpoint -force $routed_dcp

set final_wns [worst_slack max]
set final_whs [worst_slack min]
lassign [negative_setup_metrics] failing_endpoints final_tns
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir report_timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_setup_top100.rpt]
report_timing -delay_type min -max_paths 100 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_hold_top100.rpt]
report_route_status -file [file join $report_dir report_route_status.rpt]
set route_status_text [report_route_status -return_string]
set bus_skew_text [report_bus_skew -return_string \
  -file [file join $report_dir report_bus_skew.rpt]]
report_drc -file [file join $report_dir report_drc.rpt]
report_cdc -details -file [file join $report_dir report_cdc.rpt]
report_clock_interaction \
  -file [file join $report_dir report_clock_interaction.rpt]
report_clocks -file [file join $report_dir report_clocks.rpt]
report_utilization -file [file join $report_dir report_utilization.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir report_utilization_hierarchical.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir report_congestion.rpt]

set drc_error_count [llength \
  [get_drc_violations -quiet -filter {SEVERITY == "Error"}]]
set bus_skew_violated \
  [expr {[string first "Slack (VIOLATED)" $bus_skew_text] >= 0}]
set routing_error_count -1
regexp -nocase \
  {# of nets with routing errors\.*[ \t]*:[ \t]*([0-9]+)[ \t]*:} \
  $route_status_text -> routing_error_count
set lut_primitives [primitive_count LUT*]
set dsp_primitives [primitive_count DSP48*]

set metrics_values [list \
  FORMAT_VERSION 1 \
  INPUT_DCP $input_dcp \
  PLACE_DIRECTIVE $place_directive \
  CORE_FREQUENCY_MHZ $core_frequency_mhz \
  CORE_CLOCK_NAME $core_clock_name \
  IMPLEMENTED_CORE_PERIOD_NS $implemented_core_period_ns \
  DMA_FREQUENCY_MHZ $dma_frequency_mhz \
  DMA_CLOCK_NAME $dma_clock_name \
  IMPLEMENTED_DMA_PERIOD_NS $implemented_dma_period_ns \
  WNS_NS $final_wns \
  TNS_NS $final_tns \
  SETUP_FAILING_ENDPOINTS $failing_endpoints \
  WHS_NS $final_whs \
  DRC_ERROR_COUNT $drc_error_count \
  ROUTING_ERROR_COUNT $routing_error_count \
  BUS_SKEW_VIOLATED $bus_skew_violated \
  LUT_PRIMITIVES $lut_primitives \
  DSP48_PRIMITIVES $dsp_primitives \
  OUTPUT_DCP $routed_dcp]
write_metrics [file join $report_dir candidate_metrics.kv] $metrics_values

puts "TIMING_CANDIDATE_FINAL WNS_NS=$final_wns TNS_NS=$final_tns SETUP_FAILING_ENDPOINTS=$failing_endpoints WHS_NS=$final_whs DRC_ERROR_COUNT=$drc_error_count ROUTING_ERROR_COUNT=$routing_error_count BUS_SKEW_VIOLATED=$bus_skew_violated LUT_PRIMITIVES=$lut_primitives DSP48_PRIMITIVES=$dsp_primitives"
puts "OUTPUT_DCP=$routed_dcp"

set all_gates_pass [expr {
  $final_wns >= 0.0 && $final_whs >= 0.0 &&
  $drc_error_count == 0 && $routing_error_count == 0 &&
  $bus_skew_violated == 0 &&
  $lut_primitives <= 300000 && $dsp_primitives < 500
}]
close_design
if {!$all_gates_pass} {
  error "Timing candidate failed one or more release gates"
}
puts "PASS: timing candidate satisfies all release gates"
exit
