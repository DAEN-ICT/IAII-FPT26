# Create a portable archive from a generated and validated Vivado 2025.2
# FPGAtten project.  Run results are included so the routed implementation can
# be inspected without repeating synthesis and implementation.
#
# Usage:
#   vivado -mode batch -source archive_project_2025_2.tcl \
#     -tclargs <FPGAtten_z19p.xpr> <archive.zip>

if {$argc != 2} {
  error "Usage: archive_project_2025_2.tcl <FPGAtten_z19p.xpr> <archive.zip>"
}
if {[version -short] ne "2025.2"} {
  error "This archive step requires Vivado 2025.2, running [version -short]"
}

set project_file [file normalize [lindex $argv 0]]
set archive_file [file normalize [lindex $argv 1]]
if {![file isfile $project_file]} {
  error "Project does not exist: $project_file"
}
file mkdir [file dirname $archive_file]

open_project $project_file
if {[get_property PART [current_project]] ne "xczu19eg-ffvc1760-2-i"} {
  error "Unexpected project part: [get_property PART [current_project]]"
}
set locked_ips [get_ips -quiet -filter {IS_LOCKED == 1}]
if {[llength $locked_ips] != 0} {
  error "Refusing to archive a project with locked IPs: $locked_ips"
}

set script_dir [file normalize [file dirname [info script]]]
set reset_cdc_check [file normalize \
  [file join $script_dir check_z19p_reset_cdc.tcl]]
if {![file isfile $reset_cdc_check]} {
  error "Missing implementation hook required by impl_1: $reset_cdc_check"
}
set reset_cdc_check_object [get_files -quiet $reset_cdc_check]
if {[llength $reset_cdc_check_object] == 0} {
  add_files -fileset utils_1 -norecurse $reset_cdc_check
  set reset_cdc_check_object [get_files -quiet $reset_cdc_check]
}
if {[llength $reset_cdc_check_object] != 1} {
  error "Expected one archived reset/CDC hook, found: $reset_cdc_check_object"
}
set_property STEPS.INIT_DESIGN.TCL.POST $reset_cdc_check [get_runs impl_1]

# Vivado 2025.2 includes completed run results by default; only the inverse
# -exclude_run_results switch exists in this release.
archive_project -force -include_config_settings $archive_file
if {![file isfile $archive_file]} {
  error "Vivado returned success but did not create archive: $archive_file"
}
puts "FPGATTEN_2025_2_PROJECT_ARCHIVE=$archive_file"
puts "FPGATTEN_2025_2_PROJECT_ARCHIVE_PASS=1"
close_project
exit
