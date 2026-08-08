#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PETALINUX_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_ROOT="$PETALINUX_ROOT/source"
PETALINUX_SETTINGS="${PETALINUX_SETTINGS:-/home/LUO/petalinux/2024.2/settings.sh}"
PROJECT_DIR="${PROJECT_DIR:-/home/LUO/fpgatten_build/FPGAtten_Z19P}"
META_USER="$PROJECT_DIR/project-spec/meta-user"
MAIN_CONFIG="$PROJECT_DIR/project-spec/configs/config"
ROOTFS_CONFIG="$PROJECT_DIR/project-spec/configs/rootfs_config"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

set_kconfig() {
    key="$1"
    value="$2"
    file="$3"
    sed -i -e "/^${key}=/d" -e "/^# ${key} is not set$/d" "$file"
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

unset_kconfig() {
    key="$1"
    file="$2"
    sed -i -e "/^${key}=/d" -e "/^# ${key} is not set$/d" "$file"
    printf '# %s is not set\n' "$key" >> "$file"
}

[ "$(id -u)" -ne 0 ] || fail "PetaLinux must be run as a non-root user"
[ -r "$PETALINUX_SETTINGS" ] || fail "settings.sh not found: $PETALINUX_SETTINGS"
[ -f "$MAIN_CONFIG" ] || fail "PetaLinux project not found: $PROJECT_DIR"
[ -d "$SOURCE_ROOT" ] || fail "source tree not found: $SOURCE_ROOT"

install -d "$META_USER/recipes-bsp/device-tree/files"
install -d "$META_USER/recipes-apps"
install -d "$META_USER/recipes-core"
install -d "$META_USER/wic"

install -m 0644 "$SOURCE_ROOT/device-tree/device-tree.bbappend" \
    "$META_USER/recipes-bsp/device-tree/device-tree.bbappend"
install -m 0644 "$SOURCE_ROOT/device-tree/system-user.dtsi" \
    "$META_USER/recipes-bsp/device-tree/files/system-user.dtsi"
install -m 0644 "$SOURCE_ROOT/device-tree/fpgatten-user.dtsi" \
    "$META_USER/recipes-bsp/device-tree/files/fpgatten-user.dtsi"
cp -a "$SOURCE_ROOT/recipes-apps/." "$META_USER/recipes-apps/"
cp -a "$SOURCE_ROOT/recipes-core/." "$META_USER/recipes-core/"
install -m 0644 "$SOURCE_ROOT/wic/fpgatten-sd.wks" \
    "$META_USER/wic/fpgatten-sd.wks"
# PetaLinux 2024.2 package_wic.py only collects custom WIC output whose
# kickstart basename is "rootfs".  Keep the descriptive source name, and
# install this compatibility alias as a real file (not a symlink because the
# wrapper resolves symlinks before deriving the output basename).
install -m 0644 "$SOURCE_ROOT/wic/fpgatten-sd.wks" \
    "$META_USER/wic/rootfs.wks"
install -m 0644 "$SOURCE_ROOT/rootfs/user-rootfsconfig" \
    "$META_USER/conf/user-rootfsconfig"

unset_kconfig CONFIG_SUBSYSTEM_ROOTFS_INITRAMFS "$MAIN_CONFIG"
unset_kconfig CONFIG_SUBSYSTEM_ROOTFS_INITRD "$MAIN_CONFIG"
unset_kconfig CONFIG_SUBSYSTEM_ROOTFS_UBIFS "$MAIN_CONFIG"
unset_kconfig CONFIG_SUBSYSTEM_ROOTFS_NFS "$MAIN_CONFIG"
unset_kconfig CONFIG_SUBSYSTEM_ROOTFS_OTHER "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_ROOTFS_EXT4 y "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_RFS_FORMATS '"ext4 tar.gz"' "$MAIN_CONFIG"
unset_kconfig CONFIG_SUBSYSTEM_BOOTARGS_AUTO "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_USER_CMDLINE \
    '"earlycon console=ttyPS0,115200 root=/dev/mmcblk1p2 rootwait rw rootfstype=ext4 maxcpus=1 uio_pdrv_genirq.of_id=generic-uio"' \
    "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_HOSTNAME '"fpgatten-z19p"' "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_PRODUCT '"FPGAtten"' "$MAIN_CONFIG"
set_kconfig CONFIG_SUBSYSTEM_FW_VERSION '"1.0"' "$MAIN_CONFIG"

# shellcheck disable=SC1090
source "$PETALINUX_SETTINGS"
cd "$PROJECT_DIR"
petalinux-config --silentconfig

set_kconfig CONFIG_bash y "$ROOTFS_CONFIG"
unset_kconfig CONFIG_sudo "$ROOTFS_CONFIG"
set_kconfig CONFIG_coreutils y "$ROOTFS_CONFIG"
set_kconfig CONFIG_fpgatten-platform y "$ROOTFS_CONFIG"
set_kconfig CONFIG_fpgatten-cases y "$ROOTFS_CONFIG"
unset_kconfig CONFIG_imagefeature-ssh-server-openssh "$ROOTFS_CONFIG"
unset_kconfig CONFIG_imagefeature-ssh-server-dropbear "$ROOTFS_CONFIG"
unset_kconfig CONFIG_imagefeature-debug-tweaks "$ROOTFS_CONFIG"
unset_kconfig CONFIG_imagefeature-empty-root-password "$ROOTFS_CONFIG"
unset_kconfig CONFIG_imagefeature-serial-autologin-root "$ROOTFS_CONFIG"
set_kconfig CONFIG_ADD_EXTRA_USERS '""' "$ROOTFS_CONFIG"
set_kconfig CONFIG_CREATE_NEW_GROUPS '""' "$ROOTFS_CONFIG"
set_kconfig CONFIG_ADD_USERS_TO_GROUPS '""' "$ROOTFS_CONFIG"
set_kconfig CONFIG_ADD_USERS_TO_SUDOERS '""' "$ROOTFS_CONFIG"

petalinux-config -c rootfs --silentconfig

printf 'PROJECT_CONFIGURED=%s\n' "$PROJECT_DIR"
printf 'LOGIN_USER=FPGAteen\n'
printf 'ROOTFS=SD_EXT4\n'
printf 'SSH=DISABLED\n'
