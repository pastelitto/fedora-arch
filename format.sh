#!/usr/bin/env bash
# Fedora-Arch stage 1 disk formatter/bootstrapper
# Run ONLY from the Arch ISO, before arch-chroot.
#
# Goals:
# - top-level storage menu: create mdadm RAID, format/install, or mount prepared storage
# - safe disk selector + destructive confirmation
# - user-selected /boot size, swap size, root/home layout
# - root/home filesystem: F2FS, ext4, Btrfs, XFS
# - /boot filesystem can be FAT32 or, in advanced mode, a Linux filesystem
#   with a separate 512 MiB FAT32 ESP at /efi
# - F2FS mount options are PROBED against the running Arch ISO kernel before
#   being written to fstab, so an unsupported option cannot abort the install
# - mdadm RAID0/1/10/5/6 creation with chunk + data-offset controls
# - pacstrap -K, exact UUID fstab, repo copy, automatic arch-chroot -> install.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_URL="https://github.com/pastelitto/fedora-arch.git"
TARGET=/mnt
REPO_DST="$TARGET/root/fedora-arch"
FORMAT_LOG=/tmp/fedora-arch-format.log

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || fatal "Run this script as root from the Arch ISO."
}

require_archiso() {
    [[ -e /run/archiso ]] || grep -q 'archisobasedir=' /proc/cmdline 2>/dev/null || \
        fatal "This script is only for the Arch ISO environment, outside arch-chroot."
}

require_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] || \
        fatal "UEFI was not detected. Boot the Arch ISO in UEFI mode first."
}

ensure_live_tools() {
    local missing=0 cmd
    for cmd in dialog sgdisk partprobe mkfs.fat mkfs.f2fs mkfs.ext4 mkfs.xfs mkfs.btrfs \
               pacstrap arch-chroot git blkid findmnt swapon mdadm wipefs blockdev; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    if (( missing )); then
        info "Installing formatter tools into the live ISO"
        pacman -Sy --needed --noconfirm \
            dialog gptfdisk parted dosfstools f2fs-tools e2fsprogs xfsprogs \
            btrfs-progs arch-install-scripts git mdadm
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
    DISK="$(dialog --clear --stdout --title "Fedora-Arch disk setup" \
        --menu "Select the ENTIRE target disk. The Arch ISO device is hidden when detectable." \
        22 105 12 "${menu[@]}")" || exit 0

    [[ -b "$DISK" ]] || fatal "Selected target is not a block device: $DISK"
    [[ "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fatal "$DISK is not a whole disk."
    DISK_BYTES="$(blockdev --getsize64 "$DISK")"
}

# Return whole disks which are members of an active MD array.
active_md_member_disks() {
    local md slave parent
    for md in /sys/block/md*; do
        [[ -d "$md/slaves" ]] || continue
        for slave in "$md"/slaves/*; do
            [[ -e "$slave" ]] || continue
            parent="$(lsblk -ndo PKNAME "/dev/${slave##*/}" 2>/dev/null || true)"
            if [[ -n "$parent" ]]; then
                printf '/dev/%s\n' "$parent"
            else
                printf '/dev/%s\n' "${slave##*/}"
            fi
        done
    done | sort -u
}

next_md_device() {
    local i
    for ((i=0; i<128; i++)); do
        [[ -e "/dev/md$i" ]] || { printf '/dev/md%d\n' "$i"; return 0; }
    done
    fatal "No free /dev/mdN device name was found."
}

raid_level_min_disks() {
    case "$1" in
        0) echo 2 ;;
        1) echo 2 ;;
        10) echo 4 ;;
        5) echo 3 ;;
        6) echo 4 ;;
        *) echo 99 ;;
    esac
}

chunk_to_kib() {
    local x="${1^^}" n
    if [[ "$x" =~ ^([0-9]+)K$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
    if [[ "$x" =~ ^([0-9]+)M$ ]]; then echo $(( BASH_REMATCH[1] * 1024 )); return; fi
    if [[ "$x" =~ ^([0-9]+)G$ ]]; then echo $(( BASH_REMATCH[1] * 1024 * 1024 )); return; fi
    [[ "$x" =~ ^[0-9]+$ ]] && { echo "$x"; return; }
    return 1
}

is_power_of_two() {
    local n="$1"
    (( n > 0 && (n & (n - 1)) == 0 ))
}

choose_raid_chunk() {
    local choice kib
    if [[ "$RAID_LEVEL" == 1 ]]; then
        RAID_CHUNK=""
        return 0
    fi
    while true; do
        choice="$(dialog --stdout --title "RAID chunk size" --default-item 512K --menu \
            "Choose mdadm chunk size. RAID5/6/10 require a power of two. RAID1 does not use a chunk size." \
            24 84 16 \
            64K '64 KiB' 128K '128 KiB' 256K '256 KiB' 512K '512 KiB (mdadm create default)' \
            1M '1 MiB' 2M '2 MiB' 3M '3 MiB' 4M '4 MiB' 5M '5 MiB' 6M '6 MiB' \
            7M '7 MiB' 8M '8 MiB' custom 'Custom value')" || return 1
        if [[ "$choice" == custom ]]; then
            choice="$(dialog --stdout --title "Custom RAID chunk" --inputbox \
                "Enter a chunk value such as 1024K, 2M, or 4096K." 9 64 '512K')" || return 1
        fi
        kib="$(chunk_to_kib "$choice" 2>/dev/null || true)"
        [[ -n "$kib" && "$kib" -ge 4 ]] || { dialog --msgbox "Chunk must be at least 4 KiB." 7 48; continue; }
        if [[ "$RAID_LEVEL" =~ ^(5|6|10)$ ]] && ! is_power_of_two "$kib"; then
            dialog --msgbox "RAID$RAID_LEVEL requires a power-of-two chunk. Choose 64K/128K/256K/512K/1M/2M/4M/8M or a valid custom power-of-two value." 10 78
            continue
        fi
        RAID_CHUNK="$choice"
        return 0
    done
}

choose_raid_offset() {
    local choice
    choice="$(dialog --stdout --title "MD data offset / SSD alignment" --default-item 8M --menu \
        "mdadm metadata 1.2 can place array data after an explicit offset. For an Intel SSD with an 8 MiB erase/alignment unit, choose 8M. This is --data-offset, not reserved filesystem space." \
        26 100 18 \
        auto 'Let mdadm choose automatically' \
        1M '1 MiB' 2M '2 MiB' 3M '3 MiB' 4M '4 MiB' 5M '5 MiB' 6M '6 MiB' \
        7M '7 MiB' 8M '8 MiB' 9M '9 MiB' 10M '10 MiB' 11M '11 MiB' 12M '12 MiB' \
        13M '13 MiB' 14M '14 MiB' 15M '15 MiB' 16M '16 MiB' custom 'Custom offset')" || return 1
    if [[ "$choice" == custom ]]; then
        choice="$(dialog --stdout --title "Custom mdadm data offset" --inputbox \
            "Enter an offset accepted by mdadm, for example 8192K, 8M, or 16M." 9 70 '8M')" || return 1
        [[ "$choice" =~ ^[0-9]+([KkMmGgTt])?$ ]] || { dialog --msgbox "Invalid offset." 7 40; return 1; }
    fi
    [[ "$choice" == auto ]] && RAID_DATA_OFFSET="" || RAID_DATA_OFFSET="$choice"
}

create_raid_array() {
    local iso_disk d size model min typed summary mdname
    iso_disk="$(iso_parent_disk || true)"

    RAID_LEVEL="$(dialog --stdout --title "Create Linux software RAID" --default-item 0 --menu \
        "First select the RAID level." 18 78 8 \
        0 'RAID0 - striping, speed/capacity, no redundancy' \
        1 'RAID1 - mirror, redundancy' \
        10 'RAID10 - striped mirrors, 4+ drives' \
        5 'RAID5 - single parity, 3+ drives' \
        6 'RAID6 - dual parity, 4+ drives')" || return 0

    local -a menu=() selected=()
    local -A active_members=()
    while read -r d; do [[ -n "$d" ]] && active_members["$d"]=1; done < <(active_md_member_disks)
    while read -r d; do
        [[ -b "$d" ]] || continue
        [[ "$d" == "$iso_disk" ]] && continue
        [[ -n "${active_members[$d]:-}" ]] && continue
        size="$(lsblk -dnro SIZE "$d" | xargs)"
        model="$(lsblk -dnro MODEL "$d" | xargs)"; [[ -n "$model" ]] || model='Unknown model'
        menu+=("$d" "$size | $model" off)
    done < <(lsblk -dpno NAME,TYPE | awk '$2=="disk" {print $1}')
    ((${#menu[@]})) || fatal "No physical disks are available for RAID."

    mapfile -t selected < <(dialog --stdout --separate-output --title "RAID member disks" --checklist \
        "Select the WHOLE disks to become RAID members. Selected disks will be wiped when the array is created." \
        24 100 14 "${menu[@]}") || return 0

    min="$(raid_level_min_disks "$RAID_LEVEL")"
    if (( ${#selected[@]} < min )); then
        dialog --msgbox "RAID$RAID_LEVEL requires at least $min disks; you selected ${#selected[@]}." 8 62
        return 0
    fi
    if [[ "$RAID_LEVEL" == 10 ]] && (( ${#selected[@]} % 2 != 0 )); then
        dialog --msgbox "This installer requires an even number of drives for RAID10." 8 64
        return 0
    fi

    choose_raid_chunk || return 0
    choose_raid_offset || return 0
    MD_DEVICE="$(next_md_device)"
    mdname="fedora-arch-${MD_DEVICE##*/md}"

    summary="Array: $MD_DEVICE\nLevel: RAID$RAID_LEVEL\nMetadata: 1.2\nMembers: ${selected[*]}\n"
    [[ -n "$RAID_CHUNK" ]] && summary+="Chunk: $RAID_CHUNK\n"
    [[ -n "$RAID_DATA_OFFSET" ]] && summary+="Data offset: $RAID_DATA_OFFSET\n" || summary+="Data offset: mdadm automatic\n"
    summary+="\nTHIS WRITES MD METADATA AND WIPES SIGNATURES ON EVERY SELECTED MEMBER DISK."
    dialog --title "Confirm RAID creation" --yes-label Create --no-label Cancel --yesno "$summary" 20 92 || return 0
    typed="$(dialog --stdout --title "DESTRUCTIVE RAID CONFIRMATION" --inputbox \
        "Type exactly:\n\nCREATE $MD_DEVICE" 10 70)" || return 0
    [[ "$typed" == "CREATE $MD_DEVICE" ]] || { dialog --msgbox "Confirmation did not match; RAID was not created." 7 62; return 0; }

    clear
    info "Creating $MD_DEVICE with mdadm $(mdadm --version 2>&1 | head -n1)"
    for d in "${selected[@]}"; do
        local child mp
        while read -r child; do
            [[ -n "$child" ]] || continue
            swapoff "$child" >/dev/null 2>&1 || true
            while read -r mp; do [[ -n "$mp" ]] && umount -R "$mp" >/dev/null 2>&1 || true; done < <(findmnt -rn -S "$child" -o TARGET 2>/dev/null || true)
        done < <(lsblk -lnpo NAME "$d")
        mdadm --zero-superblock --force "$d" >/dev/null 2>&1 || true
        wipefs -af "$d"
    done

    local -a cmd=(mdadm --create "$MD_DEVICE" --run --force --metadata=1.2 --level="$RAID_LEVEL" --raid-devices="${#selected[@]}" --name="$mdname")
    [[ -n "$RAID_CHUNK" ]] && cmd+=(--chunk="$RAID_CHUNK")
    [[ -n "$RAID_DATA_OFFSET" ]] && cmd+=(--data-offset="$RAID_DATA_OFFSET")
    cmd+=("${selected[@]}")
    "${cmd[@]}"
    udevadm settle
    [[ -b "$MD_DEVICE" ]] || fatal "mdadm returned success but $MD_DEVICE did not appear."
    mdadm --detail "$MD_DEVICE" || true
    ok "$MD_DEVICE created. Returning to the storage menu so it can be selected as the install/format target."
    read -r -p 'Press Enter to return to the menu... ' _ || true
}

choose_format_target() {
    local iso_disk dev type size model
    iso_disk="$(iso_parent_disk || true)"
    local -a menu=()
    while read -r dev type; do
        [[ -b "$dev" ]] || continue
        [[ "$dev" == "$iso_disk" ]] && continue
        case "$type" in
            disk)
                size="$(lsblk -dnro SIZE "$dev" | xargs)"
                model="$(lsblk -dnro MODEL "$dev" | xargs)"; [[ -n "$model" ]] || model='Unknown model'
                menu+=("$dev" "DISK | $size | $model")
                ;;
            raid0|raid1|raid10|raid5|raid6)
                size="$(lsblk -dnro SIZE "$dev" | xargs)"
                menu+=("$dev" "MD RAID (${type#raid}) | $size")
                ;;
        esac
    done < <(lsblk -dpno NAME,TYPE)
    ((${#menu[@]})) || fatal "No disk or active MD RAID target was found."
    INSTALL_TARGET="$(dialog --stdout --title "Format/install target" --menu \
        "Select a physical disk for the normal partition layout, or an MD RAID array for root. RAID root uses a separate selectable FAT32 /boot/ESP device." \
        24 105 14 "${menu[@]}")" || return 1
    type="$(lsblk -dnro TYPE "$INSTALL_TARGET")"
    if [[ "$type" == disk ]]; then
        TARGET_KIND=disk
        DISK="$INSTALL_TARGET"
        DISK_BYTES="$(blockdev --getsize64 "$DISK")"
    else
        TARGET_KIND=md
        RAID_ROOT="$INSTALL_TARGET"
        DISK_BYTES="$(blockdev --getsize64 "$RAID_ROOT")"
    fi
}

choose_boot_target_for_md() {
    local iso_disk dev type size fs model parent
    iso_disk="$(iso_parent_disk || true)"
    local -a menu=()
    local -A blocked=()
    local slave
    for slave in "/sys/block/${RAID_ROOT##*/}"/slaves/*; do
        [[ -e "$slave" ]] || continue
        parent="$(lsblk -ndo PKNAME "/dev/${slave##*/}" 2>/dev/null || true)"
        [[ -n "$parent" ]] && blocked["/dev/$parent"]=1 || blocked["/dev/${slave##*/}"]=1
    done

    while read -r dev type size fs; do
        [[ -b "$dev" ]] || continue
        [[ "$dev" == "$RAID_ROOT" || "$dev" == "$iso_disk" ]] && continue
        [[ -n "${blocked[$dev]:-}" ]] && continue
        case "$type" in
            disk)
                model="$(lsblk -dnro MODEL "$dev" | xargs)"; [[ -n "$model" ]] || model='Unknown model'
                menu+=("$dev" "WHOLE DISK | $size | $model (will create a new FAT32 ESP)")
                ;;
            part)
                parent="/dev/$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)"
                [[ -n "${blocked[$parent]:-}" || "$parent" == "$iso_disk" ]] && continue
                menu+=("$dev" "PARTITION | $size | ${fs:-unformatted} (partition will be formatted FAT32)")
                ;;
        esac
    done < <(lsblk -rpno NAME,TYPE,SIZE,FSTYPE)
    ((${#menu[@]})) || fatal "No separate disk/partition is available for the RAID system's UEFI /boot."
    RAID_BOOT_TARGET="$(dialog --stdout --title "Separate /boot for RAID root" --menu \
        "UEFI firmware cannot boot your root MD array directly. Select a separate physical disk or partition for FAT32 /boot. A USB device is allowed." \
        24 110 14 "${menu[@]}")" || return 1
    RAID_BOOT_TYPE="$(lsblk -dnro TYPE "$RAID_BOOT_TARGET")"
    BOOT_FS=fat32
    SWAP_GIB=0
    CREATE_HOME=0
    HOME_FS=""
    ROOT_GIB=0
    if [[ "$RAID_BOOT_TYPE" == disk ]]; then
        local bytes gib maxb
        bytes="$(blockdev --getsize64 "$RAID_BOOT_TARGET")"; gib=$((bytes/1024/1024/1024)); maxb=$gib; ((maxb>16)) && maxb=16
        (( maxb >= 1 )) || fatal "Selected boot disk is smaller than 1 GiB."
        ask_integer "RAID /boot size" "How many GiB should the new FAT32 /boot ESP use on $RAID_BOOT_TARGET? The rest of the disk is left unallocated." 1 1 "$maxb"
        BOOT_GIB="$REPLY"
    else
        BOOT_GIB=0
    fi
}

collect_f2fs_compression_choice() {
    F2FS_COMPRESSION=0
    if [[ "${ROOT_FS:-}" == f2fs || "${HOME_FS:-}" == f2fs ]]; then
        if dialog --title "F2FS compression" --defaultno --yes-label Enable --no-label 'No compression' --yesno \
            "Enable the F2FS compression feature for root/home?\n\nDefault: NO.\n\nIf you choose No, mkfs.f2fs will NOT enable the compression feature and fstab will NOT contain compress_* options." 13 78; then
            F2FS_COMPRESSION=1
        fi
    fi
}

collect_md_layout() {
    choose_linux_fs "RAID root filesystem" f2fs
    ROOT_FS="$REPLY"
    collect_f2fs_compression_choice
    choose_boot_target_for_md
    ROOT_PART="$RAID_ROOT"
    HOME_PART=""
    SWAP_PART=""
    BOOT_PART="$RAID_BOOT_TARGET"
    ESP_PART="$RAID_BOOT_TARGET"
}

confirm_md_format() {
    local typed summary
    summary="Root MD array: $RAID_ROOT -> $ROOT_FS\nF2FS compression: $([[ ${F2FS_COMPRESSION:-0} -eq 1 ]] && echo enabled || echo disabled)\n"
    if [[ "$RAID_BOOT_TYPE" == disk ]]; then
        summary+="/boot device: $RAID_BOOT_TARGET (WHOLE DISK will be repartitioned; ${BOOT_GIB} GiB FAT32 ESP)\n"
    else
        summary+="/boot device: $RAID_BOOT_TARGET (partition will be formatted FAT32)\n"
    fi
    summary+="\nThe RAID array filesystem and selected boot target will lose existing data."
    dialog --title "Confirm RAID-root formatting" --yes-label Continue --no-label Cancel --yesno "$summary" 18 92 || return 1
    typed="$(dialog --stdout --title "DESTRUCTIVE CONFIRMATION" --inputbox "Type exactly:\n\nFORMAT $RAID_ROOT" 10 70)" || return 1
    [[ "$typed" == "FORMAT $RAID_ROOT" ]] || fatal "Confirmation did not match. Nothing was changed."
}

prepare_md_boot_target() {
    if [[ "$RAID_BOOT_TYPE" == disk ]]; then
        local p mp
        while read -r p; do
            swapoff "$p" >/dev/null 2>&1 || true
            while read -r mp; do [[ -n "$mp" ]] && umount -R "$mp" >/dev/null 2>&1 || true; done < <(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
        done < <(lsblk -lnpo NAME "$RAID_BOOT_TARGET")
        wipefs -af "$RAID_BOOT_TARGET" || true
        sgdisk --zap-all "$RAID_BOOT_TARGET" >/dev/null
        sgdisk -o "$RAID_BOOT_TARGET" >/dev/null
        sgdisk -n "1:1MiB:+${BOOT_GIB}GiB" -t '1:ef00' -c '1:EFI' "$RAID_BOOT_TARGET" >/dev/null
        partprobe "$RAID_BOOT_TARGET" || true
        udevadm settle
        ESP_PART="$(part_path "$RAID_BOOT_TARGET" 1)"
        BOOT_PART="$ESP_PART"
        wait_for_partition "$ESP_PART"
    else
        umount "$RAID_BOOT_TARGET" >/dev/null 2>&1 || true
        ESP_PART="$RAID_BOOT_TARGET"
        BOOT_PART="$RAID_BOOT_TARGET"
    fi
}

choose_existing_device() {
    local title="$1" types="$2" dev type size fs
    local -a menu=()
    while read -r dev type size fs; do
        [[ -b "$dev" ]] || continue
        [[ -n "$fs" ]] || continue
        [[ "$type" =~ $types ]] || continue
        menu+=("$dev" "$type | $size | $fs")
    done < <(lsblk -rpno NAME,TYPE,SIZE,FSTYPE)
    ((${#menu[@]})) || return 1
    REPLY="$(dialog --stdout --title "$title" --menu "Select an already-prepared block device. Nothing is formatted in this mode." 22 100 14 "${menu[@]}")" || return 1
}

collect_existing_mount_layout() {
    choose_existing_device "Existing root filesystem" '^(part|raid0|raid1|raid10|raid5|raid6)$' || fatal "No formatted root candidates found."
    ROOT_PART="$REPLY"
    ROOT_FS="$(lsblk -no FSTYPE "$ROOT_PART" | head -n1)"
    [[ -n "$ROOT_FS" ]] || fatal "Could not detect root filesystem."
    choose_existing_device "Existing FAT32 /boot ESP" '^part$' || fatal "No formatted partition candidates found for /boot."
    BOOT_PART="$REPLY"; ESP_PART="$REPLY"
    local bfs="$(lsblk -no FSTYPE "$BOOT_PART" | head -n1)"
    [[ "$bfs" == vfat ]] || fatal "Mount-existing mode currently requires a preformatted FAT32/vfat /boot partition."
    BOOT_FS=fat32; BOOT_GIB=0; SWAP_GIB=0; SWAP_PART=""; CREATE_HOME=0; HOME_FS=""; HOME_PART=""; F2FS_COMPRESSION=0
}

storage_menu() {
    while true; do
        local action
        action="$(dialog --stdout --title "Fedora-Arch storage" --default-item install --menu \
            "Create RAID first if desired; after creation you return here and the MD array appears in Format/install target." \
            19 102 8 \
            raid 'Create Linux software RAID (mdadm)' \
            install 'Format/partition storage and install Arch' \
            mount 'Mount already-prepared root + /boot and install (no format)' \
            exit 'Exit without changing anything')" || exit 0
        case "$action" in
            raid) create_raid_array ;;
            install) choose_format_target || continue; INSTALL_MODE=format; return 0 ;;
            mount) collect_existing_mount_layout; INSTALL_MODE=mount; TARGET_KIND=existing; return 0 ;;
            exit) exit 0 ;;
        esac
    done
}

ask_integer() {
    local title="$1" prompt="$2" default="$3" min="$4" max="$5" value
    while true; do
        value="$(dialog --stdout --title "$title" --inputbox "$prompt" 10 72 "$default")" || exit 0
        [[ "$value" =~ ^[0-9]+$ ]] || { dialog --msgbox "Enter a whole number." 7 40; continue; }
        (( value >= min && value <= max )) || {
            dialog --msgbox "Value must be between $min and $max GiB." 8 48
            continue
        }
        REPLY="$value"
        return 0
    done
}

choose_linux_fs() {
    local title="$1" default_item="${2:-f2fs}"
    REPLY="$(dialog --stdout --title "$title" --default-item "$default_item" --menu \
        "Choose filesystem" 17 74 8 \
        f2fs "Flash-friendly; tuned + validated options" \
        ext4 "Conservative, fast, very compatible" \
        btrfs "Checksums/snapshots; zstd compression" \
        xfs "High-throughput filesystem")" || exit 0
}

collect_layout() {
    local disk_gib max_boot max_swap max_root
    disk_gib=$(( DISK_BYTES / 1024 / 1024 / 1024 ))
    (( disk_gib >= 20 )) || fatal "Target disk is too small (${disk_gib} GiB)."

    max_boot=$(( disk_gib / 4 )); (( max_boot > 16 )) && max_boot=16
    ask_integer "Boot size" "How many GiB for /boot?\n\nDefault: 1 GiB" 1 1 "$max_boot"
    BOOT_GIB="$REPLY"

    BOOT_FS="$(dialog --stdout --title "/boot filesystem" --default-item fat32 --menu \
        "Standard UEFI requires a FAT ESP. If you choose a Linux filesystem, this script safely creates an extra 512 MiB FAT32 ESP at /efi and uses your chosen filesystem for /boot. install.sh will then require GRUB." \
        19 95 8 \
        fat32 "FAT32 ESP mounted directly at /boot (recommended)" \
        ext4  "ext4 /boot + separate FAT32 ESP at /efi" \
        xfs   "XFS /boot + separate FAT32 ESP at /efi" \
        btrfs "Btrfs /boot + separate FAT32 ESP at /efi" \
        f2fs  "F2FS /boot + separate FAT32 ESP at /efi")" || exit 0

    max_swap=$(( disk_gib / 2 )); (( max_swap > 128 )) && max_swap=128
    ask_integer "Swap size" "How many GiB for swap?\n\n0 disables disk swap.\nDefault: 10 GiB" 10 0 "$max_swap"
    SWAP_GIB="$REPLY"

    choose_linux_fs "Root filesystem" f2fs
    ROOT_FS="$REPLY"

    if dialog --title "Separate /home" --yes-label Yes --no-label No --yesno \
        "Create a separate /home partition?\n\nIf yes, you choose the root size and /home receives all remaining space." 10 70; then
        CREATE_HOME=1
        local reserved=$(( BOOT_GIB + SWAP_GIB + 3 ))
        [[ "$BOOT_FS" != fat32 ]] && reserved=$(( reserved + 1 ))
        max_root=$(( disk_gib - reserved - 4 ))
        (( max_root >= 8 )) || fatal "Disk is too small for a separate /home with these sizes."
        local default_root=64
        (( default_root > max_root )) && default_root="$max_root"
        ask_integer "Root size" "How many GiB for / ?\n\n/home gets all remaining space." "$default_root" 8 "$max_root"
        ROOT_GIB="$REPLY"
        choose_linux_fs "/home filesystem" "$ROOT_FS"
        HOME_FS="$REPLY"
    else
        CREATE_HOME=0
        ROOT_GIB=0
        HOME_FS=""
    fi

    collect_f2fs_compression_choice

    local extra_esp=0
    [[ "$BOOT_FS" != fat32 ]] && extra_esp=1
    local fixed=$(( BOOT_GIB + SWAP_GIB + extra_esp + (CREATE_HOME ? ROOT_GIB : 0) ))
    (( fixed + 2 < disk_gib )) || fatal "Chosen fixed partitions leave too little room for the final filesystem."
}

confirm_destroy() {
    local size model typed summary
    size="$(lsblk -dnro SIZE "$DISK" | xargs)"
    model="$(lsblk -dnro MODEL "$DISK" | xargs)"

    summary="Target: $DISK\nModel: $model\nSize: $size\n\n"
    if [[ "$BOOT_FS" == fat32 ]]; then
        summary+="1) /boot  ${BOOT_GIB} GiB FAT32 ESP\n"
    else
        summary+="1) /efi   512 MiB FAT32 ESP\n2) /boot  ${BOOT_GIB} GiB ${BOOT_FS}\n"
    fi
    summary+="swap: ${SWAP_GIB} GiB\n"
    if (( CREATE_HOME )); then
        summary+="/:     ${ROOT_GIB} GiB ${ROOT_FS}\n/home:  remainder ${HOME_FS}\n"
    else
        summary+="/:     all remaining space ${ROOT_FS}\n"
    fi
    summary+="\nTHIS ERASES THE ENTIRE TARGET DISK."

    dialog --title "Final layout" --yes-label Continue --no-label Cancel --yesno "$summary" 22 78 || exit 0
    typed="$(dialog --stdout --title "DESTRUCTIVE CONFIRMATION" \
        --inputbox "Type exactly:\n\nERASE $DISK" 10 70)" || exit 0
    [[ "$typed" == "ERASE $DISK" ]] || fatal "Confirmation did not match. Nothing was changed."
}

part_path() {
    local disk="$1" n="$2"
    [[ "$disk" =~ [0-9]$ ]] && printf '%sp%s\n' "$disk" "$n" || printf '%s%s\n' "$disk" "$n"
}

wait_for_partition() {
    local p="$1" i
    for ((i=0; i<100; i++)); do
        [[ -b "$p" ]] && return 0
        sleep 0.1
    done
    fatal "Partition node did not appear: $p"
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

add_partition() {
    local idx="$1" start="$2" size="$3" type="$4" label="$5"
    if [[ "$size" == rest ]]; then
        sgdisk -n "${idx}:${start}:0" -t "${idx}:${type}" -c "${idx}:${label}" "$DISK" >/dev/null
    else
        sgdisk -n "${idx}:${start}:+${size}" -t "${idx}:${type}" -c "${idx}:${label}" "$DISK" >/dev/null
    fi
}

partition_disk() {
    info "Unmounting anything currently using $DISK"
    unmount_selected_disk
    wipefs -af "$DISK" || true
    sgdisk --zap-all "$DISK" >/dev/null

    if blkdiscard "$DISK" >/dev/null 2>&1; then
        ok "Whole-device discard completed"
    else
        warn "Whole-device discard unsupported; continuing"
    fi

    sgdisk -o "$DISK" >/dev/null
    local idx=1

    if [[ "$BOOT_FS" == fat32 ]]; then
        ESP_IDX=$idx; BOOT_IDX=$idx
        add_partition "$idx" 1MiB "${BOOT_GIB}GiB" ef00 EFI
        ((idx++))
    else
        ESP_IDX=$idx
        add_partition "$idx" 1MiB 512MiB ef00 EFI
        ((idx++))
        BOOT_IDX=$idx
        add_partition "$idx" 0 "${BOOT_GIB}GiB" 8300 BOOT
        ((idx++))
    fi

    if (( SWAP_GIB > 0 )); then
        SWAP_IDX=$idx
        add_partition "$idx" 0 "${SWAP_GIB}GiB" 8200 SWAP
        ((idx++))
    else
        SWAP_IDX=0
    fi

    ROOT_IDX=$idx
    if (( CREATE_HOME )); then
        add_partition "$idx" 0 "${ROOT_GIB}GiB" 8300 ARCHROOT
        ((idx++))
        HOME_IDX=$idx
        add_partition "$idx" 0 rest 8300 ARCHHOME
        ((idx++))
    else
        HOME_IDX=0
        add_partition "$idx" 0 rest 8300 ARCHROOT
        ((idx++))
    fi

    partprobe "$DISK" || true
    udevadm settle

    ESP_PART="$(part_path "$DISK" "$ESP_IDX")"
    BOOT_PART="$(part_path "$DISK" "$BOOT_IDX")"
    ROOT_PART="$(part_path "$DISK" "$ROOT_IDX")"
    wait_for_partition "$ESP_PART"
    wait_for_partition "$BOOT_PART"
    wait_for_partition "$ROOT_PART"
    if (( SWAP_IDX )); then SWAP_PART="$(part_path "$DISK" "$SWAP_IDX")"; wait_for_partition "$SWAP_PART"; else SWAP_PART=""; fi
    if (( HOME_IDX )); then HOME_PART="$(part_path "$DISK" "$HOME_IDX")"; wait_for_partition "$HOME_PART"; else HOME_PART=""; fi
}

format_linux_fs() {
    local fs="$1" dev="$2" label="$3" role="${4:-root}"
    info "Formatting $dev as $fs ($label)"
    case "$fs" in
        f2fs)
            # Compression is explicit opt-in. If disabled, the compression
            # feature is not placed in the F2FS superblock at all.
            local features="extra_attr,inode_checksum,sb_checksum"
            if (( ${F2FS_COMPRESSION:-0} )) && [[ "$role" != boot ]]; then
                features+=",compression"
            fi
            mkfs.f2fs -f -l "$label" -i -t 1 -O "$features" "$dev"
            ;;
        ext4) mkfs.ext4 -F -L "$label" "$dev" ;;
        btrfs) mkfs.btrfs -f -L "$label" "$dev" ;;
        xfs) mkfs.xfs -f -L "$label" "$dev" ;;
        *) fatal "Unsupported Linux filesystem: $fs" ;;
    esac
}

format_partitions() {
    info "Formatting EFI System Partition"
    mkfs.fat -F 32 -n EFI "$ESP_PART"

    if [[ "$BOOT_FS" != fat32 ]]; then
        format_linux_fs "$BOOT_FS" "$BOOT_PART" BOOT boot
    fi
    (( SWAP_GIB > 0 )) && mkswap -f -L SWAP "$SWAP_PART"
    format_linux_fs "$ROOT_FS" "$ROOT_PART" ARCHROOT root
    (( CREATE_HOME )) && format_linux_fs "$HOME_FS" "$HOME_PART" ARCHHOME home
}

# Return conservative/tuned mount options for non-F2FS filesystems.
base_mount_opts() {
    local fs="$1" role="$2"
    if [[ "$role" == boot ]]; then
        case "$fs" in
            fat32) printf 'rw,noatime,umask=0077' ;;
            *)     printf 'rw,noatime,lazytime' ;;
        esac
        return 0
    fi
    case "$fs" in
        fat32) printf 'rw,noatime,umask=0077' ;;
        ext4)  printf 'rw,noatime,lazytime,commit=60' ;;
        xfs)   printf 'rw,noatime,lazytime,inode64' ;;
        btrfs) printf 'rw,noatime,lazytime,compress=zstd:3,discard=async' ;;
        *)     printf 'rw,noatime,lazytime' ;;
    esac
}

# Probe one complete option set by mounting and immediately unmounting it.
probe_mount_set() {
    local fs="$1" dev="$2" opts="$3" probe=/run/fedora-arch-mount-probe
    mkdir -p "$probe"
    umount "$probe" >/dev/null 2>&1 || true
    if mount -t "$fs" -o "$opts" "$dev" "$probe" >/dev/null 2>&1; then
        umount "$probe"
        return 0
    fi
    umount "$probe" >/dev/null 2>&1 || true
    return 1
}

verified_f2fs_opts() {
    local dev="$1" role="${2:-root}"
    local opts="rw,noatime,lazytime"
    local opt trial

    probe_mount_set f2fs "$dev" "$opts" || {
        opts="rw,noatime"
        probe_mount_set f2fs "$dev" "$opts" || fatal "F2FS cannot be mounted even with safe options: $dev"
    }

    # Keep /boot deliberately conservative. GRUB has to read kernel/initramfs
    # files itself, so root/home get the aggressive F2FS policy while /boot
    # gets only universally safe mount options.
    if [[ "$role" == boot ]]; then
        printf '%s' "$opts"
        return 0
    fi

    # Every advanced option is tested by a real mount before it is accepted.
    # Unsupported kernel/f2fs-tools combinations are skipped instead of making
    # the whole installer fail (the bug in the previous format.sh).
    local -a candidates=(
        "background_gc=on"
        "checkpoint_merge"
        "gc_merge"
        "atgc"
        "flush_merge"
    )
    if (( ${F2FS_COMPRESSION:-0} )); then
        candidates+=(
            "compress_algorithm=zstd:6"
            "compress_chksum"
            "compress_extension=*"
        )
    fi

    for opt in "${candidates[@]}"; do
        trial="$opts,$opt"
        if probe_mount_set f2fs "$dev" "$trial"; then
            opts="$trial"
        else
            warn "F2FS option rejected by this live kernel; skipping: $opt"
        fi
    done
    printf '%s' "$opts"
}

mount_verified() {
    local fs="$1" dev="$2" target="$3" role="$4" opts safe
    mkdir -p "$target"

    if [[ "$fs" == f2fs ]]; then
        opts="$(verified_f2fs_opts "$dev" "$role")"
    else
        opts="$(base_mount_opts "$fs" "$role")"
        if ! probe_mount_set "$fs" "$dev" "$opts"; then
            warn "$fs tuned option set was rejected; falling back to rw,noatime,lazytime"
            opts="rw,noatime,lazytime"
            if ! probe_mount_set "$fs" "$dev" "$opts"; then
                opts="defaults"
                probe_mount_set "$fs" "$dev" "$opts" || fatal "Could not mount $dev as $fs"
            fi
        fi
    fi

    mount -t "$fs" -o "$opts" "$dev" "$target" || fatal "Failed to mount $dev at $target with verified options: $opts"
    REPLY="$opts"
}

format_md_layout() {
    info "Formatting separate RAID /boot ESP"
    mkfs.fat -F 32 -n EFI "$ESP_PART"
    format_linux_fs "$ROOT_FS" "$ROOT_PART" ARCHROOT root
}

mount_existing_target() {
    info "Mounting already-prepared root and /boot without formatting"
    mkdir -p "$TARGET"
    mountpoint -q "$TARGET" && fatal "$TARGET is already mounted."
    mount_verified "$ROOT_FS" "$ROOT_PART" "$TARGET" root
    ROOT_OPTS="$REPLY"
    mkdir -p "$TARGET/boot"
    BOOT_OPTS="rw,noatime,umask=0077"
    mount -t vfat -o "$BOOT_OPTS" "$BOOT_PART" "$TARGET/boot"
    EFI_MOUNT=/boot
    HOME_OPTS=""; EFI_OPTS=""; SWAP_PART=""
}

mount_target() {
    info "Mounting root"
    mkdir -p "$TARGET"
    if mountpoint -q "$TARGET"; then
        fatal "$TARGET is already mounted after target-disk cleanup. Unmount it first so this installer cannot overwrite another mounted system."
    fi
    mount_verified "$ROOT_FS" "$ROOT_PART" "$TARGET" root
    ROOT_OPTS="$REPLY"

    if (( CREATE_HOME )); then
        info "Mounting /home"
        mount_verified "$HOME_FS" "$HOME_PART" "$TARGET/home" home
        HOME_OPTS="$REPLY"
    else
        HOME_OPTS=""
    fi

    if [[ "$BOOT_FS" == fat32 ]]; then
        mkdir -p "$TARGET/boot"
        BOOT_OPTS="rw,noatime,umask=0077"
        mount -t vfat -o "$BOOT_OPTS" "$ESP_PART" "$TARGET/boot"
        EFI_MOUNT=/boot
    else
        info "Mounting selected /boot filesystem"
        mount_verified "$BOOT_FS" "$BOOT_PART" "$TARGET/boot" boot
        BOOT_OPTS="$REPLY"
        mkdir -p "$TARGET/efi"
        EFI_OPTS="rw,noatime,umask=0077"
        mount -t vfat -o "$EFI_OPTS" "$ESP_PART" "$TARGET/efi"
        EFI_MOUNT=/efi
    fi

    if (( SWAP_GIB > 0 )); then
        # One trim at activation, not per-page discards.
        swapon --discard=once --priority 10 "$SWAP_PART"
    fi

    ok "All filesystems mounted successfully"
    info "Verified root mount options: $ROOT_OPTS"
    [[ "$BOOT_FS" != fat32 ]] && info "Verified /boot mount options: $BOOT_OPTS"
    (( CREATE_HOME )) && info "Verified /home mount options: $HOME_OPTS"
}

uuid_of() { blkid -s UUID -o value "$1"; }

write_exact_fstab() {
    info "Writing exact UUID fstab using only mount options already verified by the live kernel"
    install -d "$TARGET/etc"
    {
        echo '# /etc/fstab: generated by fedora-arch format.sh'
        printf 'UUID=%s\t/\t%s\t%s\t0\t1\n' "$(uuid_of "$ROOT_PART")" "$ROOT_FS" "$ROOT_OPTS"
        if [[ "$BOOT_FS" == fat32 ]]; then
            printf 'UUID=%s\t/boot\tvfat\t%s\t0\t2\n' "$(uuid_of "$ESP_PART")" "$BOOT_OPTS"
        else
            printf 'UUID=%s\t/boot\t%s\t%s\t0\t2\n' "$(uuid_of "$BOOT_PART")" "$BOOT_FS" "$BOOT_OPTS"
            printf 'UUID=%s\t/efi\tvfat\t%s\t0\t2\n' "$(uuid_of "$ESP_PART")" "$EFI_OPTS"
        fi
        (( CREATE_HOME )) && printf 'UUID=%s\t/home\t%s\t%s\t0\t2\n' "$(uuid_of "$HOME_PART")" "$HOME_FS" "$HOME_OPTS"
        (( SWAP_GIB > 0 )) && printf 'UUID=%s\tnone\tswap\tdefaults,discard=once,pri=10\t0\t0\n' "$(uuid_of "$SWAP_PART")"
    } > "$TARGET/etc/fstab"

    # Syntax/semantic sanity check before stage 2. The actual option sets were
    # already proven by real mounts above; this catches a malformed fstab line.
    if ! findmnt --verify --tab-file "$TARGET/etc/fstab" >/dev/null 2>&1; then
        cat "$TARGET/etc/fstab" >&2
        fatal "Generated fstab did not pass findmnt --verify."
    fi

    cat > "$TARGET/etc/fedora-arch-layout.conf" <<EOF_LAYOUT
EFI_MOUNT=$EFI_MOUNT
BOOT_FS=$BOOT_FS
ROOT_FS=$ROOT_FS
HOME_FS=$HOME_FS
F2FS_COMPRESSION=${F2FS_COMPRESSION:-0}
ROOT_ON_MD=$([[ "${ROOT_PART:-}" == /dev/md* ]] && echo 1 || echo 0)
EOF_LAYOUT
}

bootstrap_arch() {
    info "Bootstrapping minimal Arch base with pacstrap -K"
    local -a pkgs=(base archlinux-keyring git sudo dosfstools)
    case "$ROOT_FS $BOOT_FS $HOME_FS" in *f2fs*) pkgs+=(f2fs-tools) ;; esac
    case "$ROOT_FS $BOOT_FS $HOME_FS" in *ext4*) pkgs+=(e2fsprogs) ;; esac
    case "$ROOT_FS $BOOT_FS $HOME_FS" in *btrfs*) pkgs+=(btrfs-progs) ;; esac
    case "$ROOT_FS $BOOT_FS $HOME_FS" in *xfs*) pkgs+=(xfsprogs) ;; esac
    local root_type
    root_type="$(lsblk -ndo TYPE "$ROOT_PART" 2>/dev/null || true)"
    [[ "$ROOT_PART" == /dev/md* || "$root_type" == raid* ]] && pkgs+=(mdadm)
    # Deduplicate without relying on associative-array ordering.
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++')
    pacstrap -K "$TARGET" "${pkgs[@]}"
    write_exact_fstab

    if [[ "$ROOT_PART" == /dev/md* || "$(lsblk -ndo TYPE "$ROOT_PART" 2>/dev/null || true)" == raid* ]]; then
        info "Writing mdadm array assembly configuration into the target system"
        mdadm --detail --scan > "$TARGET/etc/mdadm.conf"
    fi

    install -d "$TARGET/var/log"
    cp -f "$FORMAT_LOG" "$TARGET/var/log/fedora-arch-format.log" 2>/dev/null || true
    ok "pacstrap and fstab complete"
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
        install -m0755 "$SCRIPT_DIR/format.sh" "$REPO_DST/format.sh"
        [[ -f "$SCRIPT_DIR/install.sh" ]] && install -m0755 "$SCRIPT_DIR/install.sh" "$REPO_DST/install.sh"
        ok "Cloned $repo_url into /root/fedora-arch"
    fi
    chmod +x "$REPO_DST/install.sh" "$REPO_DST/format.sh" 2>/dev/null || true
}

run_stage2() {
    [[ -x "$REPO_DST/install.sh" ]] || fatal "install.sh is missing inside $REPO_DST"

    dialog --title "Stage 1 complete" --msgbox \
"Disk preparation and pacstrap are complete.\n\nRoot: $ROOT_PART ($ROOT_FS)\nBoot: $BOOT_PART ($BOOT_FS)\nEFI:  $ESP_PART mounted at $EFI_MOUNT\n\nThe repository is at /root/fedora-arch.\n\nThe script will now enter arch-chroot /mnt and launch install.sh." 17 84

    clear
    info "Entering arch-chroot and launching install.sh"
    arch-chroot "$TARGET" /bin/bash -lc 'cd /root/fedora-arch && exec ./install.sh'
    ok "install.sh completed successfully"
}

finish() {
    sync
    if dialog --title "Installation complete" --defaultno --yesno \
        "install.sh finished successfully.\n\nUnmount /mnt, disable swap, and reboot now?" 10 66; then
        [[ -n "${SWAP_PART:-}" ]] && swapoff "$SWAP_PART" >/dev/null 2>&1 || true
        umount -R "$TARGET"
        sync
        reboot
    else
        clear
        cat <<EOF_DONE

Installation completed and remains mounted for inspection.

Root: $ROOT_PART -> /mnt ($ROOT_FS)
Boot: $BOOT_PART -> /mnt/boot ($BOOT_FS)
ESP:  $ESP_PART -> /mnt$EFI_MOUNT
${HOME_PART:+Home: $HOME_PART -> /mnt/home ($HOME_FS)}
${SWAP_PART:+Swap: $SWAP_PART}
Repo: /mnt/root/fedora-arch
Logs: /mnt/var/log/fedora-arch-format.log

When ready:
  swapoff '${SWAP_PART:-none}' 2>/dev/null || true
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
    storage_menu

    if [[ "$INSTALL_MODE" == format ]]; then
        if [[ "$TARGET_KIND" == disk ]]; then
            collect_layout
            confirm_destroy
        else
            collect_md_layout
            confirm_md_format || exit 0
        fi
    fi

    # Start detailed logging only once the interactive storage choices are done.
    : > "$FORMAT_LOG"
    exec > >(tee -a "$FORMAT_LOG") 2>&1
    clear

    if [[ "$INSTALL_MODE" == mount ]]; then
        mount_existing_target
    elif [[ "$TARGET_KIND" == disk ]]; then
        partition_disk
        format_partitions
        mount_target
    else
        prepare_md_boot_target
        format_md_layout
        mount_target
    fi

    bootstrap_arch
    copy_repo_inside
    run_stage2
    finish
}

main "$@"
