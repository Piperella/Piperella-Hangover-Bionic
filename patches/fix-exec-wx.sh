#!/usr/bin/env bash
#
# fix-exec-wx.sh — make Wine's PE image loader produce executable code memory
# under Android's W^X (avoid SELinux execmod), so PE .text can run.
#
# WHY
# ---
# The app must launch Wine via /system/bin/linker64 (API 36 W^X). PE dlls load
# at a relocated base (e.g. ntdll 180000000 -> 6fff9b0000), so dlls/ntdll/unix/
# virtual.c map_image_into_view() file-maps each section MAP_PRIVATE, then
# relocations COW-dirty the .text pages, then it mprotect()s them PROT_EXEC.
# mprotect(PROT_EXEC) on a *modified file mapping* is "execmod", which Android
# SELinux denies for untrusted_app at targetSdk>=29 -> .text stays non-exec:
#   err:virtual:map_image_into_view failed to set 60000020 protection on
#   ntdll.dll section .text, noexec filesystem?
#
# WHAT
# ----
# Back executable sections with anonymous memory instead of a file mapping.
# Wine already has this path: map_file_into_view() falls back to
# mprotect(RW)+pread() into the view's anonymous reservation for removable media
# / noexec filesystems. We force that path for sections carrying
# IMAGE_SCN_MEM_EXECUTE by OR-ing it into the `removable` argument. The section
# then lives in anonymous memory, so the final PROT_EXEC is "execmem" (anonymous
# executable memory, which Android allows for untrusted_app — it's how ART JITs)
# rather than execmod. This covers every PE dll, not just ntdll. Data/rodata
# sections keep their efficient file mapping (they never get PROT_EXEC, so they
# never hit execmod).
#
# Implemented as a termux patch dropped into the hangover-wine recipe dir
# (dlls/ntdll/unix/virtual.c is not touched by any existing termux patch).
# Idempotent; verified to apply cleanly and the changed expression compiles.
#
# Usage: fix-exec-wx.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-exec-wx.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-exec-wx: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0901-piperella-exec-anon-mem.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = exec-anon-mem patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/ntdll/unix/virtual.c
+++ b/dlls/ntdll/unix/virtual.c
@@ -3173,7 +3173,13 @@
             end < file_start ||
             map_file_into_view( view, fd, sec[i].VirtualAddress, file_size, file_start,
                                 VPROT_COMMITTED | VPROT_READ | VPROT_WRITECOPY,
-                                removable ) != STATUS_SUCCESS)
+                                /* Piperella/Android W^X: load executable sections via read()
+                                   into the view's anonymous memory instead of file-mapping
+                                   them. Relocations COW-dirty the mapping, and mprotect(EXEC)
+                                   on a modified file mapping is execmod, which SELinux denies
+                                   for untrusted_app at targetSdk>=29; anonymous exec memory
+                                   (execmem) is allowed. */
+                                removable || (sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) ) != STATUS_SUCCESS)
         {
             ERR_(module)( "Could not map %s section %.8s, file probably truncated\n",
                           debugstr_us(nt_name), sec[i].Name );
PATCH

echo "  + wrote $(basename "$OUT") (exec sections -> anonymous memory, avoids execmod)"
echo "fix-exec-wx: done."
