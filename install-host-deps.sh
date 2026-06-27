#!/usr/bin/env bash
#
# install-host-deps.sh — install the host build dependencies for a *native*
# (no-Docker) termux-packages build, robust across Ubuntu versions.
#
# termux-packages' own scripts/setup-ubuntu.sh targets the bleeding-edge Ubuntu
# its CI image pins (it wants clang-21, gcc-15, coreutils-from-uutils, full i386
# multiarch, ...). On an older host (e.g. Ubuntu 24.04 "noble") those exact
# versions don't exist, so a verbatim run fails. This wrapper:
#
#   1. Pins the host LLVM to whatever major version IS installed/available
#      (HOST_LLVM_VERSION, default: autodetected) instead of the hardcoded 21.
#   2. Drops the apt.llvm.org repo line (its codename 404s on older releases;
#      the distro's own clang/lld/llvm packages are used instead).
#   3. Installs only packages the host's apt actually knows about, skipping the
#      newer-Ubuntu-only ones (and the `:i386` *architecture* packages — Wine's
#      32-bit host tools build via multilib: g++-multilib + libc6-dev-i386).
#
# On the Ubuntu version termux targets, prefer their script directly; this is
# the compatibility shim for everything older.
#
# USAGE
#   ./install-host-deps.sh <path-to/.work/termux-packages>
#   HOST_LLVM_VERSION=18 ./install-host-deps.sh .work/termux-packages
set -euo pipefail

SRC="${1:?usage: install-host-deps.sh <termux-packages-dir>}"
SETUP="$SRC/scripts/setup-ubuntu.sh"
[ -f "$SETUP" ] || { echo "no setup-ubuntu.sh under $SRC" >&2; exit 1; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Pick an LLVM major version that exists on this host.
if [ -z "${HOST_LLVM_VERSION:-}" ]; then
	HOST_LLVM_VERSION=""
	for v in 21 20 19 18 17; do
		if command -v "clang-$v" >/dev/null 2>&1 || apt-cache policy "clang-$v" 2>/dev/null | grep -q 'Candidate:'; then
			HOST_LLVM_VERSION="$v"; break
		fi
	done
	[ -n "$HOST_LLVM_VERSION" ] || { echo "no clang-NN found/available on host" >&2; exit 1; }
fi
log "Host LLVM major version: $HOST_LLVM_VERSION"

# Collect the PACKAGES the recipe wants, substitute the LLVM version, drop the
# :i386 arch packages, then keep only what apt can actually resolve here.
mapfile -t WANT < <(
	grep -oE 'PACKAGES\+=" [^"]+"' "$SETUP" \
		| sed -E 's/PACKAGES\+=" //; s/"$//' \
		| tr ' ' '\n' \
		| sed "s/\${TERMUX_HOST_LLVM_MAJOR_VERSION}/$HOST_LLVM_VERSION/g; s/libclang-rt-17/libclang-rt-$HOST_LLVM_VERSION/g" \
		| grep -vE ':i386$' | grep -v '^$' | sort -u
)
# The LLVM toolchain packages (the recipe adds these separately).
WANT+=( "clang-$HOST_LLVM_VERSION" "lld-$HOST_LLVM_VERSION" \
        "llvm-$HOST_LLVM_VERSION-dev" "llvm-$HOST_LLVM_VERSION-tools" )

log "Resolving ${#WANT[@]} candidate packages against apt"
$([ "$(id -u)" = 0 ] || echo sudo) apt-get -yq update >/dev/null 2>&1 || true

avail=(); skip=()
for p in "${WANT[@]}"; do
	# strip arch-qualified middle entries like 'libnss3:i386' that slipped through
	p="${p%%:i386}"
	if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate:'; then avail+=("$p"); else skip+=("$p"); fi
done
log "Installing ${#avail[@]} packages (${#skip[@]} unavailable on this Ubuntu, skipped)"
[ "${#skip[@]}" -gt 0 ] && printf '    skipped: %s\n' "${skip[*]}"

SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
$SUDO env DEBIAN_FRONTEND=noninteractive \
	apt-get install -yq --no-install-recommends "${avail[@]}"

log "Host deps installed. Export for the build:  HOST_LLVM_VERSION=$HOST_LLVM_VERSION"
