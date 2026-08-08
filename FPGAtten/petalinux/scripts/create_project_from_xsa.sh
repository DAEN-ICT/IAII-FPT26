#!/usr/bin/env bash
set -euo pipefail

PETALINUX_SETTINGS="${PETALINUX_SETTINGS:-/home/LUO/petalinux/2024.2/settings.sh}"
BUILD_ROOT="${BUILD_ROOT:-/home/LUO/fpgatten_build}"
PROJECT_NAME="${PROJECT_NAME:-FPGAtten_Z19P}"
PROJECT_DIR="${PROJECT_DIR:-${BUILD_ROOT}/${PROJECT_NAME}}"
XSA="${XSA:-${BUILD_ROOT}/input/FPGAtten_Z19P.xsa}"
EXPECTED_XSA_SHA256="ec93c372b368b92949e9fe99df502f18f604c38153726759c20179753d89a655"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -ne 0 ] || fail "PetaLinux must be run as a non-root user"
[ -r "$PETALINUX_SETTINGS" ] || fail "settings.sh not found: $PETALINUX_SETTINGS"
[ -r "$XSA" ] || fail "XSA not found: $XSA"

actual_xsa_sha256=$(sha256sum "$XSA" | awk '{print $1}')
[ "$actual_xsa_sha256" = "$EXPECTED_XSA_SHA256" ] || \
    fail "XSA SHA-256 mismatch: $actual_xsa_sha256"

# shellcheck disable=SC1090
source "$PETALINUX_SETTINGS"

if [ -d "$PROJECT_DIR" ]; then
    [ -f "$PROJECT_DIR/project-spec/attributes" ] || \
        fail "Path exists but is not a PetaLinux project: $PROJECT_DIR"
    printf 'PROJECT_REUSED=%s\n' "$PROJECT_DIR"
    exit 0
fi

mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"
petalinux-create project --template zynqMP --name "$PROJECT_NAME"
cd "$PROJECT_DIR"
petalinux-config --get-hw-description="$(dirname "$XSA")" --silentconfig

printf 'PROJECT_CREATED=%s\n' "$PROJECT_DIR"
printf 'XSA_SHA256=%s\n' "$actual_xsa_sha256"
