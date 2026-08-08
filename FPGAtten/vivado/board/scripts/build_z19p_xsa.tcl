set script_dir [file normalize [file dirname [info script]]]
if {[info exists ::env(GQAV7_Z19P_SELF_CHECK)]} {
  set create_script [file join $script_dir create_z19p_project.tcl]
  set reset_cdc_xdc [file normalize \
    [file join $script_dir ../constraints/z19p_reset_cdc.xdc]]
  set reset_cdc_check [file normalize \
    [file join $script_dir check_z19p_reset_cdc.tcl]]
  if {![file isfile $create_script]} {
    error "Missing Z19-P project creator: $create_script"
  }
  if {![file isfile $reset_cdc_xdc]} {
    error "Missing Z19-P reset CDC constraint: $reset_cdc_xdc"
  }
  if {![file isfile $reset_cdc_check]} {
    error "Missing Z19-P reset CDC implementation check: $reset_cdc_check"
  }
  puts "PASS: Z19-P XSA Tcl inputs resolve locally"
  return
}

if {[version -short] ne "2024.2"} {
  error "This build requires Vivado 2024.2, running [version -short]"
}
if {![info exists ::env(GQAV7_Z19P_PROJECT_FILE)]} {
  error "Set GQAV7_Z19P_PROJECT_FILE to GQAv7_z19p.xpr"
}
if {![info exists ::env(GQAV7_Z19P_OUTPUT_DIR)]} {
  error "Set GQAV7_Z19P_OUTPUT_DIR to a new output directory"
}

proc property_or_na {object property_name} {
  if {[catch {get_property $property_name $object} value] || $value eq ""} {
    return "NA"
  }
  return $value
}

proc cell_count {filter_expression} {
  return [llength [get_cells -hierarchical -quiet -filter $filter_expression]]
}

# Vivado's generated Windows OOC runner queries WMI only to annotate its
# `.begin.rst` status record with host core/memory counts.  The constrained
# local automation session is denied that WMI query, which leaves the runner
# stalled before it launches synthesis.  Replace only that status-recording
# fragment in generated legacy run wrappers; the Vivado command, source Tcl,
# options, and resulting hardware are unchanged.
proc patch_headless_run_wrapper {run_object} {
  set run_dir [get_property DIRECTORY $run_object]
  set wrapper [file join $run_dir ISEWrap.js]
  if {![file isfile $wrapper]} {
    error "Generated run wrapper is missing: $wrapper"
  }
  set handle [open $wrapper r]
  set content [read $handle]
  close $handle
  set begin_marker "    // BEGIN file creation\n    var wbemFlagReturnImmediately"
  set end_marker "    var ISENetwork = WScript.CreateObject( \"WScript.Network\" );"
  set begin_offset [string first $begin_marker $content]
  set end_offset [string first $end_marker $content]
  if {$begin_offset < 0 || $end_offset < 0 || $end_offset <= $begin_offset} {
    error "Unexpected generated OOC wrapper layout: $wrapper"
  }
  set replacement [join [list \
    "    // BEGIN file creation (V7.1 headless runner: no WMI access)" \
    "    var ISEHOSTCORE = 1;" \
    "    var ISEMEMTOTAL = 0;" \
    ""] "\n"]
  set content [string replace $content $begin_offset [expr {$end_offset - 1}] \
    $replacement]
  set handle [open $wrapper w]
  puts -nonewline $handle $content
  close $handle
  puts "Patched generated headless OOC wrapper: $wrapper"
}

proc headless_run_mode {} {
  if {![info exists ::env(GQAV7_Z19P_HEADLESS_RUNNER)]} {
    return 0
  }
  return [expr {$::env(GQAV7_Z19P_HEADLESS_RUNNER) eq "YES"}]
}

# Generate a normal Vivado run script, then execute its underlying Vivado Tcl
# directly.  This bypasses only the generated Windows Script Host wrapper,
# whose WMI status query is denied in this local automation session.  It does
# not alter the generated run Tcl, project run options, or synthesis command.
proc execute_run_headless {run_object} {
  launch_runs -scripts_only $run_object
  set run_dir [get_property DIRECTORY $run_object]
  set run_name [get_property NAME $run_object]
  set run_tcls [glob -nocomplain -types f [file join $run_dir *.tcl]]
  if {[llength $run_tcls] != 1} {
    error "Expected one generated run Tcl for $run_name, found: $run_tcls"
  }
  set run_tcl [lindex $run_tcls 0]
  set run_log [file join $run_dir runme.log]
  if {![info exists ::env(GQAV7_HOST_PROJECT_ROOT)]} {
    error "GQAV7_HOST_PROJECT_ROOT is required for headless run execution"
  }
  set host_workspace [file dirname $::env(GQAV7_HOST_PROJECT_ROOT)]
  if {![regexp {^([A-Za-z]:)} $run_dir unused_match mapped_drive]} {
    set mapped_drive ""
  }
  if {$mapped_drive eq "" || ![file isdirectory $host_workspace]} {
    error "Invalid headless mapped-drive context: drive=$mapped_drive workspace=$host_workspace"
  }
  set prior_dir [pwd]
  cd $run_dir
  # The parent build launcher already owns an exact subst mapping for this
  # workspace.  Reissuing `subst X: ...` in the child returns a nonzero
  # "drive already substituted" status on Windows, so the following `&&`
  # previously prevented Vivado from launching and left no runme.log.  Keep
  # the parent mapping and enter the generated run directory directly.
  # Use vivado.bat so synthesis helper processes inherit the complete Vivado
  # runtime environment.  The earlier failure came from sending a compound
  # `cd /d ... && vivado.bat ...` string through cmd.  Tcl has already changed
  # into run_dir, so pass the launcher and each argument separately instead.
  if {![info exists ::env(XILINX_VIVADO)]} {
    cd $prior_dir
    error "XILINX_VIVADO is unavailable in the parent Vivado environment"
  }
  set vivado_launcher [file normalize \
    [file join $::env(XILINX_VIVADO) bin vivado.bat]]
  if {![file isfile $vivado_launcher]} {
    cd $prior_dir
    error "Cannot locate Vivado launcher: $vivado_launcher"
  }
  # Endpoint scanning on this host can transiently make a Vivado installation
  # Tcl file unreadable to a newly spawned helper even though the file exists.
  # Retry the identical generated run before treating it as an RTL/build
  # failure.  A deterministic synthesis error will still fail all attempts.
  set run_succeeded 0
  set last_result ""
  for {set attempt 1} {$attempt <= 3} {incr attempt} {
    if {$attempt > 1} {
      puts "WARNING: retrying headless Vivado run $run_name ($attempt/3)"
      after [expr {3000 * $attempt}]
    }
    if {![catch {
      exec cmd.exe /d /c call [file nativename $vivado_launcher] \
        -log "${run_name}.vds" \
        -m64 \
        -product Vivado \
        -mode batch \
        -messageDb vivado.pb \
        -notrace \
        -source [file tail $run_tcl] \
        > $run_log 2>@1
    } last_result]} {
      set run_succeeded 1
      break
    }
  }
  if {!$run_succeeded} {
    cd $prior_dir
    error "Headless execution failed for $run_name: $last_result"
  }
  cd $prior_dir
  # The .vivado.end.rst marker is emitted by ISEWrap.js, not by the generated
  # run Tcl itself.  A direct child exits nonzero on run failure, so validate
  # the durable synthesis/implementation checkpoint instead of requiring a
  # wrapper-only status file.
  set run_checkpoints [glob -nocomplain -types f [file join $run_dir *.dcp]]
  if {[llength $run_checkpoints] == 0} {
    error "Headless execution produced no checkpoint for $run_name"
  }
  puts "PASS: headless Vivado run completed: $run_name"
}

proc require_clock_period {clock_name expected_period_ns tolerance_ns} {
  set clock_objects [get_clocks -quiet $clock_name]
  if {[llength $clock_objects] != 1} {
    error "Expected one implemented clock named $clock_name, found: $clock_objects"
  }
  set actual_period_ns [get_property PERIOD [lindex $clock_objects 0]]
  if {![string is double -strict $actual_period_ns]} {
    error "Clock $clock_name has a non-numeric PERIOD: $actual_period_ns"
  }
  if {[expr {abs(double($actual_period_ns) - double($expected_period_ns))}] >
      $tolerance_ns} {
    error [format \
      "Clock %s period mismatch: implemented %.6f ns, requested %.6f ns" \
      $clock_name $actual_period_ns $expected_period_ns]
  }
  return $actual_period_ns
}

proc require_bd_frequency {bd_object expected_hz description} {
  if {[llength $bd_object] != 1} {
    error "Expected one $description, found: $bd_object"
  }
  set actual_hz ""
  foreach property_name {CONFIG.FREQ_HZ FREQ_HZ} {
    if {![catch {get_property $property_name $bd_object} candidate] &&
        $candidate ne ""} {
      set actual_hz $candidate
      break
    }
  }
  if {![string is double -strict $actual_hz]} {
    error "$description has no numeric FREQ_HZ property: $actual_hz"
  }
  if {[expr {round(double($actual_hz))}] != $expected_hz} {
    error "$description frequency mismatch: BD=$actual_hz Hz expected=$expected_hz Hz"
  }
}

proc collect_filelist_sources {project_root filelist_path visited_name} {
  upvar $visited_name visited
  set normalized [file normalize $filelist_path]
  if {[info exists visited($normalized)]} {
    return {}
  }
  set visited($normalized) 1
  if {![file isfile $normalized]} {
    error "RTL filelist does not exist: $normalized"
  }
  if {[catch {set handle [open $normalized r]} open_error]} {
    error "Unable to open RTL filelist '$normalized': $open_error"
  }
  set content [read $handle]
  close $handle
  set sources {}
  foreach raw_line [split $content "\n"] {
    set line [string trim [lindex [split $raw_line "#"] 0]]
    if {$line eq ""} {
      continue
    }
    set tokens [regexp -all -inline {\S+} $line]
    if {[lindex $tokens 0] eq "-f"} {
      set child [file normalize \
        [file join $project_root [lindex $tokens 1]]]
      set sources [concat $sources \
        [collect_filelist_sources $project_root $child visited]]
    } else {
      set source [file normalize [file join $project_root $line]]
      if {![file isfile $source]} {
        error "RTL source does not exist: $source"
      }
      lappend sources $source
    }
  }
  return $sources
}

set project_file [file normalize $::env(GQAV7_Z19P_PROJECT_FILE)]
set output_dir [file normalize $::env(GQAV7_Z19P_OUTPUT_DIR)]
set core_frequency_mhz 235.0
set dma_frequency_mhz 300.0
if {[info exists ::env(GQAV7_CORE_FREQUENCY_MHZ)]} {
  set core_frequency_mhz $::env(GQAV7_CORE_FREQUENCY_MHZ)
}
if {[info exists ::env(GQAV7_DMA_FREQUENCY_MHZ)]} {
  set dma_frequency_mhz $::env(GQAV7_DMA_FREQUENCY_MHZ)
}
foreach {frequency_name frequency_value} [list \
    GQAV7_CORE_FREQUENCY_MHZ $core_frequency_mhz \
    GQAV7_DMA_FREQUENCY_MHZ $dma_frequency_mhz] {
  if {![string is double -strict $frequency_value] ||
      $frequency_value <= 0.0} {
    error "$frequency_name must be a positive number"
  }
}
set core_period_ns [expr {1000.0 / double($core_frequency_mhz)}]
set dma_period_ns [expr {1000.0 / double($dma_frequency_mhz)}]
if {![file isfile $project_file]} {
  error "Z19-P project does not exist: $project_file"
}
if {[file exists $output_dir]} {
  error "Refusing to overwrite existing hardware output: $output_dir"
}
file mkdir $output_dir
set report_dir [file join $output_dir reports]
file mkdir $report_dir

open_project $project_file
set bd_files [get_files -quiet */gqav7_z19p_system.bd]
if {[llength $bd_files] != 1} {
  error "Expected one gqav7_z19p_system.bd, found: $bd_files"
}
open_bd_design [lindex $bd_files 0]
# A cloned board project retains the prior release's module-reference clock
# metadata even when the external clock RTL has changed.  Refresh the module
# reference by instance name (the command accepts module-reference names/IPs,
# not bd_cell objects), then validate to propagate the new clock identity.
set project_root [file normalize [file join $script_dir ../../..]]
set current_clock_source [file normalize \
  [file join $project_root rtl/DDR/gqav7_pl_diff_clock_buffer.v]]
add_files -fileset sources_1 -norecurse $current_clock_source
update_compile_order -fileset sources_1
set expected_core_hz [expr {round(double($core_frequency_mhz) * 1000000.0)}]
set expected_dma_hz [expr {round(double($dma_frequency_mhz) * 1000000.0)}]
set reuse_module_outputs [info exists ::env(GQAV7_Z19P_REUSE_ACCELERATOR)]
if {!$reuse_module_outputs} {
  set refreshed_module_ips [concat \
    [get_ips -all -quiet *pl_clock_buffer*] \
    [get_ips -all -quiet *gqav7_accelerator*]]
  if {[llength $refreshed_module_ips] != 2} {
    error "Expected clock and accelerator module-reference IPs, found: $refreshed_module_ips"
  }
  update_module_reference $refreshed_module_ips
} else {
  puts "Reusing validated module-reference metadata and accelerator OOC DCP"
}
validate_bd_design
save_bd_design
# Refreshing a module reference invalidates and removes its previous OOC run.
# IPI-owned module references cannot be passed directly to create_ip_run;
# regenerate the block-design targets and recreate its child runs through the
# BD file object, matching the proven project-creation flow.
if {!$reuse_module_outputs} {
  set release_bd_file [lindex $bd_files 0]
  generate_target all $release_bd_file
  create_ip_run -force $release_bd_file
}
require_bd_frequency [get_bd_pins -quiet pl_clock_buffer/clk_fabric_o] \
  $expected_core_hz "core clock-buffer output pin"
require_bd_frequency [get_bd_pins -quiet gqav7_accelerator_0/aclk] \
  $expected_core_hz "accelerator core clock pin"
require_bd_frequency \
  [get_bd_intf_pins -quiet gqav7_accelerator_0/S_AXI_CONTROL] \
  $expected_core_hz "accelerator AXI-Lite interface"
require_bd_frequency [get_bd_pins -quiet pl_clock_buffer/clk_dma_o] \
  $expected_dma_hz "DMA clock-buffer output pin"
require_bd_frequency [get_bd_pins -quiet gqav7_accelerator_0/dma_aclk] \
  $expected_dma_hz "accelerator DMA clock pin"
if {[llength [get_bd_cells -quiet reset_core_235m]] != 1 ||
    [llength [get_bd_cells -quiet reset_core_238m]] != 0 ||
    [llength [get_bd_cells -quiet reset_core_240m]] != 0} {
  error "The release BD must contain reset_core_235m and no legacy core reset"
}
# Delivery cleanup deliberately removes macOS AppleDouble sidecars such as
# `._exp2_neg_bf16_lut_2048.mem`.  Older managed-project snapshots may still
# retain those non-source files in sources_1, and Vivado then aborts every OOC
# run before reading the real ROM image.  Purge only AppleDouble entries here;
# the actual `.mem` files remain in the refreshed V7 filelist below.
set stale_appledouble_files {}
foreach project_file_object [get_files -quiet] {
  set project_file_name [get_property NAME $project_file_object]
  if {[string match "._*" [file tail $project_file_name]]} {
    lappend stale_appledouble_files $project_file_object
  }
}
if {[llength $stale_appledouble_files] > 0} {
  puts "Removing stale AppleDouble project entries: $stale_appledouble_files"
  remove_files -quiet $stale_appledouble_files
}
# A board project cloned from a proven release intentionally preserves the
# generated MIG/SmartConnect products.  Refresh its external RTL file set from
# the current V7 filelists before resetting the accelerator OOC run so newly
# added iterative modules cannot be omitted by an older .xpr.
array set visited {}
set current_rtl_sources [concat \
  [collect_filelist_sources $project_root \
    [file join $project_root rtl/filelist/GQAv7.f] visited] \
  [collect_filelist_sources $project_root \
    [file join $project_root rtl/filelist/GQAv7_z19p.f] visited]]
add_files -fileset sources_1 -norecurse $current_rtl_sources
foreach current_rtl_source $current_rtl_sources {
  if {[string equal -nocase [file extension $current_rtl_source] ".sv"]} {
    set current_rtl_object [get_files -quiet $current_rtl_source]
    if {[llength $current_rtl_object] == 1} {
      set_property file_type SystemVerilog $current_rtl_object
    }
  }
}
set_property verilog_define {
  GQAV7_QK_PRODUCTION GQAV7_PV_PRODUCTION
  GQAV7_OUTPUT_UPDATE_PRODUCTION GQAV7_OUTPUT_NORMALIZE_PRODUCTION
  GQAV7_SCORE_SIDECAR_PRODUCTION
  GQAV72_LOGICAL_8X8_PRODUCTION
} [get_filesets sources_1]
update_compile_order -fileset sources_1
set reset_cdc_xdc [file normalize \
  [file join $script_dir ../constraints/z19p_reset_cdc.xdc]]
set reset_cdc_check [file normalize \
  [file join $script_dir check_z19p_reset_cdc.tcl]]
set reset_cdc_xdc_object [get_files -quiet $reset_cdc_xdc]
if {[llength $reset_cdc_xdc_object] == 0} {
  add_files -fileset constrs_1 -norecurse $reset_cdc_xdc
  set reset_cdc_xdc_object [get_files -quiet $reset_cdc_xdc]
}
set_property USED_IN_SYNTHESIS false $reset_cdc_xdc_object
set_property USED_IN_IMPLEMENTATION true $reset_cdc_xdc_object
set_property PROCESSING_ORDER LATE $reset_cdc_xdc_object
set_property STEPS.INIT_DESIGN.TCL.POST $reset_cdc_check [get_runs impl_1]
set jobs 4
if {[info exists ::env(VIVADO_JOBS)]} {
  set jobs $::env(VIVADO_JOBS)
}
if {![string is integer -strict $jobs] || $jobs < 1} {
  error "VIVADO_JOBS must be a positive integer"
}

# A release build must refresh the production accelerator module-reference.
# Resetting only top synthesis/implementation can otherwise reuse an old OOC
# checkpoint from the block design and produce a bitstream with stale RTL.
set accelerator_runs [get_runs -quiet *gqav7_accelerator*_synth_1]
if {[llength $accelerator_runs] != 1} {
  error "Expected one accelerator OOC synthesis run, found: $accelerator_runs"
}
set accelerator_run [lindex $accelerator_runs 0]
set clock_buffer_runs [get_runs -quiet *pl_clock_buffer*_synth_1]
if {[llength $clock_buffer_runs] != 1} {
  error "Expected one clock-buffer OOC synthesis run, found: $clock_buffer_runs"
}
set clock_buffer_run [lindex $clock_buffer_runs 0]
set reuse_synthesis [info exists ::env(GQAV7_Z19P_REUSE_SYNTHESIS)]
set reuse_accelerator [info exists ::env(GQAV7_Z19P_REUSE_ACCELERATOR)]
if {[info exists ::env(GQAV7_Z19P_ACCELERATOR_SYNTH_STRATEGY)]} {
  set accelerator_synth_strategy \
    $::env(GQAV7_Z19P_ACCELERATOR_SYNTH_STRATEGY)
  if {$accelerator_synth_strategy eq ""} {
    error "GQAV7_Z19P_ACCELERATOR_SYNTH_STRATEGY must not be empty"
  }
  set_property strategy $accelerator_synth_strategy $accelerator_run
  puts "Accelerator synthesis strategy: $accelerator_synth_strategy"
}
if {!$reuse_synthesis} {
  # Run both local module-reference OOC syntheses explicitly before top
  # synthesis.  This prevents Vivado from silently reusing an old clock-buffer
  # DCP after clock topology changes, and exposes Windows launcher failures
  # directly instead of leaving synth_1 waiting on a broken dependency.
  reset_run $clock_buffer_run
  reset_run synth_1
  set ooc_runs [list $clock_buffer_run]
  if {!$reuse_accelerator} {
    reset_run $accelerator_run
    lappend ooc_runs $accelerator_run
  }
  if {[headless_run_mode]} {
    # Execute OOC runs serially in this constrained desktop session.  This
    # limits peak memory and avoids the unavailable WMI status service.
    foreach ooc_run $ooc_runs {
      execute_run_headless $ooc_run
      if {$ooc_run eq $accelerator_run} {
        set accelerator_run_log [file join \
          [get_property DIRECTORY $accelerator_run] runme.log]
        if {[file isfile $accelerator_run_log]} {
          set accelerator_log_handle [open $accelerator_run_log r]
          set accelerator_log_text [read $accelerator_log_handle]
          close $accelerator_log_handle
          if {[string first "Netlist 29-358" $accelerator_log_text] >= 0} {
            error "Accelerator OOC contains untimed asynchronous set/reset registers"
          }
        }
      }
    }

    # synth_1 consumes DCPs from every block-design IP.  launch_runs normally
    # schedules these dependencies automatically, while -scripts_only does
    # not.  Generate them explicitly in dependency order before the top run;
    # otherwise a fresh project fails immediately on the first missing PS or
    # DDR DCP even though the accelerator OOC synthesis itself completed.
    set headless_ip_run_patterns {
      *zynq_ultra_ps_e*_synth_1
      *reset_core*_synth_1
      *reset_dma*_synth_1
      *control_smartconnect*_synth_1
      *data_smartconnect*_synth_1
      *data_reset_gate*_synth_1
      *ps_pl_ddr_rebase*_synth_1
      ddr4_controller_synth_1
      ddr_clock_converter_synth_1
      *pl_ddr4*_synth_1
    }
    foreach run_pattern $headless_ip_run_patterns {
      set matched_runs [get_runs -quiet $run_pattern]
      foreach dependency_run $matched_runs {
        if {$dependency_run eq $accelerator_run ||
            $dependency_run eq $clock_buffer_run ||
            $dependency_run eq [get_runs synth_1]} {
          continue
        }
        set dependency_status [get_property STATUS $dependency_run]
        if {![string match "*Complete*" $dependency_status]} {
          reset_run $dependency_run
          execute_run_headless $dependency_run
        }
      }
    }
    execute_run_headless [get_runs synth_1]
  } else {
    launch_runs $ooc_runs -jobs $jobs
    wait_on_run $clock_buffer_run
    set clock_buffer_status [get_property STATUS $clock_buffer_run]
    if {![string match "*Complete*" $clock_buffer_status]} {
      error "Clock-buffer OOC synthesis did not complete: $clock_buffer_status"
    }
    if {!$reuse_accelerator} {
      wait_on_run $accelerator_run
    }
    set accelerator_status [get_property STATUS $accelerator_run]
    if {![string match "*Complete*" $accelerator_status]} {
      error "Accelerator OOC synthesis did not complete: $accelerator_status"
    }
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
  }
}
if {![headless_run_mode]} {
  set synth_status [get_property STATUS [get_runs synth_1]]
  if {![string match "*Complete*" $synth_status]} {
    error "Synthesis did not complete: $synth_status"
  }
}

# Vivado 2024.2 leaves a module-reference block as a black box in the top
# synthesis DCP.  Explicitly attach the freshly generated accelerator OOC DCP
# to its BD cell before implementation; otherwise link_design reports INBB-3.
set accelerator_run_dir [get_property DIRECTORY $accelerator_run]
set accelerator_dcps [glob -nocomplain -types f \
  [file join $accelerator_run_dir *.dcp]]
if {[llength $accelerator_dcps] != 1} {
  error "Expected one accelerator OOC DCP, found: $accelerator_dcps"
}
set accelerator_dcp [lindex $accelerator_dcps 0]
set accelerator_dcp_object [get_files -quiet $accelerator_dcp]
if {[llength $accelerator_dcp_object] == 0} {
  add_files -fileset sources_1 -norecurse $accelerator_dcp
  set accelerator_dcp_object [get_files -quiet $accelerator_dcp]
}
set_property USED_IN_SYNTHESIS false $accelerator_dcp_object
set_property USED_IN_IMPLEMENTATION true $accelerator_dcp_object
set_property SCOPED_TO_CELLS \
  {gqav7_z19p_system_i/gqav7_accelerator_0} $accelerator_dcp_object

if {[info exists ::env(GQAV7_Z19P_IMPL_STRATEGY)]} {
  set impl_strategy $::env(GQAV7_Z19P_IMPL_STRATEGY)
  if {$impl_strategy eq ""} {
    error "GQAV7_Z19P_IMPL_STRATEGY must not be empty"
  }
  set_property strategy $impl_strategy [get_runs impl_1]
  puts "Implementation strategy: $impl_strategy"
}

# Vivado 2024.2 has repeatedly terminated without a Tcl error while running
# the standalone post-route phys_opt step on this design.  The router's own
# timing-driven physical optimization remains enabled, so allow release builds
# to keep the proven Explore/tns-cleanup route while skipping only that
# unstable extra step.  Require an explicit value to avoid silently changing
# the selected strategy.
if {[info exists ::env(GQAV7_Z19P_DISABLE_POST_ROUTE_PHYS_OPT)]} {
  if {$::env(GQAV7_Z19P_DISABLE_POST_ROUTE_PHYS_OPT) ne "YES"} {
    error "GQAV7_Z19P_DISABLE_POST_ROUTE_PHYS_OPT must be YES when set"
  }
  set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED false \
    [get_runs impl_1]
  puts "Standalone post-route phys_opt disabled; router timing optimization remains enabled"
}

# Applying a named strategy can replace step properties.  Re-attach the
# implementation-only reset/CDC topology gate after the strategy is selected.
set_property STEPS.INIT_DESIGN.TCL.POST $reset_cdc_check [get_runs impl_1]

reset_run impl_1
set implementation_strategy [property_or_na [get_runs impl_1] STRATEGY]
set accelerator_synthesis_strategy \
  [property_or_na $accelerator_run STRATEGY]
if {[headless_run_mode]} {
  execute_run_headless [get_runs impl_1]
} else {
  launch_runs impl_1 -to_step write_bitstream -jobs $jobs
  wait_on_run impl_1
  set impl_status [get_property STATUS [get_runs impl_1]]
  if {![string match "*Complete*" $impl_status]} {
    error "Implementation did not complete: $impl_status"
  }
}

if {[headless_run_mode]} {
  set impl_run_dir [get_property DIRECTORY [get_runs impl_1]]
  set impl_dcps [glob -nocomplain -types f [file join $impl_run_dir *_routed.dcp]]
  if {[llength $impl_dcps] != 1} {
    error "Expected one routed V7.1 DCP, found: $impl_dcps"
  }
  open_checkpoint [lindex $impl_dcps 0]
} else {
  open_run impl_1
}
set actual_core_period_ns \
  [require_clock_period clk_core_235_unbuf $core_period_ns 0.002]
set actual_dma_period_ns \
  [require_clock_period clk_dma_300_unbuf $dma_period_ns 0.002]
report_drc -file [file join $report_dir report_drc.rpt]
report_clocks -file [file join $report_dir report_clocks.rpt]
report_cdc -details -file [file join $report_dir report_cdc.rpt]
report_clock_interaction -file [file join $report_dir report_clock_interaction.rpt]
report_bus_skew -file [file join $report_dir report_bus_skew.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir report_timing_summary.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_setup_top10.rpt]
report_timing -delay_type max -max_paths 100 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_setup_top100.rpt]
report_timing -delay_type min -max_paths 10 -nworst 1 -path_type full \
  -file [file join $report_dir report_timing_hold_top10.rpt]
set utilization_report [file join $report_dir report_utilization.rpt]
set route_status_report [file join $report_dir report_route_status.rpt]
report_utilization -hierarchical -file $utilization_report
report_route_status -file $route_status_report
report_high_fanout_nets -fanout_greater_than 64 -max_nets 100 \
  -file [file join $report_dir report_high_fanout_nets.rpt]
report_design_analysis -congestion \
  -file [file join $report_dir report_congestion.rpt]

set timing_paths [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
set wns "NA"
set tns [property_or_na [get_clocks -quiet] TNS]
set datapath_delay "NA"
set logic_delay "NA"
set route_delay "NA"
set route_ratio "NA"
if {[llength $timing_paths] > 0} {
  set worst_path [lindex $timing_paths 0]
  set wns [property_or_na $worst_path SLACK]
  set datapath_delay [property_or_na $worst_path DATAPATH_DELAY]
  set logic_delay [property_or_na $worst_path DATAPATH_LOGIC_DELAY]
  set route_delay [property_or_na $worst_path DATAPATH_NET_DELAY]
  if {$datapath_delay ne "NA" && $route_delay ne "NA" &&
      [string is double -strict $datapath_delay] &&
      [string is double -strict $route_delay] && $datapath_delay > 0.0} {
    set route_ratio [expr {100.0 * $route_delay / $datapath_delay}]
  }
}

set hold_paths [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
set whs "NA"
set ths [property_or_na [get_clocks -quiet] THS]
if {[llength $hold_paths] > 0} {
  set whs [property_or_na [lindex $hold_paths 0] SLACK]
}

set max_nonclock_fanout 0
set max_nonclock_fanout_net "NONE"
set max_nonclock_fanout_driver "NONE"
foreach net_object [get_nets -hierarchical -quiet -filter {FLAT_PIN_COUNT > 64}] {
  set net_name [get_property NAME $net_object]
  set net_parent [property_or_na $net_object PARENT]
  # Vivado may place a constant below an arbitrary hierarchy and may suffix
  # GND/VCC replicated nets.  Do not let those implementation-only nets
  # masquerade as a datapath broadcast in the machine-readable gate.
  if {[regexp -nocase {<const[01]>|(^|/)(GND|VCC)(_[0-9]+)?$|GLOBAL_LOGIC[01]} \
      $net_name]} {
    continue
  }
  if {[regexp -nocase {(clk|clock|rst|reset)} $net_name] ||
      [regexp -nocase {(clk|clock|rst|reset)} $net_parent]} {
    continue
  }
  set flat_pin_count [get_property FLAT_PIN_COUNT $net_object]
  if {$flat_pin_count > $max_nonclock_fanout} {
    set max_nonclock_fanout $flat_pin_count
    set max_nonclock_fanout_net $net_name
    set driver_pins [get_pins -quiet -of_objects $net_object \
      -filter {DIRECTION == OUT}]
    if {[llength $driver_pins] > 0} {
      set driver_cell [get_cells -quiet -of_objects [lindex $driver_pins 0]]
      set max_nonclock_fanout_driver \
        [property_or_na $driver_cell REF_NAME]
    } else {
      set max_nonclock_fanout_driver "UNKNOWN"
    }
  }
}

set drc_error_count 0
foreach violation [get_drc_violations -quiet] {
  if {[string toupper [get_property SEVERITY $violation]] eq "ERROR"} {
    incr drc_error_count
  }
}
set route_status "NA"
set route_report_handle [open $route_status_report r]
set route_report_text [read $route_report_handle]
close $route_report_handle
if {[regexp -nocase {\|[ \t]*Design State[ \t]*:[ \t]*Routed} \
    $route_report_text] &&
    [regexp {# of nets with routing errors\.+[ \t]*:[ \t]*0[ \t]*:} \
    $route_report_text]} {
  set route_status "ROUTED"
}

set total_luts "NA"
set logic_luts "NA"
set lutrams "NA"
set srls "NA"
set total_ffs "NA"
set total_ramb36 "NA"
set total_ramb18 "NA"
set total_uram "NA"
set total_dsps "NA"
set utilization_handle [open $utilization_report r]
set utilization_text [read $utilization_handle]
close $utilization_handle
set top_row_pattern [format \
  {\|[ \t]*%s[ \t]*\|[ \t]*\(top\)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|[ \t]*([0-9]+)[ \t]*\|} \
  "gqav7_z19p_system_wrapper"]
regexp $top_row_pattern $utilization_text unused_match \
  total_luts logic_luts lutrams srls total_ffs total_ramb36 total_ramb18 \
  total_uram total_dsps

set metrics_handle [open [file join $report_dir physical_metrics.kv] w]
puts $metrics_handle "TOP=gqav7_z19p_system_wrapper"
puts $metrics_handle "PART=xczu19eg-ffvc1760-2-i"
puts $metrics_handle "CORE_FREQUENCY_MHZ=$core_frequency_mhz"
puts $metrics_handle \
  [format "CORE_PERIOD_NS=%.6f" $core_period_ns]
puts $metrics_handle \
  [format "IMPLEMENTED_CORE_PERIOD_NS=%.6f" $actual_core_period_ns]
puts $metrics_handle "DMA_FREQUENCY_MHZ=$dma_frequency_mhz"
puts $metrics_handle \
  [format "DMA_PERIOD_NS=%.6f" $dma_period_ns]
puts $metrics_handle \
  [format "IMPLEMENTED_DMA_PERIOD_NS=%.6f" $actual_dma_period_ns]
puts $metrics_handle \
  "ACCELERATOR_SYNTHESIS_STRATEGY=$accelerator_synthesis_strategy"
puts $metrics_handle "IMPLEMENTATION_STRATEGY=$implementation_strategy"
puts $metrics_handle "FREQUENCY_MHZ=$core_frequency_mhz"
puts $metrics_handle [format "PERIOD_NS=%.6f" $core_period_ns]
puts $metrics_handle "WNS_NS=$wns"
puts $metrics_handle "TNS_NS=$tns"
puts $metrics_handle "WHS_NS=$whs"
puts $metrics_handle "THS_NS=$ths"
puts $metrics_handle "DATAPATH_DELAY_NS=$datapath_delay"
puts $metrics_handle "LOGIC_DELAY_NS=$logic_delay"
puts $metrics_handle "ROUTE_DELAY_NS=$route_delay"
puts $metrics_handle "ROUTE_RATIO_PERCENT=$route_ratio"
puts $metrics_handle "MAX_NONCLOCK_FANOUT=$max_nonclock_fanout"
puts $metrics_handle "MAX_NONCLOCK_FANOUT_NET=$max_nonclock_fanout_net"
puts $metrics_handle "MAX_NONCLOCK_FANOUT_DRIVER=$max_nonclock_fanout_driver"
puts $metrics_handle "TOTAL_LUTS=$total_luts"
puts $metrics_handle "LOGIC_LUTS=$logic_luts"
puts $metrics_handle "LUTRAMS=$lutrams"
puts $metrics_handle "SRLS=$srls"
puts $metrics_handle "TOTAL_FFS=$total_ffs"
puts $metrics_handle "TOTAL_RAMB36=$total_ramb36"
puts $metrics_handle "TOTAL_RAMB18=$total_ramb18"
puts $metrics_handle "TOTAL_URAM=$total_uram"
puts $metrics_handle "TOTAL_DSPS=$total_dsps"
puts $metrics_handle "LOGIC_LUT_PRIMITIVES=[cell_count {REF_NAME =~ LUT*}]"
puts $metrics_handle "FF_PRIMITIVES=[cell_count {REF_NAME =~ FD*}]"
puts $metrics_handle "DSP48_PRIMITIVES=[cell_count {REF_NAME =~ DSP48*}]"
puts $metrics_handle "RAMB36_PRIMITIVES=[cell_count {REF_NAME =~ RAMB36*}]"
puts $metrics_handle "RAMB18_PRIMITIVES=[cell_count {REF_NAME =~ RAMB18*}]"
puts $metrics_handle "URAM_PRIMITIVES=[cell_count {REF_NAME =~ URAM*}]"
puts $metrics_handle "DRC_ERROR_COUNT=$drc_error_count"
puts $metrics_handle "ROUTE_STATUS=$route_status"
close $metrics_handle

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == "Error"}]
if {[llength $drc_errors] != 0} {
  error "Implementation has [llength $drc_errors] DRC errors"
}
set failing_path [get_timing_paths -quiet -slack_lesser_than 0 -max_paths 1]
if {[llength $failing_path] != 0} {
  error "Timing is not met; WNS=[get_property SLACK [lindex $failing_path 0]] ns"
}
set failing_hold_path [get_timing_paths -quiet -delay_type min \
  -slack_lesser_than 0 -max_paths 1]
if {[llength $failing_hold_path] != 0} {
  error "Hold timing is not met; WHS=[get_property SLACK \
    [lindex $failing_hold_path 0]] ns"
}

if {[headless_run_mode]} {
  set impl_dir $impl_run_dir
} else {
  set impl_dir [get_property DIRECTORY [get_runs impl_1]]
}
set bit_files [glob -nocomplain -types f [file join $impl_dir *.bit]]
if {[headless_run_mode] && [llength $bit_files] == 0} {
  # A scripts-only implementation run stops after route_design unless the
  # generated wrapper is launched with an explicit write_bitstream target.
  # The routed checkpoint is already open and has passed DRC/setup/hold gates,
  # so produce the release bitstream directly without repeating implementation.
  set generated_bit [file join $impl_dir gqav7_z19p_system_wrapper.bit]
  write_bitstream -force $generated_bit
  set bit_files [glob -nocomplain -types f [file join $impl_dir *.bit]]
}
if {[llength $bit_files] != 1} {
  error "Expected one implementation bitstream, found: $bit_files"
}
set xsa_file [file join $output_dir GQAv7_z19p.xsa]
write_hw_platform -fixed -include_bit -file $xsa_file
file copy [lindex $bit_files 0] [file join $output_dir GQAv7_z19p.bit]
close_project

puts "PASS: GQAv7 Z19-P bitstream and XSA satisfy DRC/timing gates"
puts "Hardware output: $output_dir"
