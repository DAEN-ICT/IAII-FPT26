# Generate timing evidence from an existing routed checkpoint without
# modifying placement, routing, or the checkpoint itself.
#
# Usage:
#   vivado -mode batch -notrace -source report_routed_timing_readonly.tcl \
#     -tclargs <routed.dcp> <output_dir>

if {$argc != 2} {
  error "Usage: report_routed_timing_readonly.tcl <routed.dcp> <output_dir>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $input_dcp]} {
  error "Routed checkpoint does not exist: $input_dcp"
}

file mkdir $output_dir
set_param general.maxThreads 2
puts "READONLY_TIMING_BEGIN input=$input_dcp output=$output_dir"
open_checkpoint $input_dcp

report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $output_dir report_timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -nworst 1 -path_type full \
  -file [file join $output_dir report_timing_setup_top100.rpt]
report_timing -delay_type min -max_paths 20 -nworst 1 -path_type full \
  -file [file join $output_dir report_timing_hold_top20.rpt]

foreach clock_name {clk_core_235_unbuf clk_dma_300_unbuf} {
  set clock_object [get_clocks -quiet $clock_name]
  if {[llength $clock_object] != 0} {
    report_timing -delay_type max -max_paths 20 -nworst 1 \
      -path_type full -group $clock_object \
      -file [file join $output_dir "report_timing_${clock_name}_top20.rpt"]
  }
}

set setup_paths [get_timing_paths -delay_type max -max_paths 100 -nworst 1]
set table [open [file join $output_dir setup_top100.tsv] w]
puts $table "rank\tslack_ns\tdatapath_delay_ns\tlogic_levels\tstartpoint\tendpoint"
set rank 0
foreach timing_path $setup_paths {
  incr rank
  set slack [get_property SLACK $timing_path]
  set datapath [get_property DATAPATH_DELAY $timing_path]
  set logic_levels [get_property LOGIC_LEVELS $timing_path]
  set startpoint [get_property STARTPOINT_PIN $timing_path]
  set endpoint [get_property ENDPOINT_PIN $timing_path]
  puts $table "$rank\t$slack\t$datapath\t$logic_levels\t$startpoint\t$endpoint"
}
close $table

puts "READONLY_TIMING_PATH_COUNT=[llength $setup_paths]"
puts "READONLY_TIMING_DONE"
close_design
exit
