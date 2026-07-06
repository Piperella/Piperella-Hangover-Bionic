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
#   * libarm64ecfex.dll / libwow64fex.dll must be the freshly-built ones from
#     build-fex-arm64ec.sh (FEX >= 2605, containing the #4493 arm64ec/CEF
#     MEM_RESET fix) — NOT the stale FEX-2605 bundled in the Hangover release
#     tarball, which crash-loops Steam's 64-bit client. Gated by (a) a
#     FEX_BUILD_INFO metadata file shipped in the package and (b) the backend
#     DLLs' sha256 differing from the known-stale hashes.
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

# --- FEX backends must be the fresh build (>= FEX-2605, has the #4493 fix) ---
# Known-stale sha256 of the FEX-2605 DLLs bundled in the Hangover 11.9 release
# tarball (captured from our own build8 release before the fix): if a future
# build ever reproduces these exact bytes, the fresh-FEX step silently no-oped
# and the crash-causing backend shipped again.
STALE_ARM64ECFEX_SHA256="36d6d17089faee767c42c9e4fe57f80e1c65de7320d909ae8b1d3f201585d41f"
STALE_WOW64FEX_SHA256="d29099e1459471e5c1bbeb1a29d4273ac92657b6863c8d790ea4ab4557185490"
MIN_FEX_NUM=2605

echo "FEX backends are the freshly-built fix (not the stale bundled FEX-2605):"
info="$(find "$work" -type f -name FEX_BUILD_INFO | head -n1)"
if [ -z "$info" ]; then
	printf "  ${r}\xe2\x9c\x97 FEX_BUILD_INFO not found in package (fresh-FEX step didn't run?)${x}\n"; rc=1
else
	# shellcheck disable=SC1090
	( . "$info"
	  fex_num="$(echo "${FEX_TAG:-}" | grep -oE '[0-9]+' | head -1)"
	  if [ -z "$fex_num" ] || [ "$fex_num" -lt "$MIN_FEX_NUM" ]; then
		  printf "  ${r}\xe2\x9c\x97 FEX_BUILD_INFO reports FEX_TAG=%s (< FEX-%s)${x}\n" "${FEX_TAG:-?}" "$MIN_FEX_NUM"
		  exit 1
	  fi
	  [ -n "${FIX_4493_VERIFIED:-}" ] || { printf "  ${r}\xe2\x9c\x97 FEX_BUILD_INFO missing FIX_4493_VERIFIED record${x}\n"; exit 1; }
	  printf "  ${g}\xe2\x9c\x93${x} FEX_BUILD_INFO: %s (%s), %s\n" "$FEX_TAG" "${FEX_COMMIT:-?}" "$FIX_4493_VERIFIED"
	) || rc=1
fi

for pair in "libarm64ecfex.dll:$STALE_ARM64ECFEX_SHA256" "libwow64fex.dll:$STALE_WOW64FEX_SHA256"; do
	fname="${pair%%:*}"; stale="${pair##*:}"
	f="$winedir/$fname"
	if [ ! -s "$f" ]; then
		continue  # already reported missing by the earlier `check` block
	fi
	got="$(sha256sum "$f" | cut -d' ' -f1)"
	if [ "$got" = "$stale" ]; then
		printf "  ${r}\xe2\x9c\x97 %-19s is byte-identical to the known-stale FEX-2605 build${x}\n" "$fname"; rc=1
	else
		printf "  ${g}\xe2\x9c\x93${x} %-19s differs from the known-stale FEX-2605 build\n" "$fname"
	fi
done

if [ "$rc" -ne 0 ]; then
	echo -e "${r}inspect-deb: FAIL${x} — required component(s) missing from $(basename "$DEB")" >&2
else
	echo -e "${g}inspect-deb: OK${x} — winewayland.drv + 3 fresh FEX backends (>= FEX-$MIN_FEX_NUM, #4493 fix), server dir honors \$XDG_RUNTIME_DIR, no wine-preloader"
fi
exit "$rc"
