if {![info exists ::env(FPGATTEN_JTAG_STAGING_ROOT)] ||
    $::env(FPGATTEN_JTAG_STAGING_ROOT) eq ""} {
    error "FPGATTEN_JTAG_STAGING_ROOT is not set"
}

set staging_root [file normalize $::env(FPGATTEN_JTAG_STAGING_ROOT)]
set image_root "${staging_root}/images"
set hardware_root "${staging_root}/hw"
puts stderr "FPGATTEN_JTAG_STAGING_ROOT=${staging_root}"

foreach required_file [list \
    "${image_root}/system.bit" \
    "${image_root}/pmufw.elf" \
    "${image_root}/zynqmp_fsbl.elf" \
    "${image_root}/system.dtb" \
    "${image_root}/u-boot.elf" \
    "${image_root}/Image" \
    "${image_root}/rootfs.cpio.gz.u-boot" \
    "${image_root}/boot.scr" \
    "${image_root}/bl31.elf" \
    "${hardware_root}/psu_init.tcl"] {
    if {![file isfile $required_file]} {
        error "Missing FPGAtten JTAG boot input: $required_file"
    }
}

connect -url TCP:localhost:3121
for {set retry 0} {$retry < 20} {incr retry} {
    if {[ta] ne ""} {
        break
    }
    after 50
}

puts stderr "FPGATTEN_JTAG_STAGE=SYSTEM_RESET"
targets -set -nocase -filter {name =~ "*PSU*"}
rst -system
after 3000

puts stderr "FPGATTEN_JTAG_STAGE=FPGA"
fpga "${image_root}/system.bit"

targets -set -nocase -filter {name =~ "*PSU*"}
mask_write 0xFFCA0038 0x1C0 0x1C0
targets -set -nocase -filter {name =~ "*MicroBlaze PMU*"}
if {[string first "Stopped" [state]] != 0} {
    stop
}

puts stderr "FPGATTEN_JTAG_STAGE=PMUFW"
dow "${image_root}/pmufw.elf"
con

targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor -clear-registers
source "${hardware_root}/psu_init.tcl"

puts stderr "FPGATTEN_JTAG_STAGE=FSBL"
dow "${image_root}/zynqmp_fsbl.elf"
con
after 3000
stop
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config

puts stderr "FPGATTEN_JTAG_STAGE=LINUX_IMAGES"
dow -data "${image_root}/system.dtb" 0x100000
dow "${image_root}/u-boot.elf"
dow -data "${image_root}/Image" 0x200000
dow -data "${image_root}/rootfs.cpio.gz.u-boot" 0x30000000
dow -data "${image_root}/boot.scr" 0x20000000

puts stderr "FPGATTEN_JTAG_STAGE=BOOT"
dow "${image_root}/bl31.elf"
con
puts stderr "FPGATTEN_JTAG_BOOT_DISPATCHED=1"
exit
