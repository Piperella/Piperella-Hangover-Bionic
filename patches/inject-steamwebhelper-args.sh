#!/usr/bin/env bash
#
# inject-steamwebhelper-args.sh — let the app add arbitrary Chromium switches to
# Steam's steamwebhelper.exe (and its child processes) via an env var, without a
# new Wine build.
#
# WHY
# ---
# Steam's Deck/Big Picture UI is CEF (Chromium). On Windows, Chromium M126
# GPU-presents via DirectComposition; Wine's dcomp.dll is a stub, so the Big
# Picture window renders on the GPU but never presents (webhelper_gpu.txt shows
# "[ Direct composition ]: (null)"). The fix under test is to launch the
# webhelper with --disable-direct-composition, but Steam only forwards an
# allowlist of -cef-* flags to steamwebhelper and does NOT forward that switch.
#
# WHAT
# ----
# In dlls/kernelbase/process.c CreateProcessInternalW, right after the child
# image name (app_name) and command line (tidy_cmdline) are resolved, if the
# child's base image name is steamwebhelper.exe (case-insensitive) and the env
# var STEAMWEBHELPER_EXTRA_ARGS is set and non-empty, append " " + its value to a
# freshly heap-allocated copy of the command line (the caller's buffer is never
# overflowed; the old tidy_cmdline is freed if it was ours). app_name is fully
# resolved at that point -- it is either lpApplicationName or the first token of
# lpCommandLine -- so its base name identifies the child, covering the browser
# process and its --type=gpu-process/renderer/utility children. A TRACE(process)
# prints the final command line. Entirely gated on the env var: unset -> upstream
# behaviour is byte-for-byte unchanged.
#
# This turns every future Chromium-flag experiment into a client-side env change
# instead of a ~1h rebuild.
#
# Delivered as a termux patch dropped into the hangover-wine recipe dir. Termux
# applies every *.patch with `patch -p1` and HARD-FAILS on reject, so a green
# build guarantees it applied. Verified to apply cleanly against AndreRH/wine
# hangover-11.9 and the added C passes a standalone syntax check.
#
# Idempotent; safe to re-run.
#
# Usage: inject-steamwebhelper-args.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: inject-steamwebhelper-args.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "inject-steamwebhelper-args: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0906-piperella-steamwebhelper-extra-args.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = steamwebhelper-extra-args patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/kernelbase/process.c
+++ b/dlls/kernelbase/process.c
@@ -542,6 +542,35 @@
         app_name = name;
     }
 
+    /* Piperella: inject extra Chromium switches into steamwebhelper.exe and its
+       child processes (--type=gpu-process/renderer/utility). Steam only forwards
+       an allowlist of -cef-* flags to the webhelper (e.g. --disable-direct-
+       composition is NOT forwarded), so this lets the app add arbitrary Chromium
+       flags via $STEAMWEBHELPER_EXTRA_ARGS and makes each flag test a client-side
+       env change instead of a new build. app_name is fully resolved here (either
+       lpApplicationName or the first token of lpCommandLine), so its base name
+       identifies the child image. Gated on the env var: unset -> unchanged. */
+    {
+        const WCHAR *base = app_name, *q;
+        for (q = app_name; *q; q++) if (*q == '\\' || *q == '/') base = q + 1;
+        if (app_name && !lstrcmpiW( base, L"steamwebhelper.exe" ))
+        {
+            WCHAR extraW[2048];
+            if (GetEnvironmentVariableW( L"STEAMWEBHELPER_EXTRA_ARGS", extraW, ARRAY_SIZE(extraW) ) && extraW[0])
+            {
+                SIZE_T merged_len = lstrlenW(tidy_cmdline) + 1 + lstrlenW(extraW) + 1;
+                WCHAR *merged = RtlAllocateHeap( GetProcessHeap(), 0, merged_len * sizeof(WCHAR) );
+                if (merged)
+                {
+                    swprintf( merged, merged_len, L"%s %s", tidy_cmdline, extraW );
+                    if (tidy_cmdline != cmd_line) RtlFreeHeap( GetProcessHeap(), 0, tidy_cmdline );
+                    tidy_cmdline = merged;
+                    TRACE( "Piperella: steamwebhelper cmdline -> %s\n", debugstr_w(tidy_cmdline) );
+                }
+            }
+        }
+    }
+
     /* Warn if unsupported features are used */
 
     if (flags & (IDLE_PRIORITY_CLASS | HIGH_PRIORITY_CLASS | REALTIME_PRIORITY_CLASS |
PATCH

echo "  + wrote $(basename "$OUT") (steamwebhelper.exe honors \$STEAMWEBHELPER_EXTRA_ARGS)"
echo "inject-steamwebhelper-args: done."
