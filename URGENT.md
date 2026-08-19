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

## 2. `mlx-swift` pin had drifted off the background-safe fork — FIXED, verify

Both `Package.resolved` (working tree — the committed value was already
correct) and `DemoApp/.../swiftpm/Package.resolved` (gitignored, since the
`.xcodeproj` is generated from `project.yml`) had drifted to mlx-swift
revision `eb889e01`. Neither drift was committed, but both affected every
local and demo-app build. That commit is:

* **not the fork commit** — its `.gitmodules` points `Source/Cmlx/mlx` at
  `ml-explore/mlx`, i.e. **without** the background-safe `check_error` patch
  that `Docs/mlx-swift-bg-safe-fork.md` and the `Package.swift` comment both
  claim is present. The iOS background-Metal crash was therefore unmitigated
  in anything built from that pin, including the demo app.
* **unreachable on the remote** — tag `0.31.5` on
  `fil-technology/mlx-swift` resolves to `82246c3b`, and `eb889e01` exists
  only in local checkouts. Any clean checkout or CI build failed to resolve.

Both files are now re-pinned to `82246c3b` ("Point mlx submodule at
fil-technology/mlx background-safe fork"), whose submodule
`fil-technology/mlx@6525eded` does carry the patch (verified by reading
`mlx/backend/metal/eval.cpp`).

**Still to do:** work out how the drift happened so it cannot recur. A stray
`swift package update` is the likeliest cause — it moves the pin to a newer
upstream commit that satisfies `exact: "0.31.5"` by tag name alone. Because
the demo app's resolution file is gitignored and regenerated, nothing in the
repo protects against this; consider asserting the expected mlx-swift
revision in CI, or verifying the resolved submodule URL at build time.

Note: the `eb889e01` drift is also what made iOS builds fail with
`encuda-utils.swift: cannot find type 'Process'` — that newer upstream commit
introduced a CUDA build-tool plugin that Xcode wrongly builds for iOS. The
correct pin has no such plugin.

## 3. MOSS-TTS-Nano is `.implemented`, not `.validated`

The port (backbone + MOSS-Audio-Tokenizer-Nano decoder) is numerically
validated against the Python `mlx-audio` reference, but:

* **Peak memory is high**: 1.3–1.8 GB observed on macOS when a whole passage
  is generated in one `generate` call. The codec's deepest decoder stage
  attends over `frames * 32` positions, so peak scales with chunk length.
  Note the Reader path is much gentler — `TTSTextChunker` splits at 80/220
  characters, well under MOSS's own 75-token budget, so each call decodes a
  short span. `peakMemoryMB` is set to 1600 from the pessimistic
  single-call figure and should be re-measured on device (via the Reader
  path) before promoting to `.validated`.
* **Upstream already has this model.** `Blaizzy/mlx-audio-swift` ships
  `MossTTSNano` plus a `MossAudioTokenizer` **with an encoder**, so it
  supports cloning from arbitrary reference audio. Evaluate adopting it
  instead of maintaining this port; note upstream also has `OmniVoice`,
  which the `feature/omnivoice` branch is separately mid-port on, and that
  upstream lacks KittenTTS, so it is a merge rather than a fast-forward.
* **Reference-audio cloning is not supported here**: the MOSS codec
  *encoder* is not ported. Named voices ship as pre-encoded prompt codes
  (`MossVoicePack`); `referenceAudio` from callers is rejected, and the
  descriptor sets `supportsReferenceAudio: false`.
* **Time-to-first-audio** measured through the real Reader path
  (`synthesizeLong` + `TTSTextChunker`) is 3.3 s, with overall throughput of
  about 1.2x realtime in a debug build on an M-series Mac. Calling
  `generate` directly on a whole passage is far worse (~25–30 s to first
  audio) because MOSS's own 75-token budget then yields a single chunk;
  `MossTTSNanoModel.maxTextTokensPerChunk` tunes that case.

## 4. Downloaded models live in a directory iOS is allowed to delete

`HubCache.default` resolves to `URL.cachesDirectory/huggingface/hub` on iOS —
i.e. inside `~/Library/Caches`. iOS purges that directory under storage
pressure, without notice and without telling the app.

For a news app that downloads ~375 MB once during onboarding, that means the
model can silently disappear and the next article stalls on a re-download. The
risk is proportional to how tight the user's storage is.

Both halves already agree on this location — the runtime loader
(`ModelUtils`) and `TTSBackgroundModelDownloader` — so moving it is a single
coherent change rather than a hunt:

* `TTS.loadModel(modelRepo:hfToken:cache:)` and
  `ModelUtils.resolveOrDownloadModel(..., cache:)` already accept a `HubCache`.
  `MLXTTSModelLoader.load` is what currently drops it and falls back to
  `.default`.
* A custom `HubCache(cacheDirectory:)` under Application Support would be
  durable. Application Support is backed up, so the model directory should be
  marked `isExcludedFromBackup` or users get ~375 MB added to their iCloud
  backup.
* Existing installs would need either a migration or one re-download.

Not changed here because it alters where every model lives and needs a
migration decision.

## 5. Consumers must add a SwiftPM mirror for `mlx-swift`

Three packages name `mlx-swift`: TTSMLX names the background-safe fork, while
`mlx-audio-swift` and `mlx-swift-lm` name upstream. Upstream publishes the
same version tags, so SwiftPM resolves the shared identity to whichever URL it
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

Both spellings are required: `mlx-swift-lm` declares the URL without `.git`.

Verify with `Tools/verify-mlx-fork.sh`, which checks the resolved submodule URL
and greps the patch marker out of `eval.cpp`. Wire it into CI — this drift has
appeared three separate ways (a stale `Package.resolved` pin, Xcode resolving
to upstream, and a poisoned local SwiftPM repository mirror), and every time
the build succeeded while silently lacking the fix.

The durable fix is to fork `mlx-swift-lm` and repoint its `mlx-swift`, after
which nothing in the graph names upstream and no mirror is needed. That needs
a new repository under `fil-technology`.
