# Targeted 240 MHz timing recovery for the timingfix3 checkpoints.
#
# Safety model:
#   * "audit" is read-only and is the only mode that runs without an explicit
#     environment guard.
#   * Every mutating mode requires GQAV7_ENABLE_TARGETED_RECOVERY=YES.
#   * No mode writes a bitstream or XSA.  A candidate DCP plus setup/hold/DRC
#     reports are produced for separate signoff.
#
# Usage:
#   vivado -mode batch -notrace \
#     -source recover_routed_timing_targeted.tcl \
#     -tclargs <mode> <input.dcp> <output_dir> ?route_directive?
#
# Modes:
#   audit
#       Resolve the exact candidate objects and report fanout/path coverage.
#       Does not request an Implementation license.
#
#   targeted_reroute
#       Starting from a routed DCP, reroute only the lane-3 BRAM->DSP B[0]
#       net and the three named CE branches with route_design -auto_delay.
#
#   targeted_replication
#       Starting from a routed DCP, run only forced driver replication on the
#       sidecar CEB2 net and the output-update CEB2 cluster.  Supplying a
#       specific phys_opt option disables the normal global post-route
#       critical-path passes that terminated in the timingfix3 build.
#
#   targeted_combo
#       Run targeted_replication followed by targeted_reroute.
#
#   route_from_physopt <directive>
#       Starting from the pre-route physopt DCP, run one complete routing pass
#       with the selected legal Vivado 2024.2 directive and -tns_cleanup.
#       Recommended first directive: NoTimingRelaxation.  Other accepted
#       alternatives are HigherDelayCost, MoreGlobalIterations,
#       AdvancedSkewModeling, AggressiveExplore, Explore, and Default.
#
# Optional environment guards:
#   GQAV7_INCLUDE_CORE_RST_REPLICATION=YES
#       Also force-replicate core_rst_ni (fanout ~6471).  This is intentionally
#       excluded by default because it has a much larger placement/hold blast
#       radius than the two local CEB candidates.
#   GQAV7_INCLUDE_BANK2_ROUTE=YES
#       Also reroute lane-2 BRAM->DSP B[4], currently around -0.016 ns.

if {[llength $argv] < 3 || [llength $argv] > 4} {
  puts stderr "usage: recover_routed_timing_targeted.tcl <mode> <input.dcp> <output_dir> ?route_directive?"
  exit 2
}

set mode [lindex $argv 0]
set input_dcp [file normalize [lindex $argv 1]]
set output_dir [file normalize [lindex $argv 2]]
set route_directive ""
if {[llength $argv] == 4} {
  set route_directive [lindex $argv 3]
}

set legal_modes {
  audit
  targeted_reroute
  targeted_replication
  targeted_combo
  route_from_physopt
}
if {[lsearch -exact $legal_modes $mode] < 0} {
  error "unsupported mode '$mode'; expected one of: $legal_modes"
}
if {![file isfile $input_dcp]} {
  error "checkpoint does not exist: $input_dcp"
}

if {$mode ne "audit"} {
  if {![info exists ::env(GQAV7_ENABLE_TARGETED_RECOVERY)] ||
      $::env(GQAV7_ENABLE_TARGETED_RECOVERY) ne "YES"} {
    error "mutating mode '$mode' requires GQAV7_ENABLE_TARGETED_RECOVERY=YES"
  }
}

set legal_route_directives {
  NoTimingRelaxation
  HigherDelayCost
  MoreGlobalIterations
  AdvancedSkewModeling
  AggressiveExplore
  Explore
  Default
}
if {$mode eq "route_from_physopt"} {
  if {[lsearch -exact $legal_route_directives $route_directive] < 0} {
    error "route_from_physopt requires one legal directive: $legal_route_directives"
  }
} elseif {$route_directive ne ""} {
  error "route directive is accepted only by route_from_physopt"
}

if {[info exists ::env(GQAV7_MAX_THREADS)]} {
  set requested_threads $::env(GQAV7_MAX_THREADS)
  if {![string is integer -strict $requested_threads] ||
      $requested_threads < 1} {
    error "GQAV7_MAX_THREADS must be a positive integer"
  }
  set_param general.maxThreads $requested_threads
}

file mkdir $output_dir
set report_dir [file join $output_dir reports]
file mkdir $report_dir

proc exact_nets {name} {
  return [get_nets -quiet -hierarchical -filter \
      [format {NAME == "%s"} $name]]
}

proc exact_pins {name} {
  return [get_pins -quiet -hierarchical -filter \
      [format {NAME == "%s"} $name]]
}

proc require_exact_net {label name} {
  set nets [exact_nets $name]
  if {[llength $nets] != 1} {
    error "$label expected exactly one net, got [llength $nets]: $name"
  }
  return [lindex $nets 0]
}

proc require_exact_pin {label name} {
  set pins [exact_pins $name]
  if {[llength $pins] != 1} {
    error "$label expected exactly one pin, got [llength $pins]: $name"
  }
  return [lindex $pins 0]
}

proc require_net_at_pin {label pin_name} {
  set pin [require_exact_pin "${label}_anchor_pin" $pin_name]
  set nets [get_nets -quiet -of_objects $pin]
  if {[llength $nets] != 1} {
    error "$label expected exactly one net at pin $pin_name, got [llength $nets]"
  }
  return [lindex $nets 0]
}

proc path_metric {delay_type property} {
  set paths [get_timing_paths -quiet -delay_type $delay_type \
      -max_paths 1 -nworst 1]
  if {[llength $paths] == 0} {
    return "NA"
  }
  return [get_property $property [lindex $paths 0]]
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

proc emit_object_audit {label object object_type} {
  if {$object_type eq "net"} {
    set pins [get_pins -quiet -leaf -of_objects $object]
    set drivers [filter $pins {DIRECTION == OUT || DIRECTION == INOUT}]
    set loads [filter $pins {DIRECTION == IN}]
    set paths [get_timing_paths -quiet -delay_type max -through $object \
        -max_paths 1000 -nworst 1 -slack_lesser_than 0.0]
    set worst "NA"
    if {[llength $paths] > 0} {
      set worst [get_property SLACK [lindex $paths 0]]
    }
    puts "TARGET_OBJECT label=$label type=net name=[get_property NAME $object] drivers=[llength $drivers] loads=[llength $loads] violating_paths=[llength $paths] worst_slack_ns=$worst"
  } else {
    set paths [get_timing_paths -quiet -delay_type max -to $object \
        -max_paths 1000 -nworst 1 -slack_lesser_than 0.0]
    set worst "NA"
    if {[llength $paths] > 0} {
      set worst [get_property SLACK [lindex $paths 0]]
    }
    set cell [get_cells -quiet -of_objects $object]
    puts "TARGET_OBJECT label=$label type=pin name=[get_property NAME $object] cell=[get_property NAME $cell] loc=[get_property LOC $cell] violating_paths=[llength $paths] worst_slack_ns=$worst"
  }
}

set sidecar_ce_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_score_sidecar/gen_scale[3].i_scale/significand_product_w/CEB2
}
set output_ce_cluster_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/CEB2_repN_1_alias
}
set core_rst_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_pv/gen_pv_engine[0].i_compute_capture/i_qk/i_engine/core_rst_ni
}
set bank3_b0_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/gen_update_lane[3].i_scale_state/significand_product_w/B[0]
}
set bank2_b4_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/gen_update_lane[2].i_scale_state/significand_product_w/B[4]
}
set sidecar_ce_pin_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_score_sidecar/gen_scale[3].i_scale/significand_product_w/DSP_A_B_DATA_INST/CEB2
}
set output_ce_cluster_pin_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/bypass_state_packed_q_reg[426]/CE
}
set bank3_b0_pin_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/gen_update_lane[3].i_scale_state/significand_product_w/DSP_A_B_DATA_INST/B[0]
}
set bank2_b4_pin_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_output_update/gen_update_lane[2].i_scale_state/significand_product_w/DSP_A_B_DATA_INST/B[4]
}
set reset_ce_11_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_pv/gen_pv_engine[0].i_compute_capture/i_qk/i_engine/retire_first_q_reg[2]_replica_11/CE
}
set reset_ce_15_name {
  gqav7_z19p_system_i/gqav7_accelerator_0/inst/u_accelerator/i_core/i_pipeline/i_downstream/i_pv/gen_pv_engine[0].i_compute_capture/i_qk/i_engine/retire_first_q_reg[2]_replica_15/CE
}

foreach variable_name {
  sidecar_ce_name output_ce_cluster_name core_rst_name bank3_b0_name
  bank2_b4_name sidecar_ce_pin_name output_ce_cluster_pin_name
  bank3_b0_pin_name bank2_b4_pin_name reset_ce_11_name reset_ce_15_name
} {
  set $variable_name [string trim [set $variable_name]]
}

open_checkpoint $input_dcp
puts "TARGETED_RECOVERY_BEGIN mode=$mode input=$input_dcp"
puts "BASELINE_WNS_NS=[path_metric max SLACK]"
puts "BASELINE_WHS_NS=[path_metric min SLACK]"

if {$mode eq "audit"} {
  set sidecar_ce [require_net_at_pin sidecar_ce $sidecar_ce_pin_name]
  set output_ce_cluster [require_net_at_pin output_ce_cluster \
      $output_ce_cluster_pin_name]
  set core_rst [require_net_at_pin core_rst $reset_ce_11_name]
  set bank3_b0 [require_net_at_pin bank3_b0 $bank3_b0_pin_name]
  set bank2_b4 [require_net_at_pin bank2_b4 $bank2_b4_pin_name]
  set sidecar_ce_pin [require_exact_pin sidecar_ce_pin $sidecar_ce_pin_name]
  set reset_ce_11 [require_exact_pin reset_ce_11 $reset_ce_11_name]
  set reset_ce_15 [require_exact_pin reset_ce_15 $reset_ce_15_name]

  foreach item [list \
      [list sidecar_ce $sidecar_ce net] \
      [list output_ce_cluster $output_ce_cluster net] \
      [list core_rst $core_rst net] \
      [list bank3_b0 $bank3_b0 net] \
      [list bank2_b4 $bank2_b4 net] \
      [list sidecar_ce_pin $sidecar_ce_pin pin] \
      [list reset_ce_11 $reset_ce_11 pin] \
      [list reset_ce_15 $reset_ce_15 pin]] {
    lassign $item label object object_type
    emit_object_audit $label $object $object_type
  }
  report_timing -delay_type max -max_paths 100 -nworst 1 \
      -path_type full -file [file join $report_dir audit_setup_top100.rpt]
  report_timing -delay_type min -max_paths 20 -nworst 1 \
      -path_type full -file [file join $report_dir audit_hold_top20.rpt]
  close_design
  puts "PASS: read-only exact-object audit completed"
  exit
}

if {$mode eq "targeted_replication" || $mode eq "targeted_combo"} {
  set replication_nets [list \
      [require_net_at_pin sidecar_ce $sidecar_ce_pin_name] \
      [require_net_at_pin output_ce_cluster $output_ce_cluster_pin_name]]
  if {[info exists ::env(GQAV7_INCLUDE_CORE_RST_REPLICATION)] &&
      $::env(GQAV7_INCLUDE_CORE_RST_REPLICATION) eq "YES"} {
    lappend replication_nets [require_net_at_pin core_rst $reset_ce_11_name]
  }
  puts "TARGETED_FORCE_REPLICATION nets=[join [get_property NAME $replication_nets] ,]"
  phys_opt_design -force_replication_on_nets $replication_nets
}

if {$mode eq "targeted_reroute" || $mode eq "targeted_combo"} {
  set bank3_b0 [require_net_at_pin bank3_b0 $bank3_b0_pin_name]
  puts "TARGETED_REROUTE_NET name=[get_property NAME $bank3_b0] method=auto_delay"
  route_design -unroute -nets $bank3_b0
  route_design -auto_delay -nets $bank3_b0

  if {[info exists ::env(GQAV7_INCLUDE_BANK2_ROUTE)] &&
      $::env(GQAV7_INCLUDE_BANK2_ROUTE) eq "YES"} {
    set bank2_b4 [require_net_at_pin bank2_b4 $bank2_b4_pin_name]
    puts "TARGETED_REROUTE_NET name=[get_property NAME $bank2_b4] method=auto_delay"
    route_design -unroute -nets $bank2_b4
    route_design -auto_delay -nets $bank2_b4
  }

  foreach pin_item [list \
      [list sidecar_ce_pin $sidecar_ce_pin_name] \
      [list reset_ce_11 $reset_ce_11_name] \
      [list reset_ce_15 $reset_ce_15_name]] {
    lassign $pin_item label pin_name
    set pin [require_exact_pin $label $pin_name]
    puts "TARGETED_REROUTE_PIN label=$label name=[get_property NAME $pin] method=auto_delay"
    route_design -unroute -pins $pin
    route_design -auto_delay -pins $pin
  }
}

if {$mode eq "route_from_physopt"} {
  puts "ROUTE_ONLY_FROM_PHYSOPT directive=$route_directive tns_cleanup=1"
  route_design -directive $route_directive -tns_cleanup
}

set final_wns [path_metric max SLACK]
set final_whs [path_metric min SLACK]
lassign [negative_setup_metrics] failing_endpoints final_tns

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir report_timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -nworst 1 -path_type full \
    -file [file join $report_dir report_timing_setup_top100.rpt]
report_timing -delay_type min -max_paths 20 -nworst 1 -path_type full \
    -file [file join $report_dir report_timing_hold_top20.rpt]
report_route_status -file [file join $report_dir report_route_status.rpt]
report_drc -file [file join $report_dir report_drc.rpt]

set candidate_dcp [file join $output_dir \
    "gqav7_z19p_system_wrapper_${mode}.dcp"]
write_checkpoint -force $candidate_dcp

set metrics [open [file join $report_dir targeted_recovery_metrics.kv] w]
puts $metrics "MODE=$mode"
puts $metrics "INPUT_DCP=$input_dcp"
puts $metrics "ROUTE_DIRECTIVE=$route_directive"
puts $metrics "WNS_NS=$final_wns"
puts $metrics "TNS_NS=$final_tns"
puts $metrics "SETUP_FAILING_ENDPOINTS=$failing_endpoints"
puts $metrics "WHS_NS=$final_whs"
puts $metrics "OUTPUT_DCP=$candidate_dcp"
close $metrics

puts "TARGETED_RECOVERY_RESULT mode=$mode WNS_NS=$final_wns TNS_NS=$final_tns SETUP_FAILING_ENDPOINTS=$failing_endpoints WHS_NS=$final_whs"
puts "OUTPUT_DCP=$candidate_dcp"
if {[string is double -strict $final_whs] && $final_whs < 0.0} {
  puts stderr "REJECT: candidate has a hold violation; do not use for signoff"
} elseif {[string is double -strict $final_wns] && $final_wns < 0.0} {
  puts stderr "INCOMPLETE: setup timing remains negative; preserve only as an intermediate candidate"
} else {
  puts "PASS: candidate has nonnegative setup and hold slack; full signoff is still required"
}
close_design
exit
