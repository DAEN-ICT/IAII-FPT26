# Open a generated FPGAtten project and validate its 2025.2 identity, IP state,
# block design, clocks and externally visible address map.
#
# Usage:
#   vivado -mode batch -source validate_project_2025_2.tcl \
#     -tclargs <FPGAtten_z19p.xpr>

if {$argc != 1} {
  error "Usage: validate_project_2025_2.tcl <FPGAtten_z19p.xpr>"
}
if {[version -short] ne "2025.2"} {
  error "This validation requires Vivado 2025.2, running [version -short]"
}

proc require_one {objects description} {
  if {[llength $objects] != 1} {
    error "Expected one $description, found: $objects"
  }
  return [lindex $objects 0]
}

proc numeric_value {value} {
  if {[regexp -nocase {^([0-9]+)([KMG])$} $value unused amount suffix]} {
    array set scale {K 1024 M 1048576 G 1073741824}
    return [expr {wide($amount) * $scale([string toupper $suffix])}]
  }
  return [expr {wide($value)}]
}

proc require_numeric_property {object property expected description} {
  set actual [get_property $property $object]
  if {[catch {set actual_number [numeric_value $actual]}] ||
      $actual_number != $expected} {
    error "$description mismatch: actual=$actual expected=$expected"
  }
  puts "FPGATTEN_2025_2_CHECK description=$description actual=$actual"
}

proc require_frequency {object expected description} {
  foreach property {CONFIG.FREQ_HZ FREQ_HZ} {
    if {![catch {set actual [get_property $property $object]}] &&
        $actual ne ""} {
      if {[numeric_value $actual] != $expected} {
        error "$description mismatch: actual=$actual expected=$expected"
      }
      puts "FPGATTEN_2025_2_CHECK description=$description actual=$actual"
      return
    }
  }
  error "$description has no FREQ_HZ property"
}

set project_file [file normalize [lindex $argv 0]]
if {![file isfile $project_file]} {
  error "Project does not exist: $project_file"
}
open_project $project_file
if {[get_property PART [current_project]] ne "xczu19eg-ffvc1760-2-i"} {
  error "Unexpected project part: [get_property PART [current_project]]"
}
update_ip_catalog
set locked_ips [get_ips -quiet -filter {IS_LOCKED == 1}]
if {[llength $locked_ips] != 0} {
  error "Project contains locked IPs: $locked_ips"
}
foreach project_ip [get_ips -quiet] {
  puts "FPGATTEN_2025_2_PROJECT_IP name=[get_property NAME $project_ip] ipdef=[get_property IPDEF $project_ip] locked=[get_property IS_LOCKED $project_ip]"
}

set bd_file [require_one [get_files -quiet */gqav7_z19p_system.bd] \
  "FPGAtten block design"]
open_bd_design $bd_file
validate_bd_design

require_frequency \
  [require_one [get_bd_pins -quiet pl_clock_buffer/clk_fabric_o] \
    "core clock pin"] 235000000 "core clock frequency"
require_frequency \
  [require_one [get_bd_pins -quiet pl_clock_buffer/clk_dma_o] \
    "DMA clock pin"] 300000000 "DMA clock frequency"

foreach {segment_pattern expected_offset expected_range description} {
  *SEG_GQAV7_CSR            0xA0010000 0x00001000 "CSR"
  *SEG_PS_PL_DDR_WINDOW     0xB0000000 0x10000000 "PS PL-DDR window"
  *SEG_GQAV7_PL_DDR         0x00000000 0x80000000 "accelerator PL-DDR"
  *SEG_GQAV7_V_PL_DDR       0x00000000 0x80000000 "accelerator V PL-DDR"
} {
  set segment [require_one [get_bd_addr_segs -quiet -filter \
    "NAME =~ $segment_pattern"] "$description address segment"]
  require_numeric_property $segment OFFSET [expr {$expected_offset}] \
    "$description offset"
  require_numeric_property $segment RANGE [expr {$expected_range}] \
    "$description range"
}

puts "FPGATTEN_2025_2_PROJECT=[file normalize $project_file]"
puts "FPGATTEN_2025_2_PROJECT_VALIDATION_PASS=1"
close_project
exit
