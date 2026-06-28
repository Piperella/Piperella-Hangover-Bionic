#!/usr/bin/env bash
#
# fix-wineserver-dir.sh — make Wine's server/temp directory honor
# $XDG_RUNTIME_DIR (preferred) or $TMPDIR, and drop the unusable wine-preloader.
#
# WHY
# ---
# The Piperella app launches Wine via /system/bin/linker64 at targetSdk 36 with
# WINEPREFIX / XDG_RUNTIME_DIR / TMPDIR all pointed at its own writable dir. But
# wineboot --init fails: wineserver creates its socket/temp dir at a path baked
# in at build time, /data/data/com.termux/files/usr/tmp/.wine-<uid>, which can
# not exist in a non-Termux app (per-UID SELinux, no root).
#
# The Termux recipe's 0001-fix-paths.patch hardcodes that path in BOTH places
# that must agree — server/request.c (create_server_dir, the wineserver side)
# and dlls/ntdll/unix/server.c (init_server_dir, the client side) — by replacing
# Wine's "/tmp/.wine-%u" with "@TERMUX_PREFIX@/tmp/.wine-%u". Neither honors the
# environment, so the app's exported XDG_RUNTIME_DIR/TMPDIR are ignored.
#
# WHAT
# ----
# 1. Rewrite those two hardcoded lines in 0001-fix-paths.patch so the server dir
#    is chosen at runtime:
#        $XDG_RUNTIME_DIR/wine/server-<dev>-<ino>      if XDG_RUNTIME_DIR is abs
#        $TMPDIR/.wine-<uid>/server-<dev>-<ino>        else if TMPDIR is abs
#        /tmp/.wine-<uid>/server-<dev>-<ino>           else (upstream fallback)
#    Both files use identical logic so client and server still agree. We only
#    rewrite the content of the patch's added ('+') lines and keep them single
#    lines, so the unified-diff hunk offsets are untouched and the patch keeps
#    applying cleanly (patch verifies only context/removed lines).
#
# 2. Add --without-preloader: wine-preloader is a fixed-address ET_EXEC that
#    /system/bin/linker64 (PIE-only) cannot load and that cannot be execve'd at
#    API 36 (the app works around it today with WINELOADERNOEXEC=1). Building
#    without it removes the dead binary.
#
# Idempotent and overlay-update-safe: every edit is guarded by a presence check.
#
# Usage: fix-wineserver-dir.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-wineserver-dir.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-wineserver-dir: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
PATCH="$DIR/0001-fix-paths.patch"

# 1. --without-preloader into TERMUX_PKG_EXTRA_CONFIGURE_ARGS (anchor on the
#    --enable-archs= line, the last entry of that heredoc — same anchor used by
#    enable-wayland.sh).
if grep -q -- "--without-preloader" "$F"; then
	echo "  = configure : --without-preloader (already present)"
elif grep -q -- "--enable-archs=" "$F"; then
	sed -i -E "s|^(--enable-archs=)|--without-preloader\n\1|" "$F"
	echo "  + configure : --without-preloader"
else
	echo "fix-wineserver-dir: WARNING — no --enable-archs anchor; add --without-preloader manually." >&2
	exit 2
fi

# 2. Rewrite the hardcoded wineserver dir in 0001-fix-paths.patch.
[ -f "$PATCH" ] || { echo "fix-wineserver-dir: $PATCH not found (upstream layout changed?)" >&2; exit 1; }
if grep -q 'XDG_RUNTIME_DIR' "$PATCH"; then
	echo "  = wineserver dir : already honors XDG_RUNTIME_DIR/TMPDIR (already present)"
else
	python3 - "$PATCH" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

# dlls/ntdll/unix/server.c : init_server_dir  (client side; builds the full dir)
old1 = '''+    asprintf( &dir, "@TERMUX_PREFIX@/tmp/.wine-%u/server-%llx-%llx", getuid(), (unsigned long long)dev, (unsigned long long)ino );'''
new1 = '''+    do { const char *_x = getenv("XDG_RUNTIME_DIR"), *_t = getenv("TMPDIR"); int _r; if (_x && _x[0] == '/') _r = asprintf( &dir, "%s/wine/server-%llx-%llx", _x, (unsigned long long)dev, (unsigned long long)ino ); else if (_t && _t[0] == '/') _r = asprintf( &dir, "%s/.wine-%u/server-%llx-%llx", _t, getuid(), (unsigned long long)dev, (unsigned long long)ino ); else _r = asprintf( &dir, "/tmp/.wine-%u/server-%llx-%llx", getuid(), (unsigned long long)dev, (unsigned long long)ino ); (void)_r; } while (0);'''

# server/request.c : create_server_dir  (wineserver side; builds base_dir)
old2 = '''+    if (asprintf( &base_dir, "@TERMUX_PREFIX@/tmp/.wine-%u", getuid() ) == -1)'''
new2 = '''+    if (({ const char *_x = getenv("XDG_RUNTIME_DIR"), *_t = getenv("TMPDIR"); int _r; if (_x && _x[0] == '/') _r = asprintf( &base_dir, "%s/wine", _x ); else if (_t && _t[0] == '/') _r = asprintf( &base_dir, "%s/.wine-%u", _t, getuid() ); else _r = asprintf( &base_dir, "/tmp/.wine-%u", getuid() ); _r; }) == -1)'''

for old, new in ((old1, new1), (old2, new2)):
    if old not in s:
        sys.stderr.write("fix-wineserver-dir: expected line not found in patch:\n%s\n" % old)
        sys.exit(3)
    s = s.replace(old, new)

open(p, "w").write(s)
print("  + wineserver dir : rewritten to honor XDG_RUNTIME_DIR/TMPDIR (both server + ntdll)")
PY
fi

echo "fix-wineserver-dir: done."
