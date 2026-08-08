#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PETALINUX_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
FPGATTEN_ROOT=$(cd -- "$PETALINUX_ROOT/.." && pwd)
OUTPUT_DIR="${OUTPUT_DIR:-$FPGATTEN_ROOT/FPGAtten_PetaLinux_SD}"

fail() {
    printf 'VERIFY_FAIL: %s\n' "$*" >&2
    exit 1
}

for artifact in FPGAtten_Z19P.wic FPGAtten_Z19P.wic.xz BOOT.BIN boot.scr \
    Image system.dtb rootfs.tar.gz BUILD_MANIFEST.txt SHA256SUMS \
    SD卡制作与启动说明.md FPGAtten_串口命令清单.md \
    FPGAtten_一般录制视频串口命令清单.md; do
    [ -s "$OUTPUT_DIR/$artifact" ] || fail "missing artifact: $artifact"
done

(
    cd "$OUTPUT_DIR"
    sha256sum -c SHA256SUMS
)

python3 "$SCRIPT_DIR/inspect_wic.py" "$OUTPUT_DIR/FPGAtten_Z19P.wic"
xz -t "$OUTPUT_DIR/FPGAtten_Z19P.wic.xz"
xz -dc "$OUTPUT_DIR/FPGAtten_Z19P.wic.xz" \
    | cmp - "$OUTPUT_DIR/FPGAtten_Z19P.wic" || \
    fail "compressed and uncompressed WIC files differ"

if find "$OUTPUT_DIR" -maxdepth 1 -type f -printf '%f\n' \
    | grep -Ei '(^|[-_.])(demo|r[0-9]+|gqav[0-9])([-_.]|$)' >/dev/null; then
    fail "legacy name found in output filename"
fi

if strings "$OUTPUT_DIR/system.dtb" \
    | grep -Ei 'gqav[0-9]|demo|v7\.3|(^|[^[:alnum:]])r(20|24|25)([^[:alnum:]]|$)' \
        >/dev/null; then
    fail "legacy name found in system.dtb"
fi
strings "$OUTPUT_DIR/system.dtb" | grep -F 'attention@a0010000' >/dev/null || \
    fail "FPGAtten attention node not found in system.dtb"
strings "$OUTPUT_DIR/system.dtb" | grep -F 'memory-window@b0000000' >/dev/null || \
    fail "FPGAtten memory node not found in system.dtb"

rootfs_dir=$(mktemp -d)
trap 'rm -rf "$rootfs_dir"' EXIT
tar -xzf "$OUTPUT_DIR/rootfs.tar.gz" -C "$rootfs_dir"

grep -Eq '^FPGAteen:x:1000:[0-9]+:.*:/home/FPGAteen:/bin/bash$' \
    "$rootfs_dir/etc/passwd" || fail "FPGAteen account attributes are incorrect"
! grep -q '^petalinux:' "$rootfs_dir/etc/passwd" || fail "legacy petalinux user exists"
grep -Eq '^root:[!*]:' "$rootfs_dir/etc/shadow" || fail "root account is not locked"
grep -Eq '^FPGAteen:\$6\$FPGAtten\$' "$rootfs_dir/etc/shadow" || \
    fail "FPGAteen password hash is missing"
[ -x "$rootfs_dir/usr/bin/fpgatten-replay" ] || fail "fpgatten-replay is missing"
[ -x "$rootfs_dir/usr/bin/fpgatten-run" ] || fail "fpgatten-run is missing"
[ -f "$rootfs_dir/etc/fpgatten-release" ] || fail "release metadata is missing"
[ "$(cat "$rootfs_dir/etc/hostname")" = "fpgatten-z19p" ] || \
    fail "hostname is not fpgatten-z19p"
[ ! -e "$rootfs_dir/usr/sbin/sshd" ] || fail "sshd is present"
[ ! -e "$rootfs_dir/usr/bin/sudo" ] || fail "sudo is present"
user_gid=$(awk -F: '$1 == "FPGAteen" {print $4}' "$rootfs_dir/etc/passwd")
device_gid=$(awk -F: '$1 == "fpgatten" {print $3}' "$rootfs_dir/etc/group")
[ -n "$user_gid" ] && [ "$user_gid" = "$device_gid" ] || \
    fail "FPGAteen primary group is not the fpgatten device group"

case_count=$(find "$rootfs_dir/opt/fpgatten/cases" -mindepth 3 -maxdepth 3 -type d | wc -l)
[ "$case_count" -eq 10 ] || fail "expected 10 real-data cases, found $case_count"
while IFS= read -r checksum_file; do
    (
        cd "$(dirname "$checksum_file")"
        sha256sum -c SHA256SUMS >/dev/null
    )
done < <(find "$rootfs_dir/opt/fpgatten/cases" -name SHA256SUMS -type f | sort)

printf 'VERIFY_PASS=1\n'
printf 'LOGIN_USER=FPGAteen\n'
printf 'REAL_CASES=%s\n' "$case_count"
printf 'OUTPUT_DIR=%s\n' "$OUTPUT_DIR"
