#!/usr/bin/env bash
#
# enable-wayland.sh — idempotently turn on the Wine Wayland driver in a
# termux-packages `hangover-wine` recipe.
#
# The upstream Termux recipe builds Hangover X11-only: it ships no libwayland at
# configure time, so Wine silently omits winewayland.drv.  Piperella needs that
# driver to talk to its compositor.  This patch adds:
#
#   TERMUX_PKG_DEPENDS        += libwayland, libxkbcommon   (runtime: client libs)
#   TERMUX_PKG_BUILD_DEPENDS  += libwayland, libwayland-protocols,
#                                libwayland-cross-scanner
#                                   (build: headers, protocol XML, cross scanner)
#   configure                 += --with-wayland
#
# NOTE on names: Termux ships the Wayland library as `libwayland` (not `wayland`),
# the protocol XML as `libwayland-protocols`, and the host wayland-scanner for
# cross builds as `libwayland-cross-scanner`.
#
# It is safe to run repeatedly and across upstream recipe updates: every edit is
# guarded by a presence check, so re-running is a no-op and a changed upstream
# recipe is re-patched cleanly.
#
# Usage: enable-wayland.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: enable-wayland.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "enable-wayland: no such file: $F" >&2; exit 1; }

# add_pkg VAR pkg — append `pkg` to a TERMUX_PKG_*="comma, list" assignment,
# creating the assignment if it doesn't exist yet.  Word-boundary match avoids
# double-adding (e.g. 'wayland' must not match inside 'wayland-protocols').
add_pkg() {
	local var="$1" pkg="$2"
	if ! grep -qE "^${var}=" "$F"; then
		echo "${var}=\"${pkg}\"" >> "$F"
		echo "  + ${var} (created) : ${pkg}"
		return
	fi
	if grep -E "^${var}=" "$F" | grep -qE "(^|[\"=, ])${pkg}([\", ]|\$)"; then
		echo "  = ${var} : ${pkg} (already present)"
		return
	fi
	# Insert before the closing quote of the VAR="...".
	sed -i -E "s/^(${var}=\"[^\"]*)\"/\1, ${pkg}\"/" "$F"
	echo "  + ${var} : ${pkg}"
}

add_pkg TERMUX_PKG_DEPENDS       libwayland
add_pkg TERMUX_PKG_DEPENDS       libxkbcommon
add_pkg TERMUX_PKG_BUILD_DEPENDS libwayland
add_pkg TERMUX_PKG_BUILD_DEPENDS libwayland-protocols
add_pkg TERMUX_PKG_BUILD_DEPENDS libwayland-cross-scanner

# Add `--with-wayland` into the TERMUX_PKG_EXTRA_CONFIGURE_ARGS heredoc.  We
# anchor on the `--enable-archs=` line, which is the last entry of that block.
if grep -q -- "--with-wayland" "$F"; then
	echo "  = configure : --with-wayland (already present)"
elif grep -q -- "--enable-archs=" "$F"; then
	sed -i -E "s|^(--enable-archs=)|--with-wayland\n\1|" "$F"
	echo "  + configure : --with-wayland"
else
	echo "enable-wayland: WARNING — could not find --enable-archs anchor;" >&2
	echo "                add --with-wayland to the configure args manually." >&2
	exit 2
fi

echo "enable-wayland: done."
