#!/usr/bin/env bash
# Fedora-like Arch post-install setup
# Run as root from inside the installed Arch system / arch-chroot.
# Replaces the old hard-coded multi-script setup with one interactive installer.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WALLPAPER_ASSET_DIR="$SCRIPT_DIR/assets/wallpapers"
FEDORA_BACKGROUND_ASSET_DIR="$SCRIPT_DIR/assets/backgrounds"
FEDORA_LOOKANDFEEL_ASSET_DIR="$SCRIPT_DIR/assets/fedora-look-and-feel"
FEDORA_BRANDING_ASSET_DIR="$SCRIPT_DIR/assets/fedora-branding"
FEDORA_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/fedora-config"
FEDORA_USER_CONFIG_ASSET_DIR="$SCRIPT_DIR/assets/fedora-user-config"
LOG_FILE="/var/log/fedora-arch-installer.log"

exec > >(tee -a "$LOG_FILE") 2>&1

# ----------------------------- UI helpers -----------------------------
info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer
    local suffix='[y/N]'
    [[ "$default" == "y" ]] && suffix='[Y/n]'
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
    local label="$1" allow_empty="${2:-no}" a b
    while true; do
        read -r -s -p "$label: " a || true; echo
        if [[ -z "$a" && "$allow_empty" == "yes" ]]; then
            REPLY=""
            return 0
        fi
        [[ -n "$a" ]] || { echo "Password cannot be empty."; continue; }
        read -r -s -p "Confirm $label: " b || true; echo
        [[ "$a" == "$b" ]] || { echo "Passwords do not match."; continue; }
        REPLY="$a"
        return 0
    done
}

backup_once() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    [[ -e "${path}.fedora-arch.bak" ]] || cp -a "$path" "${path}.fedora-arch.bak"
}

require_root() {
    [[ $EUID -eq 0 ]] || fatal "Run this installer as root (ideally inside arch-chroot)."
    command -v pacman >/dev/null || fatal "pacman not found. This installer is for Arch Linux."
}

# ----------------------------- questions -----------------------------
collect_answers() {
    clear || true
    cat <<'BANNER'
============================================================
   Arch + ALHP + Fedora KDE experience installer
============================================================
Repositories are configured FIRST, before the normal package install.
BANNER

    while true; do
        read -r -p "Username: " USERNAME
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
        echo "Use a normal Linux username: lowercase letters/numbers/_/- only."
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

    echo
    echo "CPU feature levels reported by glibc:"
    /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -E 'x86-64-v[234]' || true

    if ask_yes_no "Enable ALHP optimized repositories?" y; then
        ENABLE_ALHP=1
        ask_choice "Choose ALHP CPU level" 1 \
            "x86-64-v2 (broad compatibility)" \
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
        "dracut (Fedora-style default for this installer)" \
        "mkinitcpio (Arch default)" \
        "booster (small/fast alternative)"
    case "$REPLY" in
        1) INITRAMFS=dracut ;;
        2) INITRAMFS=mkinitcpio ;;
        3) INITRAMFS=booster ;;
    esac

    if ask_yes_no "Install your NVIDIA 580xx legacy stack (GTX 10xx/Maxwell/Pascal style setup)?" y; then
        INSTALL_NVIDIA_580=1
    else
        INSTALL_NVIDIA_580=0
    fi

    if ask_yes_no "Apply your existing Intel/NVIDIA performance tuning files?" n; then
        APPLY_TUNING=1
    else
        APPLY_TUNING=0
    fi

    echo
    echo "---------------- Summary ----------------"
    printf 'User:             %s\n' "$USERNAME"
    printf 'Hostname:         %s\n' "$HOSTNAME"
    printf 'ALHP:             %s\n' "$([[ $ENABLE_ALHP -eq 1 ]] && echo "yes ($ALHP_LEVEL)" || echo no)"
    printf 'Chaotic-AUR:      %s\n' "$([[ $ENABLE_CHAOTIC -eq 1 ]] && echo yes || echo no)"
    printf 'Initramfs:        %s\n' "$INITRAMFS"
    printf 'NVIDIA 580xx:     %s\n' "$([[ $INSTALL_NVIDIA_580 -eq 1 ]] && echo yes || echo no)"
    printf 'Personal tuning:  %s\n' "$([[ $APPLY_TUNING -eq 1 ]] && echo yes || echo no)"
    printf 'Wallpaper folder: %s\n' "$WALLPAPER_ASSET_DIR"
    echo "-----------------------------------------"
    ask_yes_no "Continue?" y || exit 0
}

# ----------------------------- repository stage -----------------------------
enable_multilib() {
    info "Enabling multilib (repository stage)"
    if grep -q '^#\[multilib\]' /etc/pacman.conf; then
        sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//;}' /etc/pacman.conf
    fi
    grep -q '^\[multilib\]' /etc/pacman.conf || warn "Could not find [multilib] in /etc/pacman.conf"
}

init_arch_keyring() {
    info "Initializing pacman keyring"
    pacman-key --init
    pacman-key --populate archlinux
}

bootstrap_chaotic_trust() {
    info "Installing Chaotic-AUR keyring/mirrorlist bootstrap"
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || \
        pacman-key --recv-key 3056513887B78AEB --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key 3056513887B78AEB
    pacman -U --noconfirm --needed \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
        'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
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

configure_alhp_repos() {
    [[ $ENABLE_ALHP -eq 1 ]] || return 0

    info "Validating CPU support for ALHP $ALHP_LEVEL"
    if ! /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-${ALHP_LEVEL} (supported"; then
        fatal "This CPU does not report x86-64-${ALHP_LEVEL} as supported. Pick a lower ALHP level."
    fi

    # ALHP currently distributes keyring + mirrorlist through AUR.  We use a
    # temporary Chaotic-AUR config only to install these two bootstrap packages.
    # This happens before the normal package installation stage.
    bootstrap_chaotic_trust

    local tmpconf
    tmpconf="$(mktemp)"
    cp /etc/pacman.conf "$tmpconf"
    if ! grep -q '^\[chaotic-aur\]' "$tmpconf"; then
        cat >> "$tmpconf" <<'CHAOTIC'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC
    fi
    pacman --config "$tmpconf" -Syy --noconfirm
    pacman --config "$tmpconf" -S --needed --noconfirm alhp-keyring alhp-mirrorlist
    rm -f "$tmpconf"

    info "Adding ALHP repositories above their Arch counterparts"
    backup_once /etc/pacman.conf
    local cleaned inserted
    cleaned="$(mktemp)"
    inserted="$(mktemp)"
    strip_repo_sections /etc/pacman.conf "$cleaned" '^\[(core|extra|multilib)-x86-64-v[234]\]$'

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

configure_chaotic_repo() {
    local cleaned
    cleaned="$(mktemp)"
    strip_repo_sections /etc/pacman.conf "$cleaned" '^\[chaotic-aur\]$'
    install -m 0644 "$cleaned" /etc/pacman.conf
    rm -f "$cleaned"

    if [[ $ENABLE_CHAOTIC -eq 1 ]]; then
        # May already be present because ALHP bootstrap used it.
        if ! pacman -Q chaotic-keyring >/dev/null 2>&1; then
            bootstrap_chaotic_trust
        fi
        cat >> /etc/pacman.conf <<'EOF_CHAOTIC'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF_CHAOTIC
        ok "Chaotic-AUR enabled"
    elif [[ $ENABLE_ALHP -eq 1 ]]; then
        # ALHP bootstrap no longer needs Chaotic after keyring/mirrorlist are installed.
        pacman -R --noconfirm chaotic-keyring chaotic-mirrorlist >/dev/null 2>&1 || true
        ok "Chaotic-AUR left disabled (bootstrap packages removed)"
    fi
}

configure_repositories_first() {
    info "STAGE 1 — repositories FIRST"
    backup_once /etc/pacman.conf
    enable_multilib
    init_arch_keyring

    # When Chaotic alone is requested, install its bootstrap now.
    if [[ $ENABLE_CHAOTIC -eq 1 && $ENABLE_ALHP -eq 0 ]]; then
        bootstrap_chaotic_trust
    fi

    configure_alhp_repos
    configure_chaotic_repo

    info "Synchronizing databases and upgrading after repository selection"
    pacman -Syyu --noconfirm
    ok "Repository stage complete"
}

# ----------------------------- identity/user -----------------------------
configure_identity_and_user() {
    info "Configuring locale, timezone, hostname and accounts"

    ln -sf /usr/share/zoneinfo/America/Mexico_City /etc/localtime
    hwclock --systohc || true

    if grep -q '^#en_US.UTF-8 UTF-8' /etc/locale.gen; then
        sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    fi
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

    if id "$USERNAME" >/dev/null 2>&1; then
        warn "User $USERNAME already exists; updating password/groups."
    else
        useradd -m -U -s /bin/bash "$USERNAME"
    fi
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    USER_GROUP="$(id -gn "$USERNAME")"

    # Groups may not all exist on every Arch install, so add only existing ones.
    local groups=() g
    for g in wheel audio video optical storage; do
        getent group "$g" >/dev/null && groups+=("$g")
    done
    ((${#groups[@]})) && usermod -aG "$(IFS=,; echo "${groups[*]}")" "$USERNAME"

    ok "Identity and user configured"
}

# ----------------------------- package install -----------------------------
install_repo_packages() {
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
        info "Installing $label (${#available[@]} packages)"
        pacman -S --needed --noconfirm "${available[@]}"
    fi

    if ((${#missing[@]})); then
        warn "$label: package(s) not found in the enabled repositories: ${missing[*]}"
    fi
}

install_packages() {
    info "STAGE 2 — installing Arch packages that reproduce Fedora KDE"

    # Core packages required for a usable Fedora-like Plasma desktop.  These are
    # Arch package names, not Fedora RPM names.
    local core_required=(
        sudo networkmanager
        plasma-desktop plasma-workspace plasma-workspace-wallpapers
        systemsettings plasma-login-manager kwin kscreen kscreenlocker powerdevil
        breeze breeze-gtk breeze-icons breeze-cursors
        noto-fonts noto-fonts-emoji
        discover packagekit packagekit-qt6 flatpak flatpak-kcm
        plymouth plymouth-kcm
        polkit-kde-agent plasma-nm plasma-pa plasma-systemmonitor
        xdg-desktop-portal-kde xdg-desktop-portal-gtk
        pipewire pipewire-alsa pipewire-pulse wireplumber
        bluez bluez-utils
        cups
    )

    pacman -S --needed --noconfirm "${core_required[@]}"

    # Fedora 44 KDE group -> Arch package mapping.
    # Source groups captured from the live Fedora install:
    #   kde-desktop, kde-apps, kde-media, kde-pim, libreoffice,
    #   desktop-accessibility and admin-tools.
    # Fedora-only configuration/branding RPMs are intentionally NOT listed here;
    # those are reproduced later from assets/fedora-*.
    local fedora_kde_defaults=(
        # kde-desktop defaults / Plasma integration
        akonadi mariadb
        ark audiocd-kio aurorae bluedevil colord-kde cups-pk-helper dolphin
        ffmpegthumbs filelight firewall-config firewalld
        fprintd
        kaccounts-integration kaccounts-providers
        kcharselect kdeconnect kde-gtk-config kde-inotify-survey partitionmanager
        kdebugsettings kdegraphics-thumbnailers kdenetwork-filesharing kdeplasma-addons
        kdialog kdnssd baloo kfind khelpcenter kinfocenter kio-admin kio-gdrive
        kjournald kmenuedit konsole krdp krfb ksshaskpass kunifiedpush
        kwalletmanager kate libappindicator kwallet-pam phonon-qt6-vlc pinentry
        plasma-disks drkonqi
        networkmanager-l2tp networkmanager-openconnect networkmanager-strongswan
        networkmanager-openvpn networkmanager-pptp networkmanager-vpnc
        print-manager plasma-thunderbolt plasma-vault plasma-welcome
        samba signon-kwallet-extension spectacle thermald toolbox udisks2
        vlc-plugin-gstreamer xwaylandvideobridge

        # kde-apps group
        kcalc keditbookmarks kmahjongg kmines kmouth kpat krdc krusader ktorrent
        neochat okular qrca skanpage

        # kde-media group
        digikam dragon elisa gwenview k3b kamera kamoso kolourpaint

        # kde-pim group
        akregator kaddressbook kleopatra kmail kontact korganizer

        # desktop-accessibility group
        # Fedora's old at-spi2-atk split is folded into Arch's at-spi2-core.
        at-spi2-core brltty orca speech-dispatcher

        # admin-tools group: Fedora's SELinux/setroubleshoot and
        # system-config-language are Fedora-specific; GNOME Disks is portable.
        gnome-disk-utility

        # Fedora LibreOffice group maps to Arch's complete suite package.
        libreoffice-fresh
    )

    install_repo_packages "Fedora KDE default application set" "${fedora_kde_defaults[@]}"

    # Useful pieces from the user's previous Arch setup.  These are not claimed
    # to be Fedora defaults, but are retained from the original installer.
    local personal_extras=(
        firefox lutris steam
        dolphin-plugins kimageformats kio-extras qqc2-desktop-style
        qt6-imageformats tesseract tesseract-data-eng unrar xsettingsd
        kdecoration kgamma kpipewire kwayland-integration qqc2-breeze-style
        system-config-printer fwupd
        fish micro git base-devel
    )
    install_repo_packages "existing personal Arch extras" "${personal_extras[@]}"

    # Fedora ships a Flathub remote package.  On Arch reproduce the result
    # directly instead of attempting to install a Fedora-specific RPM.
    if command -v flatpak >/dev/null 2>&1; then
        flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo \
            || warn "Could not add Flathub right now; add it later if the network is unavailable."
    fi

    # Sudo: normal wheel access + preserve the old narrowly-scoped NOPASSWD tools.
    install -d -m 0750 /etc/sudoers.d
    cat > /etc/sudoers.d/10-wheel <<'EOF_SUDO'
%wheel ALL=(ALL:ALL) ALL
EOF_SUDO
    chmod 0440 /etc/sudoers.d/10-wheel

    cat > "/etc/sudoers.d/90-${USERNAME}-hardware-tools" <<EOF_SUDO_USER
${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/dmsetup
${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/cpupower
${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
${USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/nvidia-settings
EOF_SUDO_USER
    chmod 0440 "/etc/sudoers.d/90-${USERNAME}-hardware-tools"

    # Fedora-like default services where the corresponding unit exists.
    systemctl enable NetworkManager.service
    systemctl disable sddm.service >/dev/null 2>&1 || true
    systemctl enable plasmalogin.service

    for unit in bluetooth.service cups.service firewalld.service systemd-oomd.service fstrim.timer; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            systemctl enable "$unit" >/dev/null 2>&1 || warn "Could not enable $unit"
        fi
    done

    ok "Fedora KDE application/package set installed using Arch package names"
}

install_nvidia_580_stack() {
    [[ $INSTALL_NVIDIA_580 -eq 1 ]] || return 0
    info "Installing NVIDIA 580xx legacy/DKMS stack"

    if [[ $ENABLE_CHAOTIC -ne 1 ]]; then
        warn "NVIDIA 580xx packages are AUR packages. Chaotic-AUR is disabled, so this installer will skip them."
        warn "Enable Chaotic-AUR in the installer, or install nvidia-580xx-dkms from AUR afterward."
        return 0
    fi

    local kernel header
    for kernel in linux linux-lts linux-zen linux-hardened; do
        if pacman -Q "$kernel" >/dev/null 2>&1; then
            header="${kernel}-headers"
            pacman -Si "$header" >/dev/null 2>&1 && pacman -S --needed --noconfirm "$header"
        fi
    done

    local pkgs=(
        nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings
        opencl-nvidia-580xx lib32-nvidia-580xx-utils lib32-opencl-nvidia-580xx
        nvidia-prime libva libva-intel-driver libva-nvidia-driver lib32-libva
        lib32-libva-intel-driver libvpl mesa lib32-mesa vulkan-intel
        lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader
        vulkan-mesa-implicit-layers lib32-vulkan-mesa-implicit-layers
        vulkan-tools egl-gbm egl-wayland egl-x11 libvdpau onetbb
    )
    local available=() pkg
    for pkg in "${pkgs[@]}"; do
        pacman -Si "$pkg" >/dev/null 2>&1 && available+=("$pkg") || warn "Package not found: $pkg"
    done
    ((${#available[@]})) && pacman -S --needed --noconfirm "${available[@]}"

    systemctl enable nvidia-persistenced.service >/dev/null 2>&1 || true

    install -d /etc/modprobe.d
    cat > /etc/modprobe.d/nvidia.conf <<'EOF_NVIDIA'
options nvidia NVreg_EnableMSI=1
options nvidia NVreg_EnablePCIeGen3=1
options nvidia NVreg_EnableResizableBar=1
options nvidia NVreg_UsePageAttributeTable=1
options nvidia NVreg_EnablePCIERelaxedOrderingMode=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
EOF_NVIDIA

    ok "NVIDIA stack configured"
}

# ----------------------------- Fedora KDE experience -----------------------------
install_fedora_look_and_feel() {
    info "Installing Fedora Light look-and-feel definition"

    # If the user dropped extracted Fedora look-and-feel folders into the project,
    # prefer those exact copies.
    if compgen -G "$FEDORA_LOOKANDFEEL_ASSET_DIR/*/" >/dev/null; then
        while IFS= read -r -d '' dir; do
            cp -a "$dir" /usr/share/plasma/look-and-feel/
        done < <(find "$FEDORA_LOOKANDFEEL_ASSET_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
        ok "Copied Fedora look-and-feel assets from project"
    fi

    # Always ensure the exact Fedora Light profile you extracted exists.
    local base=/usr/share/plasma/look-and-feel/org.fedoraproject.fedoralight.desktop
    install -d "$base/contents/layouts"
    cat > "$base/metadata.json" <<'EOF_META'
{
    "KPackageStructure": "Plasma/LookAndFeel",
    "KPlugin": {
        "Authors": [{"Email": "kde@lists.fedoraproject.org", "Name": "Fedora KDE SIG"}],
        "Category": "",
        "Description": "Fedora light theme by Fedora KDE SIG",
        "Id": "org.fedoraproject.fedoralight.desktop",
        "License": "GPLv2+",
        "Name": "Fedora Light",
        "Website": "https://fedoraproject.org/"
    }
}
EOF_META

    cat > "$base/contents/defaults" <<'EOF_DEFAULTS'
[kdeglobals][KDE]
widgetStyle=Breeze

[kdeglobals][General]
ColorScheme=BreezeLight

[kdeglobals][Icons]
Theme=breeze

[plasmarc][Theme]
name=default

[Wallpaper]
Image=Fedora

[kcminputrc][Mouse]
cursorTheme=breeze_cursors

[kwinrc][org.kde.kdecoration2]
library=org.kde.breeze
theme=Breeze

[ksplashrc][KSplash]
Theme=org.kde.breeze.desktop
EOF_DEFAULTS

    cat > "$base/contents/layouts/org.kde.plasma.desktop-layout.js" <<'EOF_LAYOUT'
loadTemplate("org.kde.plasma.desktop.defaultPanel")

var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
}
EOF_LAYOUT

    ok "Fedora Light look-and-feel ready"
}

install_fedora_branding() {
    info "Installing captured Fedora KDE branding"

    if [[ -f "$FEDORA_BRANDING_ASSET_DIR/00-start-here-2.js" ]]; then
        install -D -m 0644 \
            "$FEDORA_BRANDING_ASSET_DIR/00-start-here-2.js" \
            /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/00-start-here-2.js
        ok "Installed Fedora Plasma launcher/default update script"
    fi

    # The capture command intentionally kept the original /usr/share/... paths.
    # Copy only that captured subtree back into /usr/share on Arch.
    if [[ -d "$FEDORA_BRANDING_ASSET_DIR/logos/usr/share" ]]; then
        cp -a "$FEDORA_BRANDING_ASSET_DIR/logos/usr/share/." /usr/share/
        ok "Installed captured Fedora logo/start-here assets"
    fi
}

install_fedora_xdg_defaults() {
    info "Installing captured Fedora Plasma/XDG defaults"
    if [[ -d "$FEDORA_CONFIG_ASSET_DIR/xdg/plasma-workspace" ]]; then
        install -d /etc/xdg
        rm -rf /etc/xdg/plasma-workspace.fedora-arch-prev
        [[ -e /etc/xdg/plasma-workspace ]] && cp -a /etc/xdg/plasma-workspace /etc/xdg/plasma-workspace.fedora-arch-prev || true
        cp -a "$FEDORA_CONFIG_ASSET_DIR/xdg/plasma-workspace" /etc/xdg/
        ok "Installed Fedora plasma-workspace XDG defaults"
    fi
}

install_wallpapers() {
    info "Installing Fedora-style wallpaper package"
    install -d /usr/share/wallpapers /usr/share/backgrounds

    # Fedora's /usr/share/wallpapers/F44 package is mostly symlinks into
    # /usr/share/backgrounds/f44/default/.  Preserve that exact layout when the
    # real background payload was captured into assets/backgrounds/f44/.
    if [[ -d "$FEDORA_BACKGROUND_ASSET_DIR/f44" ]]; then
        rm -rf /usr/share/backgrounds/f44
        cp -a "$FEDORA_BACKGROUND_ASSET_DIR/f44" /usr/share/backgrounds/
        ok "Installed Fedora F44 day/night background payload"
    fi

    # Preferred layout: exact Fedora F44 Plasma wallpaper package.
    if [[ -d "$WALLPAPER_ASSET_DIR/F44/contents" ]]; then
        rm -rf /usr/share/wallpapers/F44
        cp -a "$WALLPAPER_ASSET_DIR/F44" /usr/share/wallpapers/F44
        rm -rf /usr/share/wallpapers/Default /usr/share/wallpapers/Fedora
        ln -s F44 /usr/share/wallpapers/Default
        ln -s Default /usr/share/wallpapers/Fedora

        # Fail loudly if the Fedora package was copied without its symlink targets.
        local broken=0 link
        while IFS= read -r -d '' link; do
            [[ -e "$link" ]] || { warn "Broken wallpaper symlink: $link -> $(readlink "$link")"; broken=1; }
        done < <(find /usr/share/wallpapers/F44 -type l -print0)
        if [[ $broken -eq 1 ]]; then
            fatal "F44 wallpaper symlink targets are missing. On Fedora copy /usr/share/backgrounds/f44 to assets/backgrounds/f44, then rerun."
        fi

        ok "Installed exact Fedora F44 wallpaper package + Fedora -> Default -> F44 aliases"
        return 0
    fi

    # Convenience mode: ordinary local image files.
    local imgs=()
    while IFS= read -r -d '' f; do imgs+=("$f"); done < <(
        find "$WALLPAPER_ASSET_DIR" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.jxl' \) -print0 2>/dev/null
    )

    if ((${#imgs[@]})); then
        local dest=/usr/share/wallpapers/FedoraLocal
        rm -rf "$dest"
        install -d "$dest/contents/images"
        cp -a "${imgs[@]}" "$dest/contents/images/"
        cat > "$dest/metadata.json" <<'EOF_WMETA'
{
  "KPlugin": {
    "Id": "FedoraLocal",
    "Name": "Fedora Local Wallpaper",
    "License": "User supplied"
  }
}
EOF_WMETA
        rm -rf /usr/share/wallpapers/Default /usr/share/wallpapers/Fedora
        ln -s FedoraLocal /usr/share/wallpapers/Default
        ln -s Default /usr/share/wallpapers/Fedora
        ok "Installed ${#imgs[@]} user-supplied wallpaper image(s)"
    else
        warn "No wallpapers found in $WALLPAPER_ASSET_DIR"
    fi
}

configure_plasma_login_manager() {
    info "Configuring Plasma Login Manager like Fedora"
    install -d /etc/plasmalogin.conf.d

    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" ]]; then
        # Arch supports /etc/plasmalogin.conf.d/*.conf. Keep Fedora's package
        # defaults out of /usr/lib so pacman continues to own Arch package files.
        install -m 0644 \
            "$FEDORA_CONFIG_ASSET_DIR/plasmalogin/defaults.conf" \
            /etc/plasmalogin.conf.d/10-fedora-defaults.conf
        ok "Installed captured Fedora Plasma Login defaults"
    else
        cat > /etc/plasmalogin.conf.d/10-fedora-defaults.conf <<'EOF_PLM'
[Greeter]
WallpaperPlugin=org.kde.image

[Greeter][Wallpaper][org.kde.image][General]
Image=file:///usr/share/wallpapers/Fedora/
PreviewImage=file:///usr/share/wallpapers/Fedora/
EOF_PLM
    fi
    ok "Plasma Login Manager configured"
}

configure_discover_offline_updates() {
    info "Configuring Discover + PackageKit offline updates"
    install -d /etc/xdg

    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" ]]; then
        install -m 0644 "$FEDORA_CONFIG_ASSET_DIR/discover/discoverrc" /etc/xdg/discoverrc
        ok "Installed Fedora's captured Discover configuration"
    else
        cat > /etc/xdg/discoverrc <<'EOF_DISCOVER'
[Software]
UseOfflineUpdates=true
EOF_DISCOVER
    fi

    # Guarantee the setting even if a future captured file contains more keys.
    if grep -q '^UseOfflineUpdates=' /etc/xdg/discoverrc; then
        sed -i 's/^UseOfflineUpdates=.*/UseOfflineUpdates=true/' /etc/xdg/discoverrc
    elif grep -q '^\[Software\]' /etc/xdg/discoverrc; then
        sed -i '/^\[Software\]/a UseOfflineUpdates=true' /etc/xdg/discoverrc
    else
        printf '\n[Software]\nUseOfflineUpdates=true\n' >> /etc/xdg/discoverrc
    fi

    ok "Discover offline updates enabled"
}

configure_user_kde() {
    info "Applying your current Fedora KDE appearance to $USERNAME"
    local home
    home="$(getent passwd "$USERNAME" | cut -d: -f6)"
    install -d -o "$USERNAME" -g "$USERNAME" "$home/.config"

    # Restore the live Fedora Plasma settings/layout that were explicitly
    # captured.  Skip kscreen.txt because it is a diagnostic snapshot, not a
    # KDE configuration file.  Missing files are fine.
    if [[ -d "$FEDORA_USER_CONFIG_ASSET_DIR" ]]; then
        local captured file
        for captured in \
            kdeglobals kwinrc kcminputrc plasmarc ksplashrc kscreenlockerrc \
            kglobalshortcutsrc plasma-org.kde.plasma.desktop-appletsrc; do
            file="$FEDORA_USER_CONFIG_ASSET_DIR/$captured"
            [[ -f "$file" ]] && install -o "$USERNAME" -g "$USER_GROUP" -m 0644 "$file" "$home/.config/$captured"
        done
        ok "Restored captured live Fedora KDE user configuration"
    fi

    if command -v plasma-apply-lookandfeel >/dev/null 2>&1; then
        runuser -u "$USERNAME" -- env HOME="$home" QT_QPA_PLATFORM=offscreen \
            plasma-apply-lookandfeel --platform offscreen --apply org.fedoraproject.fedoralight.desktop \
            >/dev/null 2>&1 || warn "Could not apply the global theme offscreen; writing settings directly instead."
    fi

    local kwrite=/usr/bin/kwriteconfig6
    if [[ -x "$kwrite" ]]; then
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group KDE --key LookAndFeelPackage org.fedoraproject.fedoralight.desktop
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group KDE --key widgetStyle Breeze
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key ColorScheme BreezeLight
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key font 'Noto Sans,10,-1,5,50,0,0,0,0,0'
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key fixed 'Noto Sans Mono,10,-1,5,50,0,0,0,0,0'
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key menuFont 'Noto Sans,10,-1,5,50,0,0,0,0,0'
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key toolBarFont 'Noto Sans,9,-1,5,50,0,0,0,0,0'
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group General --key smallestReadableFont 'Noto Sans,8,-1,5,50,0,0,0,0,0'
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kdeglobals --group Icons --key Theme breeze
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file plasmarc --group Theme --key name breeze-dark
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kcminputrc --group Mouse --key cursorTheme Breeze_Light
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kwinrc --group org.kde.kdecoration2 --key library org.kde.breeze
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file kwinrc --group org.kde.kdecoration2 --key theme Breeze
        runuser -u "$USERNAME" -- env HOME="$home" "$kwrite" --file ksplashrc --group KSplash --key Theme org.kde.breeze.desktop
    else
        warn "kwriteconfig6 not found; Fedora theme files were installed but user overrides were not written."
    fi

    chown -R "$USERNAME:$USER_GROUP" "$home/.config"
    ok "KDE appearance configured"
}

# ----------------------------- Plymouth/initramfs -----------------------------
ensure_plymouth_update_ui() {
    info "Configuring Fedora-style Plymouth BGRT/offline-update screen"
    local theme=/usr/share/plymouth/themes/bgrt/bgrt.plymouth
    [[ -f "$theme" ]] || fatal "Arch Plymouth BGRT theme not found after installing plymouth."
    backup_once "$theme"

    if [[ -f "$FEDORA_CONFIG_ASSET_DIR/plymouth/bgrt.plymouth" ]]; then
        install -m 0644 "$FEDORA_CONFIG_ASSET_DIR/plymouth/bgrt.plymouth" "$theme"
        ok "Installed captured Fedora BGRT Plymouth definition"
    fi

    # Modern upstream BGRT normally already has these. Append only if missing.
    if ! grep -q '^\[updates\]' "$theme"; then
        cat >> "$theme" <<'EOF_UPDATES'

[updates]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Installing Updates...
SubTitle=Do not turn off your computer

[system-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading System...
SubTitle=Do not turn off your computer

[firmware-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading Firmware...
SubTitle=Do not turn off your computer
EOF_UPDATES
    fi

    plymouth-set-default-theme bgrt
    ok "Plymouth theme = bgrt"
}

append_kernel_args() {
    local args=(quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0)
    local cmdline=/etc/kernel/cmdline arg current=""

    # If /etc/kernel/cmdline already exists, preserve its root/encryption arguments
    # and only append our splash parameters. Do NOT create it from scratch: doing
    # that with only "quiet splash" can break UKI/root discovery.
    if [[ -f "$cmdline" ]]; then
        current="$(cat "$cmdline")"
        for arg in "${args[@]}"; do
            [[ " $current " == *" $arg "* ]] || current+=" $arg"
        done
        echo "${current# }" > "$cmdline"
    fi

    # systemd-boot classic entries
    if compgen -G '/boot/loader/entries/*.conf' >/dev/null; then
        local entry line
        for entry in /boot/loader/entries/*.conf; do
            [[ -f "$entry" ]] || continue
            line="$(grep '^options ' "$entry" || true)"
            for arg in "${args[@]}"; do
                [[ " $line " == *" $arg "* ]] || line+=" $arg"
            done
            if grep -q '^options ' "$entry"; then
                sed -i "s|^options .*|$line|" "$entry"
            fi
        done
    fi

    # GRUB
    if [[ -f /etc/default/grub ]]; then
        local old new
        old="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p' /etc/default/grub | head -n1)"
        new="$old"
        for arg in "${args[@]}"; do
            [[ " $new " == *" $arg "* ]] || new+=" $arg"
        done
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${new# }\"|" /etc/default/grub
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${new# }\"" >> /etc/default/grub
        fi
    fi
}

mask_hook() {
    local hook="$1"
    install -d /etc/pacman.d/hooks
    ln -sfn /dev/null "/etc/pacman.d/hooks/$hook"
}

unmask_hook() {
    local hook="$1" path="/etc/pacman.d/hooks/$1"
    [[ -L "$path" && "$(readlink "$path")" == /dev/null ]] && rm -f "$path" || true
}

mkinitcpio_add_plymouth_hook() {
    local conf=/etc/mkinitcpio.conf
    [[ -f "$conf" ]] || fatal "/etc/mkinitcpio.conf not found"
    backup_once "$conf"

    # shellcheck disable=SC1090
    source "$conf"
    local old_hooks=("${HOOKS[@]}") new_hooks=() hook inserted=0

    # Remove existing plymouth so we can place it correctly.
    for hook in "${old_hooks[@]}"; do
        [[ "$hook" == plymouth ]] || new_hooks+=("$hook")
    done
    old_hooks=("${new_hooks[@]}")
    new_hooks=()

    # Insert after systemd/udev, but before encrypt/sd-encrypt if present.
    for hook in "${old_hooks[@]}"; do
        if [[ $inserted -eq 0 && ( "$hook" == encrypt || "$hook" == sd-encrypt ) ]]; then
            new_hooks+=(plymouth)
            inserted=1
        fi
        new_hooks+=("$hook")
        if [[ $inserted -eq 0 && ( "$hook" == systemd || "$hook" == udev ) ]]; then
            # Delay insertion one token if autodetect follows? Not required; placing here is valid.
            new_hooks+=(plymouth)
            inserted=1
        fi
    done
    [[ $inserted -eq 1 ]] || new_hooks+=(plymouth)

    local newline="HOOKS=(${new_hooks[*]})"
    sed -i "s|^HOOKS=.*|$newline|" "$conf"
}

configure_initramfs() {
    info "Configuring initramfs: $INITRAMFS"
    append_kernel_args

    case "$INITRAMFS" in
        dracut)
            pacman -S --needed --noconfirm dracut
            install -d /etc/dracut.conf.d
            cat > /etc/dracut.conf.d/10-fedora-arch-plymouth.conf <<'EOF_DRACUT'
add_dracutmodules+=" plymouth "
EOF_DRACUT
            if [[ $INSTALL_NVIDIA_580 -eq 1 ]]; then
                cat >> /etc/dracut.conf.d/10-fedora-arch-plymouth.conf <<'EOF_DRACUT_NVIDIA'
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF_DRACUT_NVIDIA
            fi
            mask_hook 90-mkinitcpio-install.hook
            mask_hook 60-mkinitcpio-remove.hook
            unmask_hook 90-dracut-install.hook
            unmask_hook 60-dracut-remove.hook
            dracut --regenerate-all --force
            ;;

        mkinitcpio)
            pacman -S --needed --noconfirm mkinitcpio
            unmask_hook 90-mkinitcpio-install.hook
            unmask_hook 60-mkinitcpio-remove.hook
            mask_hook 90-dracut-install.hook
            mask_hook 60-dracut-remove.hook
            mask_hook 90-booster-install.hook
            mask_hook 60-booster-remove.hook
            mkinitcpio_add_plymouth_hook
            if [[ $INSTALL_NVIDIA_580 -eq 1 ]]; then
                backup_once /etc/mkinitcpio.conf
                # Add early NVIDIA KMS modules only if not already in MODULES.
                # shellcheck disable=SC1091
                source /etc/mkinitcpio.conf
                local nmods=(nvidia nvidia_modeset nvidia_uvm nvidia_drm) m found modules_new=("${MODULES[@]}")
                for m in "${nmods[@]}"; do
                    found=0
                    for x in "${modules_new[@]}"; do [[ "$x" == "$m" ]] && found=1; done
                    [[ $found -eq 1 ]] || modules_new+=("$m")
                done
                sed -i "s|^MODULES=.*|MODULES=(${modules_new[*]})|" /etc/mkinitcpio.conf
            fi
            mkinitcpio -P
            ;;

        booster)
            pacman -S --needed --noconfirm booster
            unmask_hook 90-booster-install.hook
            unmask_hook 60-booster-remove.hook
            mask_hook 90-mkinitcpio-install.hook
            mask_hook 60-mkinitcpio-remove.hook
            mask_hook 90-dracut-install.hook
            mask_hook 60-dracut-remove.hook
            touch /etc/booster.yaml
            if grep -q '^enable_plymouth:' /etc/booster.yaml; then
                sed -i 's/^enable_plymouth:.*/enable_plymouth: true/' /etc/booster.yaml
            else
                echo 'enable_plymouth: true' >> /etc/booster.yaml
            fi
            if [[ $INSTALL_NVIDIA_580 -eq 1 ]]; then
                if grep -q '^modules_force_load:' /etc/booster.yaml; then
                    sed -i 's/^modules_force_load:.*/modules_force_load: nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm/' /etc/booster.yaml
                else
                    echo 'modules_force_load: nvidia,nvidia_modeset,nvidia_uvm,nvidia_drm' >> /etc/booster.yaml
                fi
            fi
            /usr/lib/booster/regenerate_images
            if compgen -G '/boot/loader/entries/*.conf' >/dev/null; then
                local entry
                for entry in /boot/loader/entries/*.conf; do
                    [[ -f "$entry" ]] || continue
                    sed -Ei 's#^initrd[[:space:]]+/initramfs-([^[:space:]]+)\.img#initrd /booster-\1.img#' "$entry"
                done
                ok "Updated systemd-boot entries to booster-*.img where applicable"
            fi
            warn "Booster images are named /boot/booster-*.img. Verify your bootloader entry points to them before rebooting."
            ;;
    esac

    if command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
        grub-mkconfig -o /boot/grub/grub.cfg
    fi

    ok "$INITRAMFS configured with Plymouth"
}

# ----------------------------- personal tuning -----------------------------
apply_existing_tuning() {
    [[ $APPLY_TUNING -eq 1 ]] || return 0
    info "Applying your existing tuning profile"

    install -d /etc/modprobe.d /etc/sysctl.d

    cat > /etc/modprobe.d/blacklist.conf <<'EOF_BLACKLIST'
blacklist iTCO_wdt
blacklist iTCO_vendor_support
#blacklist lpc_ich
#blacklist at24
EOF_BLACKLIST
    if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" != "btrfs" ]]; then
        echo 'blacklist btrfs' >> /etc/modprobe.d/blacklist.conf
    else
        warn "Root filesystem is Btrfs; not blacklisting the btrfs module."
    fi

    cat > /etc/modprobe.d/intel.conf <<'EOF_INTEL'
options i915 enable_dc=-1 enable_dpt=1 enable_dsb=1 enable_flipq=1 enable_sagv=1 disable_power_well=1 enable_ips=1 enable_dp_mst=1 enable_fbc=-1 enable_psr=-1 enable_panel_replay=-1 psr_safest_params=0 enable_psr2_sel_fetch=1 enable_dmc_wl=-1 nuclear_pageflip=1 reset=2 enable_hangcheck=1 enable_guc=-1 guc_log_level=0 enable_gvt=0 request_timeout_ms=20000 memtest=0 mmio_debug=0 verbose_state_checks=0 mitigations=off
EOF_INTEL

    cat > /etc/sysctl.d/99-performance.conf <<'EOF_SYSCTL'
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.core.rmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_default = 1048576
net.core.wmem_max = 16777216
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 1048576 2097152
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_local_port_range = 30000 65535
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.ping_group_range = 0 65535
vm.swappiness = 180
vm.dirty_background_ratio = 10
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 6000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
EOF_SYSCTL

    cat > /etc/sysctl.d/99-misc.conf <<'EOF_MISC'
dev.i915.perf_stream_paranoid = 0
kernel.yama.ptrace_scope = 0
EOF_MISC

    backup_once /etc/environment
    cat > /etc/environment <<'EOF_ENV'
__GLX_VENDOR_LIBRARY_NAME=mesa
MESA_LOADER_DRIVER_OVERRIDE=crocus
LIBVA_DRIVER_NAME=i965
VDPAU_DRIVER=va_gl
ANV_VIDEO_DECODE=1
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_hasvk_icd.json
GST_VA_ALL_DRIVERS=1
XDG_CURRENT_DESKTOP=KDE
KWIN_DRM_USE_MODIFIERS=1
KWIN_DRM_NO_AMS=1
KWIN_USE_OVERLAYS=1
KWIN_USE_INTEL_SWAP_EVENT=1
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland
PROTON_ENABLE_WAYLAND=1
WINE_DISABLE_X11=1
PROTON_USE_NTSYNC=1
SYSTEMD_EDITOR=micro
OGL_DEDICATED_HW_STATE_PER_CONTEXT=ENABLE
EOF_ENV

    install -d /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/90-cheesecake.conf <<'EOF_JOURNAL'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
MaxLevelStore=warning
EOF_JOURNAL

    sysctl --system || true
    ok "Personal tuning applied"
}

finalize() {
    info "Final checks"
    systemctl enable NetworkManager.service plasmalogin.service >/dev/null 2>&1 || true

    echo
    echo "============================================================"
    echo " DONE"
    echo "============================================================"
    echo "User:              $USERNAME"
    echo "Hostname:          $HOSTNAME"
    echo "Initramfs:         $INITRAMFS"
    echo "Plymouth:          bgrt"
    echo "Discover offline:  enabled"
    echo "Login manager:     Plasma Login Manager"
    if [[ $ENABLE_ALHP -eq 1 ]]; then echo "ALHP:               $ALHP_LEVEL"; else echo "ALHP:               disabled"; fi
    if [[ $ENABLE_CHAOTIC -eq 1 ]]; then echo "Chaotic-AUR:        enabled"; else echo "Chaotic-AUR:        disabled"; fi
    echo
    echo "Installer log: $LOG_FILE"
    echo
    if [[ "$INITRAMFS" == booster ]]; then
        echo "IMPORTANT: verify your bootloader uses /boot/booster-*.img before rebooting."
    else
        echo "You can reboot when your bootloader/kernel installation is ready."
    fi

    unset USER_PASSWORD ROOT_PASSWORD
}

main() {
    require_root
    collect_answers
    configure_repositories_first
    configure_identity_and_user
    install_packages
    install_nvidia_580_stack
    install_fedora_look_and_feel
    install_fedora_branding
    install_fedora_xdg_defaults
    install_wallpapers
    configure_plasma_login_manager
    configure_discover_offline_updates
    configure_user_kde
    ensure_plymouth_update_ui
    configure_initramfs
    apply_existing_tuning
    finalize
}

main "$@"
