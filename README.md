# hangover-bionic

Wayland-enabled, **bionic-native** Hangover (Wine + FEX WoW64) for Android arm64,
built in CI and published as Release assets for the
[Piperella Wayland compositor](https://github.com/piperella/piperella-wayland-compositor).

## Why

Android apps targeting API ≥ 29 can't `execve()` app-data binaries; the only legal
launch path is `/system/bin/linker64 <elf>`, and `linker64` loads **bionic** ELFs,
not glibc. Upstream Hangover ships a **glibc** build, so it can't be launched that
way without fragile userland-exec hacks. Termux builds Hangover against **bionic**
(NDK + llvm-mingw) with the same FEX WoW64 backends — it just lacks
`winewayland.drv` (built X11-only). This repo adds the Wayland driver and ships the
result.

## What it produces

A GitHub Release per Hangover version, always reachable at a stable URL:

```
https://github.com/piperella/hangover-bionic/releases/latest/download/hangover-bionic-aarch64.tar
```

The tar contains the bionic `hangover-wine_<ver>_aarch64.deb` plus the bionic
runtime-dependency `.debs` it links against. The Piperella app downloads this the
same way it already downloads upstream Hangover.

## How it works

- `.github/workflows/build.yml` — clones termux-packages (latest), applies the
  Wayland overlay, builds with Termux's pinned **Docker builder** (free unlimited
  Actions on a public repo), and publishes the Release. Nothing is version-pinned:
  the Hangover version is read from the recipe.
- `patches/enable-wayland.sh` — idempotent overlay: adds `libwayland`/`libxkbcommon`
  deps + `--with-wayland`. Re-applied each build, so it survives upstream updates.
- `fetch-runtime-deps.sh` — resolves + downloads the bionic `.so` dependency closure
  from the Termux apt repos.
- `build.sh` / `install-host-deps.sh` — optional local (no-Docker) native build.

## Run it

Push to `patches/**` (or use the Actions tab → **Run workflow**) and the workflow
builds + publishes. To build an older Hangover version, dispatch with a different
`termux_ref`.
