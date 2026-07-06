#!/usr/bin/env bash
#
# install-fex-backends.sh — guarantee the FEX / Box64 WoW64 backend DLLs end up
# INSIDE the hangover-wine package.
#
# THE BUG
# -------
# Hangover's actual x86 -> ARM64 recompilers ship as three prebuilt PE DLLs:
#   libwow64fex.dll    (32-bit FEX)
#   libarm64ecfex.dll  (64-bit FEX, via ARM64EC)
#   wowbox64.dll       (64-bit Box64)
# wow64.dll / wow64win.dll are only Wine's WoW64 *thunk* layer — no JIT — so
# without at least one real backend no x86 Windows app can execute.
#
# The upstream recipe tries to install the three DLLs in
# termux_step_post_make_install: it `ar -x`s the hangover-<type>_*_arm64.deb
# files bundled in the 2nd source and `install`s each DLL into the Wine tree.
# Empirically those DLLs silently never reach the final .deb (the produced
# hangover-wine_11.9_aarch64.deb contains wow64.dll/wow64win.dll/winewayland.drv
# but none of the three backends). The build still reports success, so an
# X11/Wayland-correct but emulator-dead package gets published. Termux's own
# published hangover-wine has the same gap.
#
# THE FIX
# -------
# Don't depend on the fragile post_make_install path. Re-install the three DLLs
# in termux_step_post_massage, which runs AFTER all of termux's file
# selection/massage (termux_step_copy_into_massagedir + termux_step_massage)
# and immediately before the package is archived from
# $TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX_CLASSICAL. Files written here go
# straight into the .deb, so whatever drops them earlier no longer matters.
# A missing backend is a HARD build failure — no more silent success.
#
# The source DEBs are located with `find` (not a hard-coded $TERMUX_PKG_SRCDIR
# root path), so this survives a change in where termux unpacks the 2nd source.
#
# libarm64ecfex.dll / libwow64fex.dll: Hangover's release bundle ships these
# built from a stale FEX (2605) that crashes 64-bit (arm64ec) apps using CEF's
# MEM_RESET allocator pattern (FEX-Emu issue #4493 / steamwebhelper). CI builds
# fresh ones from upstream FEX-Emu/FEX (see build-fex-arm64ec.sh) containing
# that fix, and this override REQUIRES those freshly-built DLLs be present
# (located via a broad filesystem search, since the Termux Docker container's
# exact bind-mount path isn't guaranteed) -- it does not fall back to the stale
# bundled ones, so a build that skips the fresh-FEX step fails loudly instead of
# silently re-shipping the crash. wowbox64.dll (Box64) is unaffected by this and
# still comes from the bundle.
#
# Idempotent: guarded by a marker, so re-running and upstream recipe updates
# are safe.
#
# Usage: install-fex-backends.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: install-fex-backends.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "install-fex-backends: no such file: $F" >&2; exit 1; }

MARKER="# >>> piperella: FEX WoW64 backends (post_massage) >>>"
if grep -qF "$MARKER" "$F"; then
	echo "install-fex-backends: already applied (no-op)"
	exit 0
fi

cat >> "$F" <<'EOF'

# >>> piperella: FEX WoW64 backends (post_massage) >>>
# Install the FEX/Box64 WoW64 backend DLLs into the package. This runs after
# termux's massage/file-selection with CWD = $TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX_CLASSICAL,
# so anything written here is archived directly into the .deb. See
# patches/install-fex-backends.sh for why the upstream post_make_install path
# is not relied upon. A missing backend hard-fails the build.
termux_step_post_massage() {
	local _winedir="./opt/hangover-wine/lib/wine/aarch64-windows"
	[ -d "$_winedir" ] || termux_error_exit "FEX install: wine dir missing in package ($_winedir)"

	# libarm64ecfex.dll / libwow64fex.dll: REQUIRE the freshly-built overrides
	# from build-fex-arm64ec.sh (upstream FEX with the #4493 fix). Search
	# broadly since the exact bind-mount path inside the Docker container isn't
	# guaranteed; -xdev keeps it from wandering into /proc, /sys, etc.
	local _fresh_dir _fresh_info
	_fresh_dir="$(find / -xdev -maxdepth 10 -type f -name libarm64ecfex.dll -path '*piperella-fex-dlls*' 2>/dev/null | head -n1)"
	[ -n "$_fresh_dir" ] || termux_error_exit "FEX install: freshly-built libarm64ecfex.dll not found anywhere under piperella-fex-dlls/ -- the build-fex-arm64ec.sh step did not run or its output was not staged; refusing to fall back to the stale bundled FEX (issue #4493)"
	_fresh_dir="$(dirname "$_fresh_dir")"
	for _type in libarm64ecfex libwow64fex; do
		[ -s "$_fresh_dir/${_type}.dll" ] || termux_error_exit "FEX install: $_fresh_dir/${_type}.dll missing/empty"
		install -Dm644 "$_fresh_dir/${_type}.dll" "$_winedir/${_type}.dll"
		echo "install-fex-backends: packaged ${_type}.dll ($(stat -c%s "$_winedir/${_type}.dll") bytes) from freshly-built FEX (see FEX_BUILD_INFO)"
	done
	_fresh_info="$_fresh_dir/FEX_BUILD_INFO"
	if [ -s "$_fresh_info" ]; then
		mkdir -p "./share/doc/hangover-libarm64ecfex"
		cp "$_fresh_info" "./share/doc/hangover-libarm64ecfex/FEX_BUILD_INFO"
		echo "install-fex-backends: embedded FEX_BUILD_INFO -- $(tr '\n' ' ' < "$_fresh_info")"
	fi

	# wowbox64.dll (Box64) is unaffected by the FEX bump; still comes from the
	# 2nd source tar bundled in Hangover's release (hangover_<ver>_ubuntu2204_
	# jammy_arm64.tar). Prefer the copy termux already unpacked into
	# $TERMUX_PKG_SRCDIR; fall back to extracting it from the cached source tar,
	# so we never depend on where termux chose to unpack the 2nd source.
	local _stage="$TERMUX_PKG_TMPDIR/fex-debs"
	rm -rf "$_stage"; mkdir -p "$_stage"
	local _bundle _type _deb _tmp
	_bundle="$(find "$TERMUX_PKG_CACHEDIR" "$TERMUX_PKG_TMPDIR" -maxdepth 2 -name 'hangover_*_arm64.tar' 2>/dev/null | head -n1)"
	for _type in wowbox64; do
		_deb="$(find "$TERMUX_PKG_SRCDIR" -maxdepth 4 -name "hangover-${_type}_*_arm64.deb" 2>/dev/null | head -n1)"
		if [ -z "$_deb" ] && [ -n "$_bundle" ]; then
			tar -C "$_stage" -xf "$_bundle" --wildcards "hangover-${_type}_*_arm64.deb" 2>/dev/null || true
			_deb="$(find "$_stage" -name "hangover-${_type}_*_arm64.deb" 2>/dev/null | head -n1)"
		fi
		[ -n "$_deb" ] || termux_error_exit "FEX install: cannot locate hangover-${_type}_*_arm64.deb (searched \$TERMUX_PKG_SRCDIR and the cached source tar)"
		_tmp="$TERMUX_PKG_TMPDIR/fex-extract-$_type"
		rm -rf "$_tmp"; mkdir -p "$_tmp"
		( cd "$_tmp" && ar -x "$_deb" && for _d in data.tar.*; do tar xf "$_d"; done )
		install -Dm644 "$_tmp/usr/lib/wine/aarch64-windows/${_type}.dll" "$_winedir/${_type}.dll"
		[ -s "$_winedir/${_type}.dll" ] || termux_error_exit "FEX install: ${_type}.dll missing/empty after install"
		echo "install-fex-backends: packaged ${_type}.dll ($(stat -c%s "$_winedir/${_type}.dll") bytes) from $(basename "$_deb")"
	done
}
# <<< piperella: FEX WoW64 backends (post_massage) <<<
EOF

echo "install-fex-backends: appended termux_step_post_massage override to $F"
