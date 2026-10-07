#!/usr/bin/env bash
# Fedora-like Arch post-install configurator
# UEFI only. Run this AFTER entering the installed system with: arch-chroot /mnt
# Assumptions: base Arch is installed and networking works. The EFI System
# Partition is mounted at /boot for the standard layout, or at /efi when a
# Linux filesystem was selected for /boot by format.sh.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=/var/log/fedora-arch-installer.log

WALLPAPER_ASSET_DIR="$SCRIPT_DIR/assets/wallpapers"
FEDORA_BACKGROUND_ASSET_DIR="$SCRIPT_DIR/assets/backgrounds"
FEDORA_LOOKANDFEEL_ASSET_DIR="$SCRIPT_DIR/assets/fedora-look-and-feel"
FEDORA_BRANDING_ASSET_DIR="$SCRIPT_DIR/assets/fedora-branding"
FEDORA_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/fedora-config"
FAUGUS_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/faugus-launcher"
CACHY_KERNEL_ASSET="$SCRIPT_DIR/assets/cachy-kernel/build-cachyos-kernel.sh"

# Built dynamically from the selected performance/debloat options. Root= and
# BOOT_IMAGE are intentionally never stored here; bootloaders add their own
# root device information.
KERNEL_EXTRA_ARGS=()
EFI_MOUNT=""

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer suffix='[y/N]'
    [[ "$default" == y ]] && suffix='[Y/n]'
    while true; do
        read -r -p "$prompt $suffix " answer || true
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

ask_choice() {
    local prompt="$1" default="$2"; shift 2
    local options=("$@") choice i
    while true; do
        echo
        echo "$prompt"
        for ((i=0; i<${#options[@]}; i++)); do
            if [[ $((i+1)) == "$default" ]]; then
                printf '  %d) %s  [default]\n' "$((i+1))" "${options[$i]}"
            else
                printf '  %d) %s\n' "$((i+1))" "${options[$i]}"
            fi
        done
        read -r -p "Choice [$default]: " choice || true
        choice="${choice:-$default}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY="$choice"
            return 0
        fi
        echo "Invalid choice."
    done
}

read_secret_twice() {
    local label="$1" a b
    while true; do
        read -r -s -p "$label: " a || true; echo
        [[ -n "$a" ]] || { echo "Password cannot be empty."; continue; }
        read -r -s -p "Confirm $label: " b || true; echo
        [[ "$a" == "$b" ]] || { echo "Passwords do not match."; continue; }
        REPLY="$a"
        return 0
    done
}

require_root() {
    [[ $EUID -eq 0 ]] || fatal "Run as root."
}

is_archiso() {
    [[ -e /run/archiso ]] || grep -q 'archisobasedir=' /proc/cmdline 2>/dev/null
}

require_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] || fatal \
        "UEFI firmware was not detected. Configure the VM to use UEFI/OVMF, then boot the Arch ISO again."
}

# -----------------------------------------------------------------------------
# Questions — this script runs inside the installed Arch chroot
# -----------------------------------------------------------------------------
require_installed_arch_chroot() {
    [[ -f /etc/arch-release ]] || fatal "This does not look like an Arch installation."

    local root_source
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    case "$root_source" in
        airootfs|overlay|/dev/loop*|"")
            fatal "Run this script AFTER: arch-chroot /mnt (not from the Arch ISO root shell)."
            ;;
    esac
}

require_boot_esp() {
    # /boot may itself be the FAT ESP (the normal/default layout), or format.sh
    # may have created a Linux-filesystem /boot plus a separate FAT ESP at /efi.
    mountpoint -q /boot || fatal "/boot is not mounted. Run format.sh or mount the boot filesystem first."

    local boot_fs efi_fs
    boot_fs="$(findmnt -n -o FSTYPE /boot 2>/dev/null || true)"
    case "$boot_fs" in
        vfat|fat|msdos)
            EFI_MOUNT=/boot
            ;;
        *)
            if mountpoint -q /efi; then
                efi_fs="$(findmnt -n -o FSTYPE /efi 2>/dev/null || true)"
                case "$efi_fs" in
                    vfat|fat|msdos) EFI_MOUNT=/efi ;;
                    *) fatal "/efi exists but is '$efi_fs', not a FAT EFI System Partition." ;;
                esac
            else
                fatal "/boot is '$boot_fs', so a separate FAT EFI System Partition must be mounted at /efi."
            fi
            ;;
    esac
}

collect_answers() {
    clear || true
    cat <<'BANNER'
================================================================
   Fedora-style Arch configurator — post arch-chroot, UEFI only
================================================================
This script DOES NOT partition, format, mount, or pacstrap anything.

Expected workflow:
  1) Run ./format.sh from the Arch ISO (or prepare/mount manually)
  2) arch-chroot /mnt
  3) run ./install.sh

format.sh supports the normal FAT ESP at /boot, or an advanced Linux /boot
with a separate FAT ESP at /efi (GRUB only).

User/password/hostname setup can be completed now or deferred to the desktop's
first-boot OOBE (Plasma Setup on KDE, GNOME Initial Setup on GNOME).

Package transactions are automatic (--noconfirm). Preferred providers are
installed explicitly first (for example PipeWire JACK), so pacman does not
stop on JACK/provider questions during the unattended part of the setup.
BANNER

    ask_choice "Account setup" 1 \
        "Use the desktop first-boot setup (Plasma Setup / GNOME Initial Setup)" \
        "Create the administrator account now"
    case "$REPLY" in
        1)
            ACCOUNT_SETUP=oobe
            INSTALL_USERNAME=""
            INSTALL_HOSTNAME=""
            USER_PASSWORD=""
            ROOT_PASSWORD=""
            ;;
        2)
            ACCOUNT_SETUP=now
            while true; do
                read -r -p "Administrator username: " INSTALL_USERNAME
                if [[ "$INSTALL_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && ! id "$INSTALL_USERNAME" >/dev/null 2>&1; then
                    break
                fi
                echo "Use a new lowercase username (letters, digits, _ or -, maximum 32 characters)."
            done
            read_secret_twice "Password for $INSTALL_USERNAME"
            USER_PASSWORD="$REPLY"
            if ask_yes_no "Use the same password for root?" y; then
                ROOT_PASSWORD="$USER_PASSWORD"
            else
                read_secret_twice "Root password"
                ROOT_PASSWORD="$REPLY"
            fi
            while true; do
                read -r -p "Hostname: " INSTALL_HOSTNAME
                if [[ ${#INSTALL_HOSTNAME} -le 253 && "$INSTALL_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$INSTALL_HOSTNAME" != *..* ]]; then
                    break
                fi
                echo "Enter a valid hostname (letters, digits, dots and hyphens)."
            done
            ;;
    esac

    while true; do
        read -r -p "Time zone [America/Mexico_City]: " INSTALL_TIMEZONE
        INSTALL_TIMEZONE="${INSTALL_TIMEZONE:-America/Mexico_City}"
        [[ -f "/usr/share/zoneinfo/$INSTALL_TIMEZONE" ]] && break
        echo "Unknown zone. Use an IANA name such as America/Mexico_City or America/Chicago."
    done

    ask_choice "Desktop environment" 1 \
        "KDE Plasma" \
        "GNOME"
    case "$REPLY" in
        1) DESKTOP=kde ;;
        2) DESKTOP=gnome ;;
    esac

    if [[ "$DESKTOP" == kde ]]; then
        ask_choice "KDE edition" 1 \
            "Minimal KDE (choose optional applications)" \
            "Fedora KDE (complete application set)"
        case "$REPLY" in
            1)
                KDE_EDITION=minimal
                FEDORA_DEFAULT_APPS=0
                ask_yes_no "Install LibreOffice Fresh?" y && INSTALL_LIBREOFFICE=1 || INSTALL_LIBREOFFICE=0
                ask_yes_no "Install Lutris?" n && INSTALL_LUTRIS=1 || INSTALL_LUTRIS=0
                ask_yes_no "Install Steam?" n && INSTALL_STEAM=1 || INSTALL_STEAM=0
                ask_yes_no "Install Faugus Launcher?" n && INSTALL_FAUGUS=1 || INSTALL_FAUGUS=0
                ask_yes_no "Install ProtonUp-Qt?" n && INSTALL_PROTONUP_QT=1 || INSTALL_PROTONUP_QT=0
                ask_yes_no "Install the full virt-manager/QEMU/libvirt stack?" n && INSTALL_VIRT_MANAGER=1 || INSTALL_VIRT_MANAGER=0
                ;;
            2)
                KDE_EDITION=fedora
                FEDORA_DEFAULT_APPS=1
                INSTALL_LIBREOFFICE=1
                INSTALL_LUTRIS=1
                INSTALL_STEAM=1
                INSTALL_FAUGUS=1
                INSTALL_PROTONUP_QT=1
                INSTALL_VIRT_MANAGER=1
                ;;
        esac

        if (( INSTALL_FAUGUS )) && ask_yes_no \
            "Import the captured Pastelitto Faugus preferences and global environment variables?" y; then
            IMPORT_FAUGUS_SETTINGS=1
        else
            IMPORT_FAUGUS_SETTINGS=0
        fi

        if [[ "$KDE_EDITION" == minimal ]]; then
            if ask_yes_no "Enable daily automatic Discover updates, applied after rebooting?" y; then
                ENABLE_DISCOVER_SYSTEM=1
            else
                ENABLE_DISCOVER_SYSTEM=0
            fi

            if ask_yes_no "Spoof Discover's OS view so it does not show the Arch/PackageKit warning?" y; then
                SPOOF_DISCOVER_WARNING=1
            else
                SPOOF_DISCOVER_WARNING=0
            fi
        else
            # Fedora KDE is the complete preset.
            ENABLE_DISCOVER_SYSTEM=1
            SPOOF_DISCOVER_WARNING=1
        fi

        if ask_yes_no "Apply the KDE Pastelitto customization to the first user?" n; then
            APPLY_PASTELITTO_KDE=1
        else
            APPLY_PASTELITTO_KDE=0
        fi
    else
        KDE_EDITION=none
        if ask_yes_no "Install the Fedora default/captured application bundle?" y; then
            FEDORA_DEFAULT_APPS=1
        else
            FEDORA_DEFAULT_APPS=0
        fi
        INSTALL_LIBREOFFICE=0
        INSTALL_LUTRIS=0
        INSTALL_STEAM=0
        INSTALL_FAUGUS=0
        INSTALL_PROTONUP_QT=0
        INSTALL_VIRT_MANAGER=0
        IMPORT_FAUGUS_SETTINGS=0
        ENABLE_DISCOVER_SYSTEM=0
        SPOOF_DISCOVER_WARNING=0
        APPLY_PASTELITTO_KDE=0
    fi

    if ask_yes_no "Install Fish and make it the default shell for the administrator user?" y; then
        INSTALL_FISH=1
    else
        INSTALL_FISH=0
    fi

    if ask_yes_no "Enable ALHP optimized repositories?" y; then
        ENABLE_ALHP=1
        ask_choice "Choose ALHP CPU level" 1 \
            "x86-64-v2" \
            "x86-64-v3" \
            "x86-64-v4"
        case "$REPLY" in
            1) ALHP_LEVEL=v2 ;;
            2) ALHP_LEVEL=v3 ;;
            3) ALHP_LEVEL=v4 ;;
        esac
    else
        ENABLE_ALHP=0
        ALHP_LEVEL=""
    fi

    if ask_yes_no "Enable CachyOS general repository (below Arch/ALHP, above Chaotic-AUR)?" y; then
        ENABLE_CACHYOS=1
    else
        ENABLE_CACHYOS=0
    fi

    if ask_yes_no "Enable Chaotic-AUR permanently?" y; then
        ENABLE_CHAOTIC=1
    else
        ENABLE_CHAOTIC=0
    fi

    ask_choice "Initramfs generator" 1 \
        "dracut (Fedora default style)" \
        "mkinitcpio (Arch default)" \
        "booster"
    case "$REPLY" in
        1) INITRAMFS=dracut ;;
        2) INITRAMFS=mkinitcpio ;;
        3) INITRAMFS=booster ;;
    esac

    ask_choice "UEFI boot loader" 1 \
        "GRUB (installed with --removable)" \
        "systemd-boot" \
        "Limine (fallback EFI path)"
    case "$REPLY" in
        1) BOOTLOADER=grub ;;
        2) BOOTLOADER=systemd-boot ;;
        3) BOOTLOADER=limine ;;
    esac

    # systemd-boot/Limine handling in this project expects the kernel files on
    # the ESP mounted at /boot.  A Linux-filesystem /boot + /efi layout is
    # intentionally supported through GRUB only.
    if [[ "$EFI_MOUNT" != /boot && "$BOOTLOADER" != grub ]]; then
        warn "A separate ESP at $EFI_MOUNT with non-FAT /boot requires GRUB in this installer. Forcing GRUB."
        BOOTLOADER=grub
    fi

    if ask_yes_no "Install NVIDIA 580xx legacy DKMS packages (Pascal/GTX 1050)?" n; then
        INSTALL_NVIDIA_580=1
        if ask_yes_no "Write the NVIDIA performance modprobe options unconditionally (no installed/running-module check)?" y; then
            APPLY_NVIDIA_PERFORMANCE=1
        else
            APPLY_NVIDIA_PERFORMANCE=0
        fi
    else
        INSTALL_NVIDIA_580=0
        APPLY_NVIDIA_PERFORMANCE=0
    fi

    ask_choice "Performance profile" 3 \
        "Normal / distro defaults" \
        "Performance (manual performance.sh + I/O + sysctl tuning)" \
        "Extreme performance / debloat" \
        "Custom"
    case "$REPLY" in
        1)
            PERF_PROFILE=normal
            PERF_CPU=0; PERF_IO=0; PERF_SYSCTL=0
            ;;
        2)
            PERF_PROFILE=performance
            PERF_CPU=1; PERF_IO=1; PERF_SYSCTL=1
            ;;
        3)
            PERF_PROFILE=extreme
            PERF_CPU=1; PERF_IO=1; PERF_SYSCTL=1
            ;;
        4)
            PERF_PROFILE=custom
            ask_yes_no "Create manual ~/performance.sh for max CPU performance/Turbo (no custom service)?" y && PERF_CPU=1 || PERF_CPU=0
            ask_yes_no "Install ArchWiki-style I/O scheduler rules and periodic TRIM?" y && PERF_IO=1 || PERF_IO=0
            ask_yes_no "Install desktop-performance sysctl.d tuning?" y && PERF_SYSCTL=1 || PERF_SYSCTL=0
            ;;
    esac

    if ask_yes_no "Enable a Wayland-only desktop (native Qt/GTK/SDL/Firefox; keep Xwayland only for legacy apps)?" n; then
        WAYLAND_ONLY=1
    else
        WAYLAND_ONLY=0
    fi

    if ask_yes_no "Apply Intel IOMMU/KVM virtualization tuning (passthrough, EPT, FlexPriority, nested KVM)?" n; then
        ENABLE_INTEL_KVM_TUNING=1
    else
        ENABLE_INTEL_KVM_TUNING=0
    fi

    if ask_yes_no "Force the Pastelitto Intel i915 performance options in modprobe.d?" n; then
        APPLY_INTEL_IGPU_PERFORMANCE=1
    else
        APPLY_INTEL_IGPU_PERFORMANCE=0
    fi

    if ask_yes_no "Install and enable TuneD + tuned-ppd with the Pastelitto power profiles?" n; then
        ENABLE_PASTELITTO_TUNED=1
    else
        ENABLE_PASTELITTO_TUNED=0
    fi

    if ask_yes_no "Install the CachyOS kernel build shortcut in Documents/cachy-kernel?" n; then
        INSTALL_CACHY_BUILDER=1
        if [[ "$ACCOUNT_SETUP" == now ]] && ask_yes_no "Compile and install the custom CachyOS kernel now? (This can take a long time.)" n; then
            COMPILE_CACHY_NOW=1
        else
            COMPILE_CACHY_NOW=0
            [[ "$ACCOUNT_SETUP" == oobe ]] && warn "Compile-now requires an existing user; the builder will be staged for the OOBE user instead."
        fi
        ask_yes_no "Make the custom CachyOS kernel the default after it is installed?" y && MAKE_CACHY_DEFAULT=1 || MAKE_CACHY_DEFAULT=0
    else
        INSTALL_CACHY_BUILDER=0
        COMPILE_CACHY_NOW=0
        MAKE_CACHY_DEFAULT=0
    fi

    if ask_yes_no "Apply your Fedora kernel command-line tuning set (excluding BOOT_IMAGE/root=)?" y; then
        APPLY_FEDORA_CMDLINE=1
    else
        APPLY_FEDORA_CMDLINE=0
    fi

    # Keep this explicit even in Extreme. It materially reduces CPU-side
    # security/isolation protections and must never be silently enabled.
    if ask_yes_no "Disable CPU vulnerability mitigations (mitigations=off + your Fedora flags)?" n; then
        DISABLE_MITIGATIONS=1
    else
        DISABLE_MITIGATIONS=0
    fi

    local log_default=1
    [[ "$PERF_PROFILE" == extreme ]] && log_default=4
    ask_choice "Logging profile" "$log_default" \
        "Normal journald" \
        "RAM-only journal, max 32 MiB" \
        "Minimal RAM-only journal, max 8 MiB, warning+ only" \
        "Almost zero: journald Storage=none and no kernel/audit forwarding"
    LOGGING_PROFILE="$REPLY"

    local extreme_default=n
    [[ "$PERF_PROFILE" == extreme ]] && extreme_default=y
    ask_yes_no "After installation, use a 25%-of-RAM pacman download cache and discard packages after each transaction?" "$extreme_default" && PACMAN_RAM_CACHE=1 || PACMAN_RAM_CACHE=0
    ask_yes_no "Disable automatic core dumps?" "$extreme_default" && DISABLE_COREDUMP=1 || DISABLE_COREDUMP=0
    ask_yes_no "Disable Linux audit/auditd?" "$extreme_default" && DISABLE_AUDIT=1 || DISABLE_AUDIT=0
    ask_yes_no "Disable kernel/system watchdogs?" "$extreme_default" && DISABLE_WATCHDOG=1 || DISABLE_WATCHDOG=0
    ask_yes_no "Disable pstore persistent crash logs?" "$extreme_default" && DISABLE_PSTORE=1 || DISABLE_PSTORE=0
    ask_yes_no "Disable rsyslog/syslog-ng if installed?" "$extreme_default" && DISABLE_SYSLOG=1 || DISABLE_SYSLOG=0
    ask_yes_no "Disable systemd-oomd?" "$extreme_default" && DISABLE_OOMD=1 || DISABLE_OOMD=0

    if [[ "$DESKTOP" == kde ]]; then
        ask_yes_no "Disable KDE Baloo file indexing?" "$extreme_default" && DISABLE_BALOO=1 || DISABLE_BALOO=0
    else
        DISABLE_BALOO=0
    fi

    local service_default=y
    [[ "$PERF_PROFILE" == extreme ]] && service_default=n
    ask_yes_no "Keep Bluetooth service enabled?" "$service_default" && KEEP_BLUETOOTH=1 || KEEP_BLUETOOTH=0
    ask_yes_no "Keep CUPS/printing service enabled?" "$service_default" && KEEP_CUPS=1 || KEEP_CUPS=0
    ask_yes_no "Keep Avahi/mDNS enabled if installed?" "$service_default" && KEEP_AVAHI=1 || KEEP_AVAHI=0
    ask_yes_no "Keep ModemManager enabled if installed?" "$service_default" && KEEP_MODEMMANAGER=1 || KEEP_MODEMMANAGER=0

    # This build deliberately uses disk swap + zswap, not zram.
    ENABLE_ZSWAP=1

    local root_fstype
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    EXT4_EXTREME=0
    if [[ -f /etc/fedora-arch-layout.conf ]] && grep -qx 'EXT4_EXTREME=1' /etc/fedora-arch-layout.conf; then
        EXT4_EXTREME=1
    elif awk '
        $1 !~ /^#/ && $3 == "ext4" && ($2 == "/" || $2 == "/home") &&
        $4 ~ /(^|,)data=writeback(,|$)/ && $4 ~ /(^|,)barrier=0(,|$)/ &&
        $4 ~ /(^|,)journal_async_commit(,|$)/ { found=1 }
        END { exit !found }
    ' /etc/fstab 2>/dev/null; then
        # Also recognize a manually prepared installation with the exact
        # aggressive policy, even when format.sh did not create the marker.
        EXT4_EXTREME=1
    fi
    local f2fs_default=n
    [[ "$root_fstype" == f2fs ]] && f2fs_default=y
    if ask_yes_no "Preserve/validate F2FS performance + reduced-write options from format.sh?" "$f2fs_default"; then
        OPTIMIZE_F2FS=1
    else
        OPTIMIZE_F2FS=0
    fi
    # Advanced F2FS compression/GC options are now selected only by format.sh
    # after real mount probes; install.sh never injects untested options.
    F2FS_COMPRESS_ALL=0

    echo
    echo "---------------- Configuration summary ----------------"
    printf 'Root filesystem:    %s (%s)\n' "$(findmnt -n -o SOURCE /)" "$root_fstype"
    printf '/boot:              %s (%s)\n' "$(findmnt -n -o SOURCE /boot)" "$(findmnt -n -o FSTYPE /boot)"
    printf 'EFI mount:          %s -> %s (%s)\n' "$EFI_MOUNT" "$(findmnt -n -o SOURCE "$EFI_MOUNT")" "$(findmnt -n -o FSTYPE "$EFI_MOUNT")"
    printf 'Desktop:            %s\n' "$DESKTOP"
    printf 'Account setup:      %s\n' "$([[ $ACCOUNT_SETUP == now ]] && echo "now ($INSTALL_USERNAME@$INSTALL_HOSTNAME)" || echo 'desktop OOBE')"
    printf 'Time zone:          %s\n' "$INSTALL_TIMEZONE"
    printf 'KDE edition:        %s\n' "$KDE_EDITION"
    printf 'Fedora app bundle:  %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo yes || echo no)"
    if [[ "$DESKTOP" == kde ]]; then
        printf 'LibreOffice Fresh:  %s\n' "$([[ $INSTALL_LIBREOFFICE -eq 1 ]] && echo yes || echo no)"
        printf 'Gaming apps:        Lutris=%s Steam=%s Faugus=%s ProtonUp-Qt=%s\n' \
            "$([[ $INSTALL_LUTRIS -eq 1 ]] && echo yes || echo no)" \
            "$([[ $INSTALL_STEAM -eq 1 ]] && echo yes || echo no)" \
            "$([[ $INSTALL_FAUGUS -eq 1 ]] && echo yes || echo no)" \
            "$([[ $INSTALL_PROTONUP_QT -eq 1 ]] && echo yes || echo no)"
        printf 'Faugus settings:    %s\n' "$([[ $IMPORT_FAUGUS_SETTINGS -eq 1 ]] && echo 'import captured preferences/environment' || echo no)"
        printf 'virt-manager stack: %s\n' "$([[ $INSTALL_VIRT_MANAGER -eq 1 ]] && echo yes || echo no)"
    fi
    printf 'Discover updates:   %s\n' "$([[ $ENABLE_DISCOVER_SYSTEM -eq 1 ]] && echo 'daily automatic; system packages apply after reboot' || echo disabled)"
    printf 'Discover spoof:     %s\n' "$([[ $SPOOF_DISCOVER_WARNING -eq 1 ]] && echo yes || echo no)"
    printf 'Pastelitto KDE:      %s\n' "$([[ $APPLY_PASTELITTO_KDE -eq 1 ]] && echo yes || echo no)"
    printf 'Fish default shell: %s\n' "$([[ $INSTALL_FISH -eq 1 ]] && echo yes || echo no)"
    printf 'ALHP:               %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo no)"
    printf 'CachyOS repo:       %s\n' "$([[ $ENABLE_CACHYOS -eq 1 ]] && echo yes || echo no)"
    printf 'Chaotic-AUR:        %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo yes || echo no)"
    printf 'zswap:              enabled (lz4, 30%% pool; zram off)\n'
    printf 'Initramfs:          %s\n' "$INITRAMFS"
    printf 'Boot loader:        %s\n' "$BOOTLOADER"
    printf 'NVIDIA 580xx:       %s\n' "$([[ $INSTALL_NVIDIA_580 -eq 1 ]] && echo yes || echo no)"
    printf 'NVIDIA modprobe:    %s\n' "$([[ $APPLY_NVIDIA_PERFORMANCE -eq 1 ]] && echo 'unconditional performance options' || echo no)"
    printf 'Performance:        %s\n' "$PERF_PROFILE"
    printf 'Pacman RAM cache:   %s\n' "$([[ $PACMAN_RAM_CACHE -eq 1 ]] && echo 'yes (25% RAM cap, post-transaction cleanup)' || echo no)"
    printf 'Wayland-only:       %s\n' "$([[ $WAYLAND_ONLY -eq 1 ]] && echo 'yes (Xwayland compatibility retained)' || echo no)"
    printf 'Intel IOMMU/KVM:    %s\n' "$([[ $ENABLE_INTEL_KVM_TUNING -eq 1 ]] && echo yes || echo no)"
    printf 'Intel i915 options: %s\n' "$([[ $APPLY_INTEL_IGPU_PERFORMANCE -eq 1 ]] && echo yes || echo no)"
    printf 'TuneD profiles:     %s\n' "$([[ $ENABLE_PASTELITTO_TUNED -eq 1 ]] && echo yes || echo no)"
    printf 'Cachy builder:      %s\n' "$([[ $INSTALL_CACHY_BUILDER -eq 1 ]] && echo "installed (compile-now=$COMPILE_CACHY_NOW, default=$MAKE_CACHY_DEFAULT)" || echo no)"
    printf 'Logging profile:    %s\n' "$LOGGING_PROFILE"
    printf 'Mitigations off:    %s\n' "$([[ $DISABLE_MITIGATIONS -eq 1 ]] && echo yes || echo no)"
    printf 'F2FS optimization:  %s\n' "$([[ $OPTIMIZE_F2FS -eq 1 ]] && echo yes || echo no)"
    printf 'Extreme ext4:       %s\n' "$([[ $EXT4_EXTREME -eq 1 ]] && echo yes || echo no)"
    echo "-------------------------------------------------------"
    echo
    ask_yes_no "Continue with configuration?" y || exit 0
}

# -----------------------------------------------------------------------------
# Installed-system helpers
# -----------------------------------------------------------------------------
backup_once() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    [[ -e "${path}.fedora-arch.bak" ]] || cp -a "$path" "${path}.fedora-arch.bak"
}

# Package transactions are intentionally unattended.  Explicit provider
# packages (notably pipewire-jack) are installed before desktop groups so the
# default provider selection cannot silently pull jack2 instead.
pacman_install() {
    pacman -S --needed --noconfirm "$@"
}

pacman_remove() {
    pacman -Rns --noconfirm "$@"
}

strip_repo_sections() {
    local input="$1" output="$2" pattern="$3"
    awk -v pat="$pattern" '
        BEGIN { skip=0 }
        /^\[/ {
            if ($0 ~ pat) { skip=1; next }
            skip=0
        }
        !skip { print }
    ' "$input" > "$output"
}

enable_multilib() {
    if grep -q '^#\[multilib\]' /etc/pacman.conf; then
        sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//;}' /etc/pacman.conf
    fi
}

configure_pacman_preferences() {
    info "Applying preferred pacman.conf UI/download settings"
    backup_once /etc/pacman.conf

    # Remove duplicate active instances before writing a single canonical one.
    sed -i -E \
        -e '/^[[:space:]]*Color[[:space:]]*$/d' \
        -e '/^[[:space:]]*CheckSpace[[:space:]]*$/d' \
        -e '/^[[:space:]]*VerbosePkgLists[[:space:]]*$/d' \
        -e '/^[[:space:]]*ParallelDownloads[[:space:]]*=/d' \
        -e '/^[[:space:]]*DownloadUser[[:space:]]*=/d' \
        /etc/pacman.conf

    # Put the requested options inside [options], immediately before the first
    # repository section.  Keep syslog/progress/sandbox settings at defaults.
    local tmp
    tmp="$(mktemp)"
    awk '
        BEGIN { inserted=0 }
        /^\[[^]]+\]$/ && $0 != "[options]" && !inserted {
            print "Color"
            print "CheckSpace"
            print "VerbosePkgLists"
            print "ParallelDownloads = 5"
            print "DownloadUser = alpm"
            print ""
            inserted=1
        }
        { print }
        END {
            if (!inserted) {
                print "Color"
                print "CheckSpace"
                print "VerbosePkgLists"
                print "ParallelDownloads = 5"
                print "DownloadUser = alpm"
            }
        }
    ' /etc/pacman.conf > "$tmp"
    install -m0644 "$tmp" /etc/pacman.conf
    rm -f "$tmp"
}

remove_pacman_ram_cache_include() {
    [[ -f /etc/pacman.conf ]] || return 0
    sed -i -E '\|^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/pacman.d/fedora-arch-ram-cache.conf[[:space:]]*$|d' \
        /etc/pacman.conf
}

prepare_pacman_disk_cache_for_install() {
    # A previous run may already have enabled the volatile cache.  Always take
    # it out of pacman's configuration while this installer performs its large
    # transactions.  The selected final policy is applied only after the last
    # package operation, avoiding RAM exhaustion halfway through installation.
    if grep -Eq '^[[:space:]]*Include[[:space:]]*=[[:space:]]*/etc/pacman.d/fedora-arch-ram-cache.conf[[:space:]]*$' \
            /etc/pacman.conf 2>/dev/null; then
        info "Temporarily disabling the pacman RAM cache during installation"
        remove_pacman_ram_cache_include
    fi
}

update_pacman_ram_cache_fstab() {
    local enable="$1" tmp
    tmp="$(mktemp)"
    awk '
        $0 == "# BEGIN fedora-arch pacman RAM cache" { skip=1; next }
        $0 == "# END fedora-arch pacman RAM cache" { skip=0; next }
        !skip { print }
    ' /etc/fstab > "$tmp"

    if [[ "$enable" == 1 ]]; then
        cat >> "$tmp" <<'EOF_PACMAN_RAM_FSTAB'

# BEGIN fedora-arch pacman RAM cache
# A separate cap prevents package downloads from consuming all system memory.
tmpfs /run/pacman-cache tmpfs rw,nosuid,nodev,noexec,noswap,size=25%,mode=0755,nofail 0 0
# END fedora-arch pacman RAM cache
EOF_PACMAN_RAM_FSTAB
    fi

    install -m 0644 "$tmp" /etc/fstab
    rm -f "$tmp"
}

configure_pacman_ram_cache() {
    local cache_include=/etc/pacman.d/fedora-arch-ram-cache.conf
    local cache_dir=/run/pacman-cache/pkg
    local cache_hook=/etc/pacman.d/hooks/98-fedora-arch-clear-ram-cache.hook
    local cache_cleaner=/usr/local/libexec/fedora-arch-clear-pacman-ram-cache
    local cache_tmpfiles=/etc/tmpfiles.d/20-fedora-arch-pacman-ram-cache.conf

    backup_once /etc/pacman.conf
    backup_once /etc/fstab
    remove_pacman_ram_cache_include

    if (( ! PACMAN_RAM_CACHE )); then
        update_pacman_ram_cache_fstab 0
        rm -f "$cache_include" "$cache_hook" "$cache_cleaner" "$cache_tmpfiles"
        if mountpoint -q /run/pacman-cache; then
            umount /run/pacman-cache || warn "Could not unmount the old pacman RAM cache; it will disappear on reboot."
        fi
        rmdir "$cache_dir" /run/pacman-cache 2>/dev/null || true
        return 0
    fi

    info "Enabling the post-install pacman RAM cache (25% RAM cap)"
    install -d -m 0755 \
        /etc/pacman.d /etc/pacman.d/hooks /etc/tmpfiles.d \
        /usr/local/libexec /run/pacman-cache "$cache_dir"

    cat > "$cache_include" <<'EOF_PACMAN_RAM_CONF'
# Managed by fedora-arch install.sh. This is included first in [options], so
# downloads use volatile memory even if another read-only cache is configured.
CacheDir = /run/pacman-cache/pkg/
EOF_PACMAN_RAM_CONF
    chmod 0644 "$cache_include"

    # Insert the include immediately after [options]. pacman tries CacheDir
    # entries in order and downloads to the first writable directory.
    grep -qx '\[options\]' /etc/pacman.conf || fatal "/etc/pacman.conf has no [options] section."
    local pacman_tmp
    pacman_tmp="$(mktemp)"
    awk '
        $0 == "[options]" {
            print
            print "Include = /etc/pacman.d/fedora-arch-ram-cache.conf"
            next
        }
        { print }
    ' /etc/pacman.conf > "$pacman_tmp"
    install -m 0644 "$pacman_tmp" /etc/pacman.conf
    rm -f "$pacman_tmp"

    update_pacman_ram_cache_fstab 1
    cat > "$cache_tmpfiles" <<'EOF_PACMAN_RAM_TMPFILES'
# The tmpfs mount itself is declared in /etc/fstab.
d /run/pacman-cache/pkg 0755 root root -
EOF_PACMAN_RAM_TMPFILES
    chmod 0644 "$cache_tmpfiles"

    cat > "$cache_cleaner" <<'EOF_PACMAN_RAM_CLEANER'
#!/usr/bin/env bash
set -euo pipefail
cache_dir=/run/pacman-cache/pkg
[[ -d "$cache_dir" ]] || exit 0
find "$cache_dir" -mindepth 1 -delete
EOF_PACMAN_RAM_CLEANER
    chmod 0755 "$cache_cleaner"

    cat > "$cache_hook" <<EOF_PACMAN_RAM_HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Clearing volatile pacman package downloads...
When = PostTransaction
Exec = $cache_cleaner
EOF_PACMAN_RAM_HOOK
    chmod 0644 "$cache_hook"

    # The installation used the normal disk cache deliberately. Reclaim it
    # only now, after all package and bootloader transactions have succeeded.
    if [[ -d /var/cache/pacman/pkg ]]; then
        find /var/cache/pacman/pkg -mindepth 1 -delete
    fi
    ok "Pacman downloads will use capped volatile RAM after reboot"
}

prepare_chroot_transaction_hooks() {
    install -d /etc/pacman.d/hooks

    # PackageKit's pacman hook talks to the system D-Bus. During arch-chroot
    # there is no activatable PackageKit service, so the hook only creates noisy
    # false errors. Mask it temporarily; remove the mask before the installer exits.
    ln -sfn /dev/null /etc/pacman.d/hooks/90-packagekit-refresh.hook

    # If dracut was selected, stop mkinitcpio before the first kernel/package
    # transaction, not only near the end. This prevents competing initramfs
    # generation throughout the installation.
    if [[ "$INITRAMFS" == dracut || "$INITRAMFS" == booster ]]; then
        ln -sfn /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
        ln -sfn /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
    fi
}

restore_runtime_packagekit_hook() {
    rm -f /etc/pacman.d/hooks/90-packagekit-refresh.hook
}

bootstrap_chaotic_trust() {
    info "Bootstrapping Chaotic-AUR signing key and mirrorlist"
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || \
        pacman-key --recv-key 3056513887B78AEB --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman -U --needed --noconfirm \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
}

configure_alhp() {
    [[ $ENABLE_ALHP -eq 1 ]] || return 0

    info "Checking CPU support for x86-64-$ALHP_LEVEL"
    /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-${ALHP_LEVEL} (supported" || \
        fatal "CPU does not report x86-64-$ALHP_LEVEL support."

    bootstrap_chaotic_trust

    local tmpconf cleaned inserted
    tmpconf="$(mktemp)"
    cp /etc/pacman.conf "$tmpconf"
    cat >> "$tmpconf" <<'CHAOTIC_TMP'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC_TMP

    pacman --config "$tmpconf" -Syy --noconfirm
    pacman --config "$tmpconf" -S --needed --noconfirm alhp-keyring alhp-mirrorlist
    rm -f "$tmpconf"

    cleaned="$(mktemp)"
    inserted="$(mktemp)"
    strip_repo_sections /etc/pacman.conf "$cleaned" '^[[](core|extra|multilib)-x86-64-v[234][]]$'

    awk -v lvl="$ALHP_LEVEL" '
        /^\[core\]$/ {
            print "[core-x86-64-" lvl "]"
            print "Include = /etc/pacman.d/alhp-mirrorlist"
            print ""
        }
        /^\[extra\]$/ {
            print "[extra-x86-64-" lvl "]"
            print "Include = /etc/pacman.d/alhp-mirrorlist"
            print ""
        }
        /^\[multilib\]$/ {
            print "[multilib-x86-64-" lvl "]"
            print "Include = /etc/pacman.d/alhp-mirrorlist"
            print ""
        }
        { print }
    ' "$cleaned" > "$inserted"

    install -m 0644 "$inserted" /etc/pacman.conf
    rm -f "$cleaned" "$inserted"
    ok "ALHP $ALHP_LEVEL configured"
}

bootstrap_cachyos_trust() {
    info "Bootstrapping CachyOS keyring and mirrorlist (without CachyOS pacman)"
    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || \
        pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47

    local tmpconf
    tmpconf="$(mktemp)"
    cp /etc/pacman.conf "$tmpconf"
    cat >> "$tmpconf" <<'CACHY_TMP'

[cachyos]
Server = https://mirror.cachyos.org/repo/x86_64/cachyos
CACHY_TMP
    pacman --config "$tmpconf" -Syy --noconfirm
    pacman --config "$tmpconf" -S --needed --noconfirm cachyos-keyring cachyos-mirrorlist
    rm -f "$tmpconf"
}

configure_cachyos() {
    local cleaned
    cleaned="$(mktemp)"
    strip_repo_sections /etc/pacman.conf "$cleaned" '^[[]cachyos[]]$'
    install -m0644 "$cleaned" /etc/pacman.conf
    rm -f "$cleaned"

    if [[ $ENABLE_CACHYOS -eq 1 ]]; then
        if ! pacman -Q cachyos-keyring >/dev/null 2>&1 || ! pacman -Q cachyos-mirrorlist >/dev/null 2>&1; then
            bootstrap_cachyos_trust
        fi
        # Deliberately appended after Arch/ALHP so Arch stays the base.
        # Chaotic-AUR is appended later, making CachyOS higher priority than Chaotic.
        cat >> /etc/pacman.conf <<'CACHY_PERM'

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
CACHY_PERM
        ok "CachyOS general repository enabled below Arch/ALHP and above Chaotic-AUR"
    fi
}

configure_chaotic() {
    local cleaned
    cleaned="$(mktemp)"
    strip_repo_sections /etc/pacman.conf "$cleaned" '^[[]chaotic-aur[]]$'
    install -m 0644 "$cleaned" /etc/pacman.conf
    rm -f "$cleaned"

    if [[ $ENABLE_CHAOTIC -eq 1 ]]; then
        pacman -Q chaotic-keyring >/dev/null 2>&1 || bootstrap_chaotic_trust
        cat >> /etc/pacman.conf <<'CHAOTIC_PERM'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC_PERM
        ok "Chaotic-AUR enabled"
    fi
}

configure_repositories_first() {
    info "Configuring repositories BEFORE kernel/desktop applications"
    backup_once /etc/pacman.conf
    configure_pacman_preferences
    enable_multilib
    pacman-key --init
    pacman-key --populate archlinux

    if [[ $ENABLE_CHAOTIC -eq 1 && $ENABLE_ALHP -eq 0 ]]; then
        bootstrap_chaotic_trust
    fi
    configure_alhp
    configure_cachyos
    configure_chaotic

    info "Synchronizing and upgrading with repository priority: ALHP/Arch > CachyOS > Chaotic-AUR"
    pacman -Syyu --noconfirm
}

configure_base_identity() {
    info "Configuring locale, clock, time synchronization, and system identity"
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    printf '%s\n' 'LANG=en_US.UTF-8' > /etc/locale.conf
    printf '%s\n' 'KEYMAP=us' > /etc/vconsole.conf
    ln -sfn "/usr/share/zoneinfo/$INSTALL_TIMEZONE" /etc/localtime
    hwclock --systohc
    systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true

    if [[ "$ACCOUNT_SETUP" == now ]]; then
        info "Creating administrator account: $INSTALL_USERNAME"
        printf '%s\n' "$INSTALL_HOSTNAME" > /etc/hostname
        getent group wheel >/dev/null || groupadd wheel
        useradd -m -G wheel -s /bin/bash "$INSTALL_USERNAME"
        printf '%s:%s\n' "$INSTALL_USERNAME" "$USER_PASSWORD" | chpasswd
        printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
        install -d -m0750 /etc/sudoers.d
        printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
        chmod 0440 /etc/sudoers.d/10-wheel
        touch /etc/fedora-arch-user-created
        USER_PASSWORD=""
        ROOT_PASSWORD=""
        unset USER_PASSWORD ROOT_PASSWORD
    else
        info "User, password, and hostname will be completed by the desktop first-boot setup"
        rm -f /etc/fedora-arch-user-created
    fi
}

# Install only package names that currently exist in enabled pacman repositories.
# Package transactions are automatic.
install_available_auto() {
    local label="$1"; shift
    local available=() missing=() pkg
    for pkg in "$@"; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then
            available+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done
    if ((${#available[@]})); then
        info "$label"
        pacman_install "${available[@]}"
    fi
    if ((${#missing[@]})); then
        warn "Not present in enabled binary repos, so skipped: ${missing[*]}"
        warn "If these are AUR-only, enable Chaotic-AUR or install them manually later."
    fi
}

# Prefer enabled binary repositories, but make explicitly selected desktop
# applications reliable even when the user disabled CachyOS/Chaotic-AUR.
install_binary_or_aur() {
    local pkg="$1" aur_pkg="${2:-$1}"
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        pacman_install "$pkg"
    else
        warn "$pkg is not in an enabled binary repository; building $aur_pkg from AUR."
        install_aur_package_temp_builder "$aur_pkg"
    fi
}

install_aur_package_temp_builder() {
    local pkg="$1" url="https://aur.archlinux.org/${1}.git"
    local builder="fedoraarch-build"
    info "Building AUR package needed for first boot: $pkg"
    pacman_install base-devel git sudo

    userdel -r "$builder" >/dev/null 2>&1 || true
    useradd -m -s /bin/bash "$builder"
    install -d -m0750 /etc/sudoers.d
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$builder" > /etc/sudoers.d/99-fedoraarch-build
    chmod 0440 /etc/sudoers.d/99-fedoraarch-build

    local rc=0
    su - "$builder" -c "git clone '$url' ~/pkg && cd ~/pkg && makepkg -si --needed --noconfirm" || rc=$?

    rm -f /etc/sudoers.d/99-fedoraarch-build
    userdel -r "$builder" >/dev/null 2>&1 || true
    (( rc == 0 )) || fatal "Failed to build/install $pkg from AUR."
}

configure_plasma_oobe_admin() {
    info "Configuring administrator access and first-user preferences"

    pacman_install sudo
    getent group wheel >/dev/null || groupadd wheel

    install -d -m0750 /etc/sudoers.d
    printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    chmod 0440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel >/dev/null \
        || fatal "Generated wheel sudoers rule failed visudo validation."

    install -d -m0755 /usr/local/libexec /var/lib/fedora-arch
    cat > /usr/local/libexec/fedora-arch-plasma-admin <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Continue after either installer-side account creation or successful OOBE.
[[ -e /etc/fedora-arch-user-created || -e /etc/plasma-setup-done ]] || exit 0

uid_min=$(awk '$1 == "UID_MIN" { print $2; exit }' /etc/login.defs 2>/dev/null || true)
uid_min=${uid_min:-1000}

changed=0
while IFS=: read -r name _ uid _ _ home shell; do
    [[ $uid =~ ^[0-9]+$ ]] || continue
    (( uid >= uid_min && uid < 65534 )) || continue
    case "$shell" in
        */nologin|*/false) continue ;;
    esac

    /usr/bin/usermod -aG wheel "$name"
    if [[ -e /etc/fedora-arch-enable-libvirt ]]; then
        /usr/bin/usermod -aG libvirt,kvm "$name"
    fi
    if [[ -e /etc/fedora-arch-use-fish && -x /usr/bin/fish ]]; then
        /usr/bin/usermod -s /usr/bin/fish "$name"
    fi
    if [[ -x /etc/skel/Documents/cachy-kernel/build-cachyos-kernel.sh && ! -e "$home/Documents/cachy-kernel/build-cachyos-kernel.sh" ]]; then
        primary_group="$(id -gn "$name")"
        /usr/bin/install -d -m0755 -o "$name" -g "$primary_group" "$home/Documents/cachy-kernel"
        /usr/bin/install -m0755 -o "$name" -g "$primary_group" \
            /etc/skel/Documents/cachy-kernel/build-cachyos-kernel.sh \
            "$home/Documents/cachy-kernel/build-cachyos-kernel.sh"
    fi

    if [[ -e /etc/fedora-arch-discover-auto && -x /usr/bin/kwriteconfig6 ]]; then
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file PlasmaDiscoverUpdates --group Global \
            --key UseUnattendedUpdates true
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file PlasmaDiscoverUpdates --group Global \
            --key RequiredNotificationInterval 86400
    fi

    # Apply the small, portable Pastelitto preset with KDE's normal config
    # files. Avoid copying the source machine's Plasma layout, wallpaper,
    # activity IDs, screen IDs, or absolute paths.
    if [[ -e /etc/fedora-arch-pastelitto && -d "$home" && -x /usr/bin/kwriteconfig6 ]]; then
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file dolphinrc --group General --key RememberOpenedTabs false
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file dolphinrc --group General --key HomeUrl "file://$home"
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file dolphinrc --group General --key GlobalViewProps true
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file dolphinrc --group DetailsMode --key PreviewSize 32
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file kwinrc --group Desktops --key Number 3
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file kwinrc --group Desktops --key Rows 1
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file kwriterc --group General --key 'Show welcome view for new window' false
        /usr/bin/runuser -u "$name" -- env HOME="$home" \
            /usr/bin/kwriteconfig6 --file kwriterc --group 'KTextEditor Renderer' --key 'Text Font' \
            'Noto Sans,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0'

        view_properties="$home/.local/share/dolphin/view_properties/global"
        /usr/bin/install -d -m0700 -o "$name" -g "$(id -gn "$name")" "$view_properties"
        printf '%s\n' '[Dolphin]' 'Version=4' 'ViewMode=1' > "$view_properties/.directory"
        /usr/bin/chown "$name:$(id -gn "$name")" "$view_properties/.directory"
        /usr/bin/chmod 0600 "$view_properties/.directory"

        if [[ -f /etc/skel/.local/share/konsole/Pastelitto.profile ]]; then
            /usr/bin/install -d -m0700 -o "$name" -g "$(id -gn "$name")" "$home/.local/share/konsole"
            /usr/bin/install -m0600 -o "$name" -g "$(id -gn "$name")" \
                /etc/skel/.local/share/konsole/Pastelitto.profile \
                "$home/.local/share/konsole/Pastelitto.profile"
            /usr/bin/runuser -u "$name" -- env HOME="$home" \
                /usr/bin/kwriteconfig6 --file konsolerc --group 'Desktop Entry' --key DefaultProfile Pastelitto.profile
        fi
    fi

    # Import only portable Faugus preferences. Game-library records, runners,
    # prefixes, artwork, and anti-cheat payloads are deliberately excluded.
    if [[ -e /etc/fedora-arch-import-faugus && -d /usr/share/fedora-arch/faugus-launcher ]]; then
        faugus_dir="$home/.config/faugus-launcher"
        primary_group="$(id -gn "$name")"
        /usr/bin/install -d -m0700 -o "$name" -g "$primary_group" "$faugus_dir"
        for source_file in config.json envar.json; do
            if [[ -f "/usr/share/fedora-arch/faugus-launcher/$source_file" ]]; then
                /usr/bin/sed "s|@HOME@|$home|g" \
                    "/usr/share/fedora-arch/faugus-launcher/$source_file" > "$faugus_dir/$source_file"
                /usr/bin/chown "$name:$primary_group" "$faugus_dir/$source_file"
                /usr/bin/chmod 0600 "$faugus_dir/$source_file"
            fi
        done

        # The captured variables reference this file, but it did not exist on
        # the source machine. Seed a valid empty config instead of a dead path.
        /usr/bin/install -d -m0700 -o "$name" -g "$primary_group" "$home/.config/dxvk"
        if [[ ! -e "$home/.config/dxvk/dxvk.conf" ]]; then
            /usr/bin/install -m0600 -o "$name" -g "$primary_group" /dev/null \
                "$home/.config/dxvk/dxvk.conf"
        fi
    fi
    changed=1
done < /etc/passwd

if (( changed )); then
    touch /var/lib/fedora-arch/oobe-admin-done
fi
EOF
    chmod 0755 /usr/local/libexec/fedora-arch-plasma-admin

    if [[ "$ACCOUNT_SETUP" == oobe ]]; then
        # Primary hook: run immediately when plasma-setup exits.
        install -d -m0755 /etc/systemd/system/plasma-setup.service.d
        cat > /etc/systemd/system/plasma-setup.service.d/20-admin-user.conf <<'EOF'
[Service]
ExecStopPost=/usr/local/libexec/fedora-arch-plasma-admin
EOF

    # Fallback: some plasma-setup builds/service types do not give us a useful
    # ExecStopPost transition after account creation.  Watch its completion
    # marker and run the same idempotent helper as soon as it appears.
    cat > /etc/systemd/system/fedora-arch-oobe-admin.service <<'EOF'
[Unit]
Description=Finish first Plasma OOBE administrator setup
ConditionPathExists=/etc/plasma-setup-done
ConditionPathExists=!/var/lib/fedora-arch/oobe-admin-done

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/fedora-arch-plasma-admin
EOF

    cat > /etc/systemd/system/fedora-arch-oobe-admin.path <<'EOF'
[Unit]
Description=Watch for Plasma Setup completion

[Path]
PathExists=/etc/plasma-setup-done
Unit=fedora-arch-oobe-admin.service

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable fedora-arch-oobe-admin.path >/dev/null 2>&1 || true
    else
        rm -rf /etc/systemd/system/plasma-setup.service.d
        systemctl disable fedora-arch-oobe-admin.path >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/fedora-arch-oobe-admin.{path,service}
    fi

    # Repairs an already-completed Plasma Setup when this installer is rerun.
    if [[ -e /etc/plasma-setup-done || -e /etc/fedora-arch-user-created ]]; then
        /usr/local/libexec/fedora-arch-plasma-admin
    fi
}

install_plasma_oobe() {
    info "Installing KDE Plasma Setup first-boot OOBE"
    local oobe_pkg="" oobe_repo=""
    if pacman -Si plasma-setup >/dev/null 2>&1; then
        oobe_pkg=plasma-setup
    elif pacman -Si plasma-setup-git >/dev/null 2>&1; then
        oobe_pkg=plasma-setup-git
    fi

    if [[ -n "$oobe_pkg" ]]; then
        oobe_repo="$(pacman -Si "$oobe_pkg" 2>/dev/null | awk -F: '/^Repository[[:space:]]*:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
        info "Using precompiled $oobe_pkg from ${oobe_repo:-an enabled binary repository}"
        pacman_install "$oobe_pkg"
    else
        warn "No precompiled plasma-setup package was found in the enabled repos; building plasma-setup-git from AUR."
        install_aur_package_temp_builder plasma-setup-git
    fi
    configure_plasma_oobe_admin
    if [[ -e /etc/plasma-setup-done ]]; then
        warn "Plasma Setup has already completed; preserving /etc/plasma-setup-done."
    else
        systemctl enable plasma-setup.service
    fi
}

configure_fish_default() {
    if (( INSTALL_FISH )); then
        info "Installing Fish and making it the default shell for the first user"
        pacman_install fish
        touch /etc/fedora-arch-use-fish

        if [[ "$INITRAMFS" == dracut ]]; then
            info "Installing the Fish dracut-all function for the first user"
            install -d -m0755 /etc/skel/.config/fish/functions
            cat > /etc/skel/.config/fish/functions/dracut-all.fish <<'EOF_DRACUT_ALL_FISH'
function dracut-all --description 'Rebuild every installed Arch kernel initramfs and refresh GRUB'
    if not test -x /usr/share/libalpm/scripts/dracut-install
        echo 'dracut-all: Arch dracut-install helper is missing' >&2
        return 1
    end

    set -l targets
    for pkgbase_file in /usr/lib/modules/*/pkgbase
        if test -f "$pkgbase_file"
            # The ALPM helper expects paths relative to /, exactly as pacman
            # supplies them through its NeedsTargets hook.
            set -a targets (string replace --regex '^/' '' -- "$pkgbase_file")
        end
    end

    if test (count $targets) -eq 0
        echo 'dracut-all: no installed kernel pkgbase files were found' >&2
        return 1
    end

    printf '%s\n' $targets | sudo /usr/share/libalpm/scripts/dracut-install
    or return $status

    if test -x /usr/local/sbin/grub-mkconfig
        sudo /usr/local/sbin/grub-mkconfig -o /boot/grub/grub.cfg
    else if test -x /usr/bin/grub-mkconfig
        sudo /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
    else
        echo 'dracut-all: initramfs images rebuilt; GRUB is not installed, so grub.cfg was not regenerated' >&2
    end
end
EOF_DRACUT_ALL_FISH
            chmod 0644 /etc/skel/.config/fish/functions/dracut-all.fish
        else
            rm -f /etc/skel/.config/fish/functions/dracut-all.fish
        fi

        if [[ -f /etc/default/useradd ]]; then
            if grep -q '^SHELL=' /etc/default/useradd; then
                sed -i 's#^SHELL=.*#SHELL=/usr/bin/fish#' /etc/default/useradd
            else
                echo 'SHELL=/usr/bin/fish' >> /etc/default/useradd
            fi
        else
            printf '%s\n' 'SHELL=/usr/bin/fish' > /etc/default/useradd
        fi

        if [[ "$ACCOUNT_SETUP" == now ]]; then
            usermod -s /usr/bin/fish "$INSTALL_USERNAME"
            install -d -m0755 -o "$INSTALL_USERNAME" -g "$(id -gn "$INSTALL_USERNAME")" \
                "/home/$INSTALL_USERNAME/.config/fish/functions"
            if [[ "$INITRAMFS" == dracut ]]; then
                install -m0644 -o "$INSTALL_USERNAME" -g "$(id -gn "$INSTALL_USERNAME")" \
                    /etc/skel/.config/fish/functions/dracut-all.fish \
                    "/home/$INSTALL_USERNAME/.config/fish/functions/dracut-all.fish"
            fi
        fi
    else
        rm -f /etc/fedora-arch-use-fish
        rm -f /etc/skel/.config/fish/functions/dracut-all.fish
    fi
}

install_kernel_and_boot_core() {
    info "Installing kernel + chosen initramfs provider"
    local provider="$INITRAMFS"
    local -a fs_pkgs=()
    local fs mp
    for mp in / /boot /home /efi; do
        mountpoint -q "$mp" || continue
        fs="$(findmnt -n -o FSTYPE "$mp" 2>/dev/null || true)"
        case "$fs" in
            f2fs) fs_pkgs+=(f2fs-tools) ;;
            ext4|ext3|ext2) fs_pkgs+=(e2fsprogs) ;;
            btrfs) fs_pkgs+=(btrfs-progs) ;;
            xfs) fs_pkgs+=(xfsprogs) ;;
        esac
    done
    mapfile -t fs_pkgs < <(printf '%s\n' "${fs_pkgs[@]:-}" | sed '/^$/d' | sort -u)

    local -a core_pkgs=("$provider" linux linux-headers linux-firmware sudo git networkmanager plymouth)
    local root_src root_type
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_type="$(lsblk -ndo TYPE "$root_src" 2>/dev/null || true)"
    [[ "$root_src" == /dev/md* || "$root_type" == raid* ]] && core_pkgs+=(mdadm)
    pacman_install "${core_pkgs[@]}" "${fs_pkgs[@]}"

    # Pastelitto preset deliberately does not install OS-provided Intel microcode.
    # Firmware/UEFI may still apply its own CPU microcode before Linux starts.
    case "$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2}')" in
        GenuineIntel)
            if pacman -Q intel-ucode >/dev/null 2>&1; then
                pacman_remove intel-ucode || warn "Could not remove intel-ucode; remove it manually if you want no Arch Intel microcode image."
            fi
            rm -f /boot/intel-ucode.img
            ;;
        AuthenticAMD) pacman_install amd-ucode ;;
    esac
}

configure_faugus_import() {
    if (( ! IMPORT_FAUGUS_SETTINGS )); then
        rm -f /etc/fedora-arch-import-faugus
        return 0
    fi

    info "Staging portable Faugus Launcher preferences for the first user"
    [[ -f "$FAUGUS_CONFIG_ASSET_DIR/config.json" ]] || \
        fatal "Missing captured Faugus asset: $FAUGUS_CONFIG_ASSET_DIR/config.json"
    [[ -f "$FAUGUS_CONFIG_ASSET_DIR/envar.json" ]] || \
        fatal "Missing captured Faugus asset: $FAUGUS_CONFIG_ASSET_DIR/envar.json"

    install -d -m0755 /usr/share/fedora-arch/faugus-launcher
    install -m0644 "$FAUGUS_CONFIG_ASSET_DIR/config.json" \
        /usr/share/fedora-arch/faugus-launcher/config.json
    install -m0644 "$FAUGUS_CONFIG_ASSET_DIR/envar.json" \
        /usr/share/fedora-arch/faugus-launcher/envar.json
    touch /etc/fedora-arch-import-faugus
}

install_kde_optional_applications() {
    (( INSTALL_LIBREOFFICE )) && pacman_install libreoffice-fresh
    (( INSTALL_LUTRIS )) && pacman_install lutris
    (( INSTALL_STEAM )) && pacman_install steam

    if (( INSTALL_LUTRIS || INSTALL_STEAM || INSTALL_FAUGUS )); then
        # Faugus' imported preset enables GameMode, so install both native and
        # 32-bit clients for Windows games rather than leaving that toggle dead.
        pacman_install gamemode lib32-gamemode
    fi

    if (( INSTALL_FAUGUS )); then
        install_binary_or_aur faugus-launcher
    fi
    if (( INSTALL_PROTONUP_QT )); then
        install_binary_or_aur protonup-qt
    fi

    configure_faugus_import
}

install_virtualization_stack() {
    if (( ! INSTALL_VIRT_MANAGER )); then
        rm -f /etc/fedora-arch-enable-libvirt
        return 0
    fi

    info "Installing the full QEMU/libvirt/virt-manager stack"
    local nft_pkg=iptables bridge_pkg=iproute2
    # Current Arch's iptables package provides the nftables backend and
    # replaced iptables-nft. Keep compatibility with repositories that still
    # expose the older package name.
    pacman -Si iptables-nft >/dev/null 2>&1 && nft_pkg=iptables-nft
    pacman -Si bridge-utils >/dev/null 2>&1 && bridge_pkg=bridge-utils

    pacman_install \
        qemu-full libvirt virt-manager virt-viewer dnsmasq \
        "$nft_pkg" "$bridge_pkg" edk2-ovmf swtpm

    getent group libvirt >/dev/null || groupadd libvirt
    getent group kvm >/dev/null || groupadd kvm
    touch /etc/fedora-arch-enable-libvirt

    # systemctl --now cannot start host services from an Arch chroot. Enable
    # libvirtd now and use an idempotent oneshot after boot to define/start the
    # packaged default NAT network.
    install -d -m0755 /usr/local/libexec
    cat > /usr/local/libexec/fedora-arch-libvirt-default-network <<'EOF_LIBVIRT_NETWORK'
#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

network_xml=/etc/libvirt/qemu/networks/default.xml
if ! /usr/bin/virsh --connect qemu:///system net-info default >/dev/null 2>&1; then
    [[ -f "$network_xml" ]] || {
        echo "libvirt default network XML is missing: $network_xml" >&2
        exit 1
    }
    /usr/bin/virsh --connect qemu:///system net-define "$network_xml"
fi

/usr/bin/virsh --connect qemu:///system net-autostart default
if [[ "$(/usr/bin/virsh --connect qemu:///system net-info default | awk '/^Active:/ {print $2}')" != yes ]]; then
    /usr/bin/virsh --connect qemu:///system net-start default
fi
EOF_LIBVIRT_NETWORK
    chmod 0755 /usr/local/libexec/fedora-arch-libvirt-default-network

    cat > /etc/systemd/system/fedora-arch-libvirt-network.service <<'EOF_LIBVIRT_SERVICE'
[Unit]
Description=Define and start libvirt's default NAT network
Requires=libvirtd.service
After=libvirtd.service
ConditionPathExists=/etc/fedora-arch-enable-libvirt

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/fedora-arch-libvirt-default-network
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_LIBVIRT_SERVICE

    systemctl daemon-reload
    systemctl enable libvirtd.service fedora-arch-libvirt-network.service
}

install_kde() {
    info "Installing the $KDE_EDITION KDE Plasma desktop"
    local -a desktop_pkgs=(
        # Minimal Plasma base and the essential desktop integrations that the
        # full Arch plasma group used to pull into this installer implicitly.
        plasma-desktop
        plasma-login-manager
        networkmanager plasma-nm plasma-pa kscreen
        xdg-desktop-portal-kde xdg-desktop-portal-gtk
        breeze breeze-icons kde-gtk-config
        noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra
        flatpak
        appstream appstream-qt archlinux-appstream-data
        polkit-kde-agent

        # Dolphin/KIO integration and useful preview providers.
        baloo-widgets dolphin-plugins ffmpegthumbs kde-inotify-survey
        kdegraphics-thumbnailers kdenetwork-filesharing
        kimageformats qt6-imageformats
        kio-admin kio-extras kio-fuse

        # Small desktop integration packages requested for the minimal image.
        kdeconnect khelpcenter qqc2-desktop-style qrca
        libappindicator orca switcheroo-control
        tesseract tesseract-data-eng unrar xsettingsd
    )

    # Force the PipeWire JACK implementation before installing Plasma packages
    # so an unattended provider choice never selects jack2.
    pacman_install \
        pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber \
        pipewire-jack lib32-pipewire-jack

    if (( ENABLE_DISCOVER_SYSTEM )); then
        desktop_pkgs+=(packagekit packagekit-qt6)
    fi
    (( SPOOF_DISCOVER_WARNING )) && desktop_pkgs+=(bubblewrap)

    (( KEEP_BLUETOOTH )) && desktop_pkgs+=(bluez bluez-utils bluedevil)
    if (( KEEP_CUPS )); then
        # Arch combines Fedora's printer applet/common/core/D-Bus pieces in
        # system-config-printer. cups-pk-helper supplies its PolicyKit bridge.
        desktop_pkgs+=(cups print-manager system-config-printer cups-pk-helper)
    fi
    if [[ "$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2}')" == GenuineIntel ]]; then
        desktop_pkgs+=(thermald)
    fi
    pacman_install "${desktop_pkgs[@]}"

    # Clean up installs made by older revisions of this project.
    if pacman -Q plasma-bigscreen >/dev/null 2>&1; then
        info "Removing plasma-bigscreen (not used by this desktop profile)"
        pacman_remove plasma-bigscreen
    fi

    if (( WAYLAND_ONLY )); then
        local -a plasma_x11_pkgs=()
        pacman -Q plasma-x11-session >/dev/null 2>&1 && plasma_x11_pkgs+=(plasma-x11-session)
        pacman -Q kwin-x11 >/dev/null 2>&1 && plasma_x11_pkgs+=(kwin-x11)
        if ((${#plasma_x11_pkgs[@]})); then
            info "Removing Plasma X11 login components: ${plasma_x11_pkgs[*]}"
            pacman_remove "${plasma_x11_pkgs[@]}"
        fi
    fi

    systemctl disable sddm.service 2>/dev/null || true
    local -a old_sddm_pkgs=()
    pacman -Q sddm-kcm >/dev/null 2>&1 && old_sddm_pkgs+=(sddm-kcm)
    pacman -Q sddm >/dev/null 2>&1 && old_sddm_pkgs+=(sddm)
    if ((${#old_sddm_pkgs[@]})); then
        info "Removing legacy SDDM packages: ${old_sddm_pkgs[*]}"
        pacman_remove "${old_sddm_pkgs[@]}"
    fi
    if ! pacman -Q sddm >/dev/null 2>&1 && id sddm >/dev/null 2>&1; then
        userdel -r sddm 2>/dev/null || userdel sddm 2>/dev/null || true
    fi

    # User-requested common KDE application set. KWrite is shipped by kate on
    # Arch, and vlc-plugins-all provides the complete codec/plugin set.
    pacman_install \
        dolphin konsole kate filelight \
        discover firefox gwenview okular \
        plasma-systemmonitor ark kcalc spectacle elisa partitionmanager \
        mpv vlc vlc-plugins-all

    # LocalSend is currently provided by the optional CachyOS and Chaotic-AUR
    # binary repositories, not official Arch extra. Keep the base installation
    # usable when a user deliberately disables both optional repositories.
    install_available_auto "Installing LocalSend" localsend
    install_kde_optional_applications
    install_virtualization_stack

    if [[ $FEDORA_DEFAULT_APPS -eq 1 ]]; then
        # Preselect useful OCR providers so pacman never auto-picks the first
        # alphabetical tessdata provider (e.g. Afrikaans) in unattended mode.
        install_available_auto "Installing OCR language providers" tesseract-data-eng tesseract-data-spa

        local fedora_kde_apps=(
            akonadi-import-wizard akregator
            dragon firewall-config gimp grantlee-editor
            kaddressbook kamoso kcharselect kdebugsettings
            kfind kinfocenter kjournald kleopatra kmahjongg kmail
            kmenuedit kmines kmouth kolourpaint kontact korganizer kpat krdc krfb
            kwalletmanager neochat obs-studio pim-data-exporter pim-sieve-editor
            plasma-welcome skanpage
            mediawriter
            osu-lazer scx-manager
            drkonqi
        )
        install_available_auto "Installing filtered Fedora KDE application bundle" "${fedora_kde_apps[@]}"
    fi

    if [[ "$ACCOUNT_SETUP" == oobe ]]; then
        install_plasma_oobe
    else
        configure_plasma_oobe_admin
    fi
    systemctl enable plasmalogin.service
}

install_gnome() {
    info "Installing GNOME"
    local desktop_pkgs=(
        gnome gdm gnome-software
        networkmanager
        pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber
        pipewire-jack lib32-pipewire-jack
        xdg-desktop-portal-gnome
        packagekit flatpak
        noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra
    )
    [[ "$ACCOUNT_SETUP" == oobe ]] && desktop_pkgs+=(gnome-initial-setup)
    (( KEEP_BLUETOOTH )) && desktop_pkgs+=(bluez bluez-utils)
    (( KEEP_CUPS )) && desktop_pkgs+=(cups)
    pacman_install "${desktop_pkgs[@]}"

    if [[ $FEDORA_DEFAULT_APPS -eq 1 ]]; then
        local fedora_generic_apps=(
            firefox firewall-config gimp libreoffice-fresh mediawriter obs-studio
            localsend osu-lazer scx-manager
        )
        install_available_auto "Installing captured Fedora desktop-neutral apps" "${fedora_generic_apps[@]}"
    fi

    systemctl enable gdm.service
}

configure_wayland_only() {
    if (( ! WAYLAND_ONLY )); then
        # Remove only this installer's managed drop-in when rerunning with the
        # option disabled; never rewrite unrelated administrator settings.
        rm -f /etc/environment.d/90-fedora-arch-wayland.conf
        return 0
    fi
    info "Configuring a Wayland-only desktop session"

    # environment.d is systemd's standard drop-in hierarchy.  These variables
    # force native Wayland client backends for the major Linux GUI toolkits;
    # OpenGL/EGL rendering then uses the toolkit's Wayland surface integration.
    # Do not set EGL_PLATFORM globally: compositors and headless/direct EGL
    # clients may legitimately require drm, device, or surfaceless platforms.
    install -d -m 0755 /etc/environment.d
    cat > /etc/environment.d/90-fedora-arch-wayland.conf <<'EOF_WAYLAND_ENV'
# Managed by fedora-arch install.sh: native Wayland application backends.
GDK_BACKEND=wayland
QT_QPA_PLATFORM=wayland
SDL_VIDEODRIVER=wayland
MOZ_ENABLE_WAYLAND=1
EOF_WAYLAND_ENV
    chmod 0644 /etc/environment.d/90-fedora-arch-wayland.conf

    # Current Arch GNOME ships only its Wayland session.  Keep GDM's standard
    # configuration explicit as well, while preserving any other local keys.
    if [[ "$DESKTOP" == gnome ]]; then
        local gdm_conf=/etc/gdm/custom.conf gdm_tmp
        install -d -m 0755 /etc/gdm
        if [[ -e "$gdm_conf" ]]; then
            backup_once "$gdm_conf"
        else
            printf '[daemon]\n' > "$gdm_conf"
        fi
        gdm_tmp="$(mktemp)"
        awk '
            BEGIN { in_daemon=0; daemon_seen=0; key_written=0 }
            /^\[daemon\][[:space:]]*$/ {
                in_daemon=1
                daemon_seen=1
                print
                next
            }
            /^\[/ {
                if (in_daemon && !key_written) {
                    print "WaylandEnable=true"
                    key_written=1
                }
                in_daemon=0
                print
                next
            }
            in_daemon && /^[#;]?[[:space:]]*WaylandEnable[[:space:]]*=/ {
                if (!key_written) {
                    print "WaylandEnable=true"
                    key_written=1
                }
                next
            }
            { print }
            END {
                if (in_daemon && !key_written)
                    print "WaylandEnable=true"
                else if (!daemon_seen) {
                    print ""
                    print "[daemon]"
                    print "WaylandEnable=true"
                }
            }
        ' "$gdm_conf" > "$gdm_tmp"
        install -m 0644 "$gdm_tmp" "$gdm_conf"
        rm -f "$gdm_tmp"
    fi
}

install_nvidia_580() {
    [[ $INSTALL_NVIDIA_580 -eq 1 ]] || return 0
    info "Installing NVIDIA 580xx legacy branch"
    if [[ $ENABLE_CHAOTIC -ne 1 ]]; then
        warn "Chaotic-AUR is disabled. Skipping 580xx because it is not in official Arch repos."
        return 0
    fi

    local pkgs=(
        nvidia-580xx-dkms nvidia-580xx-utils
        lib32-nvidia-580xx-utils opencl-nvidia-580xx lib32-opencl-nvidia-580xx
    )
    install_available_auto "NVIDIA 580xx packages" "${pkgs[@]}"
}

configure_services() {
    systemctl enable NetworkManager.service

    if [[ "$DESKTOP" == kde ]]; then
        # switcheroo-control exposes hybrid/discrete GPUs over D-Bus. thermald
        # is installed only on Intel hardware by install_kde().
        systemctl cat switcheroo-control.service >/dev/null 2>&1 && \
            systemctl enable switcheroo-control.service >/dev/null 2>&1 || true
        systemctl cat thermald.service >/dev/null 2>&1 && \
            systemctl enable thermald.service >/dev/null 2>&1 || true

        # kde-gtk-config starts the static xsettingsd user service when needed;
        # no invalid `systemctl --global enable` is attempted here.
        if pacman -Q firewalld >/dev/null 2>&1; then
            systemctl enable firewalld.service >/dev/null 2>&1 || true
            if command -v firewall-offline-cmd >/dev/null 2>&1; then
                firewall-offline-cmd --service=kdeconnect >/dev/null || \
                    warn "Could not add KDE Connect to firewalld's default zone."
            fi
        fi
    fi

    if (( KEEP_BLUETOOTH )); then
        systemctl cat bluetooth.service >/dev/null 2>&1 && systemctl enable bluetooth.service >/dev/null 2>&1 || true
    else
        systemctl mask bluetooth.service >/dev/null 2>&1 || true
    fi

    if (( KEEP_CUPS )); then
        systemctl cat cups.service >/dev/null 2>&1 && systemctl enable cups.service >/dev/null 2>&1 || true
    else
        systemctl mask cups.service cups.socket cups.path >/dev/null 2>&1 || true
    fi

    if (( KEEP_AVAHI )); then
        systemctl cat avahi-daemon.service >/dev/null 2>&1 && systemctl enable avahi-daemon.service >/dev/null 2>&1 || true
    else
        systemctl mask avahi-daemon.service avahi-daemon.socket >/dev/null 2>&1 || true
    fi

    if (( KEEP_MODEMMANAGER )); then
        systemctl cat ModemManager.service >/dev/null 2>&1 && systemctl enable ModemManager.service >/dev/null 2>&1 || true
    else
        systemctl mask ModemManager.service >/dev/null 2>&1 || true
    fi

    if (( PERF_IO || EXT4_EXTREME )); then
        systemctl cat fstrim.timer >/dev/null 2>&1 && systemctl enable fstrim.timer >/dev/null 2>&1 || true
    fi

    if (( DISABLE_OOMD )); then
        systemctl mask systemd-oomd.service systemd-oomd.socket >/dev/null 2>&1 || true
    else
        systemctl cat systemd-oomd.service >/dev/null 2>&1 && systemctl enable systemd-oomd.service >/dev/null 2>&1 || true
    fi

    # PackageKit's ALPM backend refreshes repository databases during the
    # offline transaction. On this setup it can otherwise start before DNS is
    # usable and falsely mark an already-applied update as failed. Wait for an
    # actually connected NetworkManager connection only for this service.
    if (( ENABLE_DISCOVER_SYSTEM )) && systemctl cat packagekit-offline-update.service >/dev/null 2>&1; then
        install -d /etc/systemd/system/packagekit-offline-update.service.d
        cat > /etc/systemd/system/packagekit-offline-update.service.d/10-network-online.conf <<'EOF_PK_OFFLINE'
[Unit]
Wants=network-online.target
Requires=fedora-arch-pacman-offline-preflight.service
After=NetworkManager.service NetworkManager-wait-online.service network-online.target fedora-arch-pacman-offline-preflight.service

[Service]
ExecStartPre=/usr/bin/nm-online -q -t 60
EOF_PK_OFFLINE
    fi

    if command -v flatpak >/dev/null 2>&1; then
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo || true
    fi
}

# -----------------------------------------------------------------------------
# Fedora assets / KDE appearance
# -----------------------------------------------------------------------------
install_wallpapers_and_branding() {
    # Minimal KDE deliberately stays Arch/Breeze-branded. Pastelitto is a
    # portable settings preset and does not opt the user into Fedora artwork.
    if [[ "$DESKTOP" == kde && "$KDE_EDITION" == minimal ]]; then
        info "Skipping Fedora wallpapers and branding for Minimal KDE"
        return 0
    fi
    info "Installing captured Fedora wallpapers/branding when present"

    if [[ -d "$FEDORA_BACKGROUND_ASSET_DIR/f44" ]]; then
        mkdir -p /usr/share/backgrounds
        cp -a "$FEDORA_BACKGROUND_ASSET_DIR/f44" /usr/share/backgrounds/
    fi

    if [[ -d "$WALLPAPER_ASSET_DIR/F44" ]]; then
        mkdir -p /usr/share/wallpapers
        rm -rf /usr/share/wallpapers/F44
        cp -a "$WALLPAPER_ASSET_DIR/F44" /usr/share/wallpapers/F44
        rm -rf /usr/share/wallpapers/Default /usr/share/wallpapers/Fedora
        ln -s F44 /usr/share/wallpapers/Default
        ln -s Default /usr/share/wallpapers/Fedora
    fi

    if [[ -d "$FEDORA_BRANDING_ASSET_DIR/logos/usr/share" ]]; then
        cp -a "$FEDORA_BRANDING_ASSET_DIR/logos/usr/share/." /usr/share/
    fi
}

install_fedora_kde_assets() {
    [[ "$DESKTOP" == kde ]] || return 0
    info "Configuring KDE edition assets"

    if [[ "$KDE_EDITION" == fedora ]]; then
        if compgen -G "$FEDORA_LOOKANDFEEL_ASSET_DIR/org.fedoraproject.*" >/dev/null; then
            mkdir -p /usr/share/plasma/look-and-feel
            cp -a "$FEDORA_LOOKANDFEEL_ASSET_DIR"/org.fedoraproject.* /usr/share/plasma/look-and-feel/
        fi

        if [[ -f "$FEDORA_BRANDING_ASSET_DIR/00-start-here-2.js" ]]; then
            install -Dm0644 "$FEDORA_BRANDING_ASSET_DIR/00-start-here-2.js" \
                /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/00-start-here-2.js
        fi

        if [[ -d "$FEDORA_CONFIG_ASSET_DIR/xdg/plasma-workspace" ]]; then
            mkdir -p /etc/xdg
            cp -a "$FEDORA_CONFIG_ASSET_DIR/xdg/plasma-workspace" /etc/xdg/
        fi

        if [[ -f "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" ]]; then
            install -d /etc/plasmalogin.conf.d
            install -m0644 "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" \
                /etc/plasmalogin.conf.d/10-fedora.conf
        fi
    else
        # Exact files managed by this installer; remove stale Fedora edition
        # defaults when rerunning and switching to Minimal KDE.
        rm -f /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/00-start-here-2.js
        rm -f /etc/plasmalogin.conf.d/10-fedora.conf
    fi

    install -d /etc/xdg
    if (( ENABLE_DISCOVER_SYSTEM )); then
        if [[ -f "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" ]]; then
            install -Dm0644 "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" /etc/xdg/discoverrc
        else
            cat > /etc/xdg/discoverrc <<'EOF'
[Software]
UseOfflineUpdates=true
EOF
        fi
        # KDE Discover's native unattended updater checks once per day. It
        # downloads application updates immediately but, with the setting
        # above, stages system packages for the next reboot.
        cat > /etc/xdg/PlasmaDiscoverUpdates <<'EOF_DISCOVER_UPDATES'
[Global]
RequiredNotificationInterval=86400
UseUnattendedUpdates=true
EOF_DISCOVER_UPDATES
        touch /etc/fedora-arch-discover-auto
    else
        cat > /etc/xdg/discoverrc <<'EOF'
[Software]
UseOfflineUpdates=false
EOF
        rm -f /etc/xdg/PlasmaDiscoverUpdates
        rm -f /etc/fedora-arch-discover-auto
    fi

    # Older revisions copied the source machine's entire layout. Remove only
    # those installer-managed legacy seeds; the new preset is intentionally
    # limited to the settings selected by the user.
    local -a legacy_pastelitto_files=(
        kdeglobals kwinrc kcminputrc plasmarc ksplashrc kscreenlockerrc
        kglobalshortcutsrc plasma-org.kde.plasma.desktop-appletsrc
    )
    local f
    for f in "${legacy_pastelitto_files[@]}"; do
        rm -f "/etc/skel/.config/$f"
    done

    install -d /etc/skel/.config /etc/skel/.local/share/konsole
    if (( APPLY_PASTELITTO_KDE )); then
        info "Applying the portable KDE Pastelitto preset to /etc/skel"
        touch /etc/fedora-arch-pastelitto

        cat > /etc/skel/.config/kwinrc <<'EOF_KWINRC'
[Desktops]
Number=3
Rows=1
EOF_KWINRC

        cat > /etc/skel/.local/share/konsole/Pastelitto.profile <<'EOF_KONSOLE_PROFILE'
[General]
Name=Pastelitto
Parent=FALLBACK/

[Appearance]
Font=Monospace,11,-1,5,50,0,0,0,0,0
EOF_KONSOLE_PROFILE
        cat > /etc/skel/.config/konsolerc <<'EOF_KONSOLERC'
[Desktop Entry]
DefaultProfile=Pastelitto.profile
EOF_KONSOLERC

        # HomeUrl is written with the real path by the OOBE helper. Dolphin's
        # current schema defines DetailsMode PreviewSize=32 for the captured
        # size, two increments above its smallest preview size.
        cat > /etc/skel/.config/dolphinrc <<'EOF_DOLPHINRC'
[DetailsMode]
PreviewSize=32

[General]
GlobalViewProps=true
RememberOpenedTabs=false
EOF_DOLPHINRC

        install -d /etc/skel/.local/share/dolphin/view_properties/global
        cat > /etc/skel/.local/share/dolphin/view_properties/global/.directory <<'EOF_DOLPHIN_VIEW'
[Dolphin]
Version=4
ViewMode=1
EOF_DOLPHIN_VIEW

        cat > /etc/skel/.config/kwriterc <<'EOF_KWRITERC'
[General]
Show welcome view for new window=false

[KTextEditor Renderer]
Text Font=Noto Sans,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0
EOF_KWRITERC

        cat > /etc/skel/.config/kateschemarc <<'EOF_KATESCHEMA'
[kate - Normal]
Font=Noto Sans,11,-1,5,50,0,0,0,0,0

[kwrite - Normal]
Font=Noto Sans,11,-1,5,50,0,0,0,0,0

[Normal]
Font=Noto Sans,11,-1,5,50,0,0,0,0,0
EOF_KATESCHEMA

        # Plasma's supported layout-update API applies the panel height when
        # the new user's shell creates its first panel; no captured screen or
        # activity identifiers are imported.
        install -d /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates
        cat > /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/99-pastelitto-panel-height.js <<'EOF_PANEL_HEIGHT'
for (var i = 0; i < panelIds.length; ++i) {
    var panel = panelById(panelIds[i]);
    if (panel) {
        panel.height = 38;
    }
}
EOF_PANEL_HEIGHT
    else
        info "Leaving KDE user customization unseeded"
        rm -f /etc/fedora-arch-pastelitto
        rm -f /etc/skel/.config/kwinrc /etc/skel/.config/konsolerc
        rm -f /etc/skel/.config/kateschemarc /etc/skel/.config/kwriterc /etc/skel/.config/dolphinrc
        rm -f /etc/skel/.local/share/konsole/Pastelitto.profile
        rm -f /etc/skel/.local/share/dolphin/view_properties/global/.directory
        rm -f /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/99-pastelitto-panel-height.js
    fi

    # On a repair/rerun, Plasma Setup may have completed before these assets
    # were staged. Reapply the idempotent per-user portion immediately.
    if [[ ( -e /etc/plasma-setup-done || -e /etc/fedora-arch-user-created ) && -x /usr/local/libexec/fedora-arch-plasma-admin ]]; then
        /usr/local/libexec/fedora-arch-plasma-admin
    fi
}

configure_pacman_offline_preflight() {
    info "Installing safe pacman/keyring preflight for offline updates"
    install -d -m0755 /usr/local/libexec /etc/systemd/system/packagekit-offline-update.service.d

    cat > /usr/local/libexec/fedora-arch-pacman-offline-preflight <<'EOF_PACMAN_PREFLIGHT'
#!/usr/bin/env bash
set -uo pipefail

log_file=/var/log/fedora-arch-pacman-offline-preflight.log
exec >>"$log_file" 2>&1

cancel_offline_boot() {
    [[ "${FEDORA_ARCH_OFFLINE_BOOT:-0}" == 1 ]] || return 0
    # Keep the prepared PackageKit data, but remove the boot trigger so a
    # failed validation returns to the desktop instead of entering a loop.
    /usr/bin/systemd-tmpfiles --inline --remove \
        'r /system-update' 'r /etc/system-update' >/dev/null 2>&1 || true
}

abort_update() {
    echo "ERROR: $*"
    if [[ "${FEDORA_ARCH_OFFLINE_BOOT:-0}" == 1 ]]; then
        echo "The offline update was cancelled and the machine will return to the desktop."
    else
        echo "The daily health check stopped; Discover will not receive an unsafe workaround."
    fi
    echo "Signature verification remains enabled."
    cancel_offline_boot
    exit 1
}

printf '\n===== %s =====\n' "$(date --iso-8601=seconds)"
echo "Starting signed pacman repository preflight"

if command -v nm-online >/dev/null 2>&1; then
    nm-online -q -t 60 || abort_update "NetworkManager did not reach an online state."
fi

# Ask the configured time service to synchronize. Do not block forever: a sane
# hardware clock is sufficient, and pacman remains the final signature judge.
timedatectl set-ntp true >/dev/null 2>&1 || true
for _ in {1..20}; do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]] && break
    sleep 1
done

refresh_output="$(pacman -Syy --noconfirm 2>&1)"
refresh_status=$?
printf '%s\n' "$refresh_output"
if (( refresh_status == 0 )); then
    echo "Signed repository refresh succeeded; no repair was necessary."
    exit 0
fi

# Do not touch keyrings for DNS, mirror, disk-space, lock, or unrelated errors.
# Recovery is limited to the failure classes for which repopulating installed
# keyrings and redownloading sync databases is safe and relevant.
if ! grep -Eqi \
    'signature.*(invalid|unknown trust|marginal trust|required key|could not be looked up)|database.*(invalid|corrupt)|invalid or corrupted database' \
    <<<"$refresh_output"; then
    abort_update "Repository refresh failed for a non-signature reason; no key repair was attempted."
fi

echo "Signature/database failure detected; clearing only downloaded sync databases."
find /var/lib/pacman/sync -maxdepth 1 -type f \
    \( -name '*.db' -o -name '*.db.sig' -o -name '*.files' -o -name '*.files.sig' \) \
    -delete

pacman-key --init || abort_update "pacman-key initialization failed."

keyrings=(archlinux)
for keyring in alhp cachyos chaotic; do
    [[ -f "/usr/share/pacman/keyrings/${keyring}.gpg" ]] && keyrings+=("$keyring")
done
echo "Repopulating installed keyrings: ${keyrings[*]}"
pacman-key --populate "${keyrings[@]}" || abort_update "Installed keyrings could not be repopulated."

if pacman -Syy --noconfirm; then
    echo "Signed repository recovery succeeded."
    exit 0
fi

abort_update "Signed repository refresh still fails after the safe recovery attempt."
EOF_PACMAN_PREFLIGHT
    chmod 0755 /usr/local/libexec/fedora-arch-pacman-offline-preflight

    cat > /etc/systemd/system/fedora-arch-pacman-offline-preflight.service <<'EOF_PACMAN_PREFLIGHT_SERVICE'
[Unit]
Description=Validate and safely repair pacman metadata before an offline update
Documentation=man:systemd.offline-updates(7)
DefaultDependencies=no
Requires=sysinit.target
Wants=network-online.target
After=sysinit.target NetworkManager.service NetworkManager-wait-online.service network-online.target
Before=packagekit-offline-update.service system-update.target

[Service]
Type=oneshot
Environment=FEDORA_ARCH_OFFLINE_BOOT=1
ExecStart=/usr/local/libexec/fedora-arch-pacman-offline-preflight
TimeoutStartSec=180
FailureAction=reboot

[Install]
WantedBy=system-update.target
EOF_PACMAN_PREFLIGHT_SERVICE

    # Run the same signed health check daily during normal operation. This can
    # repair the exact failure before Discover performs its user-session check;
    # the offline service above remains the final mandatory gate at reboot.
    cat > /etc/systemd/system/fedora-arch-pacman-repo-health.service <<'EOF_PACMAN_HEALTH_SERVICE'
[Unit]
Description=Daily signed pacman repository health check
Wants=network-online.target
After=NetworkManager.service NetworkManager-wait-online.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/fedora-arch-pacman-offline-preflight
TimeoutStartSec=180
Nice=10
IOSchedulingClass=idle
EOF_PACMAN_HEALTH_SERVICE

    cat > /etc/systemd/system/fedora-arch-pacman-repo-health.timer <<'EOF_PACMAN_HEALTH_TIMER'
[Unit]
Description=Run the pacman repository health check every day

[Timer]
OnBootSec=15s
OnCalendar=daily
AccuracySec=1min
Persistent=true
Unit=fedora-arch-pacman-repo-health.service

[Install]
WantedBy=timers.target
EOF_PACMAN_HEALTH_TIMER

    systemctl daemon-reload
    systemctl enable systemd-timesyncd.service NetworkManager-wait-online.service >/dev/null 2>&1 || true
    systemctl enable fedora-arch-pacman-offline-preflight.service >/dev/null 2>&1 || true
    systemctl enable fedora-arch-pacman-repo-health.timer >/dev/null 2>&1 || true
}

disable_discover_system_management() {
    systemctl disable fedora-arch-pacman-offline-preflight.service >/dev/null 2>&1 || true
    systemctl disable fedora-arch-pacman-repo-health.timer >/dev/null 2>&1 || true
    rm -f /etc/polkit-1/rules.d/10-discover-wheel-nopasswd.rules
    rm -f /usr/local/libexec/fedora-arch-pacman-offline-preflight
    rm -f /etc/systemd/system/fedora-arch-pacman-offline-preflight.service
    rm -f /etc/systemd/system/fedora-arch-pacman-repo-health.service
    rm -f /etc/systemd/system/fedora-arch-pacman-repo-health.timer
    rm -f /etc/systemd/system/packagekit-offline-update.service.d/10-network-online.conf
}

configure_discover_system_management() {
    [[ "$DESKTOP" == kde ]] || return 0

    if (( ENABLE_DISCOVER_SYSTEM )); then
        info "Configuring daily Discover updates with reboot-time system transactions"
        pacman_install packagekit packagekit-qt6 appstream appstream-qt archlinux-appstream-data
        configure_pacman_offline_preflight

        # PackageKit operations launched by an active local administrator in
        # wheel are allowed without an authentication dialog. Untrusted
        # package/key trust operations are deliberately NOT included.
        install -d -m0755 /etc/polkit-1/rules.d
        cat > /etc/polkit-1/rules.d/10-discover-wheel-nopasswd.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (!(subject.active == true && subject.local == true && subject.isInGroup("wheel"))) {
        return;
    }

    var packagekit = [
        "org.freedesktop.packagekit.package-install",
        "org.freedesktop.packagekit.package-reinstall",
        "org.freedesktop.packagekit.package-downgrade",
        "org.freedesktop.packagekit.package-remove",
        "org.freedesktop.packagekit.system-update",
        "org.freedesktop.packagekit.system-sources-refresh",
        "org.freedesktop.packagekit.system-sources-configure",
        "org.freedesktop.packagekit.trigger-offline-update",
        "org.freedesktop.packagekit.clear-offline-update",
        "org.freedesktop.packagekit.repair-system"
    ];

    var flatpak = [
        "org.freedesktop.Flatpak.app-install",
        "org.freedesktop.Flatpak.runtime-install",
        "org.freedesktop.Flatpak.app-uninstall",
        "org.freedesktop.Flatpak.runtime-uninstall",
        "org.freedesktop.Flatpak.modify-repo"
    ];

    if (packagekit.indexOf(action.id) !== -1 || flatpak.indexOf(action.id) !== -1) {
        return polkit.Result.YES;
    }
});
EOF
        chmod 0644 /etc/polkit-1/rules.d/10-discover-wheel-nopasswd.rules
    else
        info "Leaving Discover system-package automation disabled"
        disable_discover_system_management
    fi

    if (( SPOOF_DISCOVER_WARNING )); then
        info "Spoofing only Discover's OS view to hide its Arch/PackageKit warning"
        pacman_install bubblewrap
        # PackageKit remains outside this namespace and continues to see/use
        # the real Arch repositories and /etc/os-release.
        install -d -m0755 /usr/local/share/fedora-arch /usr/local/share/applications /usr/local/bin
        cp /etc/os-release /usr/local/share/fedora-arch/discover-os-release
        sed -i \
            -e 's/^ID=.*/ID=genericlinux/' \
            -e 's/^ID_LIKE=.*/ID_LIKE=linux/' \
            /usr/local/share/fedora-arch/discover-os-release
        grep -q '^ID_LIKE=' /usr/local/share/fedora-arch/discover-os-release || \
            echo 'ID_LIKE=linux' >> /usr/local/share/fedora-arch/discover-os-release

        cat > /usr/local/bin/plasma-discover <<'EOF'
#!/usr/bin/env bash
set -e
FAKE=/usr/local/share/fedora-arch/discover-os-release
REAL_OS_RELEASE="$(readlink -f /etc/os-release)"
exec /usr/bin/bwrap \
    --dev-bind / / \
    --ro-bind "$FAKE" "$REAL_OS_RELEASE" \
    /usr/bin/plasma-discover "$@"
EOF
        chmod 0755 /usr/local/bin/plasma-discover

        if [[ -f /usr/share/applications/org.kde.discover.desktop ]]; then
            cp /usr/share/applications/org.kde.discover.desktop \
               /usr/local/share/applications/org.kde.discover.desktop
            sed -i -E \
                's#^Exec=(/usr/bin/)?plasma-discover#Exec=/usr/local/bin/plasma-discover#' \
                /usr/local/share/applications/org.kde.discover.desktop
        fi
    else
        rm -f /usr/local/bin/plasma-discover
        rm -f /usr/local/share/fedora-arch/discover-os-release
        rm -f /usr/local/share/applications/org.kde.discover.desktop
    fi

    # Remove the older wrapper name if a previous revision created it.
    rm -f /usr/local/bin/plasma-discover-fedora
    systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# Extreme debloat / performance tuning
# -----------------------------------------------------------------------------
add_kernel_arg() {
    local arg="$1" existing
    for existing in "${KERNEL_EXTRA_ARGS[@]:-}"; do
        [[ "$existing" == "$arg" ]] && return 0
    done
    KERNEL_EXTRA_ARGS+=("$arg")
}

kernel_extra_args_string() {
    local out="" arg
    for arg in "${KERNEL_EXTRA_ARGS[@]:-}"; do
        [[ -n "$arg" ]] || continue
        out+="${out:+ }$arg"
    done
    printf '%s' "$out"
}

configure_kernel_tuning_args() {
    # quiet+splash are useful for the Fedora/Plymouth experience regardless of
    # the performance profile.
    add_kernel_arg quiet
    add_kernel_arg splash
    add_kernel_arg vt.global_cursor_default=0

    # User chose disk swap + zswap, not zram. Match CachyOS's current zswap
    # guidance (LZ4, 30% pool, shrinker) and retain our 80% re-accept threshold.
    add_kernel_arg systemd.zram=0
    add_kernel_arg zswap.enabled=1
    add_kernel_arg zswap.compressor=lz4
    add_kernel_arg zswap.max_pool_percent=30
    add_kernel_arg zswap.accept_threshold_percent=80
    add_kernel_arg zswap.shrinker_enabled=1

    if (( APPLY_FEDORA_CMDLINE )); then
        # Copied from the user's Fedora system, excluding BOOT_IMAGE= and root=.
        add_kernel_arg rhgb
        add_kernel_arg 'rd.driver.blacklist=nouveau,nova_core'
        add_kernel_arg 'modprobe.blacklist=nouveau,nova_core'
        add_kernel_arg ipv6.disable=0
        add_kernel_arg net.ifnames=0
        add_kernel_arg intel_pstate=active
        add_kernel_arg rd.udev.log-priority=3
        add_kernel_arg loglevel=0
    else
        add_kernel_arg rd.udev.log-priority=3
        add_kernel_arg loglevel=3
    fi

    if (( ENABLE_INTEL_KVM_TUNING )); then
        # Keep these explicit even where the kernel currently defaults a KVM
        # feature on. The user selected a stable IOMMU/KVM boot policy, and the
        # kernel command line uses the documented kvm-intel.* spelling.
        local virt_arg
        for virt_arg in \
            intel_iommu=on \
            iommu=pt \
            intremap=on \
            kvm.enable_virt_at_load=1 \
            kvm-intel.ept=1 \
            kvm-intel.unrestricted_guest=1 \
            kvm-intel.flexpriority=1 \
            kvm-intel.nested=1; do
            add_kernel_arg "$virt_arg"
        done
    fi

    # intel_pstate=active chooses the driver; Turbo is enabled manually by the
    # user's ~/performance.sh so no custom boot performance service is created.
    if (( PERF_CPU )) && grep -qm1 'vendor_id.*GenuineIntel' /proc/cpuinfo; then
        add_kernel_arg intel_pstate=active
    fi

    if (( DISABLE_MITIGATIONS )); then
        local a
        for a in \
            noibrs noibpb nopti nospectre_v1 nospectre_v2 spectre_v2=off \
            l1tf=off nospec_store_bypass_disable no_stf_barrier mds=off \
            tsx_async_abort=off mitigations=off tsx=on; do
            add_kernel_arg "$a"
        done
    fi

    (( DISABLE_AUDIT )) && add_kernel_arg audit=0
    (( DISABLE_WATCHDOG )) && add_kernel_arg nowatchdog
    (( DISABLE_PSTORE )) && add_kernel_arg efi_pstore.pstore_disable=1

    install -d /etc/modprobe.d
    cat > /etc/modprobe.d/blacklist-nouveau-nova.conf <<'EOF_BLACKLIST_GPU'
blacklist nouveau
blacklist nova_core
EOF_BLACKLIST_GPU

    if (( DISABLE_WATCHDOG )); then
        cat > /etc/modprobe.d/blacklist-intel-watchdog.conf <<'EOF_BLACKLIST_WDT'
blacklist iTCO_wdt
blacklist iTCO_vendor_support
blacklist sp5100_tco
EOF_BLACKLIST_WDT
    else
        rm -f /etc/modprobe.d/blacklist-intel-watchdog.conf
    fi
}

configure_logging() {
    install -d /etc/systemd/journald.conf.d
    case "$LOGGING_PROFILE" in
        1)
            # CachyOS caps the journal at 50 MiB. Keep normal persistent/auto
            # journaling semantics but prevent unbounded log growth.
            cat > /etc/systemd/journald.conf.d/99-fedora-arch-debloat.conf <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=50M
EOF_JOURNAL
            ;;
        2)
            cat > /etc/systemd/journald.conf.d/99-fedora-arch-debloat.conf <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
ForwardToSyslog=no
EOF_JOURNAL
            ;;
        3)
            cat > /etc/systemd/journald.conf.d/99-fedora-arch-debloat.conf <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
MaxLevelStore=warning
MaxLevelSyslog=warning
ForwardToSyslog=no
EOF_JOURNAL
            ;;
        4)
            cat > /etc/systemd/journald.conf.d/99-fedora-arch-debloat.conf <<'EOF_JOURNAL'
[Journal]
Storage=none
ReadKMsg=no
Audit=no
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
EOF_JOURNAL
            ;;
    esac
}

configure_syslog() {
    (( DISABLE_SYSLOG )) || return 0
    info "Disabling traditional syslog daemons"
    local svc
    for svc in rsyslog.service syslog-ng.service; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
            systemctl mask "$svc" >/dev/null 2>&1 || true
        fi
    done
}

configure_coredumps() {
    (( DISABLE_COREDUMP )) || return 0
    install -d /etc/systemd/coredump.conf.d /etc/security/limits.d
    cat > /etc/systemd/coredump.conf.d/99-disabled.conf <<'EOF_COREDUMP'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF_COREDUMP
    cat > /etc/sysctl.d/50-coredump.conf <<'EOF_CORE_SYSCTL'
# ArchWiki Core dump: do not dispatch automatic core dumps.
kernel.core_pattern=|/bin/false
EOF_CORE_SYSCTL
    cat > /etc/security/limits.d/99-no-coredump.conf <<'EOF_CORE_LIMIT'
* hard core 0
EOF_CORE_LIMIT
}

configure_cpu_performance() {
    (( PERF_CPU )) || return 0

    info "Installing manual performance.sh (no custom systemd performance service)"

    # Clean up the custom service created by older versions of this installer.
    # The performance policy is now applied only when the user explicitly runs
    # ~/performance.sh (copied from /etc/skel for the first-boot OOBE user).
    systemctl disable fedora-arch-max-performance.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/fedora-arch-max-performance.service

    # Small Intel userspace tool. It can explicitly enable Turbo in the CPU MSR.
    # The script also uses the kernel's intel_pstate sysfs control, so it still
    # works if this helper is unavailable for any reason.
    if grep -qm1 'vendor_id.*GenuineIntel' /proc/cpuinfo; then
        pacman_install x86_energy_perf_policy
    fi

    install -d /etc/skel
    cat > /etc/skel/performance.sh <<'EOF_PERFORMANCE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Manual gaming/max-performance profile.
# Nothing here runs automatically at boot.
if (( EUID != 0 )); then
    exec sudo -- "$0" "$@"
fi

echo '[performance] Enabling maximum CPU performance policy...'

# intel_pstate: 0 means Turbo P-states are ALLOWED.  This is the documented
# Turbo control for intel_pstate; Turbo still remains subject to BIOS, power,
# current and thermal limits.
if [[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
fi

# Do not cap intel_pstate below the hardware's maximum/turbo range.
if [[ -w /sys/devices/system/cpu/intel_pstate/max_perf_pct ]]; then
    echo 100 > /sys/devices/system/cpu/intel_pstate/max_perf_pct
fi

# Performance governor / intel_pstate performance algorithm.
for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor          /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$p" ]] || continue
    if grep -qw performance "${p%/scaling_governor}/scaling_available_governors" 2>/dev/null; then
        echo performance > "$p"
    fi
done

# Lowest possible Energy Performance Bias on pre-HWP Intel (Ivy Bridge etc.).
for p in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
    [[ -w "$p" ]] && echo 0 > "$p"
done

# Explicit Intel MSR Turbo-enable command. This is not a GRUB parameter.
# It complements no_turbo=0 above and is especially useful on older Intel CPUs.
if command -v x86_energy_perf_policy >/dev/null 2>&1; then
    x86_energy_perf_policy --turbo-enable 1 >/dev/null 2>&1 || true
    x86_energy_perf_policy --cpu all --epb performance >/dev/null 2>&1 || true
fi

# Generic boost control if a non-intel_pstate cpufreq driver exposes one.
if [[ -w /sys/devices/system/cpu/cpufreq/boost ]]; then
    echo 1 > /sys/devices/system/cpu/cpufreq/boost
fi

echo '[performance] Done.'
if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    printf '[performance] intel_pstate no_turbo=' 
    cat /sys/devices/system/cpu/intel_pstate/no_turbo
fi
EOF_PERFORMANCE_SCRIPT
    chmod 0755 /etc/skel/performance.sh
    if [[ "$ACCOUNT_SETUP" == now ]]; then
        install -m0755 -o "$INSTALL_USERNAME" -g "$(id -gn "$INSTALL_USERNAME")" \
            /etc/skel/performance.sh "/home/$INSTALL_USERNAME/performance.sh"
    fi
}

configure_io_performance() {
    (( PERF_IO )) || return 0
    info "Installing CachyOS-style adaptive I/O scheduler + storage rules"
    pacman_install hdparm
    install -d /usr/local/libexec /etc/udev/rules.d

    # CachyOS currently uses BFQ for HDD, mq-deadline for SATA/eMMC SSD, and
    # (since 26.04) Kyber for NVMe. Validate against each device's advertised
    # scheduler list so unsupported choices can never create udev errors.
    cat > /usr/local/libexec/fedora-arch-iosched <<'EOF_IOSCHED_HELPER'
#!/usr/bin/env bash
set -u
name="${1:-}"
[[ -n "$name" && -e "/sys/block/$name/queue/scheduler" ]] || exit 0
sched="/sys/block/$name/queue/scheduler"
rot="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 0)"
avail="$(cat "$sched" 2>/dev/null || true)"

pick=""
if [[ "$name" == nvme* ]]; then
    grep -qw kyber <<<"$avail" && pick=kyber
    [[ -n "$pick" ]] || { grep -qw none <<<"$avail" && pick=none; }
elif [[ "$rot" == 1 ]]; then
    grep -qw bfq <<<"$avail" && pick=bfq
    [[ -n "$pick" ]] || { grep -qw mq-deadline <<<"$avail" && pick=mq-deadline; }
else
    grep -qw mq-deadline <<<"$avail" && pick=mq-deadline
    [[ -n "$pick" ]] || { grep -qw none <<<"$avail" && pick=none; }
fi
[[ -n "$pick" ]] && printf '%s\n' "$pick" > "$sched" 2>/dev/null || true

# CachyOS keeps rotational ATA disks awake / at high APM performance.
if [[ "$rot" == 1 && "$name" == sd* && -b "/dev/$name" ]] && command -v hdparm >/dev/null 2>&1; then
    hdparm -B 254 -S 0 "/dev/$name" >/dev/null 2>&1 || true
fi
EOF_IOSCHED_HELPER
    chmod 0755 /usr/local/libexec/fedora-arch-iosched

    cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF_IOSCHED'
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", RUN+="/usr/local/libexec/fedora-arch-iosched %k"
EOF_IOSCHED

    # SATA link power management: CachyOS chooses max_performance for desktop
    # responsiveness. Assignment only occurs if the kernel exposes the attr.
    cat > /etc/udev/rules.d/61-sata-lpm-performance.rules <<'EOF_SATA_LPM'
ACTION=="add|change", SUBSYSTEM=="scsi_host", KERNEL=="host*", TEST=="link_power_management_policy", ATTR{link_power_management_policy}="max_performance"
EOF_SATA_LPM

    # CachyOS-style low-latency device permission; harmless when absent.
    cat > /etc/udev/rules.d/62-cpu-dma-latency.rules <<'EOF_DMA_LATENCY'
KERNEL=="cpu_dma_latency", GROUP="audio", MODE="0660"
EOF_DMA_LATENCY

    # CachyOS also grants the audio group access to the high-resolution timer
    # devices used by some low-latency audio/game workloads.
    cat > /etc/udev/rules.d/63-hpet-rtc-audio.rules <<'EOF_HPET_RTC'
KERNEL=="rtc0", GROUP="audio", MODE="0660"
KERNEL=="hpet", GROUP="audio", MODE="0660"
EOF_HPET_RTC

    systemctl enable fstrim.timer >/dev/null 2>&1 || true
}

configure_zswap() {
    info "Configuring CachyOS-style zswap over disk swap (zram disabled)"
    install -d /etc/sysctl.d /etc/udev/rules.d
    rm -f /etc/systemd/zram-generator.conf
    rm -f /etc/systemd/zram-generator.conf.d/99-fedora-arch.conf 2>/dev/null || true

    # CachyOS's zswap migration guide disables its zram rule with an empty local
    # override. This also protects us if a zram package is pulled in later.
    : > /etc/udev/rules.d/30-zram.rules

    cat > /etc/sysctl.d/98-fedora-arch-zswap.conf <<'EOF_ZSWAP_SYSCTL'
# Disk swap + zswap. Kernel command line selects LZ4 and a 30% zswap pool.
vm.swappiness = 100
vm.page-cluster = 0
EOF_ZSWAP_SYSCTL
}

configure_vm_sysctl() {
    (( PERF_SYSCTL )) || return 0

    local ram_kib ram_bytes dirty_bytes bg_bytes cpus min_dirty max_dirty
    ram_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
    ram_bytes=$(( ram_kib * 1024 ))
    cpus="$(nproc)"
    min_dirty=$((64 * 1024 * 1024))
    max_dirty=$((512 * 1024 * 1024))

    # Adaptive extension of CachyOS's 256/64 MiB defaults: use ~1/64 of RAM,
    # clamped to 64..512 MiB, and background flushing at one quarter of that.
    # On the user's 16 GiB system this is exactly CachyOS's 256 MiB / 64 MiB.
    dirty_bytes=$(( ram_bytes / 64 ))
    (( dirty_bytes < min_dirty )) && dirty_bytes=$min_dirty
    (( dirty_bytes > max_dirty )) && dirty_bytes=$max_dirty
    bg_bytes=$(( dirty_bytes / 4 ))

    info "Installing CachyOS-derived sysctl tuning (${cpus} CPU threads, $((ram_bytes/1024/1024/1024)) GiB RAM)"
    install -d /etc/sysctl.d
    cat > /etc/sysctl.d/99-fedora-arch-performance.conf <<EOF_SYSCTL
# CachyOS-derived desktop tuning.
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
kernel.unprivileged_userns_clone = 1
kernel.printk = 3 3 3 3
kernel.kptr_restrict = 2
net.core.netdev_max_backlog = 4096
fs.file-max = 2097152
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
kernel.sysrq = 1
EOF_SYSCTL
    if (( ! EXT4_EXTREME )); then
        cat >> /etc/sysctl.d/99-fedora-arch-performance.conf <<EOF_DIRTY_SYSCTL
# RAM-sized dirty-write thresholds (replaced by 99-ssd-writeback.conf when
# extreme ext4 tuning is selected).
vm.dirty_bytes = $dirty_bytes
vm.dirty_background_bytes = $bg_bytes
vm.dirty_writeback_centisecs = 1500
EOF_DIRTY_SYSCTL
    fi
    (( DISABLE_WATCHDOG )) && echo 'kernel.nmi_watchdog = 0' >> /etc/sysctl.d/99-fedora-arch-performance.conf

    # CachyOS explicitly warns that its game-performance profile often hurts
    # older / <6c12t CPUs. We therefore keep the user's manual performance.sh
    # instead of enabling a background scheduler/performance service.
    if (( cpus < 12 )); then
        info "CPU has $cpus threads: skipping CachyOS game-performance/scx automation; manual performance.sh remains opt-in."
    fi
}

configure_ext4_extreme_writeback() {
    if (( ! EXT4_EXTREME )); then
        return 0
    fi

    info "Installing extreme ext4 writeback tuning and periodic TRIM"
    install -d /etc/sysctl.d
    cat > /etc/sysctl.d/99-ssd-writeback.conf <<'EOF_EXT4_WRITEBACK'
# Extreme ext4 policy selected during formatting. Absolute byte limits avoid
# RAM-sized write bursts while moving data toward PLP-backed storage quickly.
vm.dirty_background_bytes = 134217728
vm.dirty_bytes = 1073741824
vm.dirty_writeback_centisecs = 100
vm.dirty_expire_centisecs = 1000
EOF_EXT4_WRITEBACK
    systemctl enable fstrim.timer >/dev/null 2>&1 || true
}

f2fs_root_has_compression() {
    local src dev feature_file
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    src="$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")"
    dev="$(basename "$src")"
    feature_file="/sys/fs/f2fs/$dev/features"
    [[ -r "$feature_file" ]] && grep -qw compression "$feature_file"
}

configure_f2fs_fstab() {
    (( OPTIMIZE_F2FS )) || return 0
    if ! awk '$1 !~ /^#/ && $3 == "f2fs" {found=1} END{exit !found}' /etc/fstab; then
        warn "F2FS optimization requested, but /etc/fstab has no F2FS entries. New format.sh writes verified F2FS entries automatically; leaving fstab untouched."
        return 0
    fi

    info "Validating/preserving F2FS options written by format.sh"
    pacman_install f2fs-tools
    backup_once /etc/fstab

    # format.sh probes every advanced F2FS option against the live kernel before
    # mounting and writes that exact successful option set to fstab. Do NOT add
    # atgc/gc_merge/compression blindly here: that was the cause of the old
    # mount failure. Only ensure the universally safe write-reduction options.
    local tmp
    tmp="$(mktemp)"
    awk '
        BEGIN { OFS="\t" }
        /^[[:space:]]*#/ || NF < 4 { print; next }
        $3 == "f2fs" {
            opts="," $4 ","
            if (opts !~ /,noatime,/) $4=$4 ",noatime"
            opts="," $4 ","
            if (opts !~ /,lazytime,/) $4=$4 ",lazytime"
            gsub(/^defaults,/, "", $4)
        }
        { print }
    ' /etc/fstab > "$tmp"
    install -m0644 "$tmp" /etc/fstab
    rm -f "$tmp"

    # New format.sh records the explicit F2FS compression choice. When disabled,
    # keep all F2FS fstab entries free of compress_* mount options. The on-disk
    # compression feature itself can only be changed by reformatting.
    if [[ -f /etc/fedora-arch-layout.conf ]] && grep -qx 'F2FS_COMPRESSION=0' /etc/fedora-arch-layout.conf; then
        tmp="$(mktemp)"
        awk '
            BEGIN { OFS="\t" }
            /^[[:space:]]*#/ || NF < 4 { print; next }
            $3 == "f2fs" {
                n=split($4,a,","); out=""
                for (i=1;i<=n;i++) {
                    if (a[i] ~ /^compress(_|$)/) continue
                    out=out (out ? "," : "") a[i]
                }
                $4=out
            }
            { print }
        ' /etc/fstab > "$tmp"
        install -m0644 "$tmp" /etc/fstab
        rm -f "$tmp"
    fi

    # Root F2FS + atgc may need explicit rw during the early root remount.
    if awk '$1 !~ /^#/ && $2=="/" && $3=="f2fs" && $4 ~ /(^|,)atgc(,|$)/ {found=1} END{exit !found}' /etc/fstab; then
        add_kernel_arg rw
    fi
}

configure_cachyos_system_tuning() {
    (( PERF_SYSCTL || PERF_IO )) || return 0
    info "Applying low-bloat CachyOS systemd/THP/realtime defaults"

    install -d /etc/systemd/system.conf.d /etc/systemd/user.conf.d /etc/tmpfiles.d /etc/security/limits.d
    cat > /etc/systemd/system.conf.d/60-fedora-arch-performance.conf <<'EOF_SYSTEMD_SYS'
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
DefaultLimitNOFILE=2048:2097152
EOF_SYSTEMD_SYS
    cat > /etc/systemd/user.conf.d/60-fedora-arch-performance.conf <<'EOF_SYSTEMD_USER'
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
DefaultLimitNOFILE=1024:1048576
EOF_SYSTEMD_USER

    # CachyOS THP defaults: defer heavy defrag and let khugepaged reclaim sparse
    # huge pages. w- silently ignores kernels that do not expose a knob.
    cat > /etc/tmpfiles.d/60-fedora-arch-thp.conf <<'EOF_THP'
w- /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
w- /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none - - - - 409
EOF_THP

    cat > /etc/security/limits.d/60-fedora-arch-audio.conf <<'EOF_AUDIO_LIMITS'
@audio - rtprio 99
EOF_AUDIO_LIMITS

    # Match CachyOS user-session resource delegation. This lets the user
    # manager/game tooling manage CPU, cpuset, I/O, memory and pid cgroups.
    install -d /etc/systemd/system/user@.service.d
    cat > /etc/systemd/system/user@.service.d/60-fedora-arch-delegate.conf <<'EOF_DELEGATE'
[Service]
Delegate=cpu cpuset io memory pids
EOF_DELEGATE

    # CachyOS loads ntsync for Wine/Windows synchronization when the target
    # kernel actually ships the module. Detect the INSTALLED kernel tree (not
    # the archiso/chroot host kernel) before enabling it.
    if find /usr/lib/modules -type f \( -name 'ntsync.ko' -o -name 'ntsync.ko.zst' -o -name 'ntsync.ko.xz' -o -name 'ntsync.ko.gz' \)             -print -quit 2>/dev/null | grep -q .; then
        install -d /etc/modules-load.d
        printf '%s\n' ntsync > /etc/modules-load.d/60-fedora-arch-ntsync.conf
    else
        rm -f /etc/modules-load.d/60-fedora-arch-ntsync.conf 2>/dev/null || true
    fi
}

configure_baloo() {
    (( DISABLE_BALOO )) || return 0
    install -d /etc/xdg
    cat > /etc/xdg/baloofilerc <<'EOF_BALOO'
[Basic Settings]
Indexing-Enabled=false
EOF_BALOO
}

configure_nvidia_performance() {
    if (( ! APPLY_NVIDIA_PERFORMANCE )); then
        info "NVIDIA performance modprobe options were not selected; skipping them."
        return 0
    fi

    # Do not use modinfo here. install.sh runs in arch-chroot while the Arch ISO
    # kernel is still running, so a runtime lookup can incorrectly hide a DKMS
    # module built for the target system. This is an explicit opt-in: write the
    # requested policy without testing whether nvidia is installed or loaded.
    info "Writing NVIDIA performance modprobe options without runtime module validation"
    install -d -m0755 /etc/modprobe.d
    cat > /etc/modprobe.d/nvidia-performance.conf <<'EOF_NVIDIA_PERFORMANCE'
# Explicitly selected by the Fedora-Arch installer. This file is intentionally
# written without querying the Arch ISO's running kernel from inside chroot.
options nvidia NVreg_UsePageAttributeTable=1 NVreg_EnablePCIeGen3=1 NVreg_EnableMSI=1 NVreg_InitializeSystemMemoryAllocations=0 NVreg_EnableStreamMemOPs=1 NVreg_DynamicPowerManagement=0x00
EOF_NVIDIA_PERFORMANCE
    ok "Created /etc/modprobe.d/nvidia-performance.conf"
}

configure_intel_igpu_performance() {
    if (( ! APPLY_INTEL_IGPU_PERFORMANCE )); then
        rm -f /etc/modprobe.d/i915-performance.conf
        return 0
    fi

    # This is an explicit force option. Do not inspect the live archiso kernel
    # or require Intel graphics to be loaded while operating inside chroot.
    info "Writing the requested Intel i915 performance policy unconditionally"
    install -d -m0755 /etc/modprobe.d
    cat > /etc/modprobe.d/i915-performance.conf <<'EOF_I915_PERFORMANCE'
# Pastelitto i915 performance policy; deliberately favors performance.
options i915 mitigations=off enable_fbc=1 enable_dp_mst=1 enable_ips=1 disable_power_well=0 enable_psr=-1 enable_panel_replay=-1 enable_sagv=1 enable_dsb=1 enable_dpt=1 enable_dc=-1 enable_guc=-1
EOF_I915_PERFORMANCE
    ok "Created /etc/modprobe.d/i915-performance.conf"
}

configure_pastelitto_tuned() {
    if (( ! ENABLE_PASTELITTO_TUNED )); then
        return 0
    fi

    info "Installing TuneD/tuned-ppd and the Pastelitto power profiles"
    # tuned-ppd provides the same D-Bus API. Remove only the real conflicting
    # package, without recursively removing Plasma/PowerDevil consumers.
    if pacman -Qq 2>/dev/null | grep -Fxq power-profiles-daemon; then
        systemctl disable power-profiles-daemon.service >/dev/null 2>&1 || true
        pacman -Rdd --noconfirm power-profiles-daemon
    fi
    pacman_install tuned tuned-ppd cpupower

    install -d -m0755 /usr/local/libexec /etc/tuned/profiles /etc/tuned
    cat > /usr/local/libexec/pastelitto-power-profile <<'EOF_TUNED_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
profile="${1:-}"

find_graphics_env() {
    local uid user runtime envtxt display xauth
    uid="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$2 ~ /^[0-9]+$/ && $2 >= 1000 {print $2; exit}')"
    [[ -n "$uid" ]] || return 1
    user="$(getent passwd "$uid" | cut -d: -f1)"
    runtime="/run/user/$uid"
    [[ -n "$user" && -d "$runtime" ]] || return 1
    envtxt="$(runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user show-environment 2>/dev/null || true)"
    display="$(sed -n 's/^DISPLAY=//p' <<<"$envtxt" | head -n1)"
    xauth="$(sed -n 's/^XAUTHORITY=//p' <<<"$envtxt" | head -n1)"
    [[ -n "$display" ]] || display=:0
    if [[ -z "$xauth" || ! -r "$xauth" ]]; then
        xauth="$(find "$runtime" -maxdepth 1 -type f -name 'xauth_*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {$1=""; sub(/^ /,""); print}')"
    fi
    [[ -n "$xauth" && -r "$xauth" ]] || return 1
    printf '%s\n%s\n' "$display" "$xauth"
}

set_nvidia_x() {
    local core="$1" mem="$2" pmode="$3" gx display xauth
    command -v nvidia-settings >/dev/null 2>&1 || return 0
    gx="$(find_graphics_env || true)"
    [[ -n "$gx" ]] || return 0
    display="$(sed -n '1p' <<<"$gx")"; xauth="$(sed -n '2p' <<<"$gx")"
    env DISPLAY="$display" XAUTHORITY="$xauth" nvidia-settings \
        -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=$core" \
        -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=$mem" \
        -a "[gpu:0]/GPUPowerMizerMode=$pmode" >/dev/null || true
}

case "$profile" in
    power-saver)
        cpupower frequency-set -d 1.6GHz -u 1.6GHz -g powersave || true
        cpupower set -b 15 || true
        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -pl 52.5 >/dev/null || true
        set_nvidia_x -200 -1200 2 ;;
    balanced)
        cpupower frequency-set -d 1.6GHz -u 3.8GHz -g powersave || true
        cpupower set -b 6 || true
        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -pl 70 >/dev/null || true
        set_nvidia_x 0 0 0 ;;
    performance)
        cpupower frequency-set -d 3.8GHz -u 3.8GHz -g performance || true
        cpupower set -b 0 || true
        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -pl 75 >/dev/null || true
        set_nvidia_x 180 640 1 ;;
    *) echo "Usage: $0 {power-saver|balanced|performance}" >&2; exit 2 ;;
esac
EOF_TUNED_HELPER
    chmod 0755 /usr/local/libexec/pastelitto-power-profile

    local name governor bias boost mode summary dir
    while IFS='|' read -r name governor bias boost mode summary; do
        dir="/etc/tuned/profiles/$name"
        install -d -m0755 "$dir"
        cat > "$dir/tuned.conf" <<EOF_TUNED_PROFILE
[main]
summary=$summary

[cpu]
governor=$governor
energy_perf_bias=$bias
boost=$boost

[script]
script=\${i:PROFILE_DIR}/script.sh
EOF_TUNED_PROFILE
        cat > "$dir/script.sh" <<EOF_TUNED_SCRIPT
#!/usr/bin/env bash
set -e
case "\${1:-}" in
    start) exec /usr/local/libexec/pastelito-power-profile $mode ;;
    stop)  exec /usr/local/libexec/pastelito-power-profile balanced ;;
    *) exit 0 ;;
esac
EOF_TUNED_SCRIPT
        chmod 0755 "$dir/script.sh"
    done <<'EOF_TUNED_PROFILES'
pastelito-powersave|powersave|powersave|0|power-saver|Pastelitto: CPU 1.6 GHz + GTX 1050 minimum-power profile
pastelito-balanced|powersave|normal|1|balanced|Pastelitto: dynamic CPU + stock GTX 1050 profile
pastelito-performance|performance|performance|1|performance|Pastelitto: maximum CPU + GTX 1050 performance profile
EOF_TUNED_PROFILES

    cat > /etc/tuned/ppd.conf <<'EOF_TUNED_PPD'
[main]
default=balanced
battery_detection=false
sysfs_acpi_monitor=false

[profiles]
power-saver=pastelito-powersave
balanced=pastelito-balanced
performance=pastelito-performance
EOF_TUNED_PPD
    printf '%s\n' pastelito-balanced > /etc/tuned/active_profile
    printf '%s\n' manual > /etc/tuned/profile_mode
    systemctl unmask tuned.service tuned-ppd.service >/dev/null 2>&1 || true
    systemctl enable tuned.service tuned-ppd.service
}

install_cachy_kernel_builder() {
    if (( ! INSTALL_CACHY_BUILDER )); then
        rm -f /etc/fedora-arch-cachy-kernel-default
        return 0
    fi

    info "Installing the CachyOS kernel builder shortcut"
    [[ -f "$CACHY_KERNEL_ASSET" ]] || fatal "Missing CachyOS builder asset: $CACHY_KERNEL_ASSET"
    local target owner group
    if [[ "$ACCOUNT_SETUP" == now ]]; then
        target="/home/$INSTALL_USERNAME/Documents/cachy-kernel"
        owner="$INSTALL_USERNAME"
        group="$(id -gn "$INSTALL_USERNAME")"
        install -d -m0755 -o "$owner" -g "$group" "$target"
        install -m0755 -o "$owner" -g "$group" "$CACHY_KERNEL_ASSET" "$target/build-cachyos-kernel.sh"
    else
        target=/etc/skel/Documents/cachy-kernel
        install -d -m0755 "$target"
        install -m0755 "$CACHY_KERNEL_ASSET" "$target/build-cachyos-kernel.sh"
    fi

    cat > /usr/local/bin/cachy-kernel-builder <<'EOF_CACHY_WRAPPER'
#!/usr/bin/env bash
set -e
builder="$HOME/Documents/cachy-kernel/build-cachyos-kernel.sh"
[[ -x "$builder" ]] || { echo "CachyOS builder not found: $builder" >&2; exit 1; }
exec "$builder" "$@"
EOF_CACHY_WRAPPER
    chmod 0755 /usr/local/bin/cachy-kernel-builder

    if (( MAKE_CACHY_DEFAULT )); then
        touch /etc/fedora-arch-cachy-kernel-default
    else
        rm -f /etc/fedora-arch-cachy-kernel-default
    fi

    # The builder calls this after every successful kernel installation. It
    # preserves pkgbase filenames and updates the bootloader selected here.
    install -d -m0755 /usr/local/libexec
    cat > /usr/local/libexec/fedora-arch-register-cachy-kernel <<EOF_CACHY_REGISTER
#!/usr/bin/env bash
set -Eeuo pipefail
pkgbase="\${1:?kernel pkgbase is required}"
provider='$INITRAMFS'
bootloader='$BOOTLOADER'

pkgbase_file=""
for candidate in /usr/lib/modules/*/pkgbase; do
    [[ -f "\$candidate" ]] || continue
    [[ "\$(<"\$candidate")" == "\$pkgbase" ]] && { pkgbase_file="\$candidate"; break; }
done
[[ -n "\$pkgbase_file" ]] || { echo "No installed module tree for \$pkgbase" >&2; exit 1; }
kver="\${pkgbase_file#/usr/lib/modules/}"; kver="\${kver%/pkgbase}"
install -Dm0644 "/usr/lib/modules/\$kver/vmlinuz" "/boot/vmlinuz-\$pkgbase"

case "\$provider" in
    dracut)
        dracut --force -L 3 "/boot/initramfs-\$pkgbase.img" --kver "\$kver" ;;
    mkinitcpio)
        mkinitcpio -P ;;
    booster)
        /usr/lib/booster/regenerate_images
        [[ -f "/boot/booster-\$pkgbase.img" ]] && ln -sfn "booster-\$pkgbase.img" "/boot/initramfs-\$pkgbase.img" ;;
esac
[[ -f "/boot/initramfs-\$pkgbase.img" ]] || { echo "Missing /boot/initramfs-\$pkgbase.img" >&2; exit 1; }

make_default=0
[[ -e /etc/fedora-arch-cachy-kernel-default ]] && make_default=1
case "\$bootloader" in
    grub)
        if [[ -x /usr/local/sbin/grub-mkconfig ]]; then
            /usr/local/sbin/grub-mkconfig -o /boot/grub/grub.cfg
        else
            /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
        fi
        if (( make_default )); then
            entry_id="\$(awk -v image="/vmlinuz-\$pkgbase" '
                /^menuentry / { entry=\$0 }
                index(\$0, image) { print entry; exit }
            ' /boot/grub/grub.cfg | sed -n "s/.*\\\$menuentry_id_option '\\([^']*\\)'.*/\\1/p")"
            [[ -n "\$entry_id" ]] || { echo "Could not locate GRUB entry for \$pkgbase" >&2; exit 1; }
            grub-set-default "\$entry_id"
        fi
        ;;
    systemd-boot)
        cmdline="\$(sed -n 's/^options[[:space:]]\+//p' /boot/loader/entries/arch.conf | head -n1)"
        cat > "/boot/loader/entries/\$pkgbase.conf" <<EOF_ENTRY
title   CachyOS Custom (\$pkgbase)
linux   /vmlinuz-\$pkgbase
initrd  /initramfs-\$pkgbase.img
options \$cmdline
EOF_ENTRY
        (( make_default )) && sed -i "s|^default .*|default \$pkgbase.conf|" /boot/loader/loader.conf
        ;;
    limine)
        sed -i '/^# BEGIN FEDORA-ARCH CACHY$/,/^# END FEDORA-ARCH CACHY$/d' /boot/EFI/BOOT/limine.conf
        cmdline="\$(sed -n 's/^[[:space:]]*cmdline:[[:space:]]*//p' /boot/EFI/BOOT/limine.conf | head -n1)"
        cat >> /boot/EFI/BOOT/limine.conf <<EOF_ENTRY
# BEGIN FEDORA-ARCH CACHY
/CachyOS Custom (\$pkgbase)
    protocol: linux
    path: boot():/vmlinuz-\$pkgbase
    cmdline: \$cmdline
    module_path: boot():/initramfs-\$pkgbase.img
# END FEDORA-ARCH CACHY
EOF_ENTRY
        if (( make_default )); then
            if grep -q '^default_entry:' /boot/EFI/BOOT/limine.conf; then
                sed -i "s|^default_entry:.*|default_entry: CachyOS Custom (\$pkgbase)|" /boot/EFI/BOOT/limine.conf
            else
                sed -i "1idefault_entry: CachyOS Custom (\$pkgbase)" /boot/EFI/BOOT/limine.conf
            fi
        fi
        ;;
esac
printf '%s\n' "\$pkgbase" > /etc/fedora-arch-last-cachy-pkgbase
EOF_CACHY_REGISTER
    chmod 0755 /usr/local/libexec/fedora-arch-register-cachy-kernel
}

compile_cachy_kernel_now() {
    (( COMPILE_CACHY_NOW )) || return 0
    info "Starting the interactive CachyOS kernel build as $INSTALL_USERNAME"
    runuser -u "$INSTALL_USERNAME" -- env \
        HOME="/home/$INSTALL_USERNAME" \
        XDG_DATA_HOME="/home/$INSTALL_USERNAME/.local/share" \
        "/home/$INSTALL_USERNAME/Documents/cachy-kernel/build-cachyos-kernel.sh"
}

configure_preboot_tuning() {
    # These settings must exist before initramfs/bootloader generation because
    # they affect kernel cmdline, modprobe state, and root mount semantics.
    info "Applying pre-boot tuning needed for initramfs/bootloader generation"
    configure_kernel_tuning_args
    configure_f2fs_fstab
    configure_nvidia_performance
    configure_intel_igpu_performance
}

configure_late_performance_tuning() {
    # Everything else intentionally happens late so aggressive desktop tuning
    # cannot interfere with package installation or repository bootstrapping.
    info "Applying late performance/debloat configuration"
    configure_logging
    configure_syslog
    configure_coredumps
    configure_cpu_performance
    configure_io_performance
    configure_zswap
    configure_vm_sysctl
    configure_ext4_extreme_writeback
    configure_cachyos_system_tuning
    configure_baloo
    # Must remain last: no installer package transaction may run after the
    # volatile CacheDir becomes active.
    configure_pacman_ram_cache
}

configure_plymouth() {
    info "Configuring Plymouth BGRT"
    local theme=/usr/share/plymouth/themes/bgrt/bgrt.plymouth
    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/plymouth/bgrt.plymouth" && -f "$theme" ]]; then
        cp -a "$FEDORA_CONFIG_ASSET_DIR/plymouth/bgrt.plymouth" "$theme"
    fi
    plymouth-set-default-theme bgrt
}

mkinitcpio_add_plymouth() {
    local conf=/etc/mkinitcpio.conf
    [[ -f "$conf" ]] || fatal "mkinitcpio.conf not found"
    python3 - "$conf" <<'PY'
import re,sys
p=sys.argv[1]
s=open(p).read()
m=re.search(r'^HOOKS=\((.*?)\)$',s,re.M)
if not m: raise SystemExit('Could not parse HOOKS in mkinitcpio.conf')
h=m.group(1).split()
h=[x for x in h if x!='plymouth']
idx=len(h)
for name in ('encrypt','sd-encrypt'):
    if name in h: idx=min(idx,h.index(name))
if idx==len(h):
    for name in ('systemd','udev'):
        if name in h: idx=h.index(name)+1; break
h.insert(idx,'plymouth')
s=s[:m.start()]+'HOOKS=('+' '.join(h)+')'+s[m.end():]
open(p,'w').write(s)
PY
}

kernel_version_for_linux() {
    local f pkg
    for f in /usr/lib/modules/*/pkgbase; do
        [[ -f "$f" ]] || continue
        read -r pkg < "$f"
        if [[ "$pkg" == linux ]]; then
            basename "$(dirname "$f")"
            return 0
        fi
    done
    return 1
}

configure_initramfs() {
    info "Generating initramfs with $INITRAMFS + Plymouth"
    case "$INITRAMFS" in
        dracut)
            install -d /etc/dracut.conf.d /etc/pacman.d/hooks
            local root_src root_type root_fs
            root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
            root_type="$(lsblk -ndo TYPE "$root_src" 2>/dev/null || true)"
            root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

            {
                echo 'add_dracutmodules+=" plymouth "'
                echo 'early_microcode="no"'
                echo 'dracut_rescue_image="no"'
                [[ "$root_fs" == f2fs ]] && echo 'force_drivers+=" f2fs "'
                [[ "$root_src" == /dev/md* || "$root_type" == raid* ]] && echo 'force_add_dracutmodules+=" mdraid "'
            } > /etc/dracut.conf.d/10-fedora-arch.conf

            # Stop mkinitcpio package hooks; the stock Arch dracut ALPM hooks stay
            # active and will rebuild pkgbase-named images on future upgrades.
            ln -sfn /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
            ln -sfn /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
            if pacman -Q mkinitcpio >/dev/null 2>&1; then
                pacman_remove mkinitcpio || warn "mkinitcpio could not be removed; its hooks are masked."
            fi
            if pacman -Q booster >/dev/null 2>&1; then
                pacman_remove booster || warn "booster could not be removed; dracut remains selected."
            fi

            # Old installer revisions created a no-hostonly fallback explicitly.
            # Remove those stale images; current Arch dracut hooks do not create them.
            rm -f /boot/initramfs-*-fallback.img

            # Generate EVERY installed kernel using Arch's pkgbase names, e.g.
            # initramfs-linux.img and initramfs-linux-cachyos-bore-lto.img.
            local p kver pkgbase built=0
            for p in /usr/lib/modules/*/pkgbase; do
                [[ -f "$p" ]] || continue
                read -r pkgbase < "$p"
                kver="${p#/usr/lib/modules/}"
                kver="${kver%/pkgbase}"
                [[ -f "/usr/lib/modules/$kver/vmlinuz" ]] || { warn "Missing vmlinuz for $pkgbase ($kver); skipping"; continue; }
                install -Dm0644 "/usr/lib/modules/$kver/vmlinuz" "/boot/vmlinuz-$pkgbase"
                dracut --force -L 3 "/boot/initramfs-$pkgbase.img" --kver "$kver"
                built=1
            done
            (( built )) || fatal "No installed kernel pkgbase entries were found for dracut."
            ;;
        mkinitcpio)
            # python is normally installed by Plasma/GNOME dependencies, but make
            # sure it exists because the hook editor above uses it.
            pacman -Q python >/dev/null 2>&1 || pacman_install python
            mkinitcpio_add_plymouth
            mkinitcpio -P
            ;;
        booster)
            install -d /etc/pacman.d/hooks
            ln -sfn /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
            ln -sfn /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
            if pacman -Q mkinitcpio >/dev/null 2>&1; then
                pacman_remove mkinitcpio || warn "mkinitcpio could not be removed; its hooks are masked."
            fi
            if pacman -Q dracut >/dev/null 2>&1; then
                pacman_remove dracut || warn "dracut could not be removed; Booster remains selected."
            fi
            touch /etc/booster.yaml
            if grep -q '^enable_plymouth:' /etc/booster.yaml; then
                sed -i 's/^enable_plymouth:.*/enable_plymouth: true/' /etc/booster.yaml
            else
                echo 'enable_plymouth: true' >> /etc/booster.yaml
            fi
            /usr/lib/booster/regenerate_images
            [[ -f /boot/booster-linux.img ]] || fatal "Booster did not generate /boot/booster-linux.img"
            ln -sfn booster-linux.img /boot/initramfs-linux.img
            ;;
    esac
}

kernel_cmdline() {
    local uuid source extra
    uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
    if [[ -z "$uuid" ]]; then
        source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        [[ -n "$source" ]] && uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
    fi
    [[ -n "$uuid" ]] || fatal "Could not determine the UUID of the root filesystem."
    extra="$(kernel_extra_args_string)"
    printf 'root=UUID=%s rw%s%s' "$uuid" "${extra:+ }" "$extra"
}

booster_microcode_entry() {
    [[ "$INITRAMFS" == booster ]] || return 0
    if [[ -f /boot/intel-ucode.img ]]; then
        echo '/intel-ucode.img'
    elif [[ -f /boot/amd-ucode.img ]]; then
        echo '/amd-ucode.img'
    fi
}

# -----------------------------------------------------------------------------
# Boot loader — UEFI only; ESP is /boot or /efi depending on format.sh layout
# -----------------------------------------------------------------------------
install_fedora_style_grub_autohide() {
    info "Installing Fedora-style GRUB auto-hide / failed-boot behavior"

    cat > /etc/grub.d/10_reset_boot_success <<'EOF_GRUB_RESET'
#!/bin/sh
cat <<'EOF'
# Hiding the menu is OK if the previous boot was successful or indeterminate.
if [ "${boot_success}" = "1" -o "${boot_indeterminate}" = "1" ]; then
  set menu_hide_ok=1
else
  set menu_hide_ok=0
fi
if [ "${boot_success}" = "1" ]; then
  set boot_indeterminate=0
elif [ "${boot_indeterminate}" = "1" ]; then
  set boot_indeterminate=2
fi
set boot_success=0
save_env boot_success boot_indeterminate
EOF
EOF_GRUB_RESET

    cat > /etc/grub.d/12_menu_auto_hide <<'EOF_GRUB_HIDE'
#!/bin/sh
cat <<'EOF'
if [ x$feature_timeout_style = xy ]; then
  if [ "${menu_show_once}" ]; then
    unset menu_show_once
    save_env menu_show_once
    set timeout_style=menu
    set timeout=60
  elif [ "${menu_auto_hide}" -a "${menu_hide_ok}" = "1" ]; then
    set orig_timeout_style=${timeout_style}
    set orig_timeout=${timeout}
    if [ "${fastboot}" = "1" ]; then
      set timeout_style=menu
      set timeout=0
    else
      set timeout_style=hidden
      set timeout=1
    fi
  fi
fi
EOF
EOF_GRUB_HIDE

    cat > /etc/grub.d/14_menu_show_once <<'EOF_GRUB_ONCE'
#!/bin/sh
cat <<'EOF'
if [ x$feature_timeout_style = xy ]; then
  if [ "${menu_show_once_timeout}" ]; then
    set timeout_style=menu
    set timeout="${menu_show_once_timeout}"
    unset menu_show_once_timeout
    save_env menu_show_once_timeout
  fi
fi
EOF
EOF_GRUB_ONCE
    chmod 0755 /etc/grub.d/10_reset_boot_success /etc/grub.d/12_menu_auto_hide /etc/grub.d/14_menu_show_once

    # Mark a normal graphical boot successful after two minutes. This is a
    # system timer rather than a performance service and does not run in the
    # offline-update boot target.
    cat > /etc/systemd/system/grub-boot-success.service <<'EOF_GRUB_SUCCESS_SERVICE'
[Unit]
Description=Mark GRUB boot as successful
ConditionPathExists=/boot/grub/grubenv

[Service]
Type=oneshot
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_success=1 boot_indeterminate=0
EOF_GRUB_SUCCESS_SERVICE

    cat > /etc/systemd/system/grub-boot-success.timer <<'EOF_GRUB_SUCCESS_TIMER'
[Unit]
Description=Mark successful graphical boot for GRUB auto-hide
After=graphical.target

[Timer]
OnActiveSec=2min
AccuracySec=15s
Unit=grub-boot-success.service

[Install]
WantedBy=graphical.target
EOF_GRUB_SUCCESS_TIMER

    # During PackageKit's special offline-update boot, mark the boot as
    # indeterminate so the next normal boot does not expose GRUB as if a crash
    # had occurred.
    cat > /etc/systemd/system/grub-boot-indeterminate.service <<'EOF_GRUB_INDET'
[Unit]
Description=Mark GRUB boot indeterminate during offline system update
DefaultDependencies=no
Before=packagekit-offline-update.service
ConditionPathExists=/boot/grub/grubenv

[Service]
Type=oneshot
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_indeterminate=1

[Install]
WantedBy=system-update.target
EOF_GRUB_INDET

    systemctl enable grub-boot-success.timer >/dev/null 2>&1 || true
    systemctl enable grub-boot-indeterminate.service >/dev/null 2>&1 || true
}

install_grub_silent_output_hook() {
    # "Loading Linux..." and "Loading initial ramdisk..." are generated text,
    # not messages requiring a custom-compiled GRUB. Sanitize the generated cfg
    # now and after future grub/linux transactions.
    install -d /usr/local/sbin /etc/pacman.d/hooks
    cat > /usr/local/sbin/fedora-arch-grub-silent <<'EOF_GRUB_SILENT'
#!/usr/bin/env bash
set -euo pipefail
cfg=/boot/grub/grub.cfg
[[ -f "$cfg" ]] || exit 0
sed -i -E \
  "/^[[:space:]]*echo[[:space:]]+['\"]?Loading (Linux|initial ramdisk)/d" \
  "$cfg"
EOF_GRUB_SILENT
    chmod 0755 /usr/local/sbin/fedora-arch-grub-silent

    cat > /usr/local/sbin/grub-mkconfig <<'EOF_GRUB_MKCONFIG_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/grub-mkconfig "$@"
/usr/local/sbin/fedora-arch-grub-silent
EOF_GRUB_MKCONFIG_WRAPPER
    chmod 0755 /usr/local/sbin/grub-mkconfig

    cat > /etc/pacman.d/hooks/99-fedora-arch-grub-silent.hook <<'EOF_GRUB_SILENT_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = grub
Target = linux

[Action]
Description = Removing GRUB Loading Linux/initramdisk messages...
When = PostTransaction
Exec = /usr/local/sbin/fedora-arch-grub-silent
EOF_GRUB_SILENT_HOOK
}

install_grub() {
    pacman_install grub efibootmgr
    backup_once /etc/default/grub
    local extra
    extra="$(kernel_extra_args_string)"

    cat > /etc/default/grub <<EOF_GRUB_DEFAULT
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Arch Linux"
GRUB_CMDLINE_LINUX_DEFAULT="$extra"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
EOF_GRUB_DEFAULT

    install_fedora_style_grub_autohide
    install_grub_silent_output_hook

    grub-install \
        --target=x86_64-efi \
        --efi-directory="$EFI_MOUNT" \
        --bootloader-id=GRUB \
        --removable \
        --recheck
    /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
    /usr/local/sbin/fedora-arch-grub-silent

    grub-editenv /boot/grub/grubenv set menu_auto_hide=1 boot_success=1 boot_indeterminate=0 saved_entry=0
}

install_systemd_boot() {
    bootctl --esp-path=/boot install
    install -d /boot/loader/entries
    cat > /boot/loader/loader.conf <<'EOF_LOADER'
default arch.conf
timeout 4
console-mode auto
editor yes
EOF_LOADER

    local cmdline micro=""
    cmdline="$(kernel_cmdline)"
    micro="$(booster_microcode_entry || true)"
    {
        echo 'title   Arch Linux'
        echo 'linux   /vmlinuz-linux'
        [[ -n "$micro" ]] && echo "initrd  $micro"
        echo 'initrd  /initramfs-linux.img'
        echo "options $cmdline"
    } > /boot/loader/entries/arch.conf
}

install_limine() {
    pacman_install limine
    install -d /boot/EFI/BOOT
    install -m0644 /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

    local cmdline micro=""
    cmdline="$(kernel_cmdline)"
    micro="$(booster_microcode_entry || true)"
    {
        echo 'timeout: 4'
        echo
        echo '/Arch Linux'
        echo '    protocol: linux'
        echo '    path: boot():/vmlinuz-linux'
        echo "    cmdline: $cmdline"
        [[ -n "$micro" ]] && echo "    module_path: boot():$micro"
        echo '    module_path: boot():/initramfs-linux.img'
    } > /boot/EFI/BOOT/limine.conf

    install -d /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/99-limine-fallback.hook <<'EOF_HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Updating fallback Limine EFI loader...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
EOF_HOOK
}

install_bootloader() {
    info "Installing UEFI boot loader: $BOOTLOADER"
    case "$BOOTLOADER" in
        grub) install_grub ;;
        systemd-boot) install_systemd_boot ;;
        limine) install_limine ;;
    esac
}

post_chroot_install() {
    require_root
    require_installed_arch_chroot
    require_uefi
    require_boot_esp
    collect_answers

    exec > >(tee -a "$LOG_FILE") 2>&1

    prepare_pacman_disk_cache_for_install

    # Mask noisy/conflicting package hooks BEFORE the first upgrade transaction.
    prepare_chroot_transaction_hooks
    trap 'restore_runtime_packagekit_hook >/dev/null 2>&1 || true' EXIT

    configure_repositories_first
    configure_base_identity
    install_kernel_and_boot_core

    case "$DESKTOP" in
        kde) install_kde ;;
        gnome) install_gnome ;;
        *) fatal "Unknown desktop: $DESKTOP" ;;
    esac

    configure_wayland_only
    configure_fish_default
    install_cachy_kernel_builder
    install_nvidia_580
    configure_services
    configure_pastelitto_tuned
    install_wallpapers_and_branding
    install_fedora_kde_assets
    configure_discover_system_management
    if [[ "$DESKTOP" == kde && -x /usr/local/libexec/fedora-arch-plasma-admin ]]; then
        # Immediate-account installs already passed the OOBE hook. Re-run the
        # idempotent helper after every optional marker/asset has been staged.
        /usr/local/libexec/fedora-arch-plasma-admin
    fi

    # Kernel/root-FS choices must be settled before initramfs and bootloader.
    configure_preboot_tuning
    configure_plymouth
    configure_initramfs
    install_bootloader
    compile_cachy_kernel_now

    # Aggressive desktop/runtime tuning is intentionally last.
    configure_late_performance_tuning

    # PackageKit's real refresh hook is wanted after first boot; it was masked
    # only to avoid D-Bus errors while running inside arch-chroot.
    restore_runtime_packagekit_hook
    trap - EXIT

    echo
    echo '================================================================'
    echo 'DONE'
    echo '================================================================'
    if [[ "$ACCOUNT_SETUP" == now ]]; then
        printf 'User/hostname:      %s@%s\n' "$INSTALL_USERNAME" "$INSTALL_HOSTNAME"
    else
        echo 'User/hostname:      configured on first boot (OOBE)'
    fi
    printf 'Locale/time zone:   en_US.UTF-8, US keyboard, %s\n' "$INSTALL_TIMEZONE"
    printf 'Desktop:           %s\n' "$DESKTOP"
    printf 'KDE edition:       %s\n' "$KDE_EDITION"
    printf 'Fedora app bundle: %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo enabled || echo disabled)"
    if [[ "$DESKTOP" == kde ]]; then
        printf 'LibreOffice Fresh: %s\n' "$([[ $INSTALL_LIBREOFFICE -eq 1 ]] && echo installed || echo disabled)"
        printf 'Gaming apps:       Lutris=%s Steam=%s Faugus=%s ProtonUp-Qt=%s\n' \
            "$([[ $INSTALL_LUTRIS -eq 1 ]] && echo on || echo off)" \
            "$([[ $INSTALL_STEAM -eq 1 ]] && echo on || echo off)" \
            "$([[ $INSTALL_FAUGUS -eq 1 ]] && echo on || echo off)" \
            "$([[ $INSTALL_PROTONUP_QT -eq 1 ]] && echo on || echo off)"
        printf 'Faugus import:     %s\n' "$([[ $IMPORT_FAUGUS_SETTINGS -eq 1 ]] && echo enabled || echo disabled)"
        printf 'virt-manager:      %s\n' "$([[ $INSTALL_VIRT_MANAGER -eq 1 ]] && echo 'full stack enabled' || echo disabled)"
    fi
    printf 'Discover updates:  %s\n' "$([[ $ENABLE_DISCOVER_SYSTEM -eq 1 ]] && echo 'daily + reboot-time + safe preflight' || echo disabled)"
    printf 'Discover spoof:    %s\n' "$([[ $SPOOF_DISCOVER_WARNING -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Pastelitto KDE:     %s\n' "$([[ $APPLY_PASTELITTO_KDE -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Fish default:       %s\n' "$([[ $INSTALL_FISH -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Fish dracut-all:    %s\n' "$([[ $INSTALL_FISH -eq 1 && $INITRAMFS == dracut ]] && echo installed || echo disabled)"
    printf 'Initramfs:         %s\n' "$INITRAMFS"
    printf 'Boot loader:       %s\n' "$BOOTLOADER"
    printf 'NVIDIA modprobe:   %s\n' "$([[ $APPLY_NVIDIA_PERFORMANCE -eq 1 ]] && echo installed || echo disabled)"
    printf 'Intel i915 policy: %s\n' "$([[ $APPLY_INTEL_IGPU_PERFORMANCE -eq 1 ]] && echo installed || echo disabled)"
    printf 'TuneD/PPD:         %s\n' "$([[ $ENABLE_PASTELITTO_TUNED -eq 1 ]] && echo 'Pastelitto profiles enabled' || echo disabled)"
    printf 'Cachy builder:     %s\n' "$([[ $INSTALL_CACHY_BUILDER -eq 1 ]] && echo "installed (compiled-now=$COMPILE_CACHY_NOW, default=$MAKE_CACHY_DEFAULT)" || echo disabled)"
    printf 'ALHP:              %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo disabled)"
    printf 'CachyOS repo:      %s\n' "$([[ $ENABLE_CACHYOS -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Chaotic-AUR:       %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo enabled || echo disabled)"
    printf 'zswap:             enabled (lz4, 30%% pool, swappiness=100; zram off)\n'
    printf 'Performance:       %s\n' "$PERF_PROFILE"
    printf 'Pacman RAM cache:  %s\n' "$([[ $PACMAN_RAM_CACHE -eq 1 ]] && echo 'enabled (25% cap, volatile)' || echo disabled)"
    printf 'Wayland-only:      %s\n' "$([[ $WAYLAND_ONLY -eq 1 ]] && echo 'enabled (native toolkits + no X11 login)' || echo disabled)"
    printf 'Intel IOMMU/KVM:   %s\n' "$([[ $ENABLE_INTEL_KVM_TUNING -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Extreme ext4:      %s\n' "$([[ $EXT4_EXTREME -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Logging profile:   %s\n' "$LOGGING_PROFILE"
    printf 'Kernel args:        %s\n' "$(kernel_extra_args_string)"
    echo
    echo "Installer log: $LOG_FILE"
    echo "Exit the chroot, unmount /mnt, and reboot when ready."
}

main() {
    post_chroot_install
}

main "$@"
