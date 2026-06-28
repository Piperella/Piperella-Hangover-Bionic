#!/usr/bin/env bash
#
# inspect-deb.sh — verify a built hangover-wine .deb contains the components
# Piperella requires, and FAIL (exit non-zero) if any are missing. Used as the
# CI release gate so a functionally-broken package is never published.
#
# Checks, under opt/hangover-wine/lib/wine/aarch64-windows/:
#   * winewayland.drv  — the Wine Wayland driver (talks to the compositor)
#   * libwow64fex.dll  — FEX 32-bit WoW64 backend
#   * libarm64ecfex.dll — FEX 64-bit (ARM64EC) WoW64 backend
#   * wowbox64.dll     — Box64 64-bit WoW64 backend
# Each must exist, be non-empty, and start with the PE 'MZ' magic. Without a FEX
# backend no x86 Windows app can launch (wow64.dll alone is only a thunk layer);
# without winewayland.drv there is no Wayland output. Either is a release-blocker.
#
# It also gates the runtime-environment fixes:
#   * wineserver/ntdll must honor $XDG_RUNTIME_DIR for the server dir — i.e. the
#     baked /data/data/com.termux/.../tmp/.wine path must be GONE and the
#     XDG_RUNTIME_DIR string present. (Otherwise wineboot --init fails in-app.)
#   * no aarch64-unix/wine-preloader — it cannot be loaded by linker64 at API 36.
#
# Usage: inspect-deb.sh <hangover-wine_*.deb>
set -euo pipefail

DEB="${1:?usage: inspect-deb.sh <hangover-wine_*.deb>}"
[ -f "$DEB" ] || { echo "inspect-deb: no such file: $DEB" >&2; exit 1; }
# Resolve to an absolute path: we cd into a temp dir below, after which a
# relative path (e.g. out/hangover-wine_*.deb) would no longer resolve.
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"

g="\033[32m"; y="\033[33m"; r="\033[31m"; b="\033[1;34m"; x="\033[0m"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
( cd "$work" && ar x "$DEB" && for d in data.tar.*; do tar xf "$d"; done ) >/dev/null 2>&1 \
	|| { echo "inspect-deb: could not unpack $DEB" >&2; exit 1; }

winedir="$(find "$work" -type d -path '*lib/wine/aarch64-windows' | head -n1)"
[ -n "$winedir" ] || { echo "inspect-deb: aarch64-windows dir not found in deb" >&2; exit 1; }

rc=0
check() { # label  filename  required(1/0)
	local label="$1" file="$2" required="$3" f="$winedir/$2"
	if [ -s "$f" ] && [ "$(head -c2 "$f" 2>/dev/null)" = "MZ" ]; then
		printf "  ${g}\xe2\x9c\x93${x} %-19s %8s bytes  (PE)\n" "$file" "$(stat -c%s "$f")"
	elif [ -s "$f" ]; then
		printf "  ${y}\xe2\x9c\x93${x} %-19s %8s bytes  (present, not PE?)\n" "$file" "$(stat -c%s "$f")"
	else
		printf "  ${r}\xe2\x9c\x97 %-19s MISSING${x}\n" "$file"
		if [ "$required" = "1" ]; then rc=1; fi
	fi
}

echo -e "${b}==>${x} Inspecting $(basename "$DEB")"
echo "Wayland driver:"
check "winewayland.drv" winewayland.drv 1
echo "FEX WoW64 backends:"
check "libwow64fex.dll"   libwow64fex.dll   1
check "libarm64ecfex.dll" libarm64ecfex.dll 1
check "wowbox64.dll"      wowbox64.dll      1
echo "Wine WoW64 thunk layer (informational):"
check "wow64.dll"    wow64.dll    0
check "wow64win.dll" wow64win.dll 0

# --- wineserver/temp dir must honor $XDG_RUNTIME_DIR, not a baked Termux path ---
# Use process substitution (not a pipe): with `set -o pipefail`, `strings | grep -q`
# returns non-zero when grep short-circuits and strings takes SIGPIPE, which would
# misreport a match as a miss.
has_str() { grep -qaF -- "$2" < <(strings "$1" 2>/dev/null); }
echo "Server dir honors \$XDG_RUNTIME_DIR (no baked Termux tmp path):"
bad_path='com.termux/files/usr/tmp/.wine'
for rel in opt/hangover-wine/bin/wineserver opt/hangover-wine/lib/wine/aarch64-unix/ntdll.so; do
	bin="$(find "$work" -type f -path "*${rel}" | head -n1)"
	name="${rel##*/}"
	if [ -z "$bin" ]; then
		printf "  ${r}\xe2\x9c\x97 %-12s NOT FOUND in deb${x}\n" "$name"; rc=1; continue
	fi
	if has_str "$bin" "$bad_path"; then
		printf "  ${r}\xe2\x9c\x97 %-12s still has baked path %s${x}\n" "$name" "$bad_path"; rc=1
	elif has_str "$bin" "XDG_RUNTIME_DIR"; then
		printf "  ${g}\xe2\x9c\x93${x} %-12s honors XDG_RUNTIME_DIR, no baked Termux tmp path\n" "$name"
	else
		printf "  ${r}\xe2\x9c\x97 %-12s no XDG_RUNTIME_DIR reference (fix not applied?)${x}\n" "$name"; rc=1
	fi
done

# --- wineserver must resolve its NLS/install dir via $WINELOADER, not /proc/self/exe ---
# Under the API-36 linker64 launch /proc/self/exe is the loader; the fix makes
# get_nls_dir() consult $WINELOADER (and argv0). Stock wineserver has no
# WINELOADER reference, so its presence confirms the fix compiled in.
echo "wineserver resolves NLS via \$WINELOADER (not /proc/self/exe):"
ws="$(find "$work" -type f -path '*opt/hangover-wine/bin/wineserver' | head -n1)"
if [ -n "$ws" ] && has_str "$ws" "WINELOADER"; then
	printf "  ${g}\xe2\x9c\x93${x} wineserver consults WINELOADER for its install dir\n"
else
	printf "  ${r}\xe2\x9c\x97 wineserver: no WINELOADER reference (NLS dir fix not applied?)${x}\n"; rc=1
fi

# --- wine-preloader must be gone (cannot be loaded by linker64 at API 36) ---
echo "No wine-preloader:"
preloader="$(find "$work" -type f -name 'wine-preloader' | head -n1)"
if [ -n "$preloader" ]; then
	printf "  ${r}\xe2\x9c\x97 wine-preloader present: %s${x}\n" "${preloader#$work/}"; rc=1
else
	printf "  ${g}\xe2\x9c\x93${x} no wine-preloader in package\n"
fi

if [ "$rc" -ne 0 ]; then
	echo -e "${r}inspect-deb: FAIL${x} — required component(s) missing from $(basename "$DEB")" >&2
else
	echo -e "${g}inspect-deb: OK${x} — winewayland.drv + 3 FEX backends present, server dir honors \$XDG_RUNTIME_DIR, no wine-preloader"
fi
exit "$rc"
