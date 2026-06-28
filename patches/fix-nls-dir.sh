#!/usr/bin/env bash
#
# fix-nls-dir.sh — make wineserver locate its NLS / install dir independently of
# /proc/self/exe, so it works under the Piperella app's API-36 launch.
#
# WHY
# ---
# The app must launch Wine via `/system/bin/linker64 <wine>` (Android API 36
# W^X), so inside the process /proc/self/exe is /system/bin/linker64, not the
# wine binary. The wine *process* copes (dlls/ntdll/unix/loader.c init_paths()
# locates the install tree from dladdr() of ntdll.so, which is correct), but the
# standalone *wineserver* binary does not: server/unicode.c get_nls_dir() reads
# realpath("/proc/self/exe") and re-roots DATADIR/wine/nls under /system/...,
# then falls back to the compiled-in absolute $TERMUX_PREFIX/.../share/wine/nls
# — neither exists in a non-Termux app, so wineserver aborts with
# "failed to load l_intl.nls" even though the file ships in the .deb.
#
# WHAT
# ----
# Patch get_nls_dir() to derive the install dir from $WINELOADER (the app sets
# it to the real wine binary, an absolute path in the same bin/ dir as
# wineserver) or, failing that, wineserver's own argv0, before falling back to
# the original /proc/self/exe logic. build_relative_path() then re-roots
# DATADIR/wine/nls at the real bin dir -> the actual .../share/wine/nls. This is
# the single root fix for the wineserver side; the wine process already resolves
# its dll/data/nls dirs correctly via dladdr().
#
# Implemented as a new termux patch dropped into the hangover-wine recipe dir
# (server/unicode.c is not touched by any existing termux patch). Idempotent:
# re-running is a no-op; a fresh termux clone gets the patch written each build.
#
# Usage: fix-nls-dir.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-nls-dir.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-nls-dir: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0900-piperella-fix-nls-loader-dir.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = NLS loader-dir patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/server/unicode.c
+++ b/server/unicode.c
@@ -278,7 +278,15 @@
 static char *get_nls_dir(void)
 {
     char *p, *dir, *ret;
+    const char *_loader = getenv( "WINELOADER" );

+    /* Piperella: under an Android linker64 launch /proc/self/exe is the loader,
+       not wine, so prefer $WINELOADER (set by the app to the real wine binary)
+       or our own argv0 to locate the install tree, then fall back. */
+    dir = (_loader && _loader[0] == '/') ? realpath( _loader, NULL ) : NULL;
+    if (!dir && server_argv0 && server_argv0[0] == '/') dir = realpath( server_argv0, NULL );
+    if (!dir)
+    {
 #if defined(__linux__) || defined(__FreeBSD_kernel__) || defined(__NetBSD__)
     dir = realpath( "/proc/self/exe", NULL );
 #elif defined (__FreeBSD__) || defined(__DragonFly__)
@@ -307,6 +315,7 @@
 #else
     dir = realpath( server_argv0, NULL );
 #endif
+    }
     if (!dir) return NULL;
     if (!(p = strrchr( dir, '/' )))
     {
PATCH

echo "  + wrote $(basename "$OUT") (wineserver NLS dir via \$WINELOADER/argv0)"
echo "fix-nls-dir: done."
