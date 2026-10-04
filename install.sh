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

Normal pacman package installation is INTERACTIVE. No --noconfirm is
used for desktop/program transactions, so pacman can ask about groups,
providers and package choices.
BANNER

    while true; do
        read -r -p "Username: " USERNAME
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
        echo "Use lowercase letters/numbers/_/- only."
    done

    read_secret_twice "Password for $USERNAME"
    USER_PASSWORD="$REPLY"

    if ask_yes_no "Use the same password for root?" y; then
        ROOT_PASSWORD="$USER_PASSWORD"
    else
        read_secret_twice "Root password"
        ROOT_PASSWORD="$REPLY"
    fi

    read -r -p "Hostname [cheesecake]: " HOSTNAME
    HOSTNAME="${HOSTNAME:-cheesecake}"

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

    if ask_yes_no "Install NVIDIA 580xx legacy DKMS packages?" n; then
        INSTALL_NVIDIA_580=1
    else
        INSTALL_NVIDIA_580=0
    fi

    echo
    echo "---------------- Configuration summary ----------------"
    printf 'Root filesystem:    %s\n' "$(findmnt -n -o SOURCE /)"
    printf 'EFI /boot:          %s (%s)\n' "$(findmnt -n -o SOURCE /boot)" "$(findmnt -n -o FSTYPE /boot)"
    printf 'Desktop:            %s\n' "$DESKTOP"
    printf 'Fedora app bundle:  %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo yes || echo no)"
    printf 'ALHP:               %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo no)"
    printf 'Chaotic-AUR:        %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo yes || echo no)"
    printf 'Initramfs:          %s\n' "$INITRAMFS"
    printf 'Boot loader:        %s\n' "$BOOTLOADER"
    printf 'NVIDIA 580xx:       %s\n' "$([[ $INSTALL_NVIDIA_580 -eq 1 ]] && echo yes || echo no)"
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
    configure_chaotic

    info "Synchronizing and upgrading with the selected repository order"
    pacman -Syyu
}

configure_identity() {
    info "Configuring locale, timezone, hostname and users"
    ln -sf /usr/share/zoneinfo/America/Mexico_City /etc/localtime
    hwclock --systohc || true

    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    echo 'KEYMAP=us' > /etc/vconsole.conf

    echo "$HOSTNAME" > /etc/hostname
    cat > /etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF_HOSTS

    echo "root:$ROOT_PASSWORD" | chpasswd
    if ! id "$USERNAME" >/dev/null 2>&1; then
        useradd -m -U -G wheel -s /bin/bash "$USERNAME"
    fi
    echo "$USERNAME:$USER_PASSWORD" | chpasswd

    install -d -m 0750 /etc/sudoers.d
    cat > /etc/sudoers.d/10-wheel <<'EOF_SUDO'
%wheel ALL=(ALL:ALL) ALL
EOF_SUDO
    chmod 0440 /etc/sudoers.d/10-wheel
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
    # 'plasma' is an Arch package group. Because this is interactive, pacman can
    # show the group selection instead of silently accepting it.
    pacman -S --needed \
        plasma plasma-login-manager \
        networkmanager plasma-nm \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        bluez bluez-utils cups \
        xdg-desktop-portal-kde \
        breeze breeze-icons noto-fonts noto-fonts-emoji \
        packagekit packagekit-qt6 flatpak \
        polkit-kde-agent

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
            # These are normally AUR/Chaotic packages. They install automatically
            # only if the enabled binary repos currently provide them.
            localsend osu-lazer scx-manager
            # Fedora's gnome-abrt has no direct Arch equivalent; DrKonqi is the
            # native Plasma crash/problem reporter.
            drkonqi
        )
        install_available_interactive "Installing filtered Fedora KDE application bundle" "${fedora_kde_apps[@]}"
    fi

    systemctl enable plasmalogin.service
}

install_gnome() {
    info "Installing GNOME"
    pacman -S --needed \
        gnome gdm gnome-software \
        networkmanager \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        bluez bluez-utils cups \
        xdg-desktop-portal-gnome \
        packagekit flatpak \
        noto-fonts noto-fonts-emoji

    if [[ $FEDORA_DEFAULT_APPS -eq 1 ]]; then
        # The captured machine is Fedora KDE. For GNOME we only carry over the
        # desktop-neutral apps from that machine rather than installing KDE PIM.
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
        nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings
        lib32-nvidia-580xx-utils opencl-nvidia-580xx lib32-opencl-nvidia-580xx
    )
    install_available_interactive "NVIDIA 580xx packages" "${pkgs[@]}"
}

configure_services() {
    systemctl enable NetworkManager.service
    for unit in bluetooth.service cups.service fstrim.timer systemd-oomd.service; do
        systemctl cat "$unit" >/dev/null 2>&1 && systemctl enable "$unit" >/dev/null 2>&1 || true
    done

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

    local home="/home/$USERNAME"
    mkdir -p "$home/.config"
    if [[ -d "$FEDORA_USER_CONFIG_ASSET_DIR" ]]; then
        local f
        for f in kdeglobals kwinrc kcminputrc plasmarc ksplashrc kscreenlockerrc kglobalshortcutsrc plasma-org.kde.plasma.desktop-appletsrc; do
            [[ -f "$FEDORA_USER_CONFIG_ASSET_DIR/$f" ]] && \
                cp -a "$FEDORA_USER_CONFIG_ASSET_DIR/$f" "$home/.config/$f"
        done
    fi

    chown -R "$USERNAME:$USERNAME" "$home/.config"
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
            install -d /etc/dracut.conf.d
            cat > /etc/dracut.conf.d/10-fedora-arch.conf <<'EOF_DRACUT'
add_dracutmodules+=" plymouth "
EOF_DRACUT
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
    local uuid source
    uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
    if [[ -z "$uuid" ]]; then
        source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
        [[ -n "$source" ]] && uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
    fi
    [[ -n "$uuid" ]] || fatal "Could not determine the UUID of the root filesystem."
    printf 'root=UUID=%s rw quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0' "$uuid"
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
install_grub() {
    pacman -S --needed grub
    backup_once /etc/default/grub
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"|' /etc/default/grub
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"' >> /etc/default/grub
    fi

    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot \
        --bootloader-id=GRUB \
        --removable \
        --recheck
    grub-mkconfig -o /boot/grub/grub.cfg
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
    configure_identity
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
    configure_plymouth
    configure_initramfs
    install_bootloader

    echo
    echo '================================================================'
    echo 'DONE'
    echo '================================================================'
    printf 'User:              %s\n' "$USERNAME"
    printf 'Desktop:           %s\n' "$DESKTOP"
    printf 'Fedora app bundle: %s\n' "$([[ $FEDORA_DEFAULT_APPS -eq 1 ]] && echo enabled || echo disabled)"
    printf 'Initramfs:         %s\n' "$INITRAMFS"
    printf 'Boot loader:       %s\n' "$BOOTLOADER"
    printf 'ALHP:              %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "$ALHP_LEVEL" || echo disabled)"
    printf 'Chaotic-AUR:       %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo enabled || echo disabled)"
    echo
    echo "Installer log: $LOG_FILE"
    echo "Exit the chroot, unmount /mnt, and reboot when ready."
}

main() {
    post_chroot_install
}

main "$@"
