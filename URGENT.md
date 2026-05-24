# URGENT — Pre-Release Blockers

**Read this file before working on anything in this repo. Surface its contents to the user at the start of every session until the items here are cleared.**

Last updated: 2026-05-24 (after the mlx-swift background-safe patch).

## Status

`v0.6.0` is tagged and pushed to `main`, **BUT it is not safely consumable yet**. There are unresolved dependencies that mean a downstream consumer pulling `v0.6.0` will hit the same crashes the release claims to fix.

## Blockers

### 1. `mlx-audio-swift` patches are uncommitted

The `broadcast_shapes (1,8,N,64) vs (1,8,2N,64)` KV-cache contamination crash is fixed by patches in `/Users/sviatoslavfil/Development/Fil.Technology/Packages/mlx-audio-swift/`. Those patches exist on disk but are **not committed**:

- `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSMimiAdapter.swift` — `resetState()`, `encodeToLatent`, `decodeFromLatent` rebuild caches outright
- `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` — `generate()` calls `mimi.resetState()` defensively at the top
- `Sources/MLXAudioCodecs/Mimi/Mimi.swift` — same fix in the shared codec, plus new public `resetDecoderCache()`

Without these patches, the model cache shipped in `v0.6.0` reintroduces the crash on voice switch and long sessions. The `v0.6.0` CHANGELOG explicitly tells consumers to pull patched mlx-audio-swift, so we owe them a published version of it.

### 2. The local `mlx-audio-swift` git state is broken

`/Users/sviatoslavfil/Development/Fil.Technology/Packages/mlx-audio-swift/.git/objects/info/` points at `/Users/sviatoslavfil/Development/Fil.Technology/Packages/TTSMLX/.build/repositories/mlx-audio-swift-4f05d7e9/objects`, which is a SwiftPM cache that no longer exists. The repo has no usable git history right now. This predates our work (the alternates pointer was already broken when the session started); none of our changes caused it. But it does mean the patches can't simply be committed in place — the `.git` directory needs repair or replacement first.

### 3. `Package.swift` points at a local path

```swift
.package(path: "../mlx-audio-swift")
```

This works for the maintainer's machine but not for any downstream consumer pulling `v0.6.0` from GitHub. The release tag effectively can't be consumed by anyone except via local-path checkout.

### 4. `mlx-swift` needs a forked + tagged release for background safety

The Metal-in-background crash (`Insufficient Permission (to submit GPU work from background)` → `std::runtime_error` thrown from Metal's completion handler → uncaught C++ exception → process termination) is **not fixable in TTSMLX or mlx-audio-swift**. The throw site is in the upstream `mlx` C++ runtime, registered as a Metal `addCompletedHandler` callback that runs on Metal's own thread. No Swift try-catch can reach it.

The patch is one block in `Source/Cmlx/mlx/mlx/backend/metal/eval.cpp` and is saved at `Patches/mlx-c-0.31.3-background-safe-check_error.patch`. It swallows the specific "submit GPU work from background" error and lets other Metal errors throw as today. The maintainer has the patch applied locally via `swift package edit mlx-swift`, so it builds and tests green right now — but that local-edit state is per-machine and not published.

To make `v0.6.x` actually safe for backgrounding in any downstream consumer, you need to:
- Fork `ml-explore/mlx` (the C++ submodule, not just `mlx-swift` — the patched file lives there)
- Apply the patch and tag (e.g. `v0.31.3-tts-bg-safe.1`)
- Fork `ml-explore/mlx-swift`, point its submodule at your `mlx` fork, tag matching version
- Point TTSMLX's `Package.swift` at your `mlx-swift` fork instead of `ml-explore/mlx-swift`

Detailed steps in [Docs/mlx-swift-bg-safe-fork.md](Docs/mlx-swift-bg-safe-fork.md).

This is **three** patched dependencies now (mlx, mlx-audio-swift, TTSMLX). Strongly consider opening upstream PRs against `ml-explore/mlx` and the relevant `mlx-audio` upstream so the forks don't have to live indefinitely.

## Required actions before the next release is meaningful

These need to happen in order:

1. **Fix or rebuild the `mlx-audio-swift` git state.** Most pragmatic path: clone fresh from your fork's upstream URL (or from your own GitHub mirror of mlx-audio-swift), and re-apply the patches from this repo's local checkout. Don't try to repair the broken `.git/objects/info/alternates` — easier to start clean.
2. **Commit the patches** to whatever your fork's main branch is. Suggested commit message: "Fix MimiAdapter KV-cache reset to rebuild caches outright (broadcast_shapes crash on model instance reuse)." Reference the TTSMLX `v0.6.0` notes if you want a link.
3. **Tag a release on your mlx-audio-swift fork** (e.g. `v0.4.3-tts-patches.1` or similar — pick a scheme that signals "based on upstream X plus our patches"). Push the tag.
4. **Fork `ml-explore/mlx` and `ml-explore/mlx-swift`, apply the background-safe patch from `Patches/mlx-c-0.31.3-background-safe-check_error.patch`, tag both.** See [Docs/mlx-swift-bg-safe-fork.md](Docs/mlx-swift-bg-safe-fork.md) for the exact steps.
5. **Update TTSMLX's `Package.swift`** to point at:
   - your `mlx-audio-swift` fork URL with `.exact(...)` pinning at its new tag, replacing the `.package(path: "../mlx-audio-swift")` line
   - your `mlx-swift` fork URL with `.exact(...)` pinning at its new tag, replacing the `ml-explore/mlx-swift` line
   Run `swift package resolve` to update `Package.resolved`. Run `swift package unedit mlx-swift` to clear the local-edit state.
6. **Cut TTSMLX `v0.6.1`** with the Package.swift / Package.resolved change. CHANGELOG entry: "Pin mlx-audio-swift and mlx-swift to public tagged versions including KV-cache reset and background-safe check_error patches." Now `v0.6.1` is safely consumable end-to-end.

## How to act on this file

When the user starts a session in this repo:

1. Surface this file's contents immediately, before doing anything else they asked for.
2. Confirm with them whether the items above are still outstanding.
3. If yes, propose tackling them before any new feature/bug work.
4. When the items are all complete, **delete this file** in the same commit that makes them complete. Future sessions don't need to keep seeing it.

Until then, treat this file as a hard precondition. Other work can proceed if the user explicitly accepts the risk of releasing `v0.6.0` without the patched dependency, but they should make that call consciously, not by default.
