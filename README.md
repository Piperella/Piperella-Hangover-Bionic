# hangover-bionic

Wayland-enabled, **bionic-native** Hangover (Wine + FEX WoW64) for Android arm64,
built in CI and published as Release assets for the
[Piperella Wayland compositor](https://github.com/piperella/piperella-wayland-compositor).

## Why

Android apps targeting API ≥ 29 can't `execve()` app-data binaries; the only legal
launch path is `/system/bin/linker64 <elf>`, and `linker64` loads **bionic** ELFs,
not glibc. Upstream Hangover ships a **glibc** build, so it can't be launched that
way. Termux builds Hangover against **bionic** (NDK + llvm-mingw), but its package
lacks `winewayland.drv`, ships **stale FEX** backends, and isn't hardened for the
`linker64`/W^X launch. This repo fixes all of that and publishes the result.

## What it produces

One GitHub Release **per successful build**, each marked `latest`, so a stable URL
always resolves to the newest build:

```
https://github.com/piperella/Piperella-Hangover-Bionic/releases/latest/download/hangover-bionic-aarch64.tar
```

The tar holds the bionic `hangover-wine_<ver>_aarch64.deb` plus the bionic
runtime-dependency `.debs` it links against. The Piperella app downloads it the
same way it already downloads upstream Hangover.

## What we changed

Everything is applied as **idempotent overlays** on the upstream termux recipe at
build time (nothing is forked or version-pinned), so it survives upstream updates.

- **Wayland** (`patches/enable-wayland.sh`) — adds `libwayland`/`libxkbcommon` +
  `--with-wayland`, so `winewayland.drv` is built and talks to the compositor.
- **Real FEX backends** (`patches/install-fex-backends.sh` + `build-fex-arm64ec.sh`) —
  the upstream package silently drops the x86→ARM64 recompiler DLLs, and Hangover's
  bundled ones are a stale FEX that crash-loops 64-bit/arm64ec apps (Steam's CEF,
  FEX-Emu #4493). CI compiles **fresh FEX-2607** (`libwow64fex` + `libarm64ecfex`,
  with the #4493 MEM_RESET fix) and forces them into the package; `wowbox64`
  (Box64) is kept from the bundle.
- **Runtime hardening for the `linker64` launch:**
  - `fix-wineserver-dir.sh` — wineserver/temp dir honors `$XDG_RUNTIME_DIR`/`$TMPDIR`
    instead of a baked Termux path; drops `wine-preloader` (unloadable at API 36).
  - `fix-nls-dir.sh` — wineserver resolves its NLS/install dir via `$WINELOADER`
    (not `/proc/self/exe`, which is `linker64`).
  - `fix-exec-wx.sh` — PE image loader backs executable sections with anonymous
    memory (`execmem`), avoiding the `execmod` SELinux denial under Android W^X.
  - `fix-rpc-contexthandle.sh` / `fix-rpc-ctx-marshall.sh` — two NULL/low-pointer
    guards in RPC client context-handle unmarshalling, so a bad handle raises
    `RPC_X_SS_CONTEXT_MISMATCH` (or is redirected to a scratch) instead of
    crashing the 64-bit Steam client (`c0000005`).
  - `fix-vulkan-lib-env.sh` — win32u's host Vulkan loader honors
    `$PIPERELLA_VULKAN_LIB`, so the app can point Wine at a non-public Vulkan
    driver (our AdrenoTools→Turnip bridge) instead of the allowlisted system
    `libvulkan.so.1`. Unset → default behaviour unchanged.
  - `inject-steamwebhelper-args.sh` — `kernelbase` `CreateProcessInternalW`
    appends `$STEAMWEBHELPER_EXTRA_ARGS` to `steamwebhelper.exe` (and its
    gpu/renderer/utility children), so extra Chromium switches (e.g.
    `--disable-direct-composition`) can be tested as a client-side env change
    instead of a rebuild. Steam doesn't forward those flags itself. Unset →
    default behaviour unchanged.
  - `add-winewayland-xdg-foreign.sh` — cross-process window presentation for
    `winewayland.drv` via `xdg-foreign-unstable-v2`: an owner process exports its
    toplevel and a child process (e.g. Steam's `steamwebhelper.exe` CEF UI, which
    renders in a separate Wine process and `SetParent`s into `steam.exe`) imports
    the handle and `set_parent_of`s, so the child maps as a real `xdg_toplevel`
    under the compositor instead of a black screen. Handle transported via a
    cross-process global atom in a window property.

## How it works

- `.github/workflows/build.yml` — clones termux-packages (latest), builds fresh FEX,
  applies the overlays, builds with Termux's pinned **Docker builder** (free
  unlimited Actions on a public repo), gates the result, and publishes the Release.
  The Hangover version is read from the recipe, not hardcoded.
- `inspect-deb.sh` — **release gate**: fails the build unless the `.deb` contains
  `winewayland.drv`, all three WoW64 backends (as PE), fresh (non-stale) FEX with a
  `FEX_BUILD_INFO` record, and the runtime fixes above. A broken package is never
  published.
- `fetch-runtime-deps.sh` — resolves + downloads the bionic `.so` dependency closure
  from the Termux apt repos.
- `build.sh` / `install-host-deps.sh` — optional local (no-Docker) native build.

## Run it

Push to `patches/**` (or Actions tab → **Run workflow**) to build + publish. To
build a different Hangover version, dispatch with another `termux_ref`.
