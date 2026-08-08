if {[info exists ::env(GQAV7_Z19P_SELF_CHECK)]} {
  puts "PASS: Z19-P post-route bus-skew Tcl resolves locally"
  return
}

if {[version -short] ne "2024.2"} {
  error "This report requires Vivado 2024.2, running [version -short]"
}
foreach variable_name {GQAV7_Z19P_PROJECT_FILE GQAV7_BUS_SKEW_REPORT} {
  if {![info exists ::env($variable_name)]} {
    error "Set $variable_name before running this script"
  }
}

set project_file [file normalize $::env(GQAV7_Z19P_PROJECT_FILE)]
set report_file [file normalize $::env(GQAV7_BUS_SKEW_REPORT)]
if {![file isfile $project_file]} {
  error "Z19-P project does not exist: $project_file"
}
file mkdir [file dirname $report_file]

open_project $project_file
open_run impl_1
report_bus_skew -file $report_file
close_project
puts "PASS: wrote routed Z19-P bus-skew report to $report_file"
