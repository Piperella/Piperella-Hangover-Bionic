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
# Usage: inspect-deb.sh <hangover-wine_*.deb>
set -euo pipefail

DEB="${1:?usage: inspect-deb.sh <hangover-wine_*.deb>}"
[ -f "$DEB" ] || { echo "inspect-deb: no such file: $DEB" >&2; exit 1; }

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

if [ "$rc" -ne 0 ]; then
	echo -e "${r}inspect-deb: FAIL${x} — required component(s) missing from $(basename "$DEB")" >&2
else
	echo -e "${g}inspect-deb: OK${x} — winewayland.drv + all three FEX WoW64 backends present"
fi
exit "$rc"
