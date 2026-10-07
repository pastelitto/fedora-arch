#!/usr/bin/env bash
# Minimal Arch KDE post-install. Run as root INSIDE: arch-chroot /mnt
# Requires: working network, UEFI boot, FAT EFI System Partition mounted at /boot.
set -Eeuo pipefail

info(){ printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
yesno(){ local a; read -r -p "$1 [Y/n] " a || true; [[ "${a:-y}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; }

[[ $EUID -eq 0 ]] || die "Run as root inside arch-chroot /mnt."
[[ -f /etc/arch-release ]] || die "Not an Arch installation."
[[ -d /sys/firmware/efi/efivars ]] || die "UEFI not detected."
mountpoint -q /boot || die "/boot is not mounted."
case "$(findmnt -n -o FSTYPE /boot)" in vfat|fat|msdos) ;; *) die "/boot must be the FAT EFI System Partition." ;; esac
case "$(findmnt -n -o SOURCE / 2>/dev/null || true)" in airootfs|overlay|/dev/loop*|"") die "Run this after: arch-chroot /mnt" ;; esac

clear || true
cat <<'EOF_BANNER'
=======================================================
 Minimal Arch KDE install
=======================================================
Automatic:
  timezone       America/Mexico_City
  locale/keymap  en_US.UTF-8 / us
  ALHP           x86-64-v2
  repo priority  ALHP/Arch > CachyOS > Chaotic-AUR
  initramfs      mkinitcpio
  bootloader     systemd-boot
  splash         Plymouth BGRT + quiet splash

The password below is used for BOTH your user and root.
EOF_BANNER

while true; do
  read -r -p "Username: " USERNAME
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && ! id "$USERNAME" &>/dev/null && break
  echo "Invalid/existing username."
done

while true; do
  read -r -s -p "Password: " PASSWORD; echo
  [[ -n "$PASSWORD" ]] || { echo "Password cannot be empty."; continue; }
  read -r -s -p "Confirm password: " PASSWORD2; echo
  [[ "$PASSWORD" == "$PASSWORD2" ]] && break
  echo "Passwords do not match."
done
unset PASSWORD2

while true; do
  read -r -p "Hostname: " HOSTNAME_NEW
  [[ ${#HOSTNAME_NEW} -le 253 && "$HOSTNAME_NEW" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$HOSTNAME_NEW" != *..* ]] && break
  echo "Invalid hostname."
done

if yesno "Enable Discover + PackageKit + automatic offline updates without password prompts in Discover?"; then
  DISCOVER=1
else
  DISCOVER=0
fi

echo
echo "User:             $USERNAME"
echo "Hostname:         $HOSTNAME_NEW"
echo "Discover offline: $([[ $DISCOVER -eq 1 ]] && echo yes || echo no)"
yesno "Continue?" || exit 0

# -----------------------------------------------------------------------------
# Base identity
# -----------------------------------------------------------------------------
info "Configuring account, locale and time"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf 'KEYMAP=us\n' > /etc/vconsole.conf
ln -sfn /usr/share/zoneinfo/America/Mexico_City /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd.service &>/dev/null || true
printf '%s\n' "$HOSTNAME_NEW" > /etc/hostname
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF_HOSTS
getent group wheel &>/dev/null || groupadd wheel
useradd -m -U -G wheel -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
printf 'root:%s\n' "$PASSWORD" | chpasswd
PASSWORD=''; unset PASSWORD

# -----------------------------------------------------------------------------
# Repositories: ALHP v2 / Arch / CachyOS / Chaotic-AUR
# -----------------------------------------------------------------------------
strip_repo(){
  awk -v pat="$3" 'BEGIN{s=0} /^\[/{if($0~pat){s=1;next}s=0} !s{print}' "$1" > "$2"
}

enable_multilib(){
  grep -q '^#\[multilib\]' /etc/pacman.conf && sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//;}' /etc/pacman.conf || true
}

info "Configuring repositories"
cp -a /etc/pacman.conf /etc/pacman.conf.minimal-install.bak

# Remove old copies if a previous attempt already added them.
a=$(mktemp); b=$(mktemp); c=$(mktemp)
strip_repo /etc/pacman.conf "$a" '^[[](core|extra|multilib)-x86-64-v[234][]]$'
strip_repo "$a" "$b" '^[[]cachyos[]]$'
strip_repo "$b" "$c" '^[[]chaotic-aur[]]$'
install -m0644 "$c" /etc/pacman.conf
rm -f "$a" "$b" "$c"

enable_multilib
pacman-key --init
pacman-key --populate archlinux

# Chaotic bootstrap. It is written permanently LAST later.
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com || \
  pacman-key --recv-key 3056513887B78AEB --keyserver hkps://keyserver.ubuntu.com
pacman-key --lsign-key 3056513887B78AEB
pacman -U --needed --noconfirm \
  https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst \
  https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst

# ALHP keyring/mirrorlist are AUR packages; use the now-trusted Chaotic repo to get them.
/lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q 'x86-64-v2 (supported' || die "CPU does not support x86-64-v2."
tmp=$(mktemp)
cp /etc/pacman.conf "$tmp"
cat >> "$tmp" <<'EOF_CHAOTIC_TMP'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF_CHAOTIC_TMP
pacman --config "$tmp" -Syy --noconfirm
pacman --config "$tmp" -S --needed --noconfirm alhp-keyring alhp-mirrorlist || {
  rm -f "$tmp"
  die "Could not install ALHP keyring/mirrorlist. No signature-repair workaround was attempted."
}
rm -f "$tmp"

# Put each ALHP v2 repo immediately above its normal Arch counterpart.
a=$(mktemp)
awk '
  /^\[core\]$/     {print "[core-x86-64-v2]\nInclude = /etc/pacman.d/alhp-mirrorlist\n"}
  /^\[extra\]$/    {print "[extra-x86-64-v2]\nInclude = /etc/pacman.d/alhp-mirrorlist\n"}
  /^\[multilib\]$/ {print "[multilib-x86-64-v2]\nInclude = /etc/pacman.d/alhp-mirrorlist\n"}
  {print}
' /etc/pacman.conf > "$a"
install -m0644 "$a" /etc/pacman.conf
rm -f "$a"

# CachyOS trust/mirrorlist only; Arch pacman remains preferred because CachyOS is below Arch.
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || \
  pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
tmp=$(mktemp)
cp /etc/pacman.conf "$tmp"
cat >> "$tmp" <<'EOF_CACHY_TMP'

[cachyos]
Server = https://mirror.cachyos.org/repo/x86_64/cachyos
EOF_CACHY_TMP
pacman --config "$tmp" -Syy --noconfirm
pacman --config "$tmp" -S --needed --noconfirm cachyos-keyring cachyos-mirrorlist
rm -f "$tmp"

cat >> /etc/pacman.conf <<'EOF_FINAL_REPOS'

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF_FINAL_REPOS

pacman -Syyu --noconfirm || die "Upgrade failed. No automatic signature/key repair was run."

# -----------------------------------------------------------------------------
# Kernel + minimal Plasma
# -----------------------------------------------------------------------------
info "Installing minimal KDE Plasma"
pacman -S --needed --noconfirm \
  linux linux-headers linux-firmware mkinitcpio plymouth sudo networkmanager \
  pipewire pipewire-audio pipewire-alsa pipewire-pulse wireplumber \
  plasma-desktop plasma-workspace plasma-login-manager plasma-nm plasma-pa \
  powerdevil systemsettings kscreen xdg-desktop-portal-kde polkit-kde-agent \
  breeze breeze-icons dolphin konsole kate noto-fonts noto-fonts-emoji

install -d -m0750 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null

systemctl enable NetworkManager.service
systemctl disable sddm.service &>/dev/null || true
systemctl enable plasmalogin.service

# -----------------------------------------------------------------------------
# Optional Discover + classic PackageKit offline updates
# -----------------------------------------------------------------------------
if (( DISCOVER )); then
  info "Configuring Discover + PackageKit offline updates"
  pacman -S --needed --noconfirm \
    discover packagekit packagekit-qt6 appstream appstream-qt archlinux-appstream-data

  # System packages are staged for PackageKit's standard system-update.target boot.
  install -d /etc/xdg
  cat > /etc/xdg/discoverrc <<'EOF_DISCOVER'
[Software]
UseOfflineUpdates=true
EOF_DISCOVER

  # Discover's notifier performs unattended update handling once per day while
  # the user session is running. It stages system updates; it does NOT force a reboot.
  install -d -m0700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config"
  cat > "/home/$USERNAME/.config/PlasmaDiscoverUpdates" <<'EOF_AUTO'
[Global]
UseUnattendedUpdates=true
RequiredNotificationInterval=86400
EOF_AUTO
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/PlasmaDiscoverUpdates"
  chmod 0600 "/home/$USERNAME/.config/PlasmaDiscoverUpdates"

  # No password prompt in Discover for trusted PackageKit operations by the
  # active local wheel user. Untrusted package/key operations are NOT allowed.
  install -d /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/10-discover-packagekit-nopasswd.rules <<'EOF_POLKIT'
polkit.addRule(function(action, subject) {
    if (!(subject.active == true && subject.local == true && subject.isInGroup("wheel")))
        return;

    var allowed = [
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
    if (allowed.indexOf(action.id) != -1)
        return polkit.Result.YES;
});
EOF_POLKIT
fi

# -----------------------------------------------------------------------------
# Plymouth + default Arch mkinitcpio
# -----------------------------------------------------------------------------
info "Enabling Plymouth in mkinitcpio"
[[ -d /usr/share/plymouth/themes/bgrt ]] && plymouth-set-default-theme bgrt || true

if ! grep -Eq '^HOOKS=.*(^|[[:space:]])plymouth([[:space:]]|\))' /etc/mkinitcpio.conf; then
  if grep -Eq '^HOOKS=.*(^|[[:space:]])systemd([[:space:]]|\))' /etc/mkinitcpio.conf; then
    sed -i -E '/^HOOKS=/ s/(^|[[:space:]])systemd([[:space:]])/\1systemd plymouth\2/' /etc/mkinitcpio.conf
  elif grep -Eq '^HOOKS=.*(^|[[:space:]])udev([[:space:]]|\))' /etc/mkinitcpio.conf; then
    sed -i -E '/^HOOKS=/ s/(^|[[:space:]])udev([[:space:]])/\1udev plymouth\2/' /etc/mkinitcpio.conf
  else
    sed -i -E '/^HOOKS=/ s/(^|[[:space:]])filesystems([[:space:]]|\))/\1plymouth filesystems\2/' /etc/mkinitcpio.conf
  fi
fi
mkinitcpio -P

# -----------------------------------------------------------------------------
# systemd-boot + automatically generated entry
# -----------------------------------------------------------------------------
info "Installing systemd-boot"
bootctl --esp-path=/boot install

ROOT_SRC="$(findmnt -n -o SOURCE /)"
ROOT_DEV="${ROOT_SRC%%\[*}"
ROOT_UUID="$(findmnt -n -o UUID / 2>/dev/null || true)"
[[ -n "$ROOT_UUID" ]] || ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
[[ -n "$ROOT_UUID" ]] || die "Could not determine root filesystem UUID."

ROOTFLAGS=''
if [[ "$(findmnt -n -o FSTYPE /)" == btrfs ]]; then
  SUBVOL="$(tr ',' '\n' <<<"$(findmnt -n -o OPTIONS /)" | sed -n 's/^subvol=//p' | head -n1)"
  [[ -n "$SUBVOL" ]] && ROOTFLAGS=" rootflags=subvol=$SUBVOL"
fi

install -d /boot/loader/entries
cat > /boot/loader/loader.conf <<'EOF_LOADER'
default arch.conf
timeout 3
console-mode max
editor no
EOF_LOADER

{
  echo 'title   Arch Linux'
  echo 'linux   /vmlinuz-linux'
  [[ -f /boot/intel-ucode.img ]] && echo 'initrd  /intel-ucode.img'
  [[ -f /boot/amd-ucode.img ]] && echo 'initrd  /amd-ucode.img'
  echo 'initrd  /initramfs-linux.img'
  echo "options root=UUID=$ROOT_UUID rw quiet splash$ROOTFLAGS"
} > /boot/loader/entries/arch.conf

bootctl --esp-path=/boot set-default arch.conf &>/dev/null || true

echo
cat <<EOF_DONE
=======================================================
 DONE
=======================================================
User:              $USERNAME
Hostname:          $HOSTNAME_NEW
Timezone:          America/Mexico_City
Repos:             ALHP/Arch > CachyOS > Chaotic-AUR
Desktop:           minimal KDE Plasma
Login manager:     plasmalogin.service
Network:           NetworkManager.service
Discover offline:  $([[ $DISCOVER -eq 1 ]] && echo enabled || echo disabled)
Initramfs:         mkinitcpio + Plymouth
Bootloader entry:  /boot/loader/entries/arch.conf

EOF_DONE
if (( DISCOVER )); then
  cat <<'EOF_DISCOVER_DONE'
Discover:
  - trusted package installs/updates: no password prompt
  - unattended update handling: enabled
  - system packages: staged for offline installation on restart
  - automatic forced reboot: NO

EOF_DISCOVER_DONE
fi
echo "Exit the chroot, unmount /mnt, and reboot."
