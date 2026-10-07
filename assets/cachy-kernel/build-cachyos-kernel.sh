#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

ROOT="$HOME/Documents/cachy-kernel"
REPO="$ROOT/linux-cachyos"
LOG="$ROOT/build.log"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
MODDB="$DATA_HOME/modprobed-db/modprobed.db"
FORCE=0
[[ "${1:-}" == --force ]] && FORCE=1

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "Run this as your normal user, not root."
mkdir -p "$ROOT"

echo "Kernel variant:"
echo "  1) CachyOS BORE (gaming/responsiveness) [default]"
echo "  2) CachyOS normal"
echo "  3) CachyOS RC (experimental)"
while true; do
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
        1) VARIANT_KEY=bore; PKG_SUBDIR=linux-cachyos-bore; CPUSCHED=bore; break ;;
        2) VARIANT_KEY=normal; PKG_SUBDIR=linux-cachyos; CPUSCHED=cachyos; break ;;
        3) VARIANT_KEY=rc; PKG_SUBDIR=linux-cachyos-rc; CPUSCHED=cachyos; break ;;
        *) echo "Invalid choice." ;;
    esac
done

echo "LLVM LTO:"
echo "  1) Thin LTO (recommended) [default]"
echo "  2) Full LTO"
while true; do
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
        1) LTO_MODE=thin; break ;;
        2) LTO_MODE=full; break ;;
        *) echo "Invalid choice." ;;
    esac
done

PKGDIR="$REPO/$PKG_SUBDIR"
STATE="$ROOT/.last-built-${VARIANT_KEY}-${LTO_MODE}"
SOURCE_STATE="$ROOT/.source-revision-${VARIANT_KEY}"

info "Installing build dependencies"
sudo -v
sudo pacman -S --needed --noconfirm \
    base-devel git bc binutils cpio gettext glibc libelf libgcc openssl \
    pahole perl python rust rust-bindgen rust-src tar xxhash xz zlib zstd \
    clang llvm lld

if ! command -v modprobed-db >/dev/null 2>&1; then
    info "Installing modprobed-db"
    if pacman -Si modprobed-db >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm modprobed-db
    elif command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm modprobed-db
    elif command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm modprobed-db
    else
        tmp_aur="$(mktemp -d)"
        git clone --depth=1 https://aur.archlinux.org/modprobed-db.git "$tmp_aur/modprobed-db"
        (cd "$tmp_aur/modprobed-db" && makepkg -si --needed --noconfirm)
        rm -rf "$tmp_aur"
    fi
fi
systemctl --user enable --now modprobed-db.timer >/dev/null 2>&1 || true
modprobed-db store >/dev/null 2>&1 || true
[[ -s "$MODDB" ]] || die "modprobed-db is empty: $MODDB. Exercise the required hardware/modules, then run modprobed-db store."

if [[ ! -d "$REPO/.git" ]]; then
    info "Cloning the CachyOS kernel repository"
    git clone --depth=1 --branch master https://github.com/CachyOS/linux-cachyos.git "$REPO"
else
    info "Updating the CachyOS kernel repository"
    git -C "$REPO" fetch --depth=1 origin master
    git -C "$REPO" reset --hard origin/master
fi
[[ -f "$PKGDIR/PKGBUILD" ]] || die "Missing $PKGDIR/PKGBUILD"

export _cachy_config=yes
export _cpusched="$CPUSCHED"
export _processor_opt=native
export _localmodcfg=yes
export _localmodcfg_path="$MODDB"
export _use_current=no
export _cc_harder=yes
export _per_gov=yes
export _tcp_bbr3=yes
export _HZ_ticks=1000
export _tickrate=full
export _preempt=full
export _hugepage=always
export _use_llvm_lto="$LTO_MODE"
export _use_lto_suffix=yes
export _use_kcfi=no
export _build_debug=no
export _build_nvidia_open=no
export _build_zfs=no
export _build_r8125=no
export _autofdo=no
export _propeller=no
export _propeller_profiles=no

SRCINFO="$(cd "$PKGDIR" && makepkg --printsrcinfo)"
PKGBASE="$(sed -n 's/^[[:space:]]*pkgbase = //p' <<<"$SRCINFO" | head -n1)"
PKGVER="$(sed -n 's/^[[:space:]]*pkgver = //p' <<<"$SRCINFO" | head -n1)"
PKGREL="$(sed -n 's/^[[:space:]]*pkgrel = //p' <<<"$SRCINFO" | head -n1)"
REL_PATH="${PKGDIR#$REPO/}"
UPSTREAM_REV="$(git -C "$REPO" log -1 --format=%H -- "$REL_PATH/PKGBUILD" "$REL_PATH/config")"
BUILD_ID="${PKGBASE}:${PKGVER}-${PKGREL}:${UPSTREAM_REV}"
LAST_BUILD=""; [[ -f "$STATE" ]] && LAST_BUILD="$(<"$STATE")"
if (( ! FORCE )) && [[ "$LAST_BUILD" == "$BUILD_ID" ]]; then
    ok "This exact ${LTO_MODE}-LTO build is already installed. Use --force to rebuild it."
    exit 0
fi

OLD_SOURCE_REV=""; [[ -f "$SOURCE_STATE" ]] && OLD_SOURCE_REV="$(<"$SOURCE_STATE")"
if [[ "$OLD_SOURCE_REV" != "$UPSTREAM_REV" ]]; then
    git -C "$REPO" clean -fdx -- "$REL_PATH"
    printf '%s\n' "$UPSTREAM_REV" > "$SOURCE_STATE"
fi

# localmodconfig runs inside the PKGBUILD. Insert this after it so F2FS remains
# built-in even if the currently running system has not loaded the module.
python - "$PKGDIR/PKGBUILD" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
marker = 'echo "Rewrite configuration..."'
if 'CUSTOM_AUTOBUILD_F2FS_BEGIN' in s:
    raise SystemExit(0)
if marker not in s:
    raise SystemExit("Could not find CachyOS' final configuration point")
patch = r'''    # CUSTOM_AUTOBUILD_F2FS_BEGIN
    scripts/config -e F2FS_FS -e F2FS_FS_XATTR -e F2FS_FS_POSIX_ACL \
        -e F2FS_FS_SECURITY -e F2FS_FS_COMPRESSION -e F2FS_FS_LZO \
        -e F2FS_FS_LZ4 -e F2FS_FS_ZSTD
    scripts/config -d F2FS_CHECK_FS -d F2FS_FAULT_INJECTION
    # CUSTOM_AUTOBUILD_F2FS_END
'''
s = s.replace(marker, patch + '    ' + marker, 1)
p.write_text(s)
PY

mapfile -t EXPECTED_PKGS < <(cd "$PKGDIR" && makepkg --packagelist)
KERNEL_PKG="$(printf '%s\n' "${EXPECTED_PKGS[@]}" | grep -v -- '-headers-' | grep -vE -- '-(dbg|nvidia|zfs|r8125)-' | head -n1 || true)"
HEADERS_PKG="$(printf '%s\n' "${EXPECTED_PKGS[@]}" | grep -- '-headers-' | head -n1 || true)"
[[ -n "$KERNEL_PKG" && -n "$HEADERS_PKG" ]] || die "Could not determine the kernel and headers package names."

info "Building $PKGBASE ($LTO_MODE LTO); full output is in $LOG"
: > "$LOG"
if ! (cd "$PKGDIR" && makepkg --cleanbuild --syncdeps --force --noconfirm --nocheck --skipinteg) >"$LOG" 2>&1; then
    tail -n 100 "$LOG"
    die "Kernel compilation failed."
fi

KCONFIG="$(find "$PKGDIR/src" -maxdepth 2 -type f -name .config -print -quit)"
[[ -n "$KCONFIG" ]] || die "Final kernel .config was not found."
grep -q '^CONFIG_X86_NATIVE_CPU=y$' "$KCONFIG" || die "Native CPU optimization is missing."
grep -q '^CONFIG_F2FS_FS=y$' "$KCONFIG" || die "F2FS was not built in."
grep -q '^CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y$' "$KCONFIG" || die "-O3 is missing."
if [[ "$LTO_MODE" == thin ]]; then
    grep -q '^CONFIG_LTO_CLANG_THIN=y$' "$KCONFIG" || die "Thin LTO is missing."
else
    grep -q '^CONFIG_LTO_CLANG_FULL=y$' "$KCONFIG" || die "Full LTO is missing."
fi
[[ "$VARIANT_KEY" != bore ]] || grep -q '^CONFIG_SCHED_BORE=y$' "$KCONFIG" || die "BORE is missing."

info "Installing kernel and headers"
sudo pacman -U --noconfirm "$KERNEL_PKG" "$HEADERS_PKG"
printf '%s\n' "$BUILD_ID" > "$STATE"

if [[ -x /usr/local/libexec/fedora-arch-register-cachy-kernel ]]; then
    sudo /usr/local/libexec/fedora-arch-register-cachy-kernel "$PKGBASE"
fi
ok "$PKGBASE $PKGVER-$PKGREL is installed."
