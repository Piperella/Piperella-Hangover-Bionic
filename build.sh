#!/usr/bin/env bash
#
# build.sh — build a Wayland-enabled, bionic-native Hangover (Wine + FEX WoW64)
#            for Android arm64, NATIVELY on this machine (no Docker), by
#            overlaying a small patch onto the upstream termux-packages recipe
#            and driving termux's own build-package.sh directly.
#
# WHY THIS EXISTS
# --------------
# Our app targets Android API 36. At targetSdk >= 29 SELinux blocks execve() of
# app-data binaries, so the only legal way to run downloaded code is
# `/system/bin/linker64 <elf>` — and linker64 can only load *bionic* ELFs, not
# glibc ones. The Hangover Ubuntu .deb is glibc, which is why the old path had to
# userland-exec glibc's ld.so and kept crashing in dl_main.
#
# Termux already builds Hangover (whatever version the recipe pins) against *bionic* (NDK + llvm-mingw) — same
# FEX WoW64 backends (libwow64fex / libarm64ecfex / wowbox64). The only thing the
# stock recipe lacks is winewayland.drv (built X11-only); patches/enable-wayland.sh
# adds it. A bionic Hangover loads via linker64 directly: no userland-exec, no
# dl_main, no fake TEB.
#
# NATIVE BUILD (no Docker)
# ------------------------
# termux-packages normally builds inside a pinned Docker image. We run its
# build-package.sh directly on the host instead. That needs:
#   * the host build deps  -> install-host-deps.sh (robust across Ubuntu versions)
#   * an Android NDK r29    -> point $NDK at it (this repo's setup installs one)
#   * /dev/fuse usable      -> true on a real host (fuse-overlayfs stages the NDK)
#
# IMPORTANT host caveat: termux-packages master targets a very new Ubuntu
# (clang-21 / gcc-15 / full i386 multiarch / a working cross gobject-introspection
# for any package that builds gir). On an older host (e.g. 24.04) install-host-deps.sh
# backfills what it can, but some transitive dep that builds from source (pango/gir)
# may still fail. For a clean run use the Ubuntu release termux currently targets,
# or pre-seed the dependency .debs so nothing builds from source. See README.md.
#
# UPSTREAM / FORK
# ---------------
# Clones upstream termux-packages and applies our patch on top, so re-running
# pulls upstream updates. Point TERMUX_REPO_URL at a fork to track one instead.
#
# USAGE
#   ./build.sh                  # setup host deps, clone+patch, native build
#   SKIP_HOST_DEPS=1 ./build.sh # skip the apt step (deps already installed)
#   PATCH_ONLY=1 ./build.sh     # clone+patch only; no build
#   NDK=/path/to/ndk ./build.sh # override the NDK location
#   HOST_LLVM_VERSION=18 ./build.sh
#   TERMUX_REPO_URL=<fork> ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HERE/.work}"
OUTPUT="${OUTPUT:-$HERE/out}"
TERMUX_REPO_URL="${TERMUX_REPO_URL:-https://github.com/termux/termux-packages}"
TERMUX_REF="${TERMUX_REF:-master}"
ARCH="${ARCH:-aarch64}"
PATCH_ONLY="${PATCH_ONLY:-0}"
SKIP_HOST_DEPS="${SKIP_HOST_DEPS:-0}"
SRC="$WORKDIR/termux-packages"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORKDIR" "$OUTPUT"

# 1. Fetch upstream termux-packages (git if possible; tarball fallback for
#    environments where git to github is blocked).
if [ ! -e "$SRC/build-package.sh" ]; then
	if git ls-remote "$TERMUX_REPO_URL" >/dev/null 2>&1; then
		log "Cloning $TERMUX_REPO_URL ($TERMUX_REF), shallow"
		git clone --depth 1 --branch "$TERMUX_REF" "$TERMUX_REPO_URL" "$SRC"
	else
		log "git unavailable for $TERMUX_REPO_URL — fetching tarball"
		slug="${TERMUX_REPO_URL#https://github.com/}"
		curl -fsSL "https://codeload.github.com/$slug/tar.gz/refs/heads/$TERMUX_REF" -o "$WORKDIR/tp.tgz" \
			|| die "could not fetch termux-packages"
		( cd "$WORKDIR" && tar xzf tp.tgz && rm -rf termux-packages && mv "$(basename "$slug")-$TERMUX_REF" termux-packages && rm tp.tgz )
	fi
else
	log "Reusing existing checkout in $SRC"
fi

RECIPE="$SRC/x11-packages/hangover-wine/build.sh"
[ -f "$RECIPE" ] || die "recipe not found at $RECIPE (did upstream move it?)"

# 2. Overlay our idempotent Wayland patch.
log "Enabling Wayland in the hangover-wine recipe"
"$HERE/patches/enable-wayland.sh" "$RECIPE"

if [ "$PATCH_ONLY" = "1" ]; then
	log "PATCH_ONLY=1 — stopping before build."
	grep -nE "TERMUX_PKG_DEPENDS=|TERMUX_PKG_BUILD_DEPENDS=|with-wayland" "$RECIPE"
	exit 0
fi

# 3. Host build dependencies.
if [ "$SKIP_HOST_DEPS" != "1" ]; then
	log "Installing host build dependencies"
	"$HERE/install-host-deps.sh" "$SRC"
fi

# 4. Locate an Android NDK whose major version matches what the recipe wants.
#    The required major is read from termux's properties.sh (not hardcoded), so
#    this tracks upstream when they bump the NDK.
NDK_MAJOR="$(grep -oE 'TERMUX_NDK_VERSION_NUM:?="?[0-9]+' "$SRC/scripts/properties.sh" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
NDK_MAJOR="${NDK_MAJOR:-29}"
if [ -z "${NDK:-}" ]; then
	for c in "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_HOME:-}/ndk/"*; do
		[ -n "${c:-}" ] && [ -e "$c/source.properties" ] \
			&& grep -q "Pkg.Revision = ${NDK_MAJOR}\." "$c/source.properties" 2>/dev/null \
			&& { NDK="$c"; break; }
	done
fi
[ -n "${NDK:-}" ] && [ -d "$NDK" ] || die "no NDK r${NDK_MAJOR} found; set NDK=/path/to/android-ndk-r${NDK_MAJOR}"
export NDK
log "Using NDK r${NDK_MAJOR}: $NDK"

# 5. Native build. `-I` installs deps from the Termux apt repo instead of
#    building each from source.
export TERMUX_HOST_LLVM_MAJOR_VERSION="${HOST_LLVM_VERSION:-${TERMUX_HOST_LLVM_MAJOR_VERSION:-}}"
log "Building hangover-wine ($ARCH) natively — this compiles Wine + FEX (long)"
( cd "$SRC" && ./build-package.sh -a "$ARCH" -I hangover-wine )

# 6. Collect artifacts.
log "Collecting .deb artifacts into $OUTPUT"
found=0
while IFS= read -r deb; do cp -v "$deb" "$OUTPUT/"; found=1; done < <(
	find "$SRC/output" -maxdepth 1 -name 'hangover-wine_*.deb' 2>/dev/null)
[ "$found" = "1" ] || die "no hangover-wine .deb produced — check the build log above"

log "Done. Build artifacts:"; ls -la "$OUTPUT"
cat <<EOF

Next: bundle the bionic runtime dependencies the app must ship alongside this:
    ./fetch-runtime-deps.sh
EOF
