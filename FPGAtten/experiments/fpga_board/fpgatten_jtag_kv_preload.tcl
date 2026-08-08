# JTAG PL-DDR K/V preload transport for verified real-Llama3 Decode payloads.
#
# This Tcl file receives a host-generated TSV list through
# GQAV7_JTAG_KV_SEGMENTS_FILE.  It only writes the listed K/V head segments,
# then captures a binary readback for each.  The PowerShell caller performs
# bytewise and SHA-256 verification of those readbacks after XSDB exits.

foreach required [list GQAV7_JTAG_KV_SEGMENTS_FILE GQAV7_JTAG_KV_RUN_ID] {
    if {![info exists ::env($required)] || $::env($required) eq ""} {
        error "missing required environment variable $required"
    }
}

set segment_list [file normalize $::env(GQAV7_JTAG_KV_SEGMENTS_FILE)]
if {![file exists $segment_list]} {
    error "segment list does not exist: $segment_list"
}

set handle [open $segment_list rb]
try {
    fconfigure $handle -translation binary -encoding utf-8
    set lines [split [read $handle] "\n"]
} finally {
    close $handle
}

connect -url TCP:localhost:3121
# The APU DAP target applies physical accesses to PL-DDR; do not select a
# Cortex-A53 target, which would otherwise use the Linux virtual-address MMU.
targets -set -nocase -filter {name =~ "*APU"}
configparams force-mem-accesses 1
memmap -addr 0xB0000000 -size 0x10000000 -flags 3
puts "GQAV7_JTAG_KV_TARGET=[targets]"
puts "GQAV7_JTAG_KV_MEMMAP=0xB0000000/0x10000000"

set completed 0
foreach line $lines {
    set line [string trim $line "\r"]
    if {$line eq ""} {
        continue
    }
    set fields [split $line "\t"]
    if {[llength $fields] != 6} {
        error "invalid segment list row: expected 6 tab-delimited fields, got [llength $fields]"
    }
    lassign $fields source readback address words kind head
    set source [file normalize $source]
    set readback [file normalize $readback]
    if {![file exists $source]} {
        error "segment source does not exist: $source"
    }
    if {![string is integer -strict $words] || $words <= 0} {
        error "segment word count is invalid: $words"
    }
    set expected_bytes [expr {$words * 4}]
    if {[file size $source] != $expected_bytes} {
        error "segment source size mismatch for $source"
    }
    file mkdir [file dirname $readback]
    puts "GQAV7_JTAG_KV_WRITE kind=$kind head=$head address=$address bytes=$expected_bytes"
    if {[catch {mwr -bin -file $source $address $words} detail]} {
        error "mwr failed for kind=$kind head=$head address=$address: $detail"
    }
    if {[catch {mrd -bin -file $readback $address $words} detail]} {
        error "mrd failed for kind=$kind head=$head address=$address: $detail"
    }
    if {![file exists $readback] || [file size $readback] != $expected_bytes} {
        error "mrd readback size mismatch for kind=$kind head=$head"
    }
    puts "GQAV7_JTAG_KV_READBACK kind=$kind head=$head address=$address bytes=$expected_bytes file=$readback"
    incr completed
}

if {$completed != 16} {
    error "expected 16 K/V head segments, completed $completed"
}
puts "GQAV7_JTAG_KV_PRELOAD_TCL_PASS run_id=$::env(GQAV7_JTAG_KV_RUN_ID) segments=$completed"
exit
