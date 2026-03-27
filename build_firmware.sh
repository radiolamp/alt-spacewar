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

FW_REPO="https://github.com/mainlining/firmware-nothing-spacewar"
FW_REPO_DIR="${SCRIPT_DIR}/pmos/firmware-nothing-spacewar"

BASE=0x00000000
KERNEL_OFFSET=0x00008000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0x00000000
TAGS_OFFSET=0x00000100
DTB_OFFSET=0x04000000
PAGE_SIZE=4096
HEADER_VERSION=2
CMDLINE=""

PSEUDO_DIRS=(proc sys dev run tmp media mnt selinux srv)
RSYNC_EXTRA_EXCLUDES=(--exclude=/out/ --exclude=/pmos/ --exclude=/cache/)

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
    rm -rf "$OUT_DIR" "$CACHE_DIR"
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
    
    # Copy to cache directory
    cp "$ROOTFS_ARCHIVE" "$ARCHIVE" || err "Failed to copy archive"
    ok "Rootfs copied to cache"
}

# Extract rootfs
extract_rootfs() {
    log "Extracting rootfs..."
    rm -rf "$ROOT_DIR"
    mkdir -p "$ROOT_DIR"

    local fmt=$(file -b "$ARCHIVE")
    if [[ "$fmt" == *"XZ compressed"* ]]; then
        local inner=$(xz -dc "$ARCHIVE" 2>/dev/null | file -b - || true)

        if [[ "$inner" == *"tar archive"* ]]; then
            fakeroot tar -xJf "$ARCHIVE" -C "$ROOT_DIR" --no-same-owner
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
    if [[ -d "$FW_REPO_DIR/.git" ]]; then
        git -C "$FW_REPO_DIR" pull --ff-only &>/dev/null || true
    else
        git clone --depth=1 "$FW_REPO" "$FW_REPO_DIR" &>/dev/null || err "Failed to clone firmware repo"
    fi
    rsync -a --exclude='.git/' "$FW_REPO_DIR/" "$ROOT_DIR/" &>/dev/null
    ok "Firmware copied"
}

# Prepare full fstab
prepare_fstab() {
    log "Configuring fstab..."
    local fstab="${ROOT_DIR}/etc/fstab"
    local mount_opts=$(get_mount_options)

    # Create full fstab with all necessary mount points
    cat > "$fstab" << EOF
# Root filesystem
proc			/proc		proc	nosuid,noexec,gid=proc				0 0
devpts			/dev/pts	devpts	nosuid,noexec,gid=tty,mode=620,ptmxmode=0666	0 0
tmpfs			/tmp		tmpfs	nosuid						0 0
PARTLABEL=${ROOTFS_PARTITION}	/	${ROOTFS_TYPE}	defaults,x-systemd.growfs	0 1

EOF

    ok "fstab configured for $ROOTFS_TYPE"
}

# Create basic initialization scripts
prepare_init_scripts() {
    log "Creating init scripts..."

    # Create early init directory if it doesn't exist
    mkdir -p "${ROOT_DIR}/lib/systemd/system" 2>/dev/null || true

    # Check for systemd or sysvinit
    if [[ -f "${ROOT_DIR}/sbin/init" ]] || [[ -L "${ROOT_DIR}/init" ]]; then
        ok "Init system detected"
    else
        warn "Init system not found, creating symlink"
        ln -sf sbin/init "${ROOT_DIR}/init" 2>/dev/null || true
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

    # Use PARTLABEL for reliable mounting
    # Add debug parameters and workarounds
    CMDLINE="root=PARTLABEL=${ROOTFS_PARTITION} rootfstype=${ROOTFS_TYPE} rootwait rw console=ttyMSM8,115200n8 console=tty0 loglevel=4"
    mkbootimg \
        --kernel "$kernel_gz" \
        --ramdisk "$RAMDISK" \
        --dtb "$DTB" \
        --base $BASE \
        --kernel_offset $KERNEL_OFFSET \
        --ramdisk_offset $RAMDISK_OFFSET \
        --second_offset $SECOND_OFFSET \
        --tags_offset $TAGS_OFFSET \
        --dtb_offset $DTB_OFFSET \
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
        "${ROOT_DIR}/" "${STAGING}/"

    # Create necessary directories
    for d in "${PSEUDO_DIRS[@]}"; do
        mkdir -p "${STAGING}/${d}"
    done

    local used_kb=$(du -skx "$STAGING" 2>/dev/null | awk '{print $1}')
    local img_kb=$(( used_kb * 115 / 100 ))
    img_kb=$(( (img_kb + 3) / 4 * 4 ))

    log "Data size: ${used_kb}K, image size: ${img_kb}K"

    log "Creating ${ROOTFS_TYPE} image with ROOT label..."
    truncate -s "${img_kb}K" "$ROOTFS_OUT"

    # Execute filesystem creation command
    local mkfs_cmd=$(get_mkfs_cmd "$ROOTFS_OUT")
    eval "$mkfs_cmd" || err "Failed to create $ROOTFS_TYPE filesystem"

    local mount_point="${OUT_DIR}/rootfs_mount"
    mkdir -p "$mount_point"

    log "Mounting image..."
    sudo mount -o loop "$ROOTFS_OUT" "$mount_point"

    log "Copying files to image..."
    sudo cp -a "$STAGING"/* "$mount_point/"

    # Set proper permissions on important directories
    sudo chmod 755 "$mount_point"/{proc,sys,dev,run,tmp}
    sudo chmod 1777 "$mount_point/tmp"
    sudo chmod 1777 "$mount_point/run"

    log "Unmounting image..."
    sudo umount "$mount_point"
    rmdir "$mount_point"

    # Check label
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

    # Check boot.img
    if [[ -f "$BOOT_OUT" ]]; then
        ok "boot.img exists"
    else
        err "boot.img not created"
    fi

    # Check rootfs.img
    if [[ -f "$ROOTFS_OUT" ]]; then
        ok "rootfs.img exists"
        local label=$(blkid -s LABEL -o value "$ROOTFS_OUT" 2>/dev/null || echo "none")
        if [[ "$label" == "ROOT" ]]; then
            ok "ROOT label set correctly"
        else
            warn "ROOT label not set: $label"
        fi

        # Check filesystem type
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

    # Validation and setup
    validate_fstype
    check_tools
    clean
    fetch_rootfs
    extract_rootfs
    detect_ramdisk
    detect_kernel
    detect_dtb
    copy_firmware
    prepare_fstab
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

    # Additional check before exit
    log "Check boot parameters:"
    echo "  root=PARTLABEL=${ROOTFS_PARTITION}"
    echo "  rootfstype=${ROOTFS_TYPE}"
    echo "  rootwait rw"
}

main "$@"
