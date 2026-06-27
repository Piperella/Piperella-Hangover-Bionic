#!/usr/bin/env bash
#
# fetch-runtime-deps.sh — download the bionic runtime-dependency .debs that
# hangover-wine links against, from the Termux apt repository, for arm64.
#
# hangover-wine is bionic, so it does NOT depend on glibc — but it DOES link
# against a closure of Termux bionic libraries (libc++, fontconfig, freetype,
# libandroid-spawn, wayland, libxkbcommon, vulkan-loader, the libX* shims, ...).
# Android's /system/bin/linker64 resolves these via LD_LIBRARY_PATH at launch,
# so the app must ship them next to the hangover-wine tree.
#
# This resolves the dependency closure from the repo's Packages index and
# downloads every .deb into out/deps/.  Re-run after a hangover-wine rebuild if
# the dependency set changed.
#
# USAGE
#   ./fetch-runtime-deps.sh
#   ARCH=aarch64 ./fetch-runtime-deps.sh
#   TERMUX_MIRROR=https://packages.termux.dev/apt/termux-main ./fetch-runtime-deps.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${OUTPUT:-$HERE/out/deps}"
ARCH="${ARCH:-aarch64}"
MIRROR="${TERMUX_MIRROR:-https://packages.termux.dev/apt}"

# Termux splits packages across repos with different distribution names.  Our
# closure spans both: libc++/fontconfig/freetype/libandroid-spawn/libwayland live
# in termux-main; hangover-wine/sdl2/xorg-*/libxkbcommon live in termux-x11.
# "<repo>:<dist>" — Packages path is <repo>/dists/<dist>/main/binary-<arch>/.
REPOS=("termux-main:stable" "termux-x11:x11")

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
mkdir -p "$OUTPUT"

# Direct runtime deps of hangover-wine.  Prefer reading them live from the recipe
# (so this never drifts from upstream / our patch); fall back to a known-good
# list if no recipe is given.  Point RECIPE at the patched hangover-wine build.sh:
#   RECIPE=.work/termux-packages/x11-packages/hangover-wine/build.sh ./fetch-runtime-deps.sh
# Build-only deps (libwayland-protocols, *-cross-scanner, *-static, *-generic) are
# stripped — they are not needed at runtime.
RECIPE="${RECIPE:-$HERE/.work/termux-packages/x11-packages/hangover-wine/build.sh}"
if [ -f "$RECIPE" ]; then
	mapfile -t ROOTS < <(
		( . "$RECIPE" >/dev/null 2>&1; echo "$TERMUX_PKG_DEPENDS" ) \
			| tr ',' '\n' | sed 's/[[:space:]]//g' \
			| grep -vE -- '-static$|-generic$|^libwayland-protocols$|-cross-scanner$' \
			| grep -v '^$' | sort -u
	)
fi
if [ "${#ROOTS[@]}" -eq 0 ]; then
	ROOTS=(
		fontconfig freetype krb5 libandroid-spawn libc++ libgmp libgnutls
		libxcb libxcomposite libxcursor libxfixes libxrender opengl pulseaudio
		sdl2 vulkan-loader xorg-xrandr libwayland libxkbcommon
	)
fi

# 1. Fetch + merge each repo's index into "name|baseurl|filename|deps" records.
#    `baseurl` is per-repo so downloads hit the right pool.  Strip version
#    constraints and alternatives ('a | b' -> 'a') from Depends.
RECORDS="$OUTPUT/.records"
: > "$RECORDS"
for entry in "${REPOS[@]}"; do
	repo="${entry%%:*}"; dist="${entry##*:}"
	base="$MIRROR/$repo"
	idx="$OUTPUT/.Packages.$repo"
	if [ ! -s "$idx" ]; then
		log "Fetching $repo index ($ARCH)"
		if ! curl -fsSL "$base/dists/$dist/main/binary-$ARCH/Packages" -o "$idx"; then
			curl -fsSL "$base/dists/$dist/main/binary-$ARCH/Packages.gz" -o "$idx.gz" \
				|| die "could not fetch index for $repo"
			gunzip -f "$idx.gz"
		fi
	fi
	awk -v base="$base" '
		function flush() {
			if (name != "") {
				gsub(/\([^)]*\)/, "", dep); gsub(/ /, "", dep);
				n = split(dep, a, ",");
				d = "";
				for (i = 1; i <= n; i++) { split(a[i], b, "|"); d = d (d==""?"":",") b[1]; }
				print name "|" base "|" file "|" d;
			}
			name=""; file=""; dep="";
		}
		/^Package:/      { flush(); name=$2 }
		/^Filename:/     { file=$2 }
		/^Depends:/      { sub(/^Depends:[ \t]*/,""); dep=$0 }
		END { flush() }
	' "$idx" >> "$RECORDS"
done

# field NAME COL — first matching record wins (main repo listed before x11).
field() { awk -F'|' -v k="$1" -v c="$2" '$1==k{print $c; exit}' "$RECORDS"; }

# 2b. BFS the dependency closure.
declare -A seen
queue=("${ROOTS[@]}")
closure=()
while [ "${#queue[@]}" -gt 0 ]; do
	pkg="${queue[0]}"; queue=("${queue[@]:1}")
	[ -n "${seen[$pkg]:-}" ] && continue
	seen[$pkg]=1
	file="$(field "$pkg" 3)"
	if [ -z "$file" ]; then
		printf '\033[1;33m  ! %s — not in index (skipped)\033[0m\n' "$pkg"
		continue
	fi
	closure+=("$pkg")
	deps="$(field "$pkg" 4)"
	IFS=',' read -ra ds <<< "$deps"
	for d in "${ds[@]}"; do [ -n "$d" ] && [ -z "${seen[$d]:-}" ] && queue+=("$d"); done
done

log "Dependency closure: ${#closure[@]} packages"

# 3. Download each .deb from its owning repo.
for pkg in "${closure[@]}"; do
	base="$(field "$pkg" 2)"; file="$(field "$pkg" 3)"
	dest="$OUTPUT/$(basename "$file")"
	if [ -s "$dest" ]; then
		printf '  = %s (cached)\n' "$pkg"
	else
		printf '  + %s\n' "$pkg"
		curl -fsSL "$base/$file" -o "$dest" || die "download failed: $pkg ($base/$file)"
	fi
done

log "Done. Runtime dependency .debs in $OUTPUT:"
ls -la "$OUTPUT"/*.deb 2>/dev/null | wc -l | xargs printf '  %s .deb files\n'
