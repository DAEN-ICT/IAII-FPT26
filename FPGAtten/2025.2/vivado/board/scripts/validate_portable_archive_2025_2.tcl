# Verify that an extracted Vivado 2025.2 project no longer depends on the
# original build host for its implementation Tcl hook.
#
# Usage:
#   vivado -mode batch -source validate_portable_archive_2025_2.tcl \
#     -tclargs <FPGAtten_z19p.xpr>

if {$argc != 1} {
  error "Usage: validate_portable_archive_2025_2.tcl <FPGAtten_z19p.xpr>"
}
if {[version -short] ne "2025.2"} {
  error "This validation requires Vivado 2025.2, running [version -short]"
}

set project_file [file normalize [lindex $argv 0]]
if {![file isfile $project_file]} {
  error "Project does not exist: $project_file"
}
set extracted_root [file normalize [file dirname $project_file]]
open_project $project_file

set impl_run [get_runs -quiet impl_1]
if {[llength $impl_run] != 1} {
  error "Expected one impl_1 run, found: $impl_run"
}
set hook [get_property STEPS.INIT_DESIGN.TCL.POST $impl_run]
if {$hook eq ""} {
  error "impl_1 has no reset/CDC Tcl hook"
}
set normalized_hook [file normalize $hook]
if {![file isfile $normalized_hook]} {
  error "Archived impl_1 Tcl hook is missing: $normalized_hook"
}
set root_prefix "${extracted_root}/"
set normalized_hook_slash [string map {\\ /} $normalized_hook]
set root_prefix_slash [string map {\\ /} $root_prefix]
if {![string match -nocase "${root_prefix_slash}*" $normalized_hook_slash]} {
  error "Archived impl_1 Tcl hook still points outside the project: $normalized_hook"
}

puts "FPGATTEN_2025_2_ARCHIVED_HOOK=$normalized_hook"
puts "FPGATTEN_2025_2_PORTABLE_ARCHIVE_PASS=1"
close_project
exit
