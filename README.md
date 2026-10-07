# Arch → Fedora KDE Experience Installer

This project is now a **single interactive installer** for the Arch setup.

It keeps Arch/pacman/AUR flexibility while reproducing the parts of Fedora KDE we identified:

- optional ALHP `x86-64-v2`, `v3`, or `v4`
- optional Chaotic-AUR
- a choice between desktop first-boot account setup and creating the
  administrator immediately; the immediate path asks for username/password,
  optional shared root password, hostname, and IANA time zone
- a minimal explicit `plasma-desktop` base + Plasma Login Manager, with the
  Dolphin/KIO preview, format, mobile, accessibility, GPU, and portal
  integrations needed for a polished desktop (not the full Arch `plasma` group)
- a KDE edition choice:
  - **Minimal KDE** keeps Arch/Breeze branding and asks separately about
    LibreOffice Fresh, Lutris, Steam, Faugus Launcher, ProtonUp-Qt, and the
    complete virt-manager stack
  - **Fedora KDE** enables the complete application/branding set, including
    those optional Minimal KDE selections
- a focused KDE application set including Dolphin, Konsole, Kate/KWrite,
  Filelight, Ark, Spectacle, KCalc, Partition Manager, Firefox, LocalSend,
  Okular, Gwenview, MPV, and VLC with Arch's complete VLC plugin bundle
- Fedora KDE includes the Fedora Light look-and-feel definition and captured
  BreezeLight-application/dark-Breeze-shell combination
- Noto Sans / Noto Sans Mono font settings
- optional daily automatic Discover + PackageKit updates; application updates
  are applied normally while system packages are staged for the next reboot
- a separate optional Discover-only OS-view spoof that hides its Arch/PackageKit
  warning without lying to PackageKit or pacman
- systemd offline-update plumbing through Arch PackageKit, including a safe
  signed-repository preflight for Arch, ALHP, CachyOS, and Chaotic-AUR
- Plymouth `bgrt` with Fedora-style offline-update progress text
- selectable initramfs generator:
  1. **dracut** — default here, matching Fedora's approach
  2. **mkinitcpio** — Arch default
  3. **booster** — fast/small alternative
- optional extreme ext4 policy with writeback journaling, async commits,
  disabled barriers, fixed dirty-page thresholds, and periodic TRIM
- optional post-install pacman RAM cache using native `CacheDir`, a dedicated
  tmpfs capped at 25% of RAM, and automatic cleanup after each transaction;
  activation is deliberately delayed until all installer packages are finished
- optional Intel IOMMU/KVM boot policy for passthrough, EPT, FlexPriority, and
  nested virtualization
- optional unconditional Intel i915 policy in
  `/etc/modprobe.d/i915-performance.conf` with the requested FBC, PSR, panel
  replay, SAGV, DSB, DPT, display-power, GuC, IPS, and MST settings
- optional TuneD backend (`tuned` + `tuned-ppd`) with Pastelitto power-saver,
  balanced, and performance profiles exposed to KDE's standard power slider
- optional custom CachyOS kernel builder installed as
  `~/Documents/cachy-kernel/build-cachyos-kernel.sh` and the
  `cachy-kernel-builder` command; it can compile immediately, preserves Arch
  pkgbase boot filenames, refreshes GRUB/systemd-boot/Limine, and can make the
  custom kernel the default
- optional Wayland-only desktop policy: removes Plasma's X11 login session,
  explicitly enables GDM Wayland, and forces native Qt, GTK, SDL, and Firefox
  backends through `/etc/environment.d/90-fedora-arch-wayland.conf` while
  retaining Xwayland for legacy applications
- a `dracut-all` Fish function (when Fish + dracut are selected) that rebuilds
  every installed kernel with Arch pkgbase filenames and refreshes GRUB
- an optional portable **KDE Pastelitto** preset: 38 px panel, three virtual
  desktops, Dolphin opening the user's home in Details view at preview size 32,
  KWrite using Noto Sans 11 without its welcome page, and Konsole using
  Monospace 11. It does not copy wallpapers, monitor IDs, activities, or the
  captured source machine's full Plasma layout
- an optional full virtualization stack with QEMU, libvirt, virt-manager,
  virt-viewer, dnsmasq, nft-based iptables, bridge tooling, OVMF, and swtpm;
  the OOBE user is added to `libvirt,kvm` and the default NAT network is
  defined, started, and set to autostart on the first real boot
- optional NVIDIA 580xx stack (requires permanent Chaotic-AUR in this installer)
- optional original Intel/NVIDIA/system tuning profile

## Wallpaper folder

Put wallpapers here **before running the installer**:

```text
assets/wallpapers/
```

Two supported layouts:

### Exact extracted Fedora 44 package

Copy the entire Fedora folder:

```text
assets/wallpapers/F44/
├── metadata.json
└── contents/
    └── ...
```

The installer creates:

```text
/usr/share/wallpapers/Fedora -> Default
/usr/share/wallpapers/Default -> F44
```

matching Fedora.

### Simple images

Or just put `.jpg`, `.jpeg`, `.png`, or `.webp` files directly in:

```text
assets/wallpapers/
```

The installer turns them into a local KDE wallpaper package automatically.

## Optional exact Fedora look-and-feel assets

If you copied the Fedora folders from your old installation, place them in:

```text
assets/fedora-look-and-feel/
```

For example:

```text
assets/fedora-look-and-feel/
├── org.fedoraproject.fedora.desktop/
├── org.fedoraproject.fedoralight.desktop/
└── org.fedoraproject.fedoradark.desktop/
```

If this folder is empty, the installer generates the Fedora Light profile itself from the Fedora settings we extracted.

## Run

Run this from the installed Arch environment / `arch-chroot` as root:

```bash
chmod +x install.sh
./install.sh
```

Repository selection happens **before the normal package install**.

## Faugus settings import

When Faugus Launcher is selected, the installer can import the captured
Pastelitto settings. The portable import contains:

- `config.json`: launcher behavior, default prefix/runner, GameMode and GPU
  choices, list layout, language, theme/accent, window/cover sizes, backup
  preferences, and other UI preferences
- `envar.json`: the captured DXVK/OpenGL shader-cache, threaded optimization,
  vblank, staging shared-memory, and Proton local shader-cache variables
- an empty `~/.config/dxvk/dxvk.conf` if one does not exist, because the
  captured environment points there but the source file was absent

`@HOME@` placeholders are rewritten for either the account created by the
installer or the account created later by Plasma Setup.
The import intentionally excludes `games.json`, Wine prefixes, installed
runners, game files, artwork/icons, backups, and anti-cheat payloads because
those contain machine-specific paths or downloaded runtime data.

## Notes

- ALHP checks that the selected x86-64 feature level is reported as supported by glibc before enabling it.
- ALHP keyring/mirrorlist are AUR packages. When ALHP is selected but Chaotic-AUR is not, the installer uses Chaotic temporarily only to bootstrap those two packages, then removes the Chaotic bootstrap packages and leaves the repo disabled.
- Discover/PackageKit support on Arch is intentionally enabled because this project specifically targets the Fedora-style offline update workflow.
- Minimal KDE asks separately about automatic Discover updates and the warning
  spoof. Fedora KDE enables both as part of its complete preset.
- Automatic Discover updates use KDE's native `UseUnattendedUpdates=true` with
  `RequiredNotificationInterval=86400` (daily) and `UseOfflineUpdates=true`, so
  system-package transactions are applied after rebooting.
- `fedora-arch-pacman-repo-health.timer` runs the signed repository check at
  boot and daily, before Discover normally performs its unattended work. The
  same check is a mandatory gate before a reboot-time transaction through
  `fedora-arch-pacman-offline-preflight.service`. For signature/database
  failures it removes only downloaded sync databases, repopulates installed
  Arch/ALHP/CachyOS/Chaotic keyrings, and retries once. Other failures—or a
  failed retry—abort safely; during offline boot the update trigger is removed
  and the machine returns to the desktop. It never disables signature
  verification or deletes `/etc/pacman.d/gnupg`. Its log is
  `/var/log/fedora-arch-pacman-offline-preflight.log`.
- `dracut` is the default choice in the menu. Plymouth is automatically included by dracut; the installer also explicitly requests the Plymouth module.
- Extreme ext4 tuning is asked only when root or `/home` uses ext4. It assumes
  reliable storage power-loss protection and deliberately increases the risk of
  losing recent writes after a host power failure.
- NVIDIA performance module options are a separate explicit choice. When
  selected, the installer writes them unconditionally instead of querying the
  Arch ISO's running kernel from inside `arch-chroot`.
- Locale and clock setup always use `en_US.UTF-8`, the US console keymap, the
  selected `/usr/share/zoneinfo` entry, `hwclock --systohc`, and enabled
  `systemd-timesyncd`.
- `mkinitcpio` gets the `plymouth` hook added automatically.
- Current Arch package naming is handled automatically for virtualization:
  `iptables` supplies the nft backend where `iptables-nft` has been replaced,
  and `iproute2` supplies current bridge management where `bridge-utils` is not
  available. The installer still accepts repositories exposing the older names.
- Booster 0.13+ supports Plymouth through `enable_plymouth: true`; the installer enables it. Booster produces `/boot/booster-*.img`, so verify the bootloader references those files before rebooting.
- The personal tuning option is hardware-specific. Leave it off on unrelated hardware.
# fedora-arch
# fedora-arch
