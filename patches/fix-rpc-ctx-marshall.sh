#!/usr/bin/env bash
#
# fix-rpc-ctx-marshall.sh — stop NdrContextHandleUnmarshall from writing through
# a bogus context-handle pointer on the client side.
#
# WHY
# ---
# Verified on-device (disassembly + register dump): running the 64-bit Steam
# client, the client path
#   NdrClientContextUnmarshall -> NdrContextHandleUnmarshall
# crashes with c0000005. When pFormat[1] & HANDLE_PARAM_IS_VIA_PTR, the function
# does `ccontext = *(NDR_CCONTEXT**)ppMemory` and then `*ccontext = NULL` for an
# [out]-only param. Under a failed/unsupported service RPC the incoming
# handle-pointer comes back as a bogus LOW value -- observed 0x10 (a null struct
# plus a 0x10 field offset), with r12/x19 = 0x10 -- not NULL, so `*ccontext = NULL`
# writes to address 0x10 and faults. A plain `!ccontext` NULL check does NOT
# catch 0x10.
#
# This is the sibling of the get_context_entry() NULL guard
# (fix-rpc-contexthandle.sh): that one covers the *marshalled-handle* path;
# this one covers the *handle-pointer* (HANDLE_PARAM_IS_VIA_PTR) path, where the
# invalid value is the pointer we are about to write through.
#
# WHAT
# ----
# One hunk in dlls/rpcrt4/ndr_marshall.c, client (pStubMsg->IsClient) branch of
# NdrContextHandleUnmarshall only -- the server `else` branch is untouched. Two
# functional lines added:
#   + NDR_CCONTEXT discard = NULL;                 (a scratch cell)
#   + if ((UINT_PTR)ccontext < 0x1000)             (catches 0x10 AND NULL)
#   +     ccontext = &discard;
# so a bogus/low/NULL handle pointer is redirected to the scratch: the buffer is
# still consumed by NdrClientContextUnmarshall (keeping the NDR stream in sync)
# instead of dereferencing an invalid pointer. Valid handles are unaffected.
# UINT_PTR is provided by the windows headers rpcrt4 already includes.
#
# Implemented as a termux patch dropped into the hangover-wine recipe dir. Termux
# applies every *.patch there and HARD-FAILS the build if one does not apply, so
# a green build guarantees this compiled in. Verified to apply cleanly with
# `patch -p1` against AndreRH/wine hangover-11.9.
#
# Idempotent; safe to re-run.
#
# Usage: fix-rpc-ctx-marshall.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-rpc-ctx-marshall.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-rpc-ctx-marshall: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0903-piperella-rpc-ctx-marshall-lowptr.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = rpc-ctx-marshall-lowptr patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/rpcrt4/ndr_marshall.c
+++ b/dlls/rpcrt4/ndr_marshall.c
@@ -7015,10 +7015,19 @@
     if (pStubMsg->IsClient)
     {
         NDR_CCONTEXT *ccontext;
+        NDR_CCONTEXT discard = NULL;
         if (pFormat[1] & HANDLE_PARAM_IS_VIA_PTR)
             ccontext = *(NDR_CCONTEXT **)ppMemory;
         else
             ccontext = (NDR_CCONTEXT *)ppMemory;
+        /* Piperella/Android: the context-handle pointer can come back as a
+         * bogus low value (observed 0x10 -- a null struct + 0x10 field offset)
+         * or NULL under a failed/unsupported service RPC. A plain !ccontext
+         * check does not catch 0x10, so *ccontext = NULL would write to 0x10
+         * -> c0000005. Substitute a scratch so the buffer is still consumed
+         * instead of dereferencing an invalid pointer. */
+        if ((UINT_PTR)ccontext < 0x1000)
+            ccontext = &discard;
         /* [out]-only or [ret] param */
         if ((pFormat[1] & (HANDLE_PARAM_IS_IN|HANDLE_PARAM_IS_OUT)) == HANDLE_PARAM_IS_OUT)
             *ccontext = NULL;
PATCH

echo "  + wrote $(basename "$OUT") (client ctx-handle low/NULL pointer -> scratch, no invalid deref)"
echo "fix-rpc-ctx-marshall: done."
