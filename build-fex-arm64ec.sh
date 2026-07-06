#!/usr/bin/env bash
#
# build-fex-arm64ec.sh — build fresh libarm64ecfex.dll + libwow64fex.dll (the
# FEX WoW64 recompiler backends) from upstream FEX-Emu/FEX source, to replace
# the stale ones bundled in the Hangover release tarball.
#
# WHY
# ---
# Hangover 11.9's release bundle ships hangover-libarm64ecfex_11.9_arm64.deb /
# hangover-libwow64fex_11.9_arm64.deb built from FEX-2605. steam.exe's 64-bit
# client (arm64ec) crash-loops on that FEX: Chromium's CEF allocator calls
# VirtualAlloc(MEM_RESET) on code pages, and FEX-2605 wrongly strips execute
# permission in response, producing a later NX fault through the arm64ec
# call-dispatch thunk. That's FEX-Emu/FEX issue #4493, fixed by PR #4767 (two
# commits, cd1cf6f615 + 52af0aceea, authored 2025-08-07) which is present in
# FEX-2607's tagged source. FEX-2603 and FEX-2605 themselves also carry
# separate required fixes (CEF io_uring/fd ABI break, suspend-doorbell race).
# FEX ships no prebuilt Windows dll as a release asset (source only), so the
# only way to get the fix is to build the arm64ec/wow64 targets ourselves.
#
# WHAT
# ----
# Resolves the latest FEX-Emu/FEX release tag (override with FEX_TAG) and the
# latest bylaws/llvm-mingw release (override with LLVM_MINGW_VER) -- both
# tracked at latest, never hardcoded to a snapshot, since FEX's Windows headers
# and the mingw headers they build against evolve together; pinning one while
# tracking the other latest eventually desyncs (see the LLVM_MINGW_VER section
# below for a concrete case of this actually happening). Hard-gates that FEX's
# numeric suffix is >= 2605 and that its checked-out source contains the #4767
# fix (by content, see FIX_4493_PATTERN below), then builds the `arm64ecfex`
# and `wow64fex` CMake targets with the same flags Hangover's own (Docker-
# based) release CI uses for these targets (.packaging/ubuntu2204/fexpe{,ec}/
# Dockerfile in AndreRH/hangover): FEX's own Data/CMake/toolchain_mingw.cmake,
# MINGW_TRIPLE=arm64ec-w64-mingw32 / aarch64-w64-mingw32, Release build,
# BUILD_TESTING=False. wowbox64.dll (Box64) is untouched -- this task only
# concerns the two FEX backends.
#
# USAGE
#   ./build-fex-arm64ec.sh [output-dir]        # default output-dir: ./out/fex
#   FEX_TAG=FEX-2608 ./build-fex-arm64ec.sh     # override the resolved FEX tag
#   LLVM_MINGW_VER=20250920 ./build-fex-arm64ec.sh   # override the toolchain
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$HERE/out/fex}"
WORKDIR="${WORKDIR:-$HERE/.work/fex-build}"
MIN_FEX_NUM=2605
# PR #4767 (issue #4493) landed as two real commits, cd1cf6f615 ("ARM64EC: Drop
# redundant ThreadCreationMutex locks") and 52af0aceea ("Windows: Ignore
# MEM_RESET(_UNDO) allocation protection notifications"), merged 2025-08-07.
# We verify by CONTENT, not by commit-SHA ancestry: upstream commit hashes can
# differ across rebases/cherry-picks even when the code is identical (this bit
# us in practice -- a merge-commit SHA sourced from web research turned out not
# to be an ancestor of the FEX-2607 tag via `git merge-base`, even though the
# tagged source verifiably contains the exact fixed code). The fix's
# unmistakable fingerprint is this guard added to both Windows memory-
# notification handlers, so MEM_RESET(_UNDO) no longer strips exec permission:
FIX_4493_PATTERN='Type & (MEM_RESET | MEM_RESET_UNDO)'
FIX_4493_FILES="Source/Windows/ARM64EC/Module.cpp Source/Windows/WOW64/Module.cpp"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORKDIR" "$OUTPUT"

# 1. Resolve the FEX release tag to build (track latest unless overridden).
if [ -z "${FEX_TAG:-}" ]; then
	log "Resolving latest FEX-Emu/FEX release tag"
	# Capture curl's full output into a variable first, then parse it -- do NOT
	# pipe curl straight into a downstream reader that exits early: under
	# `set -o pipefail`, that closes the pipe while curl is still writing, curl
	# gets SIGPIPE and reports exit 23, and pipefail+errexit then aborts the
	# script even though the request succeeded. Parse with an actual JSON
	# parser (python3), not grep/sed text matching: fields that appear more
	# than once per response (e.g. browser_download_url, one per asset, used
	# below for llvm-mingw) can't be reliably picked out by a regex without
	# knowing whether the API returned pretty-printed or compact JSON --
	# json.load has no such ambiguity.
	fex_api_json="$(curl -fsSL https://api.github.com/repos/FEX-Emu/FEX/releases/latest)"
	FEX_TAG="$(printf '%s' "$fex_api_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
	[ -n "$FEX_TAG" ] || die "could not resolve latest FEX release tag from the GitHub API"
fi
log "FEX tag: $FEX_TAG"

fex_num="$(echo "$FEX_TAG" | grep -oE '[0-9]+' | head -1)"
[ -n "$fex_num" ] || die "could not parse a numeric version out of FEX tag '$FEX_TAG'"
[ "$fex_num" -ge "$MIN_FEX_NUM" ] || die "FEX tag '$FEX_TAG' ($fex_num) is older than the hard minimum FEX-$MIN_FEX_NUM"
log "Version check OK: $FEX_TAG ($fex_num) >= FEX-$MIN_FEX_NUM"

# 2. Clone FEX at that tag.
SRC="$WORKDIR/FEX"
if [ ! -d "$SRC/.git" ]; then
	log "Cloning FEX-Emu/FEX @ $FEX_TAG (shallow, with submodules)"
	git clone --depth 1 --branch "$FEX_TAG" --recurse-submodules --shallow-submodules \
		https://github.com/FEX-Emu/FEX.git "$SRC"
else
	log "Reusing existing checkout in $SRC"
fi

FEX_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
FEX_COMMIT_DATE="$(git -C "$SRC" log -1 --format=%cI)"
log "FEX commit: $FEX_COMMIT ($FEX_COMMIT_DATE)"

# 3. Hard gate: verify the checked-out tree actually contains the #4493 fix,
#    by content. See FIX_4493_PATTERN above for why this checks source content
#    rather than commit-SHA ancestry.
fix_found=0
for f in $FIX_4493_FILES; do
	if [ -f "$SRC/$f" ] && grep -qF "$FIX_4493_PATTERN" "$SRC/$f"; then
		log "  found fix pattern in $f"
		fix_found=$((fix_found + 1))
	else
		log "  fix pattern NOT found in $f"
	fi
done
[ "$fix_found" -eq "$(echo $FIX_4493_FILES | wc -w)" ] || \
	die "$FEX_TAG ($FEX_COMMIT) is missing the #4493 MEM_RESET fix (PR #4767) in one or more of: $FIX_4493_FILES -- refusing to build a still-broken FEX"
log "Verified: $FEX_TAG contains the #4493/PR-4767 MEM_RESET fix in all required files"

# 4. Toolchain: FEX's arm64ec-w64-mingw32 target needs the bylaws/llvm-mingw
#    fork specifically (same one Hangover's own release CI uses) -- mainline
#    mstorsjo/llvm-mingw may lack full arm64ec-w64-mingw32 support.
#
#    Resolve the LATEST bylaws/llvm-mingw release, same as FEX_TAG above --
#    do NOT hardcode a version here. A hardcoded toolchain snapshot pinned
#    against "whatever FEX looked like when this script was written" is
#    exactly the kind of skew this whole repo exists to avoid: FEX's own
#    Windows headers (Source/Windows/include/*.h) evolve alongside the mingw
#    headers they're built against, so tracking FEX's latest tag while pinning
#    the toolchain to a year-old snapshot WILL eventually desync -- e.g.
#    Source/Windows/include/winnt.h expecting IMAGE_LOAD_CONFIG_CODE_INTEGRITY
#    from mingw's headers, while an old llvm-mingw only provides
#    __IMAGE_LOAD_CONFIG_CODE_INTEGRITY under the pre-rename name.
#    (llvm-mingw's asset naming has also changed over time -- ubuntu-20.04 ->
#    ubuntu-22.04 -- so the URL pattern is resolved from the actual asset list,
#    not assumed.)
log "Resolving latest bylaws/llvm-mingw release"
llvm_mingw_api_json="$(curl -fsSL https://api.github.com/repos/bylaws/llvm-mingw/releases/latest)"
if [ -z "${LLVM_MINGW_VER:-}" ]; then
	LLVM_MINGW_VER="$(printf '%s' "$llvm_mingw_api_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
	[ -n "$LLVM_MINGW_VER" ] || die "could not resolve latest bylaws/llvm-mingw release tag from the GitHub API"
fi
# Pick the Linux x86_64 build (our runner's host arch). Asset naming has
# changed over time (ubuntu-20.04 -> ubuntu-22.04), so match on the stable
# substrings rather than assuming one specific base-OS tag.
LLVM_MINGW_URL="$(printf '%s' "$llvm_mingw_api_json" | python3 -c '
import json, sys, re
assets = json.load(sys.stdin)["assets"]
for a in assets:
    if re.search(r"ucrt-ubuntu-[\d.]+-x86_64\.tar\.xz$", a["name"]):
        print(a["browser_download_url"]); break
')"
[ -n "$LLVM_MINGW_URL" ] || die "could not find a ucrt-ubuntu-*-x86_64.tar.xz asset in bylaws/llvm-mingw $LLVM_MINGW_VER"
log "llvm-mingw: $LLVM_MINGW_VER ($LLVM_MINGW_URL)"

TOOLCHAIN_DIR="$WORKDIR/llvm-mingw-${LLVM_MINGW_VER}"
if [ ! -d "$TOOLCHAIN_DIR/bin" ]; then
	log "Downloading bylaws/llvm-mingw $LLVM_MINGW_VER"
	curl -fsSL "$LLVM_MINGW_URL" -o "$WORKDIR/llvm-mingw.tar.xz"
	mkdir -p "$TOOLCHAIN_DIR"
	tar -C "$TOOLCHAIN_DIR" --strip-components=1 -xJf "$WORKDIR/llvm-mingw.tar.xz"
	rm -f "$WORKDIR/llvm-mingw.tar.xz"
fi
export PATH="$TOOLCHAIN_DIR/bin:$PATH"
command -v arm64ec-w64-mingw32-clang >/dev/null || die "arm64ec-w64-mingw32-clang not found on PATH after toolchain setup"

# build_target TRIPLE CMAKE_TARGET OUTPUT_DLL BUILD_SUBDIR
build_target() {
	local triple="$1" target="$2" dll="$3" builddir="$WORKDIR/$4"
	log "Configuring FEX for $triple (target: $target)"
	cmake -S "$SRC" -B "$builddir" \
		-DCMAKE_BUILD_TYPE=Release \
		-DENABLE_JEMALLOC_GLIBC_ALLOC=False \
		-DENABLE_ASSERTIONS=False \
		-DCMAKE_TOOLCHAIN_FILE="$SRC/Data/CMake/toolchain_mingw.cmake" \
		-DENABLE_LTO=False \
		-DMINGW_TRIPLE="$triple" \
		-DTUNE_CPU=none \
		-DBUILD_TESTING=False \
		-G Ninja
	log "Building $target"
	cmake --build "$builddir" --target "$target" -- -j"$(nproc)"
	local built="$builddir/Bin/$dll"
	[ -s "$built" ] || die "$dll not produced at $built"
	"${triple}-strip" --strip-unneeded "$built"
	cp "$built" "$OUTPUT/$dll"
	log "Built $dll ($(stat -c%s "$OUTPUT/$dll") bytes)"
}

build_target arm64ec-w64-mingw32 arm64ecfex libarm64ecfex.dll build-ec
build_target aarch64-w64-mingw32 wow64fex   libwow64fex.dll   build-wow64

# 5. Record build metadata for the release gate and for shipping inside the .deb.
#    This file gets sourced (`. FEX_BUILD_INFO`) by both the CI workflow and
#    inspect-deb.sh, so every value must be a single shell "word" -- no spaces
#    unquoted -- or sourcing it will try to run the trailing words as commands.
fix_4493_files_csv="$(echo "$FIX_4493_FILES" | tr ' ' ',')"
cat > "$OUTPUT/FEX_BUILD_INFO" <<EOF
FEX_TAG=$FEX_TAG
FEX_COMMIT=$FEX_COMMIT
FEX_COMMIT_DATE=$FEX_COMMIT_DATE
FIX_4493_VERIFIED=content-match:$fix_4493_files_csv
LLVM_MINGW_VER=$LLVM_MINGW_VER
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "Done. FEX WoW64 backends in $OUTPUT:"
ls -la "$OUTPUT"
