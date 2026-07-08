#!/usr/bin/env bash
#
# fix-vulkan-lib-env.sh — let win32u's host Vulkan loader be pointed at a
# non-system Vulkan library via $PIPERELLA_VULKAN_LIB instead of hardcoding
# SONAME_LIBVULKAN (libvulkan.so.1).
#
# WHY
# ---
# On Android/bionic, libvulkan.so / libvulkan.so.1 are allowlisted *public*
# libraries: the system copy always wins over LD_LIBRARY_PATH, so the app cannot
# make Wine load a custom Vulkan driver. We need Wine to load our
# AdrenoTools->Turnip bridge (Turnip is HMI-format and can't be a plain ICD).
# Confirmed on-device: win32u does dlopen("libvulkan.so.1", RTLD_NOW) in
# vulkan_init_once() and always gets the vendor Adreno driver, so vkCreateInstance
# returns -9 (VK_ERROR_INCOMPATIBLE_DRIVER). Binary-patching the string is a
# bandaid; this is the real fix.
#
# WHAT
# ----
# In dlls/win32u/vulkan.c vulkan_init_once(), honor $PIPERELLA_VULKAN_LIB (a
# non-public soname the app puts on LD_LIBRARY_PATH) when set and non-empty; else
# fall back to SONAME_LIBVULKAN exactly as before. Default behaviour is unchanged
# when the env var is unset. getenv() needs <stdlib.h>, which the file does not
# already include, so the patch adds it (avoids an implicit-declaration error
# under Wine's -Werror).
#
# Implemented as a termux patch dropped into the hangover-wine recipe dir. Termux
# applies every *.patch there and HARD-FAILS the build if one does not apply, so
# a green build guarantees it compiled in. Verified to apply cleanly with
# `patch -p1` against AndreRH/wine hangover-11.9.
#
# Idempotent; safe to re-run.
#
# Usage: fix-vulkan-lib-env.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-vulkan-lib-env.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-vulkan-lib-env: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0904-piperella-vulkan-lib-env.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = vulkan-lib-env patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/win32u/vulkan.c
+++ b/dlls/win32u/vulkan.c
@@ -26,6 +26,7 @@

 #include <dlfcn.h>
 #include <pthread.h>
+#include <stdlib.h>
 #include <unistd.h>

 #include "ntstatus.h"
@@ -3030,8 +3031,18 @@
     VkResult res;

 #ifdef SONAME_LIBVULKAN
-    vulkan_handle = dlopen( SONAME_LIBVULKAN, RTLD_NOW );
-    if (!vulkan_handle) ERR( "Failed to load %s\n", SONAME_LIBVULKAN );
+    {
+        /* Piperella/Android: libvulkan.so[.1] is an allowlisted public library,
+         * so the system Adreno driver always wins over LD_LIBRARY_PATH and Wine
+         * can't be pointed at our AdrenoTools->Turnip bridge (Turnip is HMI
+         * format, not a plain ICD) -> vkCreateInstance fails with -9
+         * (INCOMPATIBLE_DRIVER). Allow the app to name a non-public soname it
+         * put on LD_LIBRARY_PATH via $PIPERELLA_VULKAN_LIB. Unset -> unchanged. */
+        const char *soname = getenv( "PIPERELLA_VULKAN_LIB" );
+        if (!soname || !*soname) soname = SONAME_LIBVULKAN;
+        vulkan_handle = dlopen( soname, RTLD_NOW );
+        if (!vulkan_handle) ERR( "Failed to load %s\n", soname );
+    }
 #else
     ERR( "Wine was built without Vulkan support.\n" );
 #endif
PATCH

echo "  + wrote $(basename "$OUT") (win32u Vulkan loader honors \$PIPERELLA_VULKAN_LIB)"
echo "fix-vulkan-lib-env: done."
