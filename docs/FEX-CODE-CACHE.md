# FEX persistent code cache — investigation (arm64ec / WoW64, FEX-2607)

**Question:** can the arm64ec/WoW64 FEX we ship (`libarm64ecfex.dll` +
`libwow64fex.dll`, built from FEX-2607 by `build-fex-arm64ec.sh`) persist a
compiled-code cache so a second cold launch of Steam/Chromium doesn't re-JIT
100s of MB of x86-64?

## Answer: No — FEX has no persistent code cache in this version (any mode).

This is **not** an arm64ec-only gap. FEX-Emu removed the entire ahead-of-time IR
/ object-code cache subsystem upstream, so there is nothing to enable for *any*
FEX frontend (Linux FEXInterpreter, WoW64, or arm64ec) in FEX-2607.

### Evidence (checked against the exact tag we build, `FEX-Emu/FEX@FEX-2607`)

- The cache/AOTIR source files no longer exist (HTTP 404 at the tag):
  - `FEXCore/Source/Interface/Core/ObjectCache/ObjectCacheService.cpp`
  - `FEXCore/Source/Interface/Core/ObjectCache/Relocations.h`
  - `FEXCore/Source/Interface/Core/AOTIR.cpp`
  - `Source/Tools/FEXLoader/AOT/AOTGenerator.cpp`
- `FEXCore/include/FEXCore/Config/Config.h` — the `ConfigOption` enum has **no**
  `AOTIR*` / `ObjectCache` / `CacheObjectCodeCompilation` values, and
  `FEXCore/Scripts/config_generator.py` defines no such option. So the config
  knobs named in the task (`CacheObjectCodeCompilation`, `AOTIRCapture` /
  `AOTIRGenerate` / `AOTIRLoad`) are gone — a `Config.json` setting or env var
  for them is silently ignored because the option no longer exists.
- The WoW64 and ARM64EC backends
  (`Source/Windows/WOW64/Module.cpp`, `Source/Windows/ARM64EC/Module.cpp`)
  contain only register-state caches (`gs_cached`, `FlushInstructionCache…`);
  no code/IR serialization to disk.

### What about the cache directory that still exists?

`Source/Common/Config.cpp` still has `GetCacheDirectory()`
(`$FEX_APP_CACHE_LOCATION`, else `$XDG_CACHE_HOME`, else `~/.cache`, then
`/fex-emu/`). It is vestigial for code caching — with the ObjectCache/AOTIR code
removed, nothing writes compiled code there. Pointing it at a persistent path
buys nothing today.

### "Which source/build define gates it?" — none

There is no build flag to flip. The feature isn't `#ifdef`-disabled; the
implementing source was deleted upstream. Re-enabling a persistent code cache
would mean **reintroducing the removed ObjectCache/AOTIR subsystem** and porting
it to the thunked WoW64/arm64ec path (which never had it wired even when AOTIR
existed) — a large FEX patch with cross-process and relocation/ASLR concerns,
not a recipe change. That is out of scope for this build and would be its own
investigation if we decide to pursue it.

## Recommendation (startup speed without a code cache)

Since FEX won't persist compiled code, cold-start JIT cost is paid every launch.
Lower-risk levers to try from the app side (no rebuild):

- `FEX_TSOENABLED=0` / the existing `FEX_PARANOIDTSO=0` already in use — keep.
- Reduce what gets JITed at all: the Deck-UI already uses `--single-process` /
  `--in-process-gpu`, which cuts the number of Chromium processes (each of which
  otherwise re-JITs its own code). Fewer processes ≈ less duplicate JIT.
- Keep the webhelper process warm across UI toggles rather than relaunching.

If persistent caching becomes a hard requirement, the realistic path is a FEX
fork that restores object-code serialization for the arm64ec backend — tracked
separately, not in this recipe.
