#!/usr/bin/env bash
#
# enable-pulseaudio.sh — idempotently give the Termux `hangover-wine` recipe a
# working audio backend by building winepulse.drv and shipping the PulseAudio
# runtime.
#
# THE BUG
# -------
# The upstream Termux hangover-wine recipe builds with no sound backend, so on
# device mmdevapi finds no driver:
#   err:mmdevapi:init_driver No driver from L"pulse,alsa,oss,coreaudio" could be found
# and Steam/games are silent.
#
# THE FIX
# -------
# Termux ships everything in one package, `pulseaudio` (17.0): it is the merged
# dev+runtime package (`libpulseaudio-dev`/`libpulseaudio` are its BREAKS/REPLACES
# aliases) providing pulse/pulseaudio.h + libpulse.pc + libpulse.so, the daemon
# bin/pulseaudio, and Android sink modules (module-sles-sink, module-aaudio-sink).
#
#   TERMUX_PKG_BUILD_DEPENDS += pulseaudio
#       -> Wine's configure autodetects libpulse (WINE_PACKAGE_FLAGS(PULSE,...)
#          + pulse/pulseaudio.h + pa_stream_is_corked) and enables winepulse.drv.
#          Wine builds pulse by default; only --without-pulse disables it, and the
#          recipe passes no such flag, so the build dep alone is sufficient.
#   TERMUX_PKG_DEPENDS       += pulseaudio
#       -> declares the runtime dependency, so fetch-runtime-deps.sh pulls the
#          pulseaudio .deb and its closure (dbus, libsndfile, libsoxr, speexdsp,
#          libwebrtc-audio-processing, libltdl, libandroid-*) into the bundle.
#          This ships the runnable daemon + libpulse (which winepulse.so links)
#          so the app can start a PulseAudio daemon with an OpenSL ES / AAudio
#          sink and point Wine at it via $PULSE_SERVER.
#
# Idempotent and word-boundary guarded, so re-running and upstream recipe updates
# are safe. Modelled on patches/enable-wayland.sh.
#
# Usage: enable-pulseaudio.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: enable-pulseaudio.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "enable-pulseaudio: no such file: $F" >&2; exit 1; }

# add_pkg VAR pkg — append `pkg` to a TERMUX_PKG_*="comma, list" assignment,
# creating the assignment if it doesn't exist. Word-boundary match avoids
# double-adding.
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
	sed -i -E "s/^(${var}=\"[^\"]*)\"/\1, ${pkg}\"/" "$F"
	echo "  + ${var} : ${pkg}"
}

add_pkg TERMUX_PKG_BUILD_DEPENDS pulseaudio
add_pkg TERMUX_PKG_DEPENDS       pulseaudio

echo "enable-pulseaudio: done."
