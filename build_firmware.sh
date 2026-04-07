#!/usr/bin/env bash
# Build boot.img + rootfs.img for Nothing Phone 1 (spacewar)
# Supported FS: ext4, f2fs

set -euo pipefail

export PATH="/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"
OUT_DIR="${SCRIPT_DIR}/out"
BOOT_OUT="${OUT_DIR}/boot.img"
ROOTFS_OUT="${OUT_DIR}/rootfs.img"

# ========== SETTINGS ==========
ROOTFS_PARTITION="userdata"
ROOTFS_TYPE="ext4"          # ext4 or f2fs
# ================================

# Archive is located next to the script
ROOTFS_ARCHIVE="${SCRIPT_DIR}/alt-mobile-phosh-def-1-20260326-aarch64.tar.xz"

ARCHIVE="${CACHE_DIR}/$(basename "$ROOTFS_ARCHIVE")"
ROOT_DIR="${CACHE_DIR}/rootfs"

DTB=""
RAMDISK=""
ALT_KERNEL_GZ=""
ALT_KERNEL_RAW=""

FW_DIR="${SCRIPT_DIR}/firmware"

BASE=0x00000000
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0x00000000
TAGS_OFFSET=0x00000100
DTB_OFFSET=0x04000000
PAGE_SIZE=4096
HEADER_VERSION=2
CMDLINE=""

PSEUDO_DIRS=(media mnt selinux srv)
RSYNC_EXTRA_EXCLUDES=(--exclude=/out/ --exclude=/firmware/ --exclude=/cache/ --exclude=/proc/ --exclude=/sys/ --exclude=/dev/ --exclude=/run/ --exclude=/tmp/ --exclude=/var/)

STAGING=""
trap '[[ -n "$STAGING" && -d "$STAGING" ]] && { rm -rf "$STAGING"; }' EXIT

# ========== COLORS ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BLUE}[*]${NC} $*"; }
ok()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# Validate supported filesystem
validate_fstype() {
    case "$ROOTFS_TYPE" in
        ext4|f2fs)
            ok "Using FS: $ROOTFS_TYPE"
            ;;
        *)
            err "Unsupported FS type: $ROOTFS_TYPE. Available: ext4, f2fs"
            ;;
    esac
}

# Get mount options for fstab
get_mount_options() {
    case "$ROOTFS_TYPE" in
        ext4)
            echo "rw,relatime,errors=remount-ro"
            ;;
        f2fs)
            echo "rw,relatime"
            ;;
    esac
}

# Get mkfs command
get_mkfs_cmd() {
    local img="$1"
    case "$ROOTFS_TYPE" in
        ext4)
            echo "mkfs.ext4 -L ROOT -F \"$img\""
            ;;
        f2fs)
            echo "mkfs.f2fs -l ROOT -f -O extra_attr,inode_checksum,sb_checksum -o 5 -w 4096 \"$img\""
            ;;
    esac
}

# Get required tools for validation
get_fs_tools() {
    case "$ROOTFS_TYPE" in
        ext4)
            echo "mkfs.ext4"
            ;;
        f2fs)
            echo "mkfs.f2fs"
            ;;
    esac
}

# Cleanup
clean() {
    log "Cleaning old files..."
    if [[ -d "$CACHE_DIR/rootfs" ]]; then
        chmod -R u+rwX "$CACHE_DIR/rootfs" 2>/dev/null || true
        rm -rf "$CACHE_DIR/rootfs" 2>/dev/null || true
    fi
    rm -rf "$OUT_DIR" 2>/dev/null || true
    mkdir -p "$OUT_DIR" "$CACHE_DIR"
    ok "Cleanup completed"
}

# Check required tools
check_tools() {
    local missing=()
    local fs_tool=$(get_fs_tools)

    for cmd in mkbootimg xz rsync fakeroot udisksctl gzip "$fs_tool"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing tools: ${missing[*]}"
    fi
}

# Copy rootfs from local archive
fetch_rootfs() {
    log "Copying rootfs from local archive..."
    if [[ ! -f "$ROOTFS_ARCHIVE" ]]; then
        err "Rootfs archive not found at: $ROOTFS_ARCHIVE"
    fi

    cp "$ROOTFS_ARCHIVE" "$ARCHIVE" || err "Failed to copy archive"
    ok "Rootfs copied to cache"
}

# Extract rootfs
extract_rootfs() {
    log "Extracting rootfs..."
    if [[ -d "$ROOT_DIR" ]]; then
        chmod -R u+rwX "$ROOT_DIR" 2>/dev/null || true
        rm -rf "$ROOT_DIR" 2>/dev/null || true
    fi
    mkdir -p "$ROOT_DIR"

    local fmt=$(file -b "$ARCHIVE")
    if [[ "$fmt" == *"XZ compressed"* ]]; then
        local inner=$(xz -dc "$ARCHIVE" 2>/dev/null | file -b - || true)

        if [[ "$inner" == *"tar archive"* ]]; then
            xz -dc "$ARCHIVE" | tar -x -C "$ROOT_DIR" --no-same-owner 2>/dev/null || true
        else
            local img="${ARCHIVE%.xz}"
            [[ ! -f "$img" ]] && xz -dk "$ARCHIVE"
            local loop_dev=$(udisksctl loop-setup -f "$img" 2>&1 | grep -oP '/dev/loop\d+')
            sleep 1

            local best_part="$loop_dev"
            for part in "${loop_dev}"p*; do
                [[ -b "$part" ]] && best_part="$part" && break
            done

            local mount_point=$(udisksctl mount -b "$best_part" 2>&1 | grep -oP 'at \K[^ .]+')
            rsync -aHAX --numeric-ids "$mount_point/" "$ROOT_DIR/"
            udisksctl unmount -b "$best_part" 2>/dev/null || true
            udisksctl loop-delete -b "$loop_dev" 2>/dev/null || true
            rm -f "$img"
        fi
    else
        err "Unknown format: $fmt"
    fi

    rm -f "$ARCHIVE"
    ok "Rootfs extracted"
}

# Find initramfs
detect_ramdisk() {
    log "Looking for initramfs..."
    if [[ -L "${ROOT_DIR}/boot/initrd.img" ]]; then
        RAMDISK="$(readlink -f "${ROOT_DIR}/boot/initrd.img")"
    else
        RAMDISK=$(ls "${ROOT_DIR}/boot/initrd-"*.img 2>/dev/null | sort -V | tail -1 || true)
    fi
    [[ -n "$RAMDISK" && -f "$RAMDISK" ]] || err "Initramfs not found"
    ok "Initramfs: $(basename "$RAMDISK")"
}

# Patch initramfs to mount /sys and /dev
patch_initramfs() {
    log "Patching initramfs for /sys and /dev mount..."

    local initrd_tmp="${CACHE_DIR}/initrd_patch"
    rm -rf "$initrd_tmp"
    mkdir -p "$initrd_tmp"

    (
    cd "$initrd_tmp"

    local fmt=$(file -b "$RAMDISK")
    if [[ "$fmt" == *"gzip"* ]]; then
        gzip -dc "$RAMDISK" | cpio -idm 2>/dev/null || err "Failed to extract initramfs (gzip)"
    elif [[ "$fmt" == *"XZ"* ]] || [[ "$fmt" == *"lzma"* ]]; then
        xz -dc "$RAMDISK" | cpio -idm 2>/dev/null || err "Failed to extract initramfs (xz)"
    else
        cpio -idm < "$RAMDISK" 2>/dev/null || err "Failed to extract initramfs (raw)"
    fi

    if [[ -f "etc/rc.d/rc.sysinit" ]]; then
        if ! grep -q "mount.*sysfs.*sys" etc/rc.d/rc.sysinit; then
            sed -i '/mount -n -t proc -o nodev,noexec,nosuid proc \/proc/a\
\
[ -d /sys ] || mkdir -p /sys\
mount -n -t sysfs -o nodev,noexec,nosuid sysfs /sys\
\
[ -d /dev ] || mkdir -p /dev\
mount -n -t devtmpfs -o mode=0755,nosuid,noexec,nodev devtmpfs /dev 2>/dev/null || mount -n -t tmpfs -o mode=0755,nosuid,noexec,nodev tmpfs /dev' etc/rc.d/rc.sysinit
            ok "Patched rc.sysinit for /sys and /dev"
        else
            ok "rc.sysinit already patched"
        fi
    else
        warn "rc.sysinit not found in initramfs"
    fi

    find . -depth | cpio -R 0:0 -o -H newc 2>/dev/null | xz -9 > "$RAMDISK"
    )
    rm -rf "$initrd_tmp"

    ok "Initramfs patched"
}

# Find kernel
detect_kernel() {
    log "Looking for kernel..."
    ALT_KERNEL_GZ="${ROOT_DIR}/boot/Image.gz"
    if [[ -f "$ALT_KERNEL_GZ" ]]; then
        ok "Kernel: Image.gz"
        return
    fi

    if [[ -L "${ROOT_DIR}/boot/vmlinuz" ]]; then
        ALT_KERNEL_RAW="$(readlink -f "${ROOT_DIR}/boot/vmlinuz")"
    else
        ALT_KERNEL_RAW=$(ls "${ROOT_DIR}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 || true)
    fi
    [[ -n "$ALT_KERNEL_RAW" && -f "$ALT_KERNEL_RAW" ]] || err "Kernel not found"
    ok "Kernel: $(basename "$ALT_KERNEL_RAW")"
}

# Find DTB
detect_dtb() {
    log "Looking for DTB..."
    local candidates=(
        "${ROOT_DIR}/boot/dtb/qcom/sm7325-nothing-spacewar-patched.dtb"
        "${ROOT_DIR}/boot/dtb/qcom/sm7325-nothing-spacewar.dtb"
        "${ROOT_DIR}/boot/dtbs/qcom/sm7325-nothing-spacewar.dtb"
        "${ROOT_DIR}/boot/sm7325-nothing-spacewar.dtb"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            DTB="$c"
            ok "DTB: $(basename "$DTB")"
            return
        fi
    done
    err "DTB not found"
}

# Copy firmware
copy_firmware() {
    log "Copying firmware..."

    # Create qcom firmware directory
    mkdir -p "$ROOT_DIR/lib/firmware/qcom/sm7325/nothing/spacewar"

    # Copy device firmware (split .b00/.b01/.mdt format) to proper qcom path
    if [[ -d "$FW_DIR/device" ]]; then
        log "Copying device firmware to /lib/firmware/qcom/sm7325/nothing/spacewar..."
        cp -a "$FW_DIR/device/"* "$ROOT_DIR/lib/firmware/qcom/sm7325/nothing/spacewar/" 2>/dev/null || true
    fi

    if [[ -d "$FW_DIR/hexagonfs" ]]; then
        log "Copying hexagonfs firmware..."
        cp -a "$FW_DIR/hexagonfs/"* "$ROOT_DIR/" 2>/dev/null || true
    fi
    if [[ -d "$FW_DIR/modem_profiles" ]]; then
        log "Copying modem profiles..."
        cp -a "$FW_DIR/modem_profiles/"* "$ROOT_DIR/lib/firmware/qcom/" 2>/dev/null || true
    fi

    # Copy patched DTB (enables second DWC3 controller usb@8c00000)
    local patched_dtb="${SCRIPT_DIR}/cache/rootfs/boot/dtb/qcom/sm7325-nothing-spacewar-patched.dtb"
    if [[ -f "$patched_dtb" ]]; then
        cp -f "$patched_dtb" "$ROOT_DIR/boot/dtb/qcom/" 2>/dev/null || true
        log "Patched DTB copied (usb@8c00000 enabled)"
    fi

    ok "Firmware copied"
}

# Copy all firmware from GitHub repository for Nothing Phone 1
copy_github_firmware() {
    log "Copying firmware from GitHub repository..."

    local github_fw="${SCRIPT_DIR}/firmware_github"

    if [[ ! -d "$github_fw" ]]; then
        warn "GitHub firmware repository not found at $github_fw"
        return 0
    fi

    # Create target directory for spacewar firmware
    local fw_target="${ROOT_DIR}/lib/firmware/qcom/sm7325/nothing/spacewar"
    mkdir -p "$fw_target"

    # Copy device-specific firmware from lib/firmware/qcom/sm7325/nothing/spacewar/
    if [[ -d "$github_fw/lib/firmware/qcom/sm7325/nothing/spacewar" ]]; then
        log "Copying device-specific firmware..."
        cp -a "$github_fw/lib/firmware/qcom/sm7325/nothing/spacewar/"* "$fw_target/" 2>/dev/null || true
    fi

    # Copy Adreno 660 GPU firmware (a660_gmu.bin, a660_sqe.fw) to /lib/firmware/qcom/
    if [[ -d "$github_fw/lib/firmware/qcom" ]]; then
        log "Copying Adreno GPU firmware..."
        for fw in "$github_fw/lib/firmware/qcom/"*; do
            [[ -f "$fw" ]] && cp -a "$fw" "$ROOT_DIR/lib/firmware/qcom/" 2>/dev/null || true
        done
    fi

    # Also copy any files from usr/share
    if [[ -d "$github_fw/usr/share" ]]; then
        log "Copying usr/share firmware..."
        cp -a "$github_fw/usr/share/"* "${ROOT_DIR}/usr/share/" 2>/dev/null || true
    fi

    log "GitHub firmware files in spacewar:"
    ls -la "$fw_target/" 2>/dev/null | head -15 || true
    log "GitHub firmware files in qcom/:"
    ls -la "$ROOT_DIR/lib/firmware/qcom/" 2>/dev/null | head -15 || true

    ok "GitHub firmware copied"
}

# Decompress .xz firmware files from the rootfs tarball
decompress_tarball_firmware() {
    log "Decompressing .xz firmware from rootfs tarball..."

    local fw_qcom="$ROOT_DIR/usr/lib/firmware/qcom"
    local fw_target="$ROOT_DIR/lib/firmware/qcom"
    local fw_target_spacewar="$fw_target/sm7325/nothing/spacewar"

    mkdir -p "$fw_target" "$fw_target_spacewar"

    # Decompress Adreno GPU firmware to /lib/firmware/qcom/
    for xz_fw in "$fw_qcom"/*.xz; do
        [[ -f "$xz_fw" ]] || continue
        local base=$(basename "$xz_fw" .xz)
        log "  Decompressing $base..."
        xz -dc "$xz_fw" > "$fw_target/$base" 2>/dev/null || true
    done

    # Decompress device-specific firmware to /lib/firmware/qcom/sm7325/nothing/spacewar/
    local dev_fw_dir="$fw_qcom/sm7325/nothing/spacewar"
    if [[ -d "$dev_fw_dir" ]]; then
        for xz_fw in "$dev_fw_dir"/*.xz; do
            [[ -f "$xz_fw" ]] || continue
            local base=$(basename "$xz_fw" .xz)
            log "  Decompressing spacewar/$base..."
            xz -dc "$xz_fw" > "$fw_target_spacewar/$base" 2>/dev/null || true
        done
    fi

    ok "Tarball firmware decompressed"
}

# Extract adreno/kgsl modules from pmos rootfs (optional - mainly for firmware)
extract_pmos_modules() {
    log "Note: Module extraction from pmos rootfs..."

    # The kernel already has msm drm driver built-in (CONFIG_DRM_MSM=y)
    # Firmware is handled by copy_github_firmware and decompress_tarball_firmware
    # modules-load.d is configured in build_rootfs

    ok "PMOS module check completed"
}

# Patch extlinux.conf to use custom DTB path
patch_extlinux() {
    local extlinux_conf="${ROOT_DIR}/boot/extlinux/extlinux.conf"
    if [[ -f "$extlinux_conf" ]]; then
        log "Patching extlinux.conf for custom DTB..."
        sed -i 's|fdtdir ../dtb$|fdtdir ../dtb/qcom|' "$extlinux_conf"
        sed -i 's|fdtdir ../devicetree/.*|fdtdir ../dtb/qcom|' "$extlinux_conf"
        ok "extlinux.conf patched"
    fi
}

# Prepare full fstab
prepare_fstab() {
    log "Configuring fstab..."
    local fstab="${ROOT_DIR}/etc/fstab"
    local mount_opts=$(get_mount_options)

    cat > "$fstab" << EOF
# Root filesystem
proc			/proc		proc	nosuid,noexec,gid=proc				0 0
sysfs			/sys		sysfs	nosuid,noexec,ro					0 0
devpts			/dev/pts	devpts	nosuid,noexec,gid=tty,mode=620,ptmxmode=0666	0 0

# Runtime directories (tmpfs)
tmpfs			/run		tmpfs	mode=0755,nosuid,noexec				0 0
tmpfs			/tmp		tmpfs	mode=1777,nosuid,noexec				0 0

# Systemd auto-mount points
tmpfs			/dev/hugepages	tmpfs	mode=1777,nosuid,noexec,nodev			0 0
tmpfs			/dev/mqueue	tmpfs	mode=1777,nosuid,noexec,nodev			0 0

PARTLABEL=${ROOTFS_PARTITION}	/	${ROOTFS_TYPE}	rw,relatime,errors=remount-ro	0 1

EOF

    ok "fstab configured for $ROOTFS_TYPE"
}

# Create basic initialization scripts
prepare_init_scripts() {
    log "Creating init scripts..."

    mkdir -p "${ROOT_DIR}/lib/systemd/system" 2>/dev/null || true

    # Create /init symlink (required by boot)
    if [[ ! -e "${ROOT_DIR}/init" ]]; then
        if [[ -L "${ROOT_DIR}/sbin/init" ]]; then
            ln -sf sbin/init "${ROOT_DIR}/init" || true
            log "Created /init symlink"
        fi
    fi

    ok "Init scripts configured"
}

# Build boot.img
build_boot() {
    log "Building boot.img..."
    local kernel_gz="${OUT_DIR}/Image.gz"

    if [[ -f "$ALT_KERNEL_GZ" ]]; then
        cp -f "$ALT_KERNEL_GZ" "$kernel_gz"
    else
        gzip --best -c "$ALT_KERNEL_RAW" > "$kernel_gz"
    fi

    CMDLINE="root=PARTLABEL=${ROOTFS_PARTITION} rootfstype=${ROOTFS_TYPE} rootflags=relatime rootwait rw role-switch-default-mode=peripheral dwc3.mode=peripheral usbcore.autosuspend=-1 console=ttyS0,115200n8 console=tty0 drm.debug=16"

    # Use pmos DTB for better hardware support
    local pmos_dtb="${SCRIPT_DIR}/pmos unzip/simg2img_win-master/simg2img_win-master/rootfs-nothing-spacewar/0.primary/sm7325-nothing-spacewar.dtb"
    local dtb_for_boot="${OUT_DIR}/dtb_for_boot.dtb"
    
    if [[ -f "$pmos_dtb" ]]; then
        log "Using pmos DTB (146319 bytes)"
        cp -f "$pmos_dtb" "$dtb_for_boot"
    elif [[ -f "$DTB" ]]; then
        cp -f "$DTB" "$dtb_for_boot"
    else
        touch "$dtb_for_boot"
    fi

    mkbootimg \
        --kernel "$kernel_gz" \
        --ramdisk "$RAMDISK" \
        --dtb "$dtb_for_boot" \
        --base $BASE \
        --kernel_offset $KERNEL_OFFSET \
        --ramdisk_offset $RAMDISK_OFFSET \
        --second_offset $SECOND_OFFSET \
        --tags_offset $TAGS_OFFSET \
        --pagesize $PAGE_SIZE \
        --header_version $HEADER_VERSION \
        --cmdline "$CMDLINE" \
        -o "$BOOT_OUT" || err "Failed to build boot.img"

    ok "boot.img ready ($(du -h "$BOOT_OUT" | cut -f1))"
    log "Kernel parameters: $CMDLINE"
}

# Build rootfs.img
build_rootfs() {
    log "Building rootfs.img (FS: $ROOTFS_TYPE)..."

    local excl_args=()
    for d in "${PSEUDO_DIRS[@]}"; do
        excl_args+=(--exclude="/${d}/")
    done

    STAGING="${OUT_DIR}/rootfs-staging"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"

    log "Copying files..."
    fakeroot rsync -aHAX --numeric-ids \
        "${excl_args[@]}" "${RSYNC_EXTRA_EXCLUDES[@]}" \
        "${ROOT_DIR}/" "${STAGING}/" 2>&1 || true

    for d in proc sys dev dev/pts dev/shm run tmp var; do
        mkdir -p "${STAGING}/${d}"
    done
    chmod 1777 "${STAGING}/tmp" "${STAGING}/run"

    # Init debug script - runs before systemd, shows boot info on console
    cat > "${STAGING}/sbin/init-debug.sh" << 'DEBUGSCRIPT'
#!/bin/sh
exec >/dev/console 2>&1
echo ""
echo "========================================"
echo "  INIT DEBUG - Before systemd"
echo "========================================"
echo ""
echo "--- Mounts ---"
mount
echo ""
echo "--- Root ---"
mount | grep " / "
echo ""
echo "--- Cmdline ---"
cat /proc/cmdline
echo ""
echo "--- Block devices ---"
lsblk 2>&1 || echo "lsblk failed"
echo ""
echo "--- Fstab ---"
cat /etc/fstab 2>&1 || echo "no fstab"
echo ""
echo "--- Init ---"
ls -la /sbin/init
echo ""
echo "--- Kernel ---"
uname -a
echo ""
echo "--- /var state ---"
ls -la /var/ 2>&1 | head -20
echo ""
echo "--- /run state ---"
ls -la /run/ 2>&1 | head -10
echo ""
echo "--- DWC3 kernel messages ---"
dmesg | grep -iE 'dwc3|usb.*probe|usb.*phy|usb.*clock|usb.*firmware|usb.*gadget' | tail -40
echo ""
echo "--- All USB kernel messages ---"
dmesg | grep -iE 'usb|udc|gadget' | tail -50
echo ""
echo "--- USB device in sysfs ---"
find /sys/devices/platform -name '*usb*' -o -name '*a600000*' 2>/dev/null | head -20
echo ""
echo "--- a600000.usb device ---"
ls -la /sys/devices/platform/a600000.usb/ 2>/dev/null || echo "  (not found)"
echo "--- a600000.usb driver ---"
ls -la /sys/devices/platform/a600000.usb/driver 2>/dev/null || echo "  (no driver bound)"
echo "--- a600000.usb modalias ---"
cat /sys/devices/platform/a600000.usb/modalias 2>/dev/null || echo "  (no modalias)"
echo ""
echo "--- DWC3 driver registration ---"
ls -la /sys/bus/platform/drivers/dwc3/ 2>/dev/null || echo "  (none)"
ls -la /sys/bus/platform/drivers/dwc3-qcom/ 2>/dev/null || echo "  (none)"
echo ""
echo "--- Attempting manual bind ---"
echo a600000.usb > /sys/bus/platform/drivers/dwc3-qcom/bind 2>/dev/null && echo "  dwc3-qcom bind: SUCCESS" || echo "  dwc3-qcom bind: FAILED"
echo a600000.usb > /sys/bus/platform/drivers/dwc3/bind 2>/dev/null && echo "  dwc3 bind: SUCCESS" || echo "  dwc3 bind: FAILED"
echo ""
echo "--- Clocks and regulators ---"
dmesg | grep -iE 'clock.*usb|regulator.*usb|usb.*clock|usb.*regulator|a600000' | tail -20
echo ""
echo "--- Setting up USB debug gadget (PMOS-style) ---"
modprobe libcomposite 2>/dev/null
mkdir -p /sys/kernel/config
mount -t configfs configfs /sys/kernel/config 2>/dev/null

# === Phase 1: Scan ALL USB sysfs paths ===
echo ""
echo "=== USB sysfs scan ==="
echo "--- DWC3 platform devices ---"
ls -la /sys/bus/platform/drivers/dwc3/ 2>/dev/null || echo "  (none)"
echo "--- DWC3 QCOM devices ---"
ls -la /sys/bus/platform/drivers/dwc3-qcom/ 2>/dev/null || echo "  (none)"
echo "--- DWC3 dr_mode values ---"
for d in $(find /sys -name 'dr_mode' -path '*dwc3*' 2>/dev/null); do
    echo "  $d = $(cat $d 2>/dev/null)"
done
echo "--- USB role switches ---"
ls -la /sys/class/usb_role_switch/ 2>/dev/null || echo "  (none)"
for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
    echo "  $r = $(cat $r 2>/dev/null)"
done
echo "--- Extcon devices ---"
ls -la /sys/class/extcon/ 2>/dev/null || echo "  (none)"
for e in $(find /sys/class/extcon/ -name state 2>/dev/null); do
    echo "  $e = $(cat $e 2>/dev/null)"
done
echo "--- Type-C ports ---"
ls -la /sys/class/typec/ 2>/dev/null || echo "  (none)"
for t in $(find /sys/class/typec/ -name orientation 2>/dev/null); do
    echo "  $t = $(cat $t 2>/dev/null)"
done
echo "--- Type-C muxes ---"
ls -la /sys/class/typec_mux/ 2>/dev/null || echo "  (none)"
echo "--- UDC class ---"
ls -la /sys/class/udc/ 2>/dev/null || echo "  (none)"
echo "--- DWC3 mode files ---"
for m in $(find /sys -name 'mode' -path '*dwc3*' 2>/dev/null); do
    echo "  $m = $(cat $m 2>/dev/null)"
done
echo "--- DWC3 QCOM mode ---"
for m in $(find /sys -name 'mode' -path '*dwc3-qcom*' 2>/dev/null); do
    echo "  $m = $(cat $m 2>/dev/null)"
done

# === Phase 2: Try ALL methods to switch to peripheral mode ===
echo ""
echo "=== Attempting USB role switch ==="

# Method 1: DWC3 dr_mode
echo "--- Method 1: DWC3 dr_mode ---"
for d in $(find /sys -name 'dr_mode' -path '*dwc3*' 2>/dev/null); do
    echo "  Trying $d: $(cat $d 2>/dev/null) -> peripheral"
    echo peripheral > "$d" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# Method 2: USB role switch
echo "--- Method 2: USB role switch ---"
for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
    echo "  Trying $r: $(cat $r 2>/dev/null) -> device"
    echo device > "$r" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# Method 3: Extcon USB state (set USB host bit to 0, device bit to 1)
echo "--- Method 3: Extcon state ---"
for e in $(find /sys/class/extcon/ -name state 2>/dev/null); do
    echo "  Trying $e: $(cat $e 2>/dev/null) -> 1 (device)"
    echo 1 > "$e" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# Method 4: Type-C orientation
echo "--- Method 4: Type-C orientation ---"
for t in $(find /sys/class/typec/ -name orientation 2>/dev/null); do
    echo "  Trying $t: $(cat $t 2>/dev/null) -> normal"
    echo normal > "$t" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# Method 5: DWC3 QCOM mode (some kernels use this)
echo "--- Method 5: DWC3 QCOM mode ---"
for m in $(find /sys -name 'mode' -path '*dwc3-qcom*' 2>/dev/null); do
    echo "  Trying $m: $(cat $m 2>/dev/null) -> peripheral"
    echo peripheral > "$m" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# Method 6: DWC3 mode
echo "--- Method 6: DWC3 mode ---"
for m in $(find /sys -name 'mode' -path '*dwc3*' 2>/dev/null); do
    echo "  Trying $m: $(cat $m 2>/dev/null) -> peripheral"
    echo peripheral > "$m" 2>/dev/null && echo "  SUCCESS" || echo "  FAILED"
done

# === Phase 3: Wait and retry ===
echo ""
echo "--- Waiting 15 sec for UDC to appear ---"
sleep 15

UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
echo "UDC after first wait: ${UDC:-none}"

if [ -z "$UDC" ]; then
    echo "--- Second attempt: retry role switch ---"
    for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
        echo device > "$r" 2>/dev/null
    done
    for d in $(find /sys -name 'dr_mode' -path '*dwc3*' 2>/dev/null); do
        echo peripheral > "$d" 2>/dev/null
    done
    echo "--- Waiting 15 sec more ---"
    sleep 15
    UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    echo "UDC after second wait: ${UDC:-none}"
fi

# === Phase 4: Create gadget if UDC found ===
if [ -n "$UDC" ]; then
    echo ""
    echo "=== Creating USB gadget ==="
    echo "UDC: $UDC"
    G="/sys/kernel/config/usb_gadget/g1"
    rm -rf "$G" 2>/dev/null
    mkdir -p "$G"
    echo 0x18D1 > "$G/idVendor"
    echo 0xD001 > "$G/idProduct"
    mkdir -p "$G/strings/0x409"
    echo "Alt Linux" > "$G/strings/0x409/manufacturer"
    echo "spacewar-debug" > "$G/strings/0x409/product"
    echo "altlinux" > "$G/strings/0x409/serialnumber"
    USB_FUNC=""
    if mkdir -p "$G/functions/ncm.usb0" 2>/dev/null; then
        USB_FUNC="$G/functions/ncm.usb0"
        echo "  Using NCM function"
    elif mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
        USB_FUNC="$G/functions/rndis.usb0"
        echo "  Using RNDIS function"
    fi
    mkdir -p "$G/functions/acm.usb0" 2>/dev/null
    if [ -n "$USB_FUNC" ]; then
        mkdir -p "$G/configs/c.1/strings/0x409"
        echo "USB Debug Network + ACM" > "$G/configs/c.1/strings/0x409/configuration"
        ln -s "$USB_FUNC" "$G/configs/c.1/" 2>/dev/null
        ln -s "$G/functions/acm.usb0" "$G/configs/c.1/" 2>/dev/null
        echo "$UDC" > "$G/UDC"
        echo "  Gadget activated with UDC: $UDC"
        sleep 2
        for iface in usb0 rndis0; do
            if ip link show "$iface" >/dev/null 2>&1; then
                ip addr add 172.16.42.2/24 dev "$iface" 2>/dev/null
                ip link set "$iface" up 2>/dev/null
                echo "  USB network ready on $iface (172.16.42.2)"
                break
            fi
        done
    else
        echo "  No USB network function available"
    fi
else
    echo ""
    echo "=== USB gadget FAILED - no UDC ==="
    echo "Full sysfs dump for debugging:"
    echo "--- All DWC3 sysfs entries ---"
    find /sys -path '*dwc3*' -type f 2>/dev/null | while read f; do
        echo "  $f = $(cat $f 2>/dev/null | head -1)"
    done
    echo "--- All USB role switch entries ---"
    find /sys/class/usb_role_switch/ -type f 2>/dev/null | while read f; do
        echo "  $f = $(cat $f 2>/dev/null | head -1)"
    done
    echo "--- All extcon entries ---"
    find /sys/class/extcon/ -type f 2>/dev/null | while read f; do
        echo "  $f = $(cat $f 2>/dev/null | head -1)"
    done
    echo "--- All typec entries ---"
    find /sys/class/typec/ -type f 2>/dev/null | while read f; do
        echo "  $f = $(cat $f 2>/dev/null | head -1)"
    done
    echo "--- All UDC entries ---"
    find /sys/class/udc/ -type f 2>/dev/null | while read f; do
        echo "  $f = $(cat $f 2>/dev/null | head -1)"
    done
fi
echo ""
echo "--- Waiting 30 sec before systemd ---"
sleep 30
echo "--- Starting systemd ---"
exec /sbin/init
DEBUGSCRIPT
    chmod +x "${STAGING}/sbin/init-debug.sh"

    # Fstab - dynamic FS type and rw mount
    cat > "${STAGING}/etc/fstab" << FSTAB
proc			/proc		proc	nosuid,noexec,gid=proc		0 0
sysfs			/sys		sysfs	nosuid,noexec,ro			0 0
devpts			/dev/pts	devpts	nosuid,noexec,gid=tty,mode=620	0 0
PARTLABEL=${ROOTFS_PARTITION}	/	${ROOTFS_TYPE}	rw,relatime	0 1
FSTAB

    # Plan A1: Simple multi-user boot (no phosh, no graphical target)
    # Just get to a working root shell with DRM and USB debug
    ln -sf /lib/systemd/system/multi-user.target "${STAGING}/etc/systemd/system/default.target"

    # Disable getty@tty1 override (use default)
    # We already have autologin configured below

    # PAM config for systemd-logind (critical for phosh session)
    mkdir -p "${STAGING}/etc/pam.d"
    cat > "${STAGING}/etc/pam.d/systemd-user" << 'PAM'
account  required  pam_nologin.so
account  include   system-auth
session  required  pam_limits.so
session  required  pam_unix.so
session  optional  pam_systemd.so
PAM

    # Credstore directories (logind requirement)
    mkdir -p "${STAGING}/etc/credstore"
    mkdir -p "${STAGING}/etc/credstore.encrypted"

    # Enable dbus (logind dependency)
    ln -sf /usr/lib/systemd/system/dbus.service "${STAGING}/etc/systemd/system/dbus-org.freedesktop.DBus.service" 2>/dev/null || true
    mkdir -p "${STAGING}/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/dbus.service "${STAGING}/etc/systemd/system/multi-user.target.wants/dbus.service" 2>/dev/null || true

    # Enable systemd-logind (critical for phosh PAM session)
    mkdir -p "${STAGING}/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/systemd-logind.service "${STAGING}/etc/systemd/system/multi-user.target.wants/systemd-logind.service" 2>/dev/null || true

    # Debug service - output boot info to console
    mkdir -p "${STAGING}/etc/systemd/system"
    cat > "${STAGING}/etc/systemd/system/debug-boot.service" << 'DEBUGSVC'
[Unit]
Description=Debug Boot
After=local-fs.target
Before=graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '
echo "==== BOOT DEBUG ====" > /dev/console
echo "cmdline:" > /dev/console
cat /proc/cmdline > /dev/console
echo " " > /dev/console
echo "drm devices:" > /dev/console
ls -la /dev/dri/ 2>&1 > /dev/console
echo " " > /dev/console
echo "framebuffer:" > /dev/console
ls -la /dev/fb0 2>&1 > /dev/console
echo " " > /dev/console
echo "modules:" > /dev/console
lsmod > /dev/console
echo " " > /dev/console
echo "dmesg drm:" > /dev/console
dmesg | grep -iE "drm|msm|adreno|kgsl" | tail -20 > /dev/console
echo " " > /dev/console
echo "==== END ====" > /dev/console
'

[Install]
WantedBy=graphical.target
DEBUGSVC

    # Create debug login script for A1 - Phosh + GNOME Shell
    cat > "${STAGING}/root/debug-login.sh" << 'DEBUGLOGIN'
#!/bin/sh
echo "=== SYSTEM DEBUG (A1 - Phosh + GNOME Shell) ==="
echo "DRM devices:"
ls -la /dev/dri/ 2>/dev/null || echo "No /dev/dri/"
echo ""
echo "Framebuffer:"
ls -la /dev/fb0 2>/dev/null || echo "No /dev/fb0"
echo ""
echo "Modules:"
lsmod | grep -E "drm|msm|adreno|kgsl|visionox" || echo "No DRM modules"
echo ""
echo "systemd graphical:"
systemctl is-active graphical.target 2>/dev/null || echo "not active"
echo ""
echo "GPU firmware (/lib/firmware/qcom/):"
ls -la /lib/firmware/qcom/a660* 2>/dev/null || echo "No a660 firmware"
echo ""
echo "Spacewar firmware:"
ls -la /lib/firmware/qcom/sm7325/nothing/spacewar/ 2>/dev/null | head -15 || echo "No spacewar firmware"
echo ""
echo "phosh check:"
ls -la /usr/libexec/phosh 2>/dev/null && echo "phosh found at /usr/libexec/phosh" || echo "phosh not found"
ls -la /usr/bin/phosh-session 2>/dev/null && echo "phosh-session found at /usr/bin/phosh-session" || echo "phosh-session not found"
echo ""
echo "phoc check:"
which phoc 2>/dev/null && echo "phoc found at $(which phoc)"
ls -la /usr/bin/phoc 2>/dev/null || echo "phoc not found"
echo ""
echo "phosh service:"
systemctl status phosh.service 2>/dev/null | head -15 || echo "phosh service not found"
echo ""
echo "phosh journal (last 20):"
journalctl -u phosh.service --no-pager -n 20 2>/dev/null || echo "no journal"
echo ""
echo "USB debug:"
echo "  UDC: $(ls /sys/class/udc 2>/dev/null | head -1 || echo 'none')"
echo "  USB role switches:"
for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
    echo "    $r = $(cat $r 2>/dev/null)"
done
echo "  DWC3 dr_mode:"
for d in $(find /sys -name 'dr_mode' -path '*dwc3*' 2>/dev/null); do
    echo "    $d = $(cat $d 2>/dev/null)"
done
echo "  USB gadget:"
ls /sys/kernel/config/usb_gadget/ 2>/dev/null || echo "  no gadget"
echo ""
echo "Wayland socket:"
ls -la /run/user/*/wayland-* 2>/dev/null || echo "No wayland socket"
echo ""
echo "dmesg drm (last 30):"
dmesg | grep -iE "drm|msm|adreno|kgsl|gpu|dpu" | tail -30
echo ""
echo "dmesg firmware:"
dmesg | grep -iE "firmware|a660|gmu|sqe|zap" | tail -20
echo ""
echo "dmesg usb:"
dmesg | grep -iE "usb|dwc3|gadget|udc|role" | tail -20
echo "==================="
echo ""
echo "=== Waiting 5 sec for system to stabilize ==="
sleep 5
echo ""
echo "=== Trying to start Phosh via phosh-session ==="
export XDG_CURRENT_DESKTOP=Phosh:GNOME
export XDG_SESSION_TYPE=wayland
export XDG_RUNTIME_DIR=/run/user/1000
export GDK_BACKEND=wayland,x11
export CLUTTER_BACKEND=wayland

mkdir -p /run/user/1000
chown 1000:1000 /run/user/1000 2>/dev/null

if [ -x /usr/bin/phosh-session ]; then
    echo "Found phosh-session at /usr/bin/phosh-session"
    echo "Starting phosh-session as altlinux user..."
    exec su -s /bin/sh altlinux -c "
        export XDG_CURRENT_DESKTOP=Phosh:GNOME
        export XDG_SESSION_TYPE=wayland
        export XDG_RUNTIME_DIR=/run/user/1000
        export GDK_BACKEND=wayland,x11
        export CLUTTER_BACKEND=wayland
        exec /usr/bin/phosh-session
    " 2>&1
elif [ -x /usr/libexec/phosh ]; then
    echo "Found phosh at /usr/libexec/phosh"
    echo "Starting phosh as altlinux user..."
    exec su -s /bin/sh altlinux -c "
        export XDG_CURRENT_DESKTOP=Phosh:GNOME
        export XDG_SESSION_TYPE=wayland
        export XDG_RUNTIME_DIR=/run/user/1000
        export GDK_BACKEND=wayland,x11
        export CLUTTER_BACKEND=wayland
        exec /usr/libexec/phosh
    " 2>&1
fi

echo "phosh not found, trying phoc with --no-seat..."
PHOC_PATH=""
for p in /usr/bin/phoc /usr/local/bin/phoc /bin/phoc; do
    if [ -x "$p" ]; then
        PHOC_PATH="$p"
        break
    fi
done

if [ -n "$PHOC_PATH" ]; then
    echo "Found phoc at: $PHOC_PATH"
    exec su -s /bin/sh altlinux -c "
        export XDG_RUNTIME_DIR=/run/user/1000
        export WLR_BACKENDS=drm
        exec $PHOC_PATH --no-seat
    " 2>&1
fi

echo "ERROR: No Phosh/Phoc components found!"
DEBUGLOGIN
    chmod +x "${STAGING}/root/debug-login.sh"

    # Add debug to root bashrc
    cat >> "${STAGING}/root/.bashrc" << 'BASHRC'

# Debug login - show system info and try phosh
if [ -f /root/debug-login.sh ]; then
    /root/debug-login.sh
fi
BASHRC

    # Getty autologin on tty1 (works without logind)
    mkdir -p "${STAGING}/etc/systemd/system/getty@tty1.service.d"
    cat > "${STAGING}/etc/systemd/system/getty@tty1.service.d/override.conf" << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN

    # CRITICAL: altlinux user missing from /etc/shadow (tarball defect)
    if ! grep -q '^altlinux:' "${STAGING}/etc/shadow" 2>/dev/null; then
        log "Fixing: adding altlinux to /etc/shadow (missing in source tarball)"
        echo 'altlinux::20538:0:99999:7:::' >> "${STAGING}/etc/shadow"
    fi

    # Also add root user for debug
    if ! grep -q '^root:' "${STAGING}/etc/shadow" 2>/dev/null; then
        log "Fixing: adding root to /etc/shadow"
        echo 'root::20538:0:99999:7:::' >> "${STAGING}/etc/shadow"
    fi

    # Ensure /etc/machine-id exists (systemd-logind requirement)
    if [[ ! -s "${STAGING}/etc/machine-id" ]]; then
        log "Fixing: initializing /etc/machine-id"
        echo "uninitialized" > "${STAGING}/etc/machine-id"
    fi

    # Early module loading - critical drivers that must load before DRM/USB init
    mkdir -p "${STAGING}/etc/modules-load.d"
    cat > "${STAGING}/etc/modules-load.d/early-drivers.conf" << 'MODULES'
# Panel driver (must load before DPU probes)
panel-visionox-rm692e5
# USB PHY drivers (required for DWC3 peripheral mode)
phy-qcom-qmp
phy-qcom-qmp-usb
phy-qcom-usb-snps-femto-v2
# USB gadget core
libcomposite
MODULES

    # Force sync_state completion for pending clock controllers
    # Without CONFIG_QCOM_GMU, clock controllers wait forever for GMU device
    mkdir -p "${STAGING}/etc/systemd/system"
    cat > "${STAGING}/etc/systemd/system/force-sync-state.service" << 'FORCESYNC'
[Unit]
Description=Force sync_state completion for pending devices
DefaultDependencies=no
After=sysinit.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '
    echo "[sync-state] Forcing sync_state completion..." > /dev/console
    # Find all devices with pending sync_state and force them
    for dev in /sys/devices/platform/*; do
        if [ -f "$dev/sync_state" ]; then
            echo 1 > "$dev/sync_state" 2>/dev/null || true
        fi
    done
    # Also try via driver bind/unbind to release clock holds
    for clk_path in /sys/kernel/debug/clk/*/prepare_count; do
        dir=$(dirname "$clk_path")
        if [ -f "$dir/clk_prepare_count" ]; then
            clk_name=$(basename "$dir")
            case "$clk_name" in
                *gmu*|*gpu_cc*)
                    echo "[sync-state] Found GPU/GMU clock: $clk_name" > /dev/console
                    ;;
            esac
        fi
    done
    echo "[sync-state] sync_state forcing complete" > /dev/console
'

[Install]
WantedBy=sysinit.target
FORCESYNC
    mkdir -p "${STAGING}/etc/systemd/system/sysinit.target.wants"
    ln -sf /etc/systemd/system/force-sync-state.service \
        "${STAGING}/etc/systemd/system/sysinit.target.wants/force-sync-state.service"

    # Re-probe DPU after panel module loads
    cat > "${STAGING}/etc/systemd/system/reprobe-dpu.service" << 'REPROBEDPU'
[Unit]
Description=Re-probe DPU after panel driver loads
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '
    echo "[dpu] Waiting 3 sec for panel module..." > /dev/console
    sleep 3

    # Check if panel is loaded
    if lsmod | grep -q visionox; then
        echo "[dpu] Panel driver loaded, re-probing DPU..." > /dev/console
        # Unbind and rebind DPU to pick up panel
        if [ -d /sys/devices/platform/soc/ae01000.display-controller/driver ]; then
            echo ae01000.display-controller > /sys/devices/platform/soc/ae01000.display-controller/driver/unbind 2>/dev/null || true
            sleep 1
            echo ae01000.display-controller > /sys/devices/platform/soc/ae01000.display-controller/driver/bind 2>/dev/null || true
            echo "[dpu] DPU re-probed" > /dev/console
        fi
    else
        echo "[dpu] Panel driver NOT loaded, trying modprobe..." > /dev/console
        modprobe panel-visionox-rm692e5 2>/dev/null || true
        sleep 2
        # Try reprobe anyway
        if [ -d /sys/devices/platform/soc/ae01000.display-controller/driver ]; then
            echo ae01000.display-controller > /sys/devices/platform/soc/ae01000.display-controller/driver/unbind 2>/dev/null || true
            sleep 1
            echo ae01000.display-controller > /sys/devices/platform/soc/ae01000.display-controller/driver/bind 2>/dev/null || true
        fi
    fi

    # Check DSI status
    echo "[dpu] DSI status:" > /dev/console
    for dsi in /sys/devices/platform/soc/*dsi*/; do
        if [ -d "$dsi" ]; then
            echo "  $(basename $dsi): $(cat $dsi/panel/panel/active 2>/dev/null || echo unknown)" > /dev/console
        fi
    done

    # Force DRM modeset retry
    if [ -d /sys/module/drm ]; then
        echo "[dpu] DRM modules loaded:" > /dev/console
        ls /sys/module/drm/ 2>/dev/null | head -5 > /dev/console
    fi
'

[Install]
WantedBy=multi-user.target
REPROBEDPU
    mkdir -p "${STAGING}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/reprobe-dpu.service \
        "${STAGING}/etc/systemd/system/multi-user.target.wants/reprobe-dpu.service"

    # USB Debug Network & Serial Gadget
    mkdir -p "${STAGING}/usr/local/bin"
    cat > "${STAGING}/usr/local/bin/setup-usb-debug.sh" << 'USBSCRIPT'
#!/bin/sh
CONFIGFS="/sys/kernel/config/usb_gadget"
HOST_IP="172.16.42.1"
CLIENT_IP="172.16.42.2"
LOG="/dev/console"

echo "[USB] Starting USB debug gadget" > $LOG

# === Phase 0: Load USB PHY modules ===
echo "[USB] Loading USB PHY modules..." > $LOG
modprobe phy-qcom-qmp 2>/dev/null || true
modprobe phy-qcom-qmp-usb 2>/dev/null || true
modprobe phy-qcom-usb-snps-femto-v2 2>/dev/null || true
sleep 2

# === Phase 1: Force USB peripheral mode via all available methods ===
echo "[USB] Attempting USB role switch..." > $LOG

# Method 1: DWC3 dr_mode
for d in $(find /sys -name 'dr_mode' -path '*dwc3*' 2>/dev/null); do
    echo "[USB] dr_mode $d: $(cat $d 2>/dev/null) -> peripheral" > $LOG
    echo peripheral > "$d" 2>/dev/null && echo "[USB] dr_mode SUCCESS" > $LOG || echo "[USB] dr_mode FAILED" > $LOG
done

# Method 2: USB role switch
for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
    echo "[USB] role_switch $r: $(cat $r 2>/dev/null) -> device" > $LOG
    echo device > "$r" 2>/dev/null && echo "[USB] role_switch SUCCESS" > $LOG || echo "[USB] role_switch FAILED" > $LOG
done

# Method 3: DWC3 mode
for m in $(find /sys -name 'mode' -path '*dwc3*' 2>/dev/null); do
    echo "[USB] mode $m: $(cat $m 2>/dev/null) -> peripheral" > $LOG
    echo peripheral > "$m" 2>/dev/null && echo "[USB] mode SUCCESS" > $LOG || echo "[USB] mode FAILED" > $LOG
done

# Method 4: Force dwc3-qcom reprobe (can trigger role switch)
echo "[USB] Attempting dwc3-qcom reprobe..." > $LOG
for dwc3_qcom in $(find /sys/bus/platform/drivers/dwc3-qcom -name 'a600000.usb' 2>/dev/null); do
    echo "[USB] Found dwc3-qcom device: $dwc3_qcom" > $LOG
    echo a600000.usb > /sys/bus/platform/drivers/dwc3-qcom/unbind 2>/dev/null || true
    sleep 1
    echo a600000.usb > /sys/bus/platform/drivers/dwc3-qcom/bind 2>/dev/null || true
    echo "[USB] dwc3-qcom reprobe done" > $LOG
done

# Wait for UDC to appear
echo "[USB] Waiting 10 sec for UDC..." > $LOG
sleep 10

UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
if [ -z "$UDC" ]; then
    echo "[USB] No UDC after 10s, retrying role switch..." > $LOG
    for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
        echo device > "$r" 2>/dev/null
    done
    # Method 5: Write directly to DWC3 GUSB2PHYCFG if accessible
    echo "[USB] Trying direct PHY config..." > $LOG
    for phy_cfg in $(find /sys -name 'GUSB2PHYCFG*' 2>/dev/null); do
        echo "[USB] Found PHY config: $phy_cfg" > $LOG
    done
    sleep 10
    UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
fi

if [ -z "$UDC" ]; then
    echo "[USB] FAILED: No UDC found after 20s" > $LOG
    echo "[USB] UDC class: $(ls /sys/class/udc 2>/dev/null)" > $LOG
    echo "[USB] role_switch: $(find /sys/class/usb_role_switch/ -name role -exec sh -c 'echo "$1: $(cat $1)"' _ {} \; 2>/dev/null)" > $LOG
    echo "[USB] dwc3-qcom devices:" > $LOG
    ls -la /sys/bus/platform/drivers/dwc3-qcom/ 2>/dev/null > $LOG
    echo "[USB] DWC3 devices:" > $LOG
    ls -la /sys/bus/platform/drivers/dwc3/ 2>/dev/null > $LOG
    echo "[USB] USB PHY drivers:" > $LOG
    lsmod | grep phy 2>/dev/null > $LOG
    return 0
fi

echo "[USB] UDC found: $UDC" > $LOG

modprobe libcomposite 2>/dev/null || true

[ -d "$CONFIGFS" ] || {
    mkdir -p /sys/kernel/config
    mount -t configfs configfs /sys/kernel/config
}
[ -d "$CONFIGFS" ] || { echo "[USB] No configfs, exit"; return 0; }

GADGET="$CONFIGFS/g1"

if [ -d "$GADGET" ]; then
    echo "" > "$GADGET/UDC" 2>/dev/null || true
    rm -rf "$GADGET"
fi

mkdir -p "$GADGET"
echo "0x18D1" > "$GADGET/idVendor"
echo "0xD001" > "$GADGET/idProduct"

mkdir -p "$GADGET/strings/0x409"
echo "Alt Linux" > "$GADGET/strings/0x409/manufacturer"
echo "spacewar-debug" > "$GADGET/strings/0x409/product"
echo "altlinux" > "$GADGET/strings/0x409/serialnumber"

NCM_FUNC="$GADGET/functions/ncm.usb0"
RNDIS_FUNC="$GADGET/functions/rndis.usb0"
ACM_FUNC="$GADGET/functions/acm.usb0"

mkdir -p "$ACM_FUNC" 2>/dev/null || true

USB_FUNC=""
if mkdir -p "$NCM_FUNC" 2>/dev/null; then
    USB_FUNC="$NCM_FUNC"
elif mkdir -p "$RNDIS_FUNC" 2>/dev/null; then
    USB_FUNC="$RNDIS_FUNC"
fi

[ -n "$USB_FUNC" ] || { echo "[USB] No USB network function available"; return 0; }

mkdir -p "$GADGET/configs/c.1/strings/0x409"
echo "USB Debug Network + ACM" > "$GADGET/configs/c.1/strings/0x409/configuration"

ln -sf "$USB_FUNC" "$GADGET/configs/c.1/" 2>/dev/null || true
[ -d "$ACM_FUNC" ] && ln -sf "$ACM_FUNC" "$GADGET/configs/c.1/" 2>/dev/null || true

echo "$UDC" > "$GADGET/UDC" || { echo "[USB] Failed to activate gadget"; return 1; }

sleep 2

IFACE=""
for iface in usb0 rndis0; do
    if ip link show "$iface" >/dev/null 2>&1; then
        IFACE="$iface"
        break
    fi
done

if [ -n "$IFACE" ]; then
    ip addr add "$HOST_IP/24" dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" up 2>/dev/null || true
    echo "[USB] Network ready on $IFACE ($HOST_IP)" > $LOG
else
    echo "[USB] No USB network interface found" > $LOG
fi

echo "[USB] Debug gadget active" > $LOG
USBSCRIPT
    chmod +x "${STAGING}/usr/local/bin/setup-usb-debug.sh"

    # Early USB role switch service - runs at sysinit to force peripheral mode
    mkdir -p "${STAGING}/etc/systemd/system"
    cat > "${STAGING}/etc/systemd/system/usb-role-switch.service" << 'USBROLE'
[Unit]
Description=Force USB Peripheral Mode (Role Switch)
DefaultDependencies=no
After=sysinit.target systemd-modules-load.service
Before=usb-debug.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '
    # Load USB PHY modules first
    modprobe phy-qcom-qmp 2>/dev/null || true
    modprobe phy-qcom-qmp-usb 2>/dev/null || true
    modprobe phy-qcom-usb-snps-femto-v2 2>/dev/null || true
    sleep 2

    for d in $(find /sys -name "dr_mode" -path "*dwc3*" 2>/dev/null); do
        echo peripheral > "$d" 2>/dev/null || true
    done
    for r in $(find /sys/class/usb_role_switch/ -name role 2>/dev/null); do
        echo device > "$r" 2>/dev/null || true
    done
    for m in $(find /sys -name "mode" -path "*dwc3*" 2>/dev/null); do
        echo peripheral > "$m" 2>/dev/null || true
    done
'

[Install]
WantedBy=sysinit.target
USBROLE
    mkdir -p "${STAGING}/etc/systemd/system/sysinit.target.wants"
    ln -sf /etc/systemd/system/usb-role-switch.service \
        "${STAGING}/etc/systemd/system/sysinit.target.wants/usb-role-switch.service"

    mkdir -p "${STAGING}/etc/systemd/system"
    cat > "${STAGING}/etc/systemd/system/usb-debug.service" << 'USBSVC'
[Unit]
Description=USB Debug Network & Serial Gadget
After=usb-role-switch.service sysinit.target systemd-modules-load.service
Wants=usb-role-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-usb-debug.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
USBSVC
    mkdir -p "${STAGING}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/usb-debug.service \
        "${STAGING}/etc/systemd/system/multi-user.target.wants/usb-debug.service"

    # Ensure systemd runtime directories exist
    mkdir -p "${STAGING}/home/altlinux"
    chown -R 1000:1000 "${STAGING}/home/altlinux"
    chmod 755 "${STAGING}/home/altlinux"

    local used_kb=$(du -skx "$STAGING" 2>/dev/null | awk '{print $1}')
    local img_kb=$(( used_kb * 115 / 100 ))
    img_kb=$(( (img_kb + 3) / 4 * 4 ))

    log "Data size: ${used_kb}K, image size: ${img_kb}K"

    log "Creating ${ROOTFS_TYPE} image with ROOT label..."
    truncate -s "${img_kb}K" "$ROOTFS_OUT"

    local mkfs_cmd=$(get_mkfs_cmd "$ROOTFS_OUT")
    eval "$mkfs_cmd" || err "Failed to create $ROOTFS_TYPE filesystem"

    local mount_point="${OUT_DIR}/rootfs_mount"
    mkdir -p "$mount_point"

    log "Mounting image..."
    sudo mount -o loop "$ROOTFS_OUT" "$mount_point"

    log "Copying files to image..."
    sudo cp -a "$STAGING/"* "$mount_point/"

    sudo chmod 755 "$mount_point"/{proc,sys,dev}

    log "Unmounting image..."
    sudo umount -l "$mount_point" 2>/dev/null || true
    sleep 1
    rmdir "$mount_point" 2>/dev/null || true

    local label=$(blkid -s LABEL -o value "$ROOTFS_OUT" 2>/dev/null || echo "none")
    if [[ "$label" == "ROOT" ]]; then
        ok "rootfs.img ready with ROOT label ($(du -h "$ROOTFS_OUT" | cut -f1))"
    else
        warn "ROOT label not set, current: $label"
    fi
}

# Verify built images
verify_images() {
    log "Verifying images..."

    if [[ -f "$BOOT_OUT" ]]; then
        ok "boot.img exists"
    else
        err "boot.img not created"
    fi

    if [[ -f "$ROOTFS_OUT" ]]; then
        ok "rootfs.img exists"
        local label=$(blkid -s LABEL -o value "$ROOTFS_OUT" 2>/dev/null || echo "none")
        if [[ "$label" == "ROOT" ]]; then
            ok "ROOT label set correctly"
        else
            warn "ROOT label not set: $label"
        fi

        local fstype=$(blkid -s TYPE -o value "$ROOTFS_OUT" 2>/dev/null || echo "unknown")
        if [[ "$fstype" == "$ROOTFS_TYPE" ]]; then
            ok "Filesystem type matches: $fstype"
        else
            warn "Filesystem type mismatch: expected $ROOTFS_TYPE, got $fstype"
        fi
    else
        err "rootfs.img not created"
    fi
}

# Main function
main() {
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Build for Nothing Phone 1 (spacewar)         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    validate_fstype
    check_tools
    clean
    fetch_rootfs
    extract_rootfs
    detect_ramdisk
    detect_kernel
    detect_dtb
    copy_firmware
    copy_github_firmware
    decompress_tarball_firmware
    extract_pmos_modules
    patch_extlinux
    prepare_init_scripts
    build_boot
    build_rootfs
    verify_images

    echo ""
    ok "Build completed successfully!"
    echo ""
    echo -e "${BOLD}Flashing instructions:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1. Reboot phone to bootloader:"
    echo "   adb reboot bootloader"
    echo ""
    echo "2. Flash images:"
    echo "   fastboot flash boot out/boot.img"
    echo "   fastboot flash ${ROOTFS_PARTITION} out/rootfs.img"
    echo ""
    echo "3. Reboot:"
    echo "   fastboot reboot"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${BOLD}Build information:${NC}"
    echo "  FS type: $ROOTFS_TYPE"
    echo "  Partition: $ROOTFS_PARTITION"
    echo ""
    warn "WARNING: All data on ${ROOTFS_PARTITION} partition will be permanently deleted!"
    echo ""

    log "Check boot parameters:"
    echo "  root=PARTLABEL=${ROOTFS_PARTITION}"
    echo "  rootfstype=${ROOTFS_TYPE}"
    echo "  Plan: A (phosh graphics)"
}

main "$@"
