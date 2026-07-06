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
# call-dispatch thunk. That's FEX-Emu/FEX issue #4493, fixed by PR #4767
# (commit 7d818e18be0c8e4d759da4faf24d0eb33c30aa71), which landed in FEX
# upstream after the 2605 tag. FEX-2603 and FEX-2605 themselves also carry
# separate required fixes (CEF io_uring/fd ABI break, suspend-doorbell race).
# FEX ships no prebuilt Windows dll as a release asset (source only), so the
# only way to get the fix is to build the arm64ec/wow64 targets ourselves.
#
# WHAT
# ----
# Resolves the latest FEX-Emu/FEX release tag (override with FEX_TAG), hard-
# gates that its numeric suffix is >= 2605 and that its history contains the
# #4767 fix commit, then builds the `arm64ecfex` and `wow64fex` CMake targets
# with the exact toolchain/flags Hangover's own (Docker-based) release CI uses
# for these targets (.packaging/ubuntu2204/fexpe{,ec}/Dockerfile in
# AndreRH/hangover): the `bylaws/llvm-mingw` fork (FEX requires this fork's
# arm64ec-w64-mingw32 support), FEX's own Data/CMake/toolchain_mingw.cmake,
# MINGW_TRIPLE=arm64ec-w64-mingw32 / aarch64-w64-mingw32, Release build,
# BUILD_TESTING=False. wowbox64.dll (Box64) is untouched -- this task only
# concerns the two FEX backends.
#
# USAGE
#   ./build-fex-arm64ec.sh [output-dir]      # default output-dir: ./out/fex
#   FEX_TAG=FEX-2608 ./build-fex-arm64ec.sh   # override the resolved tag
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$HERE/out/fex}"
WORKDIR="${WORKDIR:-$HERE/.work/fex-build}"
MIN_FEX_NUM=2605
FIX_4493_COMMIT="7d818e18be0c8e4d759da4faf24d0eb33c30aa71"  # PR #4767, fixes issue #4493
LLVM_MINGW_VER="20240929"
LLVM_MINGW_URL="https://github.com/bylaws/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-20.04-x86_64.tar.xz"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORKDIR" "$OUTPUT"

# 1. Resolve the FEX release tag to build (track latest unless overridden).
if [ -z "${FEX_TAG:-}" ]; then
	log "Resolving latest FEX-Emu/FEX release tag"
	# Capture curl's full output into a variable first, then parse it -- do NOT
	# pipe curl straight into grep/head: under `set -o pipefail`, a downstream
	# reader that exits early (e.g. `grep -m1`, `head -1`) closes the pipe while
	# curl is still writing, curl gets SIGPIPE and reports exit 23, and
	# pipefail+errexit then aborts the script even though the request succeeded.
	fex_api_json="$(curl -fsSL https://api.github.com/repos/FEX-Emu/FEX/releases/latest)"
	FEX_TAG="$(printf '%s' "$fex_api_json" | grep '"tag_name"' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')"
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

# 3. Hard gate: verify the checked-out tree actually contains the #4493 fix.
#    A shallow clone has no history to walk, so fetch just enough of it.
if ! git -C "$SRC" cat-file -e "$FIX_4493_COMMIT" 2>/dev/null; then
	git -C "$SRC" fetch --depth 200 origin "$FIX_4493_COMMIT" 2>/dev/null || \
		git -C "$SRC" fetch --unshallow origin 2>/dev/null || true
fi
if git -C "$SRC" merge-base --is-ancestor "$FIX_4493_COMMIT" HEAD 2>/dev/null; then
	log "Verified: $FEX_TAG contains the #4493/PR-4767 fix ($FIX_4493_COMMIT)"
else
	die "$FEX_TAG ($FEX_COMMIT) does NOT contain the required #4493 fix commit $FIX_4493_COMMIT -- refusing to build a still-broken FEX"
fi

# 4. Toolchain: FEX's arm64ec-w64-mingw32 target needs the bylaws/llvm-mingw
#    fork specifically (same one Hangover's own release CI uses) -- mainline
#    mstorsjo/llvm-mingw may lack full arm64ec-w64-mingw32 support.
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
cat > "$OUTPUT/FEX_BUILD_INFO" <<EOF
FEX_TAG=$FEX_TAG
FEX_COMMIT=$FEX_COMMIT
FEX_COMMIT_DATE=$FEX_COMMIT_DATE
FIX_4493_COMMIT=$FIX_4493_COMMIT
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "Done. FEX WoW64 backends in $OUTPUT:"
ls -la "$OUTPUT"
