proc collect_filelist_sources {project_root filelist_path visited_name} {
  upvar $visited_name visited
  set normalized [file normalize $filelist_path]
  if {[info exists visited($normalized)]} {
    return {}
  }
  set visited($normalized) 1
  set handle [open $normalized r]
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
      set child [file normalize [file join $project_root [lindex $tokens 1]]]
      set sources [concat $sources \
        [collect_filelist_sources $project_root $child visited]]
    } else {
      lappend sources [file normalize [file join $project_root $line]]
    }
  }
  return $sources
}

set script_dir [file normalize [file dirname [info script]]]
set project_root [file normalize [file join $script_dir ../../..]]
if {[info exists ::env(GQAV7_Z19P_SELF_CHECK)]} {
  foreach required_path [list \
    [file join $project_root rtl/filelist/GQAv7.f] \
    [file join $project_root rtl/filelist/GQAv7_z19p.f] \
    [file join $project_root vivado/board/constraints/z19p_pl_ddr4_pins.xdc] \
    [file join $project_root vivado/board/constraints/z19p_reset_cdc.xdc] \
    [file join $project_root vivado/board/scripts/configure_z19p_mig.tcl] \
    [file join $project_root vivado/board/scripts/create_z19p_bd.tcl]] {
    if {![file isfile $required_path]} {
      error "Missing Z19-P project input: $required_path"
    }
  }
  puts "PASS: Z19-P project Tcl inputs resolve locally"
  return
}

if {[version -short] ne "2024.2"} {
  error "This project requires Vivado 2024.2, running [version -short]"
}

set project_dir [file join $project_root vivado project GQAv7_z19p]
if {[llength $argv] >= 1} {
  set project_dir [file normalize [lindex $argv 0]]
}

create_project -force GQAv7_z19p $project_dir -part xczu19eg-ffvc1760-2-i
puts "GQAv7: creating the Z19-P board project with 235 MHz core and 300 MHz DMA domains"
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set ip_dir [file join $project_root vivado board ip_sources]
foreach ip_name {clock ddr4_controller ddr_clock_converter} {
  set xci_file [file join $ip_dir ${ip_name}.xci]
  if {![file isfile $xci_file]} {
    error "Missing local Z19-P IP descriptor: $xci_file"
  }
  import_ip -files $xci_file -name $ip_name
}
update_ip_catalog

array set visited {}
set production_sources [collect_filelist_sources $project_root \
  [file join $project_root rtl/filelist/GQAv7.f] visited]
set board_sources [collect_filelist_sources $project_root \
  [file join $project_root rtl/filelist/GQAv7_z19p.f] visited]
add_files -fileset sources_1 -norecurse [concat $production_sources $board_sources]
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property verilog_define {
  GQAV7_QK_PRODUCTION GQAV7_PV_PRODUCTION
  GQAV7_OUTPUT_UPDATE_PRODUCTION GQAV7_OUTPUT_NORMALIZE_PRODUCTION
  GQAV7_SCORE_SIDECAR_PRODUCTION
  GQAV72_LOGICAL_8X8_PRODUCTION
} [get_filesets sources_1]

set memory_files [glob -nocomplain \
  [file join $project_root rtl OnlineSoftmax rom *.mem]]
if {[llength $memory_files] > 0} {
  add_files -fileset sources_1 -norecurse $memory_files
  set_property file_type {Memory File} [get_files -quiet *.mem]
}

set xdc_file [file join $project_root \
  vivado board constraints z19p_pl_ddr4_pins.xdc]
add_files -fileset constrs_1 -norecurse $xdc_file
set reset_cdc_xdc [file join $project_root \
  vivado board constraints z19p_reset_cdc.xdc]
add_files -fileset constrs_1 -norecurse $reset_cdc_xdc
set_property USED_IN_SYNTHESIS false [get_files $reset_cdc_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $reset_cdc_xdc]
# The generated core/DMA clock objects are created by the clock-buffer IP XDC.
# Process the CDC exceptions after those IP constraints so the frequency-
# independent clock selection in z19p_reset_cdc.xdc resolves deterministically.
set_property PROCESSING_ORDER LATE [get_files $reset_cdc_xdc]
update_compile_order -fileset sources_1

source [file join $project_root vivado/board/scripts/configure_z19p_mig.tcl]
source [file join $project_root vivado/board/scripts/create_z19p_bd.tcl]
# The project already lives at project_dir and Vivado persists project
# mutations as they are applied.  There is no zero-argument save_project
# command, while save_project_as back onto the active project is rejected.
close_project

puts "PASS: created manually openable GQAv7 Z19-P project"
puts "Project: [file join $project_dir GQAv7_z19p.xpr]"
