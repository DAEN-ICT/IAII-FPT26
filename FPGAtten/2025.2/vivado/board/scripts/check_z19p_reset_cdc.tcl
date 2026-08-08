# XDC files accept only the constraint-command subset of Tcl.  Keep the
# cardinality check in an implementation hook, after link_design has made the
# scoped PL-DDR synchronizer cells visible.
set ddr_reset_sync_clr_pins [get_pins -hierarchical -quiet -filter {
  REF_PIN_NAME == CLR && NAME =~ *sys_resetn_sync_reg*/CLR
}]
set ddr_reset_sync_clr_pin_count [llength $ddr_reset_sync_clr_pins]
if {$ddr_reset_sync_clr_pin_count != 2} {
  error "Expected two PL-DDR sys_resetn synchronizer CLR pins, found $ddr_reset_sync_clr_pin_count"
}
puts "PASS: constrained exactly two PL-DDR sys_resetn synchronizer CLR pins"

# Reapply the system-level asynchronous relationship after every scoped IP XDC
# has been parsed.  Vivado 2024.2 can otherwise retain paths into the first
# synchronizer stages even though the earlier clock-group XDC was accepted.
# These are the only core/DMA crossings and are implemented by asynchronous
# FIFOs or explicit two-flop synchronizers.
set core_pl_clocks [get_clocks -quiet -filter {
  NAME =~ clk_core_*_unbuf
}]
set dma_pl_clocks [get_clocks -quiet -filter {
  NAME =~ clk_dma_*_unbuf
}]
if {[llength $core_pl_clocks] != 1 ||
    [llength $dma_pl_clocks] != 1} {
  error "Expected exactly one core and one DMA PL clock in implementation hook"
}
set_clock_groups -asynchronous \
  -group $core_pl_clocks \
  -group $dma_pl_clocks
set_false_path -from $core_pl_clocks -to $dma_pl_clocks
set_false_path -from $dma_pl_clocks -to $core_pl_clocks

set accelerator_cdc_sync1_d_pins [get_pins -hierarchical -quiet -filter {
  REF_PIN_NAME == D &&
  NAME =~ *gqav7_accelerator_0*sync1_q_reg*/D
}]
set accelerator_cdc_sync1_d_pin_count \
  [llength $accelerator_cdc_sync1_d_pins]
if {$accelerator_cdc_sync1_d_pin_count == 0} {
  error "Expected accelerator CDC first-stage synchronizer D pins"
}
set_false_path -to $accelerator_cdc_sync1_d_pins
puts "PASS: constrained $accelerator_cdc_sync1_d_pin_count accelerator CDC first-stage D pins"

foreach direction {
  {core_to_dma $core_pl_clocks $dma_pl_clocks}
  {dma_to_core $dma_pl_clocks $core_pl_clocks}
} {
  lassign $direction direction_name source_clocks destination_clocks
  set direction_paths [get_timing_paths -quiet \
    -from $source_clocks -to $destination_clocks -max_paths 1]
  if {[llength $direction_paths] > 0} {
    set direction_exception \
      [get_property EXCEPTION [lindex $direction_paths 0]]
    if {$direction_exception ne "Asynchronous Clock Groups" &&
        $direction_exception ne "False Path"} {
      error "$direction_name is not protected by an asynchronous timing exception"
    }
  }
}
puts "PASS: core/DMA timing paths carry asynchronous exceptions in both directions"

# gqav5_async_fifo deliberately leaves the payload RAM unreset so Vivado can
# infer block RAM.  CLOCK_DOMAINS describes the actual primitive clock nets,
# not merely their frequency or timing-clock ancestry.  Only mark a RAM COMMON
# when both primitive pins are on the exact same logical net.  Separate core
# and DMA nets must remain INDEPENDENT across the 235/300 MHz domains.
set row_mover_cdc_rams [get_cells -hierarchical -quiet -filter {
  (REF_NAME == RAMB18E2 || REF_NAME == RAMB36E2) &&
  (NAME =~ *i_row_mover/i_*_cdc/memory_q_reg* ||
   NAME =~ *i_v_row_mover/i_*_cdc/memory_q_reg*)
}]
set row_mover_cdc_ram_count [llength $row_mover_cdc_rams]
if {$row_mover_cdc_ram_count == 0} {
  error "Expected inferred row-mover CDC block RAMs, found none"
}

set common_clock_ram_count 0
set independent_clock_ram_count 0
foreach ram_cell $row_mover_cdc_rams {
  set rd_pin [get_pins -quiet ${ram_cell}/CLKARDCLK]
  set wr_pin [get_pins -quiet ${ram_cell}/CLKBWRCLK]
  if {[llength $rd_pin] != 1 || [llength $wr_pin] != 1} {
    error "Expected one read and one write clock pin on $ram_cell"
  }

  set rd_nets [get_nets -quiet -of_objects $rd_pin]
  set wr_nets [get_nets -quiet -of_objects $wr_pin]
  if {[llength $rd_nets] != 1 || [llength $wr_nets] != 1} {
    error "Could not resolve one clock net per port for inferred CDC RAM $ram_cell"
  }

  if {$rd_nets eq $wr_nets} {
    set_property CLOCK_DOMAINS COMMON $ram_cell
    incr common_clock_ram_count
  } else {
    set_property CLOCK_DOMAINS INDEPENDENT $ram_cell
    incr independent_clock_ram_count
  }
}
puts "PASS: row-mover CDC RAM clock topology: common=$common_clock_ram_count independent=$independent_clock_ram_count"
