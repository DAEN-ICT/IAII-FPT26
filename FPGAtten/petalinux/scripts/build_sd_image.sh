#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PETALINUX_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
FPGATTEN_ROOT=$(cd -- "$PETALINUX_ROOT/.." && pwd)
PETALINUX_SETTINGS="${PETALINUX_SETTINGS:-/home/LUO/petalinux/2024.2/settings.sh}"
PROJECT_DIR="${PROJECT_DIR:-/home/LUO/fpgatten_build/FPGAtten_Z19P}"
IMAGES_DIR="$PROJECT_DIR/images/linux"
OUTPUT_DIR="${OUTPUT_DIR:-$FPGATTEN_ROOT/FPGAtten_PetaLinux_SD}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-$PETALINUX_ROOT/archive}"
LOG_ROOT="${LOG_ROOT:-/home/LUO/fpgatten_build/logs}"
EXPECTED_XSA_SHA256="ec93c372b368b92949e9fe99df502f18f604c38153726759c20179753d89a655"
EXPECTED_XSA_BITSTREAM_SHA256="243ac8c0ec7ca12b4ee9bb4d6f63e7984ae760816c8b70697c7095725d8643dc"
EXPECTED_STANDALONE_BITSTREAM_SHA256="5ec632e213613c23c6ed2a7fcb90989d0799ee77e7427710dfe6757306d08f81"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

copy_required() {
    source_file="$1"
    output_name="$2"
    [ -f "$source_file" ] || fail "required build artifact missing: $source_file"
    cp -f "$source_file" "$STAGING_DIR/$output_name"
}

[ "$(id -u)" -ne 0 ] || fail "PetaLinux must be run as a non-root user"
[ -r "$PETALINUX_SETTINGS" ] || fail "settings.sh not found: $PETALINUX_SETTINGS"
[ -f "$PROJECT_DIR/project-spec/attributes" ] || fail "PetaLinux project not found: $PROJECT_DIR"

mkdir -p "$LOG_ROOT"
build_stamp=$(date -u +%Y%m%dT%H%M%SZ)
BUILD_LOG="$LOG_ROOT/FPGAtten_PetaLinux_${build_stamp}.log"
exec > >(tee "$BUILD_LOG") 2>&1

printf 'FPGATTEN_BUILD_BEGIN=%s\n' "$build_stamp"
printf 'PROJECT_DIR=%s\n' "$PROJECT_DIR"

# shellcheck disable=SC1090
source "$PETALINUX_SETTINGS"
cd "$PROJECT_DIR"

petalinux-build
petalinux-package --force boot --u-boot --fpga "$IMAGES_DIR/system.bit"
petalinux-package --force wic \
    --wks "$PROJECT_DIR/project-spec/meta-user/wic/rootfs.wks" \
    --bootfiles "BOOT.BIN boot.scr Image system.dtb" \
    --rootfs-file "$IMAGES_DIR/rootfs.tar.gz"

actual_xsa_sha256=$(sha256sum "$PROJECT_DIR/project-spec/hw-description/system.xsa" | awk '{print $1}')
actual_bitstream_sha256=$(sha256sum "$IMAGES_DIR/system.bit" | awk '{print $1}')
[ "$actual_xsa_sha256" = "$EXPECTED_XSA_SHA256" ] || fail "built XSA hash mismatch"
[ "$actual_bitstream_sha256" = "$EXPECTED_XSA_BITSTREAM_SHA256" ] || \
    fail "XSA-embedded bitstream hash mismatch"

standalone_bitstream="$PETALINUX_ROOT/hardware/FPGAtten_Z19P.bit"
standalone_bitstream_sha256=$(sha256sum "$standalone_bitstream" | awk '{print $1}')
[ "$standalone_bitstream_sha256" = "$EXPECTED_STANDALONE_BITSTREAM_SHA256" ] || \
    fail "standalone verified bitstream hash mismatch"
bitstream_comparison=$(python3 "$SCRIPT_DIR/compare_bitstreams.py" \
    "$PROJECT_DIR/project-spec/hw-description/system.xsa" \
    "$standalone_bitstream")
printf '%s\n' "$bitstream_comparison" | grep -q '^CONFIGURATION_PAYLOAD_IDENTICAL=1$' || \
    fail "XSA and standalone bitstream configuration payloads differ"

wic_file="$IMAGES_DIR/petalinux-sdimage.wic"
[ -s "$wic_file" ] || fail "petalinux-package wic did not create: $wic_file"

STAGING_DIR="$FPGATTEN_ROOT/.FPGAtten_PetaLinux_SD_${build_stamp}"
[ ! -e "$STAGING_DIR" ] || fail "staging path already exists: $STAGING_DIR"
mkdir -p "$STAGING_DIR"

copy_required "$wic_file" FPGAtten_Z19P.wic
copy_required "$IMAGES_DIR/BOOT.BIN" BOOT.BIN
copy_required "$IMAGES_DIR/boot.scr" boot.scr
copy_required "$IMAGES_DIR/Image" Image
copy_required "$IMAGES_DIR/system.dtb" system.dtb
copy_required "$IMAGES_DIR/rootfs.tar.gz" rootfs.tar.gz
if [ -f "$IMAGES_DIR/rootfs.ext4" ]; then
    cp -f "$IMAGES_DIR/rootfs.ext4" "$STAGING_DIR/rootfs.ext4"
fi

printf '%s\n' "$bitstream_comparison" > "$STAGING_DIR/BITSTREAM_EQUIVALENCE.txt"

# Write through stdout because WSL cannot always apply Unix mode metadata to a
# file created directly by xz on a Windows-mounted NTFS directory.
xz -T0 -6 -c "$STAGING_DIR/FPGAtten_Z19P.wic" \
    > "$STAGING_DIR/FPGAtten_Z19P.wic.xz"
cp -f "$PETALINUX_ROOT/docs/SD卡制作与启动说明.md" \
    "$STAGING_DIR/SD卡制作与启动说明.md"
cp -f "$PETALINUX_ROOT/docs/FPGAtten_串口命令清单.md" \
    "$STAGING_DIR/FPGAtten_串口命令清单.md"
cp -f "$PETALINUX_ROOT/docs/FPGAtten_一般录制视频串口命令清单.md" \
    "$STAGING_DIR/FPGAtten_一般录制视频串口命令清单.md"
cp -f "$BUILD_LOG" "$STAGING_DIR/BUILD_LOG.txt"

{
    printf 'Product: FPGAtten\n'
    printf 'Board: Z19-P (Zynq UltraScale+ MPSoC)\n'
    printf 'PetaLinux: 2024.2\n'
    printf 'Build UTC: %s\n' "$build_stamp"
    printf 'Login user: FPGAteen\n'
    printf 'Root filesystem: SD /dev/mmcblk1p2, EXT4, read-write\n'
    printf 'Core clock: 235000000 Hz\n'
    printf 'DMA clock: 300000000 Hz\n'
    printf 'XSA SHA-256: %s\n' "$actual_xsa_sha256"
    printf 'XSA embedded bitstream SHA-256: %s\n' "$actual_bitstream_sha256"
    printf 'Standalone verified bitstream SHA-256: %s\n' "$standalone_bitstream_sha256"
    printf 'Bitstream configuration payload SHA-256: 7cd5bb79708e124aac6993cde53ea1c199fdc19854b5ab692015e08c9b5d45b4\n'
    printf 'Bitstream configuration payload identical: yes\n'
    printf 'Source project: %s\n' "$PROJECT_DIR"
    printf 'Build log: BUILD_LOG.txt\n'
} > "$STAGING_DIR/BUILD_MANIFEST.txt"

(
    cd "$STAGING_DIR"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' \
        | sort | xargs sha256sum > SHA256SUMS
)

# Validate the complete staging tree before it can replace a prior release.
OUTPUT_DIR="$STAGING_DIR" bash "$SCRIPT_DIR/verify_artifacts.sh"

mkdir -p "$ARCHIVE_ROOT"
previous_archive=""
if [ -e "$OUTPUT_DIR" ]; then
    archive_dir="$ARCHIVE_ROOT/${build_stamp}_FPGAtten_PetaLinux_SD"
    [ ! -e "$archive_dir" ] || fail "archive path already exists: $archive_dir"
    mv "$OUTPUT_DIR" "$archive_dir"
    previous_archive="$archive_dir"
    printf 'PREVIOUS_OUTPUT_ARCHIVED=%s\n' "$archive_dir"
fi
if ! mv "$STAGING_DIR" "$OUTPUT_DIR"; then
    if [ -n "$previous_archive" ] && [ ! -e "$OUTPUT_DIR" ]; then
        mv "$previous_archive" "$OUTPUT_DIR"
        printf 'PREVIOUS_OUTPUT_RESTORED=%s\n' "$OUTPUT_DIR" >&2
    fi
    fail "failed to publish validated staging directory"
fi

printf 'FPGATTEN_BUILD_COMPLETE=%s\n' "$OUTPUT_DIR"
printf 'WIC=%s/FPGAtten_Z19P.wic\n' "$OUTPUT_DIR"
printf 'WIC_XZ=%s/FPGAtten_Z19P.wic.xz\n' "$OUTPUT_DIR"
