# Arch → Fedora KDE Experience Installer

This project is now a **single interactive installer** for the Arch setup.

It keeps Arch/pacman/AUR flexibility while reproducing the parts of Fedora KDE we identified:

- optional ALHP `x86-64-v2`, `v3`, or `v4`
- optional Chaotic-AUR
- username/password/hostname prompts (nothing hard-coded)
- Plasma 6 + Plasma Login Manager
- Fedora Light look-and-feel definition
- BreezeLight applications + dark Breeze Plasma shell, matching the captured Fedora machine
- Noto Sans / Noto Sans Mono font settings
- Discover + PackageKit with `UseOfflineUpdates=true`
- systemd offline-update plumbing through Arch PackageKit
- Plymouth `bgrt` with Fedora-style offline-update progress text
- selectable initramfs generator:
  1. **dracut** — default here, matching Fedora's approach
  2. **mkinitcpio** — Arch default
  3. **booster** — fast/small alternative
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

## Notes

- ALHP checks that the selected x86-64 feature level is reported as supported by glibc before enabling it.
- ALHP keyring/mirrorlist are AUR packages. When ALHP is selected but Chaotic-AUR is not, the installer uses Chaotic temporarily only to bootstrap those two packages, then removes the Chaotic bootstrap packages and leaves the repo disabled.
- Discover/PackageKit support on Arch is intentionally enabled because this project specifically targets the Fedora-style offline update workflow.
- `dracut` is the default choice in the menu. Plymouth is automatically included by dracut; the installer also explicitly requests the Plymouth module.
- `mkinitcpio` gets the `plymouth` hook added automatically.
- Booster 0.13+ supports Plymouth through `enable_plymouth: true`; the installer enables it. Booster produces `/boot/booster-*.img`, so verify the bootloader references those files before rebooting.
- The personal tuning option is hardware-specific. Leave it off on unrelated hardware.
# fedora-arch
# fedora-arch
