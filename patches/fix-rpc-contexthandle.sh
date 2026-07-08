#!/usr/bin/env bash
#
# fix-rpc-contexthandle.sh — make Wine's RPC client context-handle unmarshalling
# NULL-safe so a bad/NULL context handle raises RPC_X_SS_CONTEXT_MISMATCH
# instead of dereferencing NULL and crashing the process.
#
# WHY
# ---
# Running the 64-bit Steam client under Hangover on Android, the client RPC path
#   NdrClientContextUnmarshall -> NDRCContextUnmarshall
#     -> ndr_update_context_handle -> get_context_entry
# crashes with c0000005 (str xzr,[x19], x19=NULL). Steam's client RPC gets back
# a NULL / invalid context handle because the server-side service RPC fails under
# the Android sandbox; Wine then writes through that handle instead of raising an
# exception.
#
# get_context_entry() is the single validation choke point every context-handle
# unmarshall goes through: it casts the incoming handle to a struct pointer and
# unconditionally reads che->magic. If the handle is NULL (or otherwise invalid)
# that read faults. Its callers already treat a NULL return as an error:
#   * ndr_update_context_handle():  `if (!che) return RPC_X_SS_CONTEXT_MISMATCH;`
#   * NDRCContextUnmarshall():      turns that status into RpcRaiseException()
#   * NDRCContextBinding():         raises RPC_X_SS_CONTEXT_MISMATCH on NULL
# so making get_context_entry() return NULL for a NULL/invalid handle routes the
# whole path to a clean RpcException rather than a crash.
#
# WHAT
# ----
# One-hunk defensive change to dlls/rpcrt4/ndr_contexthandle.c:
#   -    if (che->magic != NDR_CONTEXT_HANDLE_MAGIC)
#   +    if (!che || che->magic != NDR_CONTEXT_HANDLE_MAGIC)
# No other file / behaviour changes; valid handles are unaffected.
#
# Implemented as a termux patch dropped into the hangover-wine recipe dir. Termux
# applies every *.patch in that dir and HARD-FAILS the build if one does not
# apply, so a green build guarantees this fix compiled in. Verified to apply
# cleanly with `patch -p1` against AndreRH/wine hangover-11.9 (and the context is
# stable on 11.12).
#
# Idempotent; safe to re-run.
#
# Usage: fix-rpc-contexthandle.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: fix-rpc-contexthandle.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "fix-rpc-contexthandle: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0902-piperella-rpc-contexthandle-nullsafe.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = rpc-contexthandle-nullsafe patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/rpcrt4/ndr_contexthandle.c
+++ b/dlls/rpcrt4/ndr_contexthandle.c
@@ -62,7 +62,14 @@
 {
     struct context_handle_entry *che = CContext;

-    if (che->magic != NDR_CONTEXT_HANDLE_MAGIC)
+    /* Piperella/Android: a 64-bit Steam client RPC can hand back a NULL (or
+       otherwise invalid) context handle when the server-side service RPC fails
+       under the Android sandbox. Without this NULL guard, NDRCContextUnmarshall
+       -> ndr_update_context_handle -> get_context_entry dereferences the NULL
+       handle and the process dies with c0000005. Returning NULL here makes the
+       existing callers raise RPC_X_SS_CONTEXT_MISMATCH (converted to an
+       RpcException by NDRCContextUnmarshall) instead of crashing. */
+    if (!che || che->magic != NDR_CONTEXT_HANDLE_MAGIC)
         return NULL;
     return che;
 }
PATCH

echo "  + wrote $(basename "$OUT") (get_context_entry NULL-safe -> RPC_X_SS_CONTEXT_MISMATCH)"
echo "fix-rpc-contexthandle: done."
