#!/usr/bin/env bash
set -euo pipefail

RUNTIME=/mnt/c/Users/Lenovo/Desktop/FPT/FPGAtten/jtag_runtime
RELEASE=/mnt/c/Users/Lenovo/Desktop/FPT/FPGAtten/FPGAtten_PetaLinux_SD
PROJECT=/home/LUO/fpgatten_build/FPGAtten_Z19P
IMAGES="$RUNTIME/images"
HW="$RUNTIME/hw"
WORK=/home/LUO/fpgatten_build/fpgatten_jtag_rootfs_work
CPIO_GZ=/home/LUO/fpgatten_build/fpgatten_jtag_rootfs.cpio.gz
VERIFY_GZ=/home/LUO/fpgatten_build/fpgatten_jtag_verify.cpio.gz

case "$WORK" in
    /home/LUO/fpgatten_build/fpgatten_jtag_rootfs_work) ;;
    *) echo "unsafe work path: $WORK" >&2; exit 1 ;;
esac

cleanup()
{
    rm -rf -- "$WORK"
    rm -f -- "$CPIO_GZ"
    rm -f -- "$VERIFY_GZ"
}
trap cleanup EXIT

rm -rf -- "$WORK"
mkdir -p "$WORK" "$IMAGES" "$HW" "$RUNTIME/logs"

cp -f "$PROJECT/images/linux/system.bit" "$IMAGES/system.bit"
cp -f "$PROJECT/images/linux/pmufw.elf" "$IMAGES/pmufw.elf"
cp -f "$PROJECT/images/linux/zynqmp_fsbl.elf" "$IMAGES/zynqmp_fsbl.elf"
cp -f "$PROJECT/images/linux/u-boot.elf" "$IMAGES/u-boot.elf"
cp -f "$PROJECT/images/linux/bl31.elf" "$IMAGES/bl31.elf"
cp -f "$RELEASE/Image" "$IMAGES/Image"
cp -f "$PROJECT/project-spec/hw-description/psu_init.tcl" "$HW/psu_init.tcl"
mkimage -A arm64 -O linux -T script -C none \
    -n "FPGAtten JTAG boot" -d "$RUNTIME/boot_jtag.cmd" \
    "$IMAGES/boot.scr" >/dev/null

dtc -I dtb -O dts -o "$RUNTIME/system_jtag.dts" \
    "$RELEASE/system.dtb" 2> "$RUNTIME/logs/dtc_decode.log"
sed \
    's#root=/dev/mmcblk1p2 rootwait rw rootfstype=ext4#root=/dev/ram0 rw#' \
    "$RUNTIME/system_jtag.dts" > "$RUNTIME/system_jtag.updated.dts"
mv -f "$RUNTIME/system_jtag.updated.dts" "$RUNTIME/system_jtag.dts"
grep -Fq 'root=/dev/ram0 rw maxcpus=1' "$RUNTIME/system_jtag.dts" || {
    echo "failed to replace JTAG root bootargs" >&2
    exit 1
}
if grep -Fq 'root=/dev/mmcblk1p2' "$RUNTIME/system_jtag.dts"; then
    echo "SD root bootargs remain in JTAG device tree" >&2
    exit 1
fi
dtc -I dts -O dtb -o "$IMAGES/system.dtb" \
    "$RUNTIME/system_jtag.dts" 2> "$RUNTIME/logs/dtc_encode.log"

fakeroot -- bash -c '
    set -euo pipefail
    archive=$1
    root=$2
    output=$3
    tar --numeric-owner -xpf "$archive" -C "$root"
    ln -s /sbin/init "$root/init"
    cd "$root"
    find . -xdev -print0 | LC_ALL=C sort -z \
        | cpio --null -o --format=newc --owner=0:0 2>/dev/null \
        | gzip -9 > "$output"
' bash "$RELEASE/rootfs.tar.gz" "$WORK" "$CPIO_GZ"

mkimage -A arm64 -O linux -T ramdisk -C gzip \
    -n "FPGAtten initramfs" -d "$CPIO_GZ" \
    "$IMAGES/rootfs.cpio.gz.u-boot" >/dev/null

ramdisk_bytes=$(stat -c '%s' "$IMAGES/rootfs.cpio.gz.u-boot")
ramdisk_start=$((0x30000000))
ramdisk_end=$((ramdisk_start + ramdisk_bytes))
[ "$ramdisk_end" -lt $((0x40000000)) ] || {
    printf 'JTAG initramfs exceeds safe region: end=0x%x\n' "$ramdisk_end" >&2
    exit 1
}
printf 'JTAG_RAMDISK_START=0x%08x\n' "$ramdisk_start"
printf 'JTAG_RAMDISK_END=0x%08x\n' "$ramdisk_end"

dumpimage -T ramdisk -p 0 -o "$VERIFY_GZ" \
    "$IMAGES/rootfs.cpio.gz.u-boot" >/dev/null
gzip -dc "$VERIFY_GZ" \
    | cpio -t 2>/dev/null > "$RUNTIME/rootfs_file_list.txt"

grep -Fxq 'usr/bin/fpgatten-run' "$RUNTIME/rootfs_file_list.txt"
grep -Fxq 'usr/bin/fpgatten-replay' "$RUNTIME/rootfs_file_list.txt"
grep -Fxq 'init' "$RUNTIME/rootfs_file_list.txt"
if grep -Fxq 'usr/bin/fpgatten-sweep' "$RUNTIME/rootfs_file_list.txt"; then
    echo "rolled-back fpgatten-sweep unexpectedly present" >&2
    exit 1
fi

(
    cd "$RUNTIME"
    find images hw -type f -printf '%p\n' | LC_ALL=C sort | xargs sha256sum \
        > JTAG_SHA256SUMS
)

printf 'FPGATTEN_JTAG_RUNTIME_READY=1\n'
printf 'JTAG_ROOTFS=initramfs\n'
printf 'JTAG_BOOTARGS=root=/dev/ram0 rw\n'
printf 'JTAG_STAGING=%s\n' "$RUNTIME"
