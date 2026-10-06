#!/usr/bin/env bash
# Fedora-Arch stage 1 formatter/bootstrapper
# Run ONLY from the Arch ISO, before arch-chroot.
#
# Layout (UEFI/GPT):
#   1) 1 GiB  EFI System Partition -> /boot
#   2) 10 GiB Linux swap
#   3) rest   F2FS root -> /
#
# The F2FS root is created with checksum + compression features and mounted
# with the ArchWiki-recommended F2FS GC/compression options, plus noatime and
# automatic compression of new files to reduce flash writes.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_URL="https://github.com/pastelitto/fedora-arch.git"
TARGET=/mnt
REPO_DST="$TARGET/root/fedora-arch"

F2FS_FEATURES="extra_attr,inode_checksum,sb_checksum,compression"
# zstd:6 is the current ArchWiki recommendation. Compression in F2FS is aimed
# primarily at reducing writes/write amplification rather than exposing free
# space. '*' enables compression on all newly created regular files. Common
# already-compressed media/archive formats are excluded to avoid wasted CPU.
F2FS_OPTS="rw,noatime,lazytime,compress_algorithm=zstd:6,compress_chksum,compress_extension=*,nocompress_extension=jpg,nocompress_extension=jpeg,nocompress_extension=png,nocompress_extension=gif,nocompress_extension=webp,nocompress_extension=avif,nocompress_extension=mp3,nocompress_extension=flac,nocompress_extension=ogg,nocompress_extension=opus,nocompress_extension=mp4,nocompress_extension=mkv,nocompress_extension=webm,nocompress_extension=avi,nocompress_extension=mov,nocompress_extension=zip,nocompress_extension=7z,nocompress_extension=rar,nocompress_extension=gz,nocompress_extension=xz,nocompress_extension=zst,nocompress_extension=iso,atgc,gc_merge"

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || fatal "Run this script as root from the Arch ISO."
}

require_archiso() {
    [[ -e /run/archiso ]] || grep -q 'archisobasedir=' /proc/cmdline 2>/dev/null || \
        fatal "This formatter is only for the Arch ISO environment, outside arch-chroot."
}

require_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] || \
        fatal "UEFI was not detected. Boot the Arch ISO in UEFI mode first."
}

ensure_live_tools() {
    local missing=0 cmd
    for cmd in dialog sgdisk partprobe mkfs.fat mkfs.f2fs pacstrap arch-chroot genfstab git; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    if (( missing )); then
        info "Installing required tools in the live ISO environment"
        pacman -Sy --needed --noconfirm \
            dialog gptfdisk parted dosfstools f2fs-tools arch-install-scripts git
    fi
}

iso_parent_disk() {
    local src pk
    src="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
    [[ -b "$src" ]] || return 0
    pk="$(lsblk -ndo PKNAME "$src" 2>/dev/null || true)"
    if [[ -n "$pk" ]]; then
        printf '/dev/%s\n' "$pk"
    elif [[ "$(lsblk -ndo TYPE "$src" 2>/dev/null || true)" == disk ]]; then
        printf '%s\n' "$src"
    fi
}

choose_disk() {
    local iso_disk d size model serial tran rota kind
    iso_disk="$(iso_parent_disk || true)"
    local -a menu=()
    mapfile -t disks < <(lsblk -dpno NAME,TYPE | awk '$2=="disk" {print $1}')

    for d in "${disks[@]}"; do
        [[ "$d" == "$iso_disk" ]] && continue
        size="$(lsblk -dnro SIZE "$d" | xargs)"
        model="$(lsblk -dnro MODEL "$d" | xargs)"
        serial="$(lsblk -dnro SERIAL "$d" | xargs)"
        tran="$(lsblk -dnro TRAN "$d" | xargs)"
        rota="$(lsblk -dnro ROTA "$d" | xargs)"
        [[ "$rota" == 0 ]] && kind="SSD/non-rotational" || kind="rotational/unknown"
        [[ -n "$model" ]] || model="Unknown model"
        [[ -n "$serial" ]] || serial="no-serial"
        [[ -n "$tran" ]] || tran="unknown-bus"
        menu+=("$d" "$size | $model | $serial | $tran | $kind")
    done

    ((${#menu[@]})) || fatal "No installable disks were found."

    DISK="$(dialog --clear --stdout \
        --title "Fedora-Arch SSD formatter" \
        --menu "Select the ENTIRE target SSD. The Arch ISO boot device is hidden when detectable." \
        22 100 12 "${menu[@]}")" || exit 0

    [[ -b "$DISK" ]] || fatal "Selected target is not a block device: $DISK"
    [[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fatal "$DISK is not a whole disk."

    local bytes min_bytes=$((13 * 1024 * 1024 * 1024))
    bytes="$(blockdev --getsize64 "$DISK")"
    (( bytes > min_bytes )) || fatal "Disk is too small. Need more than ~13 GiB for 1 GiB ESP + 10 GiB swap + root."
}

confirm_destroy() {
    local size model typed
    size="$(lsblk -dnro SIZE "$DISK" | xargs)"
    model="$(lsblk -dnro MODEL "$DISK" | xargs)"

    dialog --title "Partition layout" --yes-label "Continue" --no-label "Cancel" --yesno \
"Target: $DISK\nModel:  $model\nSize:   $size\n\nTHIS WILL ERASE THE ENTIRE DISK.\n\nNew GPT layout:\n  1. 1 GiB EFI/FAT32 mounted at /boot\n  2. 10 GiB swap\n  3. Remaining space F2FS mounted at /\n\nF2FS: checksums + compression + atgc/gc_merge + noatime/lazytime.\nA whole-device TRIM will be attempted when supported." \
        21 78 || exit 0

    typed="$(dialog --stdout --title "FINAL DESTRUCTIVE CONFIRMATION" \
        --inputbox "Type exactly:\n\nERASE $DISK" 10 70)" || exit 0
    [[ "$typed" == "ERASE $DISK" ]] || fatal "Confirmation did not match. Nothing was changed."
}

part_path() {
    local disk="$1" n="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$n"
    else
        printf '%s%s\n' "$disk" "$n"
    fi
}

unmount_selected_disk() {
    local p mp
    while read -r p; do
        [[ -n "$p" ]] || continue
        swapoff "$p" >/dev/null 2>&1 || true
        while read -r mp; do
            [[ -n "$mp" ]] || continue
            umount -R "$mp" >/dev/null 2>&1 || true
        done < <(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
    done < <(lsblk -lnpo NAME "$DISK")
}

wait_for_partition() {
    local p="$1" i
    for ((i=0; i<50; i++)); do
        [[ -b "$p" ]] && return 0
        sleep 0.1
    done
    fatal "Partition node did not appear: $p"
}

partition_and_format() {
    info "Unmounting anything currently using $DISK"
    unmount_selected_disk

    info "Wiping old signatures and partition table"
    wipefs -af "$DISK" || true
    sgdisk --zap-all "$DISK" >/dev/null

    # ArchWiki explicitly documents whole-device blkdiscard as useful for a new
    # SSD installation. It is instant on supporting devices and tells the FTL
    # that all old blocks are free. Unsupported devices simply skip it.
    if blkdiscard "$DISK" >/dev/null 2>&1; then
        ok "Whole-device TRIM/discard completed"
    else
        warn "Whole-device discard unsupported; continuing normally"
    fi

    info "Creating GPT: 1 GiB ESP + 10 GiB swap + remaining F2FS root"
    sgdisk -o "$DISK" >/dev/null
    sgdisk -n 1:1MiB:+1GiB  -t 1:ef00 -c 1:EFI        "$DISK" >/dev/null
    sgdisk -n 2:0:+10GiB    -t 2:8200 -c 2:SWAP       "$DISK" >/dev/null
    sgdisk -n 3:0:0         -t 3:8300 -c 3:ARCHROOT   "$DISK" >/dev/null

    partprobe "$DISK" || true
    udevadm settle

    ESP_PART="$(part_path "$DISK" 1)"
    SWAP_PART="$(part_path "$DISK" 2)"
    ROOT_PART="$(part_path "$DISK" 3)"
    wait_for_partition "$ESP_PART"
    wait_for_partition "$SWAP_PART"
    wait_for_partition "$ROOT_PART"

    info "Formatting EFI partition"
    mkfs.fat -F 32 -n EFI "$ESP_PART"

    info "Formatting 10 GiB swap"
    mkswap -f -L SWAP "$SWAP_PART"

    info "Formatting F2FS root with flash/write-reduction features"
    # Do not hard-code overprovisioning: mkfs.f2fs calculates the best ratio
    # automatically for the actual partition size.
    mkfs.f2fs -f -l ARCHROOT -i -t 1 -O "$F2FS_FEATURES" "$ROOT_PART"

    ok "Partitioning and formatting complete"
}

mount_target() {
    info "Mounting F2FS root at $TARGET"
    mkdir -p "$TARGET"
    mount -t f2fs -o "$F2FS_OPTS" "$ROOT_PART" "$TARGET"

    mkdir -p "$TARGET/boot"
    mount -t vfat -o rw,noatime,umask=0077 "$ESP_PART" "$TARGET/boot"

    # discard=once trims the swap partition when it is enabled without issuing
    # a discard for every freed swap page.
    swapon --discard=once --priority 10 "$SWAP_PART"

    ok "Mounted root, /boot, and swap"
}

bootstrap_arch() {
    info "Bootstrapping minimal Arch base with pacstrap -K"
    # Kernel/firmware are intentionally installed by install.sh *after* ALHP /
    # third-party repository ordering is configured.
    pacstrap -K "$TARGET" \
        base archlinux-keyring f2fs-tools git sudo

    info "Generating UUID-based fstab"
    genfstab -U "$TARGET" > "$TARGET/etc/fstab"

    local root_uuid esp_uuid swap_uuid tmp
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
    esp_uuid="$(blkid -s UUID -o value "$ESP_PART")"
    swap_uuid="$(blkid -s UUID -o value "$SWAP_PART")"

    # Enforce the exact tuned options regardless of how genfstab normalized the
    # live mount flags.
    tmp="$(mktemp)"
    awk -v ru="$root_uuid" -v eu="$esp_uuid" -v su="$swap_uuid" -v ropts="$F2FS_OPTS" '
        BEGIN { OFS="\t" }
        $1 == "UUID=" ru && $2 == "/" {
            print $1, "/", "f2fs", ropts, "0", "1"; next
        }
        $1 == "UUID=" eu && $2 == "/boot" {
            print $1, "/boot", "vfat", "rw,noatime,umask=0077", "0", "2"; next
        }
        $1 == "UUID=" su && $3 == "swap" {
            print $1, "none", "swap", "defaults,discard=once,pri=10", "0", "0"; next
        }
        { print }
    ' "$TARGET/etc/fstab" > "$tmp"
    install -m0644 "$tmp" "$TARGET/etc/fstab"
    rm -f "$tmp"

    ok "Base system and tuned fstab created"
}

copy_repo_inside() {
    info "Copying the fedora-arch Git working tree into the new system"
    rm -rf "$REPO_DST"
    mkdir -p "$(dirname "$REPO_DST")"

    if [[ -d "$SCRIPT_DIR/.git" && -f "$SCRIPT_DIR/install.sh" ]]; then
        mkdir -p "$REPO_DST"
        cp -a "$SCRIPT_DIR"/. "$REPO_DST"/
        ok "Copied current Git checkout, including .git and local changes"
    else
        local repo_url="$DEFAULT_REPO_URL"
        if [[ -d "$SCRIPT_DIR/.git" ]]; then
            repo_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || printf '%s' "$DEFAULT_REPO_URL")"
        fi
        git clone "$repo_url" "$REPO_DST"
        # Ensure this exact formatter is present even if it has not been pushed yet.
        install -m0755 "$SCRIPT_DIR/format.sh" "$REPO_DST/format.sh"
        [[ -f "$SCRIPT_DIR/install.sh" ]] && install -m0755 "$SCRIPT_DIR/install.sh" "$REPO_DST/install.sh"
        ok "Cloned $repo_url into /root/fedora-arch"
    fi

    chmod +x "$REPO_DST/install.sh" "$REPO_DST/format.sh" 2>/dev/null || true
}

run_stage2() {
    [[ -x "$REPO_DST/install.sh" ]] || fatal "install.sh is missing inside $REPO_DST"

    dialog --title "Stage 1 complete" --msgbox \
"Disk preparation and pacstrap are complete.\n\nThe repository is now at:\n  /root/fedora-arch\n\nThe script will now enter:\n  arch-chroot /mnt\n\nand start install.sh.\n\ninstall.sh remains interactive for desktop, repositories, dracut/bootloader, debloat, NVIDIA, etc." \
        17 76

    clear
    info "Entering arch-chroot and launching install.sh"
    arch-chroot "$TARGET" /bin/bash -lc 'cd /root/fedora-arch && exec ./install.sh'
    ok "install.sh completed successfully"
}

finish() {
    sync
    if dialog --title "Installation complete" --defaultno --yesno \
        "install.sh finished successfully.\n\nUnmount /mnt, disable swap, and reboot now?" 10 65; then
        swapoff "$SWAP_PART" >/dev/null 2>&1 || true
        umount -R "$TARGET"
        sync
        reboot
    else
        clear
        cat <<EOF_DONE

Installation completed and remains mounted for inspection.

Root:  $ROOT_PART -> /mnt
Boot:  $ESP_PART  -> /mnt/boot
Swap:  $SWAP_PART
Repo:  /mnt/root/fedora-arch

When ready:
  swapoff '$SWAP_PART'
  umount -R /mnt
  reboot
EOF_DONE
    fi
}

main() {
    require_root
    require_archiso
    require_uefi
    ensure_live_tools
    choose_disk
    confirm_destroy
    clear
    partition_and_format
    mount_target
    bootstrap_arch
    copy_repo_inside
    run_stage2
    finish
}

main "$@"
