# URGENT — pre-release blockers

Surfaced at the start of every session (see CLAUDE.md). Delete this file when
every item below is resolved.

## 1. `mlx-audio-swift` released (now `0.1.6-tts.1`) — RESOLVED

`feature/moss-tts-nano` is merged into `main` (`--no-ff`) and tagged
`0.1.5-tts.1`, matching how `0.1.4-tts.1` was cut. `Package.swift` pins `0.1.6-tts.1`
(which adds companion-repository support) and `Package.resolved` records it, so other repos —
including the news app — consume TTSMLX normally.

Verified: TTSMLX builds against the tag (not the local path), the resolved
checkout reports `0.1.5-tts.1`, and the full suite passes (125 tests, 20
suites).

The `Packages/mlx-audio-swift` symlink is left in place for future local
development; nothing references it now. To develop against a local checkout
again, swap the `.package(url:exact:)` line for
`.package(name: "mlx-audio-swift", path: "Packages/mlx-audio-swift")` and
remember to restore it before cutting a release.

## 2. `mlx-swift` pin had drifted off the background-safe fork — RESOLVED (0.10.0)

History: the pin drifted to an upstream commit without the patch twice, and
upstream later published its own `0.31.5`, so the fork tag stopped
identifying the fork; the mirror was the only thing keeping resolution right.

**Durable fix — DONE (2026-11-04, runtime migration).** The fork was re-cut
at upstream `mlx-swift 0.33.0` and tagged **`0.33.100`**: a normal version
(prerelease tags are excluded from the `from: "0.33.0"` ranges that upstream
mlx-audio-swift declares) with a patch number upstream will never publish, so
the tag can no longer be confused with an upstream release. The Metal patch
is re-targeted at `device.cpp`, where the completion handler now lives
(`Patches/mlx-c-0.33.0-background-safe-command-buffer.patch`), and
`Tools/verify-mlx-fork.sh` checks that file. `mlx-swift-lm` left the graph,
so only upstream mlx-audio-swift still names `ml-explore/mlx-swift`; the
tracked mirror plus CI verification stay in place for that (see item 5).

## 3. MOSS-TTS-Nano is `.implemented`, not `.validated`

Since 0.10.0 MOSS runs on **upstream's** port (`Blaizzy/mlx-audio-swift`
v0.1.8, which includes the codec *encoder*, so `referenceAudio` cloning now
works) plus three fork additions kept from the old port: the bundled
pre-encoded voices (`MossVoicePack`, default `en_news`), the `codebookCount`
dial the generation profiles drive, and sentence-by-sentence decoding (a
whole-passage decode is quadratic in length). The old port is gone with the
old fork lineage.

Still open before `.validated`:

* **Peak memory** has not been re-measured on the upstream port; the catalog
  keeps the previous macOS figure (1.6 GB) and says so.
* **Throughput** on macOS in a debug build is about 0.7x realtime (the old
  port measured 1.2x); nothing in TTSMLX changed, so the difference is the
  upstream generation loop. Worth profiling before promoting.
* **End-of-audio** occasionally does not fire at the model's sampling
  defaults: one of five macOS runs filled the 375-frame budget with silence
  after the speech. The text chunker limits that to one chunk; the catalog
  entry documents it.

## 4. Downloaded models live in a directory iOS is allowed to delete — RESOLVED (0.11.1)

`HubCache.default` resolves to `Library/Caches/huggingface/hub` on iOS, which
the system purges under storage pressure without telling the app.

**Fix (0.11.1):** on iOS-family systems `TTSModelStore.defaultModelCacheRoots()`
leads with `Library/Application Support/huggingface/hub`; the store's
`hubCache` (what the synthesizer hands the runtime loader) and
`TTSBackgroundModelDownloader.destinationDirectory` both use that first root,
so every download lands there and every load looks there first. The directory
is marked `isExcludedFromBackup`. `Library/Caches` stays in the lookup list,
and installs found there are moved into the durable root on the store's first
lookup (same-volume renames; a durable copy wins over a stale cached one).
macOS behaviour is unchanged, and an explicit `HF_HOME` / `HF_HUB_CACHE` still
wins everywhere. Covered by `Tests/TTSDurableModelCacheTests.swift`.

Residual: the runtime's Pocket-TTS voice loader fetches voice embeddings with
`HubCache.default` (a few MB, re-fetched automatically if purged); fixing it
needs a fork change.

## 5. Consumers must add a SwiftPM mirror for `mlx-swift`

Two packages name `mlx-swift`: TTSMLX names the background-safe fork, while
upstream `mlx-audio-swift` names `ml-explore/mlx-swift` (`mlx-swift-lm` left
the graph in 0.10.0). SwiftPM resolves the shared identity to whichever URL it
meets first — and the build succeeds either way. Xcode was observed picking
upstream, which ships an app **without** the Metal background patch.

Every consuming app needs this at its package root, in
`.swiftpm/configuration/mirrors.json`:

```json
{
  "object": [
    { "original": "https://github.com/ml-explore/mlx-swift.git",
      "mirror": "https://github.com/fil-technology/mlx-swift.git" },
    { "original": "https://github.com/ml-explore/mlx-swift",
      "mirror": "https://github.com/fil-technology/mlx-swift.git" }
  ],
  "version": 1
}
```

Both spellings are required: some packages declare the URL without `.git`.

Verify with `Tools/verify-mlx-fork.sh`, which checks the resolved submodule URL
and greps the patch marker out of `device.cpp`. **Now wired into CI**
(`.github/workflows/ci.yml` installs the mirror, resolves, then verifies) and
the mirror itself is tracked in this repo, so TTSMLX's own builds are covered.
This drift has appeared four separate ways (a stale `Package.resolved` pin,
Xcode resolving to upstream, a poisoned local SwiftPM repository mirror, and a
CI checkout failure once upstream published a colliding `0.31.5`) — every
consuming app still needs its own copy of the mirror, per above.

The durable fix would be to declare the fork URL inside the mlx-audio-swift
fork too, after which nothing in the graph names upstream and no mirror is
needed. Not done: upstream's own `Package.swift` keeps naming upstream, and the
fork is rebased on every upstream release, so the mirror stays the one place
that redirects every declaration at once.
