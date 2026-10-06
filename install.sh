#!/usr/bin/env bash
# Fedora-like Arch post-install configurator
# UEFI only. Run this AFTER entering the installed system with: arch-chroot /mnt
# Assumptions: base Arch is installed, networking works, and the EFI System
# Partition is already mounted directly at /boot.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE=/var/log/fedora-arch-installer.log

WALLPAPER_ASSET_DIR="$SCRIPT_DIR/assets/wallpapers"
FEDORA_BACKGROUND_ASSET_DIR="$SCRIPT_DIR/assets/backgrounds"
FEDORA_LOOKANDFEEL_ASSET_DIR="$SCRIPT_DIR/assets/fedora-look-and-feel"
FEDORA_BRANDING_ASSET_DIR="$SCRIPT_DIR/assets/fedora-branding"
FEDORA_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/fedora-config"
FEDORA_USER_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/fedora-user-config"

# Built dynamically from the selected performance/debloat options. Root= and
# BOOT_IMAGE are intentionally never stored here; bootloaders add their own
# root device information.
KERNEL_EXTRA_ARGS=()

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
    mountpoint -q /boot || fatal "/boot is not a mounted filesystem. Mount your EFI System Partition at /boot first."

    local fstype
    fstype="$(findmnt -n -o FSTYPE /boot 2>/dev/null || true)"
    case "$fstype" in
        vfat|fat|msdos) ;;
        *) fatal "/boot is mounted as '$fstype', not FAT/VFAT. This installer expects the EFI System Partition mounted directly at /boot." ;;
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
  1) Partition/install Arch yourself
  2) Mount the EFI System Partition directly at /boot
  3) arch-chroot /mnt
  4) clone this repo and run ./install.sh

Like Fedora 44+, user/password/hostname setup is deferred to the desktop's
first-boot OOBE (Plasma Setup on KDE, GNOME Initial Setup on GNOME).

Normal pacman package installation is INTERACTIVE. No --noconfirm is
used for desktop/program transactions, so pacman can ask about groups,
providers and package choices.
BANNER

    ask_choice "Desktop environment" 1 \
        "KDE Plasma" \
        "GNOME"
    case "$REPLY" in
        1) DESKTOP=kde ;;
        2) DESKTOP=gnome ;;
    esac

    if ask_yes_no "Install the Fedora default/captured application bundle?" y; then
        FEDORA_DEFAULT_APPS=1
    else
        FEDORA_DEFAULT_APPS=0
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

    if ask_yes_no "Install NVIDIA 580xx legacy DKMS packages (Pascal/GTX 1050)?" n; then
        INSTALL_NVIDIA_580=1
    else
        INSTALL_NVIDIA_580=0
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
    local f2fs_default=n
    [[ "$root_fstype" == f2fs ]] && f2fs_default=y
    if ask_yes_no "Optimize F2FS entries in /etc/fstab for performance + reduced writes?" "$f2fs_default"; then
        OPTIMIZE_F2FS=1
        if ask_yes_no "If F2FS compression feature exists, automatically compress new files (compress_extension=*)?" y; then
            F2FS_COMPRESS_ALL=1
        else
            F2FS_COMPRESS_ALL=0
        fi
    else
        OPTIMIZE_F2FS=0
        F2FS_COMPRESS_ALL=0
    fi

    echo
    echo "---------------- Configuration summary ----------------"
    printf 'Root filesystem:    %s (%s)\n' "$(findmnt -n -o SOURCE /)" "$root_fstype"
    printf 'EFI /boot:          %s (%s)\n' "$(findmnt -n -o SOURCE /boot)" "$(findmnt -n -o FSTYPE /boot)"
    printf 'Desktop:            %s\n' "$DESKTOP"
    printf 'Fedora app bundle:  %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo yes || echo no)"
    printf 'ALHP:               %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo no)"
    printf 'CachyOS repo:       %s\n' "$([[ $ENABLE_CACHYOS -eq 1 ]] && echo yes || echo no)"
    printf 'Chaotic-AUR:        %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo yes || echo no)"
    printf 'zswap:              enabled (zstd, 30%% pool)\n'
    printf 'Initramfs:          %s\n' "$INITRAMFS"
    printf 'Boot loader:        %s\n' "$BOOTLOADER"
    printf 'NVIDIA 580xx:       %s\n' "$([[ $INSTALL_NVIDIA_580 -eq 1 ]] && echo yes || echo no)"
    printf 'Performance:        %s\n' "$PERF_PROFILE"
    printf 'Logging profile:    %s\n' "$LOGGING_PROFILE"
    printf 'Mitigations off:    %s\n' "$([[ $DISABLE_MITIGATIONS -eq 1 ]] && echo yes || echo no)"
    printf 'F2FS optimization:  %s\n' "$([[ $OPTIMIZE_F2FS -eq 1 ]] && echo yes || echo no)"
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

bootstrap_chaotic_trust() {
    info "Bootstrapping Chaotic-AUR signing key and mirrorlist"
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || \
        pacman-key --recv-key 3056513887B78AEB --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman -U --needed \
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

    pacman --config "$tmpconf" -Syy
    pacman --config "$tmpconf" -S --needed alhp-keyring alhp-mirrorlist
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
    pacman --config "$tmpconf" -Syy
    pacman --config "$tmpconf" -S --needed cachyos-keyring cachyos-mirrorlist
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
    pacman -Syyu
}

configure_base_identity() {
    info "Preparing base locale for first-boot OOBE"
    # Plasma Setup / GNOME Initial Setup will handle hostname, user account,
    # password, date/time and the final locale choices on first boot.
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    [[ -e /etc/locale.conf ]] || echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    [[ -e /etc/vconsole.conf ]] || echo 'KEYMAP=us' > /etc/vconsole.conf
}

# Install only package names that currently exist in enabled pacman repositories.
# The actual pacman transaction remains interactive: NO --noconfirm.
install_available_interactive() {
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
        pacman -S --needed "${available[@]}"
    fi
    if ((${#missing[@]})); then
        warn "Not present in enabled binary repos, so skipped: ${missing[*]}"
        warn "If these are AUR-only, enable Chaotic-AUR or install them manually later."
    fi
}

install_aur_package_temp_builder() {
    local pkg="$1" url="https://aur.archlinux.org/${1}.git"
    local builder="fedoraarch-build"
    info "Building AUR package needed for first boot: $pkg"
    pacman -S --needed base-devel git sudo

    userdel -r "$builder" >/dev/null 2>&1 || true
    useradd -m -s /bin/bash "$builder"
    install -d -m0750 /etc/sudoers.d
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$builder" > /etc/sudoers.d/99-fedoraarch-build
    chmod 0440 /etc/sudoers.d/99-fedoraarch-build

    local rc=0
    su - "$builder" -c "git clone '$url' ~/pkg && cd ~/pkg && makepkg -si --needed" || rc=$?

    rm -f /etc/sudoers.d/99-fedoraarch-build
    userdel -r "$builder" >/dev/null 2>&1 || true
    (( rc == 0 )) || fatal "Failed to build/install $pkg from AUR."
}

install_plasma_oobe() {
    info "Installing KDE Plasma Setup first-boot OOBE"
    if pacman -Si plasma-setup >/dev/null 2>&1; then
        pacman -S --needed plasma-setup
    elif pacman -Si plasma-setup-git >/dev/null 2>&1; then
        pacman -S --needed plasma-setup-git
    else
        install_aur_package_temp_builder plasma-setup-git
    fi
    systemctl enable plasma-setup.service
}

install_kernel_and_boot_core() {
    info "Installing kernel + chosen initramfs provider"
    local provider="$INITRAMFS"
    pacman -S --needed "$provider" linux linux-headers linux-firmware sudo git networkmanager plymouth

    case "$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2}')" in
        GenuineIntel) pacman -S --needed intel-ucode ;;
        AuthenticAMD) pacman -S --needed amd-ucode ;;
    esac
}

install_kde() {
    info "Installing KDE Plasma"
    local -a plasma_pkgs=() desktop_pkgs=(
        plasma-login-manager
        networkmanager plasma-nm
        pipewire pipewire-alsa pipewire-pulse wireplumber
        xdg-desktop-portal-kde
        breeze breeze-icons noto-fonts noto-fonts-emoji
        packagekit packagekit-qt6 flatpak
        appstream appstream-qt archlinux-appstream-data
        polkit-kde-agent
    )

    # The Arch plasma group includes plasma-bigscreen. This desktop build does
    # not use the TV/big-screen shell/input handler, so expand the group and
    # deliberately exclude that package.
    mapfile -t plasma_pkgs < <(pacman -Sgq plasma | sort -u | grep -vx 'plasma-bigscreen')
    ((${#plasma_pkgs[@]})) || fatal "Could not resolve the Arch plasma package group."

    (( KEEP_BLUETOOTH )) && desktop_pkgs+=(bluez bluez-utils)
    (( KEEP_CUPS )) && desktop_pkgs+=(cups)
    pacman -S --needed "${plasma_pkgs[@]}" "${desktop_pkgs[@]}"

    # Clean up installs made by older revisions of this project.
    if pacman -Q plasma-bigscreen >/dev/null 2>&1; then
        info "Removing plasma-bigscreen (not used by this desktop profile)"
        pacman -Rns plasma-bigscreen
    fi

    # User-requested minimal KDE application set.
    # Arch's kate package also provides the KWrite executable/desktop entry.
    pacman -S --needed \
        dolphin konsole kate discover gwenview libreoffice-fresh \
        plasma-systemmonitor ark kcalc spectacle elisa

    if [[ $FEDORA_DEFAULT_APPS -eq 1 ]]; then
        local fedora_kde_apps=(
            akonadi-import-wizard akregator
            dragon filelight firefox firewall-config gimp grantlee-editor
            kaddressbook kamoso kcharselect kdebugsettings kdeconnect partitionmanager
            kfind khelpcenter kinfocenter kjournald kleopatra kmahjongg kmail
            kmenuedit kmines kmouth kolourpaint kontact korganizer kpat krdc krfb
            kwalletmanager neochat obs-studio okular pim-data-exporter pim-sieve-editor
            plasma-welcome qrca skanpage
            mediawriter
            localsend osu-lazer scx-manager
            drkonqi
        )
        install_available_interactive "Installing filtered Fedora KDE application bundle" "${fedora_kde_apps[@]}"
    fi

    install_plasma_oobe
    systemctl enable plasmalogin.service
}

install_gnome() {
    info "Installing GNOME"
    local desktop_pkgs=(
        gnome gdm gnome-software gnome-initial-setup
        networkmanager
        pipewire pipewire-alsa pipewire-pulse wireplumber
        xdg-desktop-portal-gnome
        packagekit flatpak
        noto-fonts noto-fonts-emoji
    )
    (( KEEP_BLUETOOTH )) && desktop_pkgs+=(bluez bluez-utils)
    (( KEEP_CUPS )) && desktop_pkgs+=(cups)
    pacman -S --needed "${desktop_pkgs[@]}"

    if [[ $FEDORA_DEFAULT_APPS -eq 1 ]]; then
        local fedora_generic_apps=(
            firefox firewall-config gimp libreoffice-fresh mediawriter obs-studio
            localsend osu-lazer scx-manager
        )
        install_available_interactive "Installing captured Fedora desktop-neutral apps" "${fedora_generic_apps[@]}"
    fi

    systemctl enable gdm.service
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
    install_available_interactive "NVIDIA 580xx packages" "${pkgs[@]}"
}

configure_services() {
    systemctl enable NetworkManager.service

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

    if (( PERF_IO )); then
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
    if systemctl cat packagekit-offline-update.service >/dev/null 2>&1; then
        install -d /etc/systemd/system/packagekit-offline-update.service.d
        cat > /etc/systemd/system/packagekit-offline-update.service.d/10-network-online.conf <<'EOF_PK_OFFLINE'
[Unit]
Wants=network-online.target
After=NetworkManager.service NetworkManager-wait-online.service network-online.target

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
    info "Installing captured Fedora KDE appearance/configuration"

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

    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" ]]; then
        install -Dm0644 "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" /etc/xdg/discoverrc
    else
        install -d /etc/xdg
        cat > /etc/xdg/discoverrc <<'EOF_DISCOVER'
[Software]
UseOfflineUpdates=true
EOF_DISCOVER
    fi

    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" ]]; then
        install -d /etc/plasmalogin.conf.d
        install -m0644 "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" \
            /etc/plasmalogin.conf.d/10-fedora.conf
    fi

    # No regular user exists yet. Seed /etc/skel so the account created by
    # Plasma Setup receives the captured Fedora Plasma configuration.
    mkdir -p /etc/skel/.config
    if [[ -d "$FEDORA_USER_CONFIG_ASSET_DIR" ]]; then
        local f
        for f in kdeglobals kwinrc kcminputrc plasmarc ksplashrc kscreenlockerrc kglobalshortcutsrc plasma-org.kde.plasma.desktop-appletsrc; do
            [[ -f "$FEDORA_USER_CONFIG_ASSET_DIR/$f" ]] && \
                cp -a "$FEDORA_USER_CONFIG_ASSET_DIR/$f" "/etc/skel/.config/$f"
        done
    fi
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

    # Disk swap is backed by an aggressive-but-bounded zswap cache. No zram.
    add_kernel_arg zswap.enabled=1
    add_kernel_arg zswap.compressor=zstd
    add_kernel_arg zswap.zpool=zsmalloc
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

    # Ivy Bridge and newer Intel systems can use intel_pstate.  This only
    # selects the scaling driver; there is NO kernel/GRUB option that forces
    # Turbo Boost on. Turbo is enabled at runtime by ~/performance.sh via
    # intel_pstate/no_turbo=0 and x86_energy_perf_policy --turbo-enable 1.
    if (( PERF_CPU )) && grep -qm1 'vendor_id.*GenuineIntel' /proc/cpuinfo; then
        add_kernel_arg intel_pstate=active
    fi

    if (( DISABLE_MITIGATIONS )); then
        # Exact mitigation-related set currently used on the user's Fedora box.
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

    # These module blacklists work with every initramfs choice; the rd.* command
    # line form above additionally handles dracut early userspace.
    install -d /etc/modprobe.d
    cat > /etc/modprobe.d/blacklist-nouveau-nova.conf <<'EOF_BLACKLIST_GPU'
blacklist nouveau
blacklist nova_core
EOF_BLACKLIST_GPU

    if (( DISABLE_WATCHDOG )); then
        cat > /etc/modprobe.d/blacklist-intel-watchdog.conf <<'EOF_BLACKLIST_WDT'
blacklist iTCO_wdt
blacklist iTCO_vendor_support
EOF_BLACKLIST_WDT
    fi
}

configure_logging() {
    install -d /etc/systemd/journald.conf.d
    case "$LOGGING_PROFILE" in
        1)
            rm -f /etc/systemd/journald.conf.d/99-fedora-arch-debloat.conf
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
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
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

    if (( DISABLE_SYSLOG )); then
        local unit
        for unit in rsyslog.service syslog-ng.service syslog-ng@default.service; do
            systemctl mask "$unit" >/dev/null 2>&1 || true
        done
    fi

    if (( DISABLE_AUDIT )); then
        systemctl mask auditd.service >/dev/null 2>&1 || true
    fi

    if (( DISABLE_PSTORE )); then
        systemctl mask systemd-pstore.service >/dev/null 2>&1 || true
    fi
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
        pacman -S --needed x86_energy_perf_policy
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
}

configure_io_performance() {
    (( PERF_IO )) || return 0
    info "Installing ArchWiki-style I/O scheduler rules"
    install -d /etc/udev/rules.d
    cat > /etc/udev/rules.d/60-ioschedulers.rules <<'EOF_IOSCHED'
# ArchWiki Improving performance example.
# Rotational HDD
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
# SATA/SAS SSD and eMMC
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="bfq"
# NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="none"
EOF_IOSCHED
    systemctl enable fstrim.timer >/dev/null 2>&1 || true
}

configure_zswap() {
    info "Configuring zswap over disk swap (zram disabled)"
    install -d /etc/sysctl.d
    rm -f /etc/systemd/zram-generator.conf
    rm -f /etc/systemd/zram-generator.conf.d/99-fedora-arch.conf 2>/dev/null || true

    cat > /etc/sysctl.d/98-fedora-arch-zswap.conf <<'EOF_ZSWAP_SYSCTL'
# zswap keeps hot swap pages compressed in RAM and evicts colder pages to the
# real swap partition. More aggressive than the kernel defaults, but bounded.
vm.swappiness = 100
vm.page-cluster = 0
EOF_ZSWAP_SYSCTL
}

configure_vm_sysctl() {
    (( PERF_SYSCTL )) || return 0
    info "Installing sysctl.d desktop-performance tuning for 16 GiB RAM"
    install -d /etc/sysctl.d
    cat > /etc/sysctl.d/99-fedora-arch-performance.conf <<'EOF_SYSCTL'
# ArchWiki-inspired desktop tuning. 16 GiB RAM target.
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 3
vm.dirty_background_ratio = 1
EOF_SYSCTL
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
        warn "F2FS optimization requested, but /etc/fstab currently has no F2FS entries. Skipping."
        return 0
    fi

    info "Optimizing F2FS fstab entries"
    pacman -S --needed f2fs-tools
    backup_once /etc/fstab

    local root_extra="noatime,lazytime,atgc,gc_merge"
    local other_extra="noatime,lazytime,atgc,gc_merge"
    if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" == f2fs ]]; then
        # ArchWiki documents rw as a workaround for root remount failures with atgc.
        add_kernel_arg rw
        if f2fs_root_has_compression; then
            root_extra+=",compress_algorithm=zstd:6,compress_chksum"
            (( F2FS_COMPRESS_ALL )) && root_extra+=",compress_extension=*"
        else
            warn "Root F2FS was not formatted with the compression feature; leaving compression mount options out."
        fi
    fi

    local tmp
    tmp="$(mktemp)"
    awk -v root_extra="$root_extra" -v other_extra="$other_extra" '
        BEGIN { OFS="\t" }
        /^[[:space:]]*#/ || NF < 4 { print; next }
        $3 == "f2fs" {
            n=split($4,a,","); out=""
            for(i=1;i<=n;i++) {
                if(a[i] ~ /^(atime|relatime|strictatime|noatime|lazytime|nolazytime|atgc|noatgc|gc_merge|nogc_merge|compress_chksum)$/) continue
                if(a[i] ~ /^compress_algorithm=/) continue
                if(a[i] ~ /^compress_extension=/) continue
                if(a[i] == "defaults") continue
                out = out (out ? "," : "") a[i]
            }
            add = ($2 == "/" ? root_extra : other_extra)
            $4 = (out ? out "," : "") add
        }
        { print }
    ' /etc/fstab > "$tmp"
    install -m0644 "$tmp" /etc/fstab
    rm -f "$tmp"
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
    (( INSTALL_NVIDIA_580 )) || return 0
    command -v modinfo >/dev/null 2>&1 || return 0
    if ! modinfo nvidia >/dev/null 2>&1; then
        warn "NVIDIA module is not available yet; not writing performance module parameters."
        return 0
    fi

    local wanted=(
        NVreg_UsePageAttributeTable=1
        NVreg_EnablePCIeGen3=1
        NVreg_EnableMSI=1
        NVreg_InitializeSystemMemoryAllocations=0
        NVreg_EnableStreamMemOPs=1
        NVreg_DynamicPowerManagement=0x00
    )
    local supported=() kv key params
    params="$(modinfo -p nvidia | cut -d: -f1)"
    for kv in "${wanted[@]}"; do
        key="${kv%%=*}"
        if grep -qxF "$key" <<<"$params"; then
            supported+=("$kv")
        else
            warn "NVIDIA 580xx does not expose $key on this build; skipping it to avoid a module-load failure."
        fi
    done

    if ((${#supported[@]})); then
        printf 'options nvidia' > /etc/modprobe.d/nvidia-performance.conf
        printf ' %s' "${supported[@]}" >> /etc/modprobe.d/nvidia-performance.conf
        printf '\n' >> /etc/modprobe.d/nvidia-performance.conf
    fi
}

configure_extreme_debloat() {
    info "Applying selected performance/debloat configuration"
    configure_kernel_tuning_args
    configure_logging
    configure_coredumps
    configure_cpu_performance
    configure_io_performance
    configure_zswap
    configure_vm_sysctl
    configure_f2fs_fstab
    configure_baloo
    configure_nvidia_performance
}

# -----------------------------------------------------------------------------
# Plymouth + initramfs
# -----------------------------------------------------------------------------
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
            cat > /etc/dracut.conf.d/10-fedora-arch.conf <<'EOF_DRACUT'
add_dracutmodules+=" plymouth "
EOF_DRACUT

            # ArchWiki's dracut setup: stop mkinitcpio's package hooks from
            # regenerating competing images. Dracut is the sole generator.
            ln -sfn /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
            ln -sfn /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook
            if pacman -Q mkinitcpio >/dev/null 2>&1; then
                pacman -Rns mkinitcpio || warn "mkinitcpio could not be removed; its hooks are masked."
            fi
            if pacman -Q booster >/dev/null 2>&1; then
                pacman -Rns booster || warn "booster could not be removed; dracut remains selected."
            fi

            local kver
            kver="$(kernel_version_for_linux)" || fatal "Could not determine linux kernel version for dracut."
            dracut --force --kver "$kver" /boot/initramfs-linux.img
            dracut --force --no-hostonly --kver "$kver" /boot/initramfs-linux-fallback.img
            ;;
        mkinitcpio)
            # python is normally installed by Plasma/GNOME dependencies, but make
            # sure it exists because the hook editor above uses it.
            pacman -Q python >/dev/null 2>&1 || pacman -S --needed python
            mkinitcpio_add_plymouth
            mkinitcpio -P
            ;;
        booster)
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
# Boot loader — UEFI only, ESP is /boot
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

install_grub() {
    pacman -S --needed grub efibootmgr
    backup_once /etc/default/grub
    local extra
    extra="$(kernel_extra_args_string)"

    # Keep Arch identity while reproducing Fedora's successful-boot auto-hide.
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

    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot \
        --bootloader-id=GRUB \
        --removable \
        --recheck
    grub-mkconfig -o /boot/grub/grub.cfg

    # First normal boot should be hidden; GRUB resets boot_success to 0 while
    # booting and the timer sets it back to 1 after a healthy graphical boot.
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
    pacman -S --needed limine
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

    configure_repositories_first
    configure_base_identity
    install_kernel_and_boot_core

    case "$DESKTOP" in
        kde) install_kde ;;
        gnome) install_gnome ;;
        *) fatal "Unknown desktop: $DESKTOP" ;;
    esac

    install_nvidia_580
    configure_services
    install_wallpapers_and_branding
    install_fedora_kde_assets
    configure_extreme_debloat
    configure_plymouth
    configure_initramfs
    install_bootloader

    echo
    echo '================================================================'
    echo 'DONE'
    echo '================================================================'
    echo 'User/hostname:      configured on first boot (OOBE)'
    printf 'Desktop:           %s\n' "$DESKTOP"
    printf 'Fedora app bundle: %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Initramfs:         %s\n' "$INITRAMFS"
    printf 'Boot loader:       %s\n' "$BOOTLOADER"
    printf 'ALHP:              %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo disabled)"
    printf 'CachyOS repo:      %s\n' "$([[ $ENABLE_CACHYOS -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Chaotic-AUR:       %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo enabled || echo disabled)"
    printf 'zswap:             enabled (zstd, 30%% pool, swappiness=100)\n'
    printf 'Performance:       %s\n' "$PERF_PROFILE"
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
