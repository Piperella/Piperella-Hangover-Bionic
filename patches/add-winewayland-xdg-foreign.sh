#!/usr/bin/env bash
#
# add-winewayland-xdg-foreign.sh — cross-process window presentation for
# winewayland.drv, so Steam's CEF UI (steamwebhelper.exe) renders under the
# Piperella compositor.
#
# WHY
# ---
# steamwebhelper.exe (CEF) renders in a SEPARATE Wine process from steam.exe and
# cross-process SetParents its windows into steam.exe containers. winewayland.drv
# has no xdg-foreign, so in window.c WAYLAND_WindowPosChanged the owner lookup
#   toplevel_data = wayland_win_data_get_nolock(toplevel)   (a per-process hash)
# misses for a cross-process owner -> toplevel_surface == NULL -> the child falls
# through to a stray WAYLAND_SURFACE_ROLE_TOPLEVEL that is never parented. Result
# on-device: black screen, 0 mapped xdg_toplevel. (wl_subcompositor_get_subsurface
# cannot cross the client boundary, so subsurfaces are not an option here.)
#
# WHAT (model: child becomes its own xdg_toplevel, linked via set_parent_of;
# the opaque handle is transported cross-process via a Win32 global atom stored
# in a window property -- the proton-GE MR !10180 approach)
#   * Add xdg-foreign-unstable-v2 to the driver: vendored protocol xml +
#     Makefile.in SOURCES + waylanddrv.h include, so wayland-scanner emits the
#     glue. Bind zxdg_exporter_v2 + zxdg_importer_v2 in wayland.c and store them
#     on process_wayland. All new behaviour is guarded on their presence.
#   * Export: in wayland_surface_make_toplevel, export_toplevel(wl_surface); on
#     the handle event, intern the handle string as a global atom and stash it on
#     the window: NtAddAtom + NtUserSetProp(hwnd,"__wl_foreign_handle",atom).
#   * Import: in WAYLAND_WindowPosChanged, when the per-process owner lookup is
#     NULL but the owner is a valid cross-process HWND and the importer is
#     present, read the atom back off the owner window (NtUserGetProp +
#     NtQueryInformationAtom), import_toplevel(handle) and set_parent_of(child).
#     The child keeps its own buffer via the existing client_surface/shm path.
#   * Clean up the exported/imported objects and the property on role-clear.
#   * TRACEs at export / handle / import / set_parent_of (WINEDEBUG=+waylanddrv).
#
# NOTE on the atom API: window.c/wayland_surface.c compile into the driver's
# UNIX half (winewayland.so, links -lwin32u, uses host wayland-client), which
# cannot call PE user32 GlobalAddAtomA/GlobalGetAtomNameA. The unix-callable
# equivalents that hit the same wineserver-backed global atom table are used
# instead: NtAddAtom (write) and NtQueryInformationAtom (read); the property
# itself is a server-side NtUserSetProp/NtUserGetProp, readable cross-process.
# Same intent as the spec, correct for the unix side.
#
# Delivered as a termux patch dropped into the hangover-wine recipe dir. Termux
# applies every *.patch with `patch -p1` and HARD-FAILS on reject, so a green
# build guarantees it applied. Verified to apply cleanly against AndreRH/wine
# hangover-11.9, and the added C passes a standalone syntax/type check.
#
# Idempotent; safe to re-run.
#
# Usage: add-winewayland-xdg-foreign.sh <path-to/x11-packages/hangover-wine/build.sh>
set -euo pipefail

F="${1:?usage: add-winewayland-xdg-foreign.sh <path-to-hangover-wine/build.sh>}"
[ -f "$F" ] || { echo "add-winewayland-xdg-foreign: no such file: $F" >&2; exit 1; }
DIR="$(cd "$(dirname "$F")" && pwd)"
OUT="$DIR/0905-piperella-winewayland-xdg-foreign.patch"

if [ -f "$OUT" ] && grep -q 'Piperella' "$OUT"; then
	echo "  = winewayland-xdg-foreign patch (already present)"
	exit 0
fi

cat > "$OUT" <<'PATCH'
--- a/dlls/winewayland.drv/Makefile.in
+++ b/dlls/winewayland.drv/Makefile.in
@@ -16,6 +16,7 @@
 	relative-pointer-unstable-v1.xml \
 	text-input-unstable-v3.xml \
 	viewporter.xml \
+	xdg-foreign-unstable-v2.xml \
 	vulkan.c \
 	wayland.c \
 	wayland_data_device.c \
--- a/dlls/winewayland.drv/waylanddrv.h
+++ b/dlls/winewayland.drv/waylanddrv.h
@@ -39,6 +39,7 @@
 #include "wlr-data-control-unstable-v1-client-protocol.h"
 #include "xdg-toplevel-icon-v1-client-protocol.h"
 #include "pointer-warp-v1-client-protocol.h"
+#include "xdg-foreign-unstable-v2-client-protocol.h"
 
 #include "windef.h"
 #include "winbase.h"
@@ -180,6 +181,8 @@
     struct xdg_toplevel_icon_manager_v1 *xdg_toplevel_icon_manager_v1;
     struct wp_cursor_shape_manager_v1 *wp_cursor_shape_manager_v1;
     struct wp_pointer_warp_v1 *wp_pointer_warp_v1;
+    struct zxdg_exporter_v2 *zxdg_exporter_v2;
+    struct zxdg_importer_v2 *zxdg_importer_v2;
     struct wayland_seat seat;
     struct wayland_keyboard keyboard;
     struct wayland_pointer pointer;
@@ -292,6 +295,10 @@
     struct wayland_window_config window;
     int content_width, content_height;
     HCURSOR hcursor;
+    /* Piperella/xdg-foreign: cross-process window parenting. */
+    struct zxdg_exported_v2 *zxdg_exported_v2;
+    struct zxdg_imported_v2 *zxdg_imported_v2;
+    HWND imported_parent;
 };
 
 /**********************************************************************
@@ -317,6 +324,7 @@
 void wayland_surface_make_toplevel(struct wayland_surface *surface);
 void wayland_surface_make_subsurface(struct wayland_surface *surface,
                                      struct wayland_surface *parent);
+void wayland_surface_import_foreign_parent(struct wayland_surface *surface, HWND parent);
 void wayland_surface_clear_role(struct wayland_surface *surface);
 void wayland_surface_attach_shm(struct wayland_surface *surface,
                                 struct wayland_shm_buffer *shm_buffer,
--- a/dlls/winewayland.drv/wayland.c
+++ b/dlls/winewayland.drv/wayland.c
@@ -205,6 +205,16 @@
         process_wayland.wp_pointer_warp_v1 =
             wl_registry_bind(registry, id, &wp_pointer_warp_v1_interface, 1);
     }
+    else if (strcmp(interface, "zxdg_exporter_v2") == 0)
+    {
+        process_wayland.zxdg_exporter_v2 =
+            wl_registry_bind(registry, id, &zxdg_exporter_v2_interface, 1);
+    }
+    else if (strcmp(interface, "zxdg_importer_v2") == 0)
+    {
+        process_wayland.zxdg_importer_v2 =
+            wl_registry_bind(registry, id, &zxdg_importer_v2_interface, 1);
+    }
 }
 
 static void registry_handle_global_remove(void *data, struct wl_registry *registry,
--- a/dlls/winewayland.drv/wayland_surface.c
+++ b/dlls/winewayland.drv/wayland_surface.c
@@ -29,11 +29,122 @@
 #include <unistd.h>
 
 #include "waylanddrv.h"
+#include "winternl.h"
 #include "wine/debug.h"
 #include "wine/server.h"
 
 WINE_DEFAULT_DEBUG_CHANNEL(waylanddrv);
 
+/* Piperella/xdg-foreign: cross-process toplevel parenting (steamwebhelper CEF).
+ * steamwebhelper.exe renders in a separate Wine process from steam.exe and
+ * cross-process SetParents its windows into steam.exe containers, so the parent
+ * HWND is not in this process's hash and the child would map as a stray
+ * toplevel. We export each toplevel via zxdg_exporter_v2, publish the opaque
+ * handle string as a cross-process Win32 global atom stored in a window
+ * property (NtAddAtom + NtUserSetProp; GlobalAddAtomA is PE-only and this code
+ * runs in the driver's unix half), and on the child side import the owner's
+ * handle and set_parent_of so the compositor stacks the child above its owner. */
+static const WCHAR foreign_handle_prop[] =
+    {'_','_','w','l','_','f','o','r','e','i','g','n','_','h','a','n','d','l','e',0};
+
+static void zxdg_exported_v2_handle_event(void *data, struct zxdg_exported_v2 *exported,
+                                          const char *handle)
+{
+    HWND hwnd = data;
+    WCHAR nameW[256];
+    RTL_ATOM atom = 0;
+    ULONG i;
+
+    for (i = 0; handle[i] && i < ARRAY_SIZE(nameW) - 1; i++)
+        nameW[i] = (unsigned char)handle[i];
+    nameW[i] = 0;
+
+    if (!NtAddAtom(nameW, i * sizeof(WCHAR), &atom) && atom)
+    {
+        NtUserSetProp(hwnd, foreign_handle_prop, (HANDLE)(ULONG_PTR)atom);
+        TRACE("Piperella/foreign: handle hwnd=%p handle=%s atom=%u published\n",
+              hwnd, handle, (unsigned int)atom);
+    }
+    else
+        ERR("Piperella/foreign: failed to intern exported handle %s\n", handle);
+}
+
+static const struct zxdg_exported_v2_listener zxdg_exported_v2_listener_impl =
+{
+    zxdg_exported_v2_handle_event,
+};
+
+static void zxdg_imported_v2_destroyed_event(void *data, struct zxdg_imported_v2 *imported)
+{
+    TRACE("Piperella/foreign: imported handle destroyed hwnd=%p\n", (HWND)data);
+}
+
+static const struct zxdg_imported_v2_listener zxdg_imported_v2_listener_impl =
+{
+    zxdg_imported_v2_destroyed_event,
+};
+
+/* Import the cross-process parent's exported toplevel (published as a global
+ * atom on its window property) and make this surface a child of it. */
+void wayland_surface_import_foreign_parent(struct wayland_surface *surface, HWND parent)
+{
+    union
+    {
+        ATOM_BASIC_INFORMATION abi;
+        char buf[sizeof(ATOM_BASIC_INFORMATION) + 256 * sizeof(WCHAR)];
+    } info;
+    char handle[256];
+    RTL_ATOM atom;
+    ULONG len = 0, i, n;
+
+    if (!process_wayland.zxdg_importer_v2) return;
+    if (surface->role != WAYLAND_SURFACE_ROLE_TOPLEVEL || !surface->xdg_toplevel) return;
+    if (surface->zxdg_imported_v2 && surface->imported_parent == parent) return;
+
+    atom = (RTL_ATOM)(ULONG_PTR)NtUserGetProp(parent, foreign_handle_prop);
+    if (!atom)
+    {
+        TRACE("Piperella/foreign: parent=%p has no exported handle yet\n", parent);
+        return;
+    }
+
+    if (NtQueryInformationAtom(atom, AtomBasicInformation, &info, sizeof(info), &len) ||
+        info.abi.NameLength == 0)
+    {
+        WARN("Piperella/foreign: cannot resolve atom %u for parent=%p\n",
+             (unsigned int)atom, parent);
+        return;
+    }
+
+    n = info.abi.NameLength / sizeof(WCHAR);
+    if (n > ARRAY_SIZE(handle) - 1) n = ARRAY_SIZE(handle) - 1;
+    for (i = 0; i < n; i++) handle[i] = (char)info.abi.Name[i];
+    handle[n] = 0;
+
+    if (surface->zxdg_imported_v2)
+    {
+        zxdg_imported_v2_destroy(surface->zxdg_imported_v2);
+        surface->zxdg_imported_v2 = NULL;
+        surface->imported_parent = 0;
+    }
+
+    surface->zxdg_imported_v2 =
+        zxdg_importer_v2_import_toplevel(process_wayland.zxdg_importer_v2, handle);
+    if (!surface->zxdg_imported_v2)
+    {
+        ERR("Piperella/foreign: import_toplevel failed handle=%s\n", handle);
+        return;
+    }
+    zxdg_imported_v2_add_listener(surface->zxdg_imported_v2,
+                                  &zxdg_imported_v2_listener_impl, surface->hwnd);
+    zxdg_imported_v2_set_parent_of(surface->zxdg_imported_v2, surface->wl_surface);
+    surface->imported_parent = parent;
+    wl_surface_commit(surface->wl_surface);
+    wl_display_flush(process_wayland.wl_display);
+    TRACE("Piperella/foreign: import+set_parent_of child hwnd=%p parent=%p handle=%s\n",
+          surface->hwnd, parent, handle);
+}
+
 static void xdg_surface_handle_configure(void *private, struct xdg_surface *xdg_surface,
                                          uint32_t serial)
 {
@@ -276,6 +387,21 @@
 
     wayland_surface_assign_icon(surface);
 
+    if (process_wayland.zxdg_exporter_v2 && !surface->zxdg_exported_v2)
+    {
+        surface->zxdg_exported_v2 =
+            zxdg_exporter_v2_export_toplevel(process_wayland.zxdg_exporter_v2,
+                                             surface->wl_surface);
+        if (surface->zxdg_exported_v2)
+        {
+            zxdg_exported_v2_add_listener(surface->zxdg_exported_v2,
+                                          &zxdg_exported_v2_listener_impl, surface->hwnd);
+            TRACE("Piperella/foreign: export_toplevel surface=%p hwnd=%p\n",
+                  surface, surface->hwnd);
+        }
+        else ERR("Piperella/foreign: export_toplevel failed hwnd=%p\n", surface->hwnd);
+    }
+
     wl_surface_commit(surface->wl_surface);
     wl_display_flush(process_wayland.wl_display);
 
@@ -364,6 +490,19 @@
             xdg_surface_destroy(surface->xdg_surface);
             surface->xdg_surface = NULL;
         }
+
+        if (surface->zxdg_exported_v2)
+        {
+            zxdg_exported_v2_destroy(surface->zxdg_exported_v2);
+            surface->zxdg_exported_v2 = NULL;
+            NtUserRemoveProp(surface->hwnd, foreign_handle_prop);
+        }
+        if (surface->zxdg_imported_v2)
+        {
+            zxdg_imported_v2_destroy(surface->zxdg_imported_v2);
+            surface->zxdg_imported_v2 = NULL;
+            surface->imported_parent = 0;
+        }
         break;
 
     case WAYLAND_SURFACE_ROLE_SUBSURFACE:
--- a/dlls/winewayland.drv/window.c
+++ b/dlls/winewayland.drv/window.c
@@ -488,6 +488,15 @@
         wayland_win_data_update_wayland_state(data);
     }
 
+    /* Piperella/xdg-foreign: when the owner toplevel lives in another Wine
+     * process, toplevel_data (a per-process lookup) is NULL, so the child was
+     * left as a stray toplevel. Parent it under the owner via xdg-foreign. */
+    if (surface && data->wayland_surface && !toplevel_data &&
+        toplevel && toplevel != hwnd && process_wayland.zxdg_importer_v2)
+    {
+        wayland_surface_import_foreign_parent(data->wayland_surface, toplevel);
+    }
+
     wayland_win_data_release(data);
 }
 
--- /dev/null
+++ b/dlls/winewayland.drv/xdg-foreign-unstable-v2.xml
@@ -0,0 +1,200 @@
+<?xml version="1.0" encoding="UTF-8"?>
+<protocol name="xdg_foreign_unstable_v2">
+
+  <copyright>
+    Copyright © 2015-2016 Red Hat Inc.
+
+    Permission is hereby granted, free of charge, to any person obtaining a
+    copy of this software and associated documentation files (the "Software"),
+    to deal in the Software without restriction, including without limitation
+    the rights to use, copy, modify, merge, publish, distribute, sublicense,
+    and/or sell copies of the Software, and to permit persons to whom the
+    Software is furnished to do so, subject to the following conditions:
+
+    The above copyright notice and this permission notice (including the next
+    paragraph) shall be included in all copies or substantial portions of the
+    Software.
+
+    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
+    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
+    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
+    THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
+    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
+    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
+    DEALINGS IN THE SOFTWARE.
+  </copyright>
+
+  <description summary="Protocol for exporting xdg surface handles">
+    This protocol specifies a way for making it possible to reference a surface
+    of a different client. With such a reference, a client can, by using the
+    interfaces provided by this protocol, manipulate the relationship between
+    its own surfaces and the surface of some other client. For example, stack
+    some of its own surface above the other clients surface.
+
+    In order for a client A to get a reference of a surface of client B, client
+    B must first export its surface using xdg_exporter.export_toplevel. Upon
+    doing this, client B will receive a handle (a unique string) that it may
+    share with client A in some way (for example D-Bus). After client A has
+    received the handle from client B, it may use xdg_importer.import_toplevel
+    to create a reference to the surface client B just exported. See the
+    corresponding requests for details.
+
+    A possible use case for this is out-of-process dialogs. For example when a
+    sandboxed client without file system access needs the user to select a file
+    on the file system, given sandbox environment support, it can export its
+    surface, passing the exported surface handle to an unsandboxed process that
+    can show a file browser dialog and stack it above the sandboxed client's
+    surface.
+
+    Warning! The protocol described in this file is experimental and backward
+    incompatible changes may be made. Backward compatible changes may be added
+    together with the corresponding interface version bump. Backward
+    incompatible changes are done by bumping the version number in the protocol
+    and interface names and resetting the interface version. Once the protocol
+    is to be declared stable, the 'z' prefix and the version number in the
+    protocol and interface names are removed and the interface version number is
+    reset.
+  </description>
+
+  <interface name="zxdg_exporter_v2" version="1">
+    <description summary="interface for exporting surfaces">
+      A global interface used for exporting surfaces that can later be imported
+      using xdg_importer.
+    </description>
+
+    <request name="destroy" type="destructor">
+      <description summary="destroy the xdg_exporter object">
+	Notify the compositor that the xdg_exporter object will no longer be
+	used.
+      </description>
+    </request>
+
+    <enum name="error">
+      <description summary="error values">
+        These errors can be emitted in response to invalid xdg_exporter
+        requests.
+      </description>
+      <entry name="invalid_surface" value="0" summary="surface is not an xdg_toplevel"/>
+    </enum>
+
+    <request name="export_toplevel">
+      <description summary="export a toplevel surface">
+	The export_toplevel request exports the passed surface so that it can later be
+	imported via xdg_importer. When called, a new xdg_exported object will
+	be created and xdg_exported.handle will be sent immediately. See the
+	corresponding interface and event for details.
+
+	A surface may be exported multiple times, and each exported handle may
+	be used to create an xdg_imported multiple times. Only xdg_toplevel
+        equivalent surfaces may be exported, otherwise an invalid_surface
+        protocol error is sent.
+      </description>
+      <arg name="id" type="new_id" interface="zxdg_exported_v2"
+	   summary="the new xdg_exported object"/>
+      <arg name="surface" type="object" interface="wl_surface"
+	   summary="the surface to export"/>
+    </request>
+  </interface>
+
+  <interface name="zxdg_importer_v2" version="1">
+    <description summary="interface for importing surfaces">
+      A global interface used for importing surfaces exported by xdg_exporter.
+      With this interface, a client can create a reference to a surface of
+      another client.
+    </description>
+
+    <request name="destroy" type="destructor">
+      <description summary="destroy the xdg_importer object">
+	Notify the compositor that the xdg_importer object will no longer be
+	used.
+      </description>
+    </request>
+
+    <request name="import_toplevel">
+      <description summary="import a toplevel surface">
+	The import_toplevel request imports a surface from any client given a handle
+	retrieved by exporting said surface using xdg_exporter.export_toplevel.
+	When called, a new xdg_imported object will be created. This new object
+	represents the imported surface, and the importing client can
+	manipulate its relationship using it. See xdg_imported for details.
+      </description>
+      <arg name="id" type="new_id" interface="zxdg_imported_v2"
+	   summary="the new xdg_imported object"/>
+      <arg name="handle" type="string"
+	   summary="the exported surface handle"/>
+    </request>
+  </interface>
+
+  <interface name="zxdg_exported_v2" version="1">
+    <description summary="an exported surface handle">
+      An xdg_exported object represents an exported reference to a surface. The
+      exported surface may be referenced as long as the xdg_exported object not
+      destroyed. Destroying the xdg_exported invalidates any relationship the
+      importer may have established using xdg_imported.
+    </description>
+
+    <request name="destroy" type="destructor">
+      <description summary="unexport the exported surface">
+	Revoke the previously exported surface. This invalidates any
+	relationship the importer may have set up using the xdg_imported created
+	given the handle sent via xdg_exported.handle.
+      </description>
+    </request>
+
+    <event name="handle">
+      <description summary="the exported surface handle">
+	The handle event contains the unique handle of this exported surface
+	reference. It may be shared with any client, which then can use it to
+	import the surface by calling xdg_importer.import_toplevel. A handle
+	may be used to import the surface multiple times.
+      </description>
+      <arg name="handle" type="string" summary="the exported surface handle"/>
+    </event>
+  </interface>
+
+  <interface name="zxdg_imported_v2" version="1">
+    <description summary="an imported surface handle">
+      An xdg_imported object represents an imported reference to surface exported
+      by some client. A client can use this interface to manipulate
+      relationships between its own surfaces and the imported surface.
+    </description>
+
+    <enum name="error">
+      <description summary="error values">
+        These errors can be emitted in response to invalid xdg_imported
+        requests.
+      </description>
+      <entry name="invalid_surface" value="0" summary="surface is not an xdg_toplevel"/>
+    </enum>
+
+    <request name="destroy" type="destructor">
+      <description summary="destroy the xdg_imported object">
+	Notify the compositor that it will no longer use the xdg_imported
+	object. Any relationship that may have been set up will at this point
+	be invalidated.
+      </description>
+    </request>
+
+    <request name="set_parent_of">
+      <description summary="set as the parent of some surface">
+        Set the imported surface as the parent of some surface of the client.
+        The passed surface must be an xdg_toplevel equivalent, otherwise an
+        invalid_surface protocol error is sent. Calling this function sets up
+        a surface to surface relation with the same stacking and positioning
+        semantics as xdg_toplevel.set_parent.
+      </description>
+      <arg name="surface" type="object" interface="wl_surface"
+	   summary="the child surface"/>
+    </request>
+
+    <event name="destroyed">
+      <description summary="the imported surface handle has been destroyed">
+	The imported surface handle has been destroyed and any relationship set
+	up has been invalidated. This may happen for various reasons, for
+	example if the exported surface or the exported surface handle has been
+	destroyed, if the handle used for importing was invalid.
+      </description>
+    </event>
+  </interface>
+
+</protocol>
PATCH

echo "  + wrote $(basename "$OUT") (winewayland.drv cross-process presentation via xdg-foreign)"
echo "add-winewayland-xdg-foreign: done."
