# TTSMLX → ReadMeBook migration guide

This document is the briefing for an LLM doing a focused migration of the
PagePod / ReadMeBook iOS app (`Source/Sources/ReadMeBook/Services/SpeechEngine.swift`)
onto the new TTSMLX 0.4 helper APIs. Read this end-to-end before editing
anything in the app.

## TL;DR

TTSMLX gained eleven new helper modules between v0.3 and v0.4. Most of
[`SpeechEngine.swift`](../../Codex-based/AppleEcosystem/iOS/ReadMeBook/Source/Sources/ReadMeBook/Services/SpeechEngine.swift)
(about 1500 lines today) duplicates work the library now does natively.
Expect to delete ~600-800 lines and gain: pitch-preserving speed control,
exact paragraph-highlight sync, prefetching with thermal/power guards,
device-aware model selection, typed error fallbacks, structured diagnostics.

The library is fully built and tested locally (50 tests, all green). It
isn't published yet — the validation flow below uses a **local SwiftPM
path** so ReadMeBook consumes the work-in-progress copy directly.

---

## Step 1 — point ReadMeBook at the local TTSMLX checkout

TTSMLX lives at:
```
/Users/sviatoslavfil/Development/Fil.Technology/Packages/TTSMLX
```

Its sibling `mlx-audio-swift` (a local fork during active dev) lives at:
```
/Users/sviatoslavfil/Development/Fil.Technology/Packages/mlx-audio-swift
```

Both must be on disk together — TTSMLX's `Package.swift` already references
`../mlx-audio-swift` via a local path dep.

### In ReadMeBook's Xcode project

1. Open `ReadMeBook.xcodeproj`.
2. Project navigator → `ReadMeBook` (the project, not the target) → **Package
   Dependencies** tab.
3. Find the `TTSMLX` entry. Note its current version constraint (probably
   `from: "0.3.0"` or similar) so you can restore it later.
4. **Remove** the remote dependency.
5. **Add Local…** and select the directory
   `/Users/sviatoslavfil/Development/Fil.Technology/Packages/TTSMLX`.
6. Xcode will resolve. Confirm the `TTSMLX` library product gets attached
   to the `ReadMeBook` target (and any widget extensions that link it).

If the project uses XcodeGen (`project.yml`), edit the package section so it
looks roughly like:
```yaml
packages:
  TTSMLX:
    path: ../../../../Packages/TTSMLX  # adjust as needed
```
…and run `xcodegen generate` followed by opening the regenerated project.

### Validation build

From the ReadMeBook root:
```
xcodebuild -scheme ReadMeBook -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Or in Xcode: ⌘B against any iPhone simulator. Confirm the build succeeds
**before** changing any app code. The old API surface is fully preserved —
this build should pass on first try.

If it doesn't, the most likely cause is that `mlx-audio-swift`'s sibling
path isn't where TTSMLX expects it. Verify the directory exists.

---

## Step 2 — read the new API surface

Everything below is shipped on the `main` branch of the local TTSMLX
checkout. File paths refer to TTSMLX:

| File | Public surface |
|---|---|
| `Source/TTSTextChunker.swift` | `TTSTextChunker`, `TTSChunkInfo` |
| `Source/TTSAudioCache.swift` | `TTSAudioCache` (actor), `WriteHandle` |
| `Source/TTSDiagnostics.swift` | `TTSDiagnostic` enum, `TTSDiagnosticHandler` typealias |
| `Source/TTSDeviceProfile.swift` | `TTSDeviceClass`, `TTSDeviceProfile` |
| `Source/TTSSupport.swift` | New `TTSError` cases + `TTSError.wrap(_:modelID:stage:)` |
| `Source/TTSModel.swift` | `TTSModelCapabilities.peakMemoryMB`, `.minimumDeviceClass`, `TTSModelDescriptor.isSupported(on:)` |
| `Source/TTSMLX.swift` | `TTSMLX.recommendedModel(for:)` |
| `Source/TTSSpeechSynthesizer.swift` | `synthesizeLong`, `synthesizeAll`, `prepareForPlayback`, `warmUp`, `unload`, `unloadAll`, `handleMemoryWarning`, `setDiagnosticHandler`, diagnostic init param |
| `Source/TTSPrefetchQueue.swift` | `TTSPrefetchQueue` (actor), `TTSPrefetchRequest`, `TTSPrefetchPolicy` |
| `Source/TTSPlaybackController.swift` | `TTSPlaybackController` (MainActor) |

Read the source files for the docstrings — they're written for callers, not
implementers. Especially:
- `TTSSpeechSynthesizer.swift` for synthesize* + lifecycle
- `TTSPrefetchQueue.swift` for the prefetch contract
- `TTSPlaybackController.swift` for the playback graph

---

## Step 3 — concrete migration map

Every row below is a unit of work. Do them one at a time. After each one,
build and run on a simulator to confirm playback still works.

### 3.1 Construct the synthesizer with a diagnostic handler

**Before** — `SpeechEngine.swift:290`
```swift
private let synthesizer = TTSSpeechSynthesizer()
```

**After**
```swift
private let synthesizer = TTSSpeechSynthesizer(diagnosticHandler: { [logger] event in
    Task { @MainActor in
        switch event {
        case let .firstBufferYielded(_, latency):
            logger.log("first buffer in \(latency, format: .fixed(precision: 3))s")
        case let .chunkStarted(_, index, range):
            // Used in step 3.6 for highlighting.
            NotificationCenter.default.post(
                name: .ttsmlxChunkStarted,
                object: nil,
                userInfo: ["index": index, "range": range]
            )
        case let .chunkFinished(_, index, duration):
            logger.log("chunk \(index) finished in \(duration)s")
        case let .errorOccurred(modelID, stage, error):
            logger.error("\(modelID ?? "?") failed at \(String(describing: stage)): \(error.localizedDescription)")
        default:
            break
        }
    }
})
```

The diagnostic handler is `@Sendable`. If you don't want to route through
`NotificationCenter`, capture a weak ref to the engine and write to its
`@MainActor` state via a `Task { @MainActor in ... }`.

### 3.2 Replace the hardcoded Pocket-TTS / iPhone fallback

**Before** — `SpeechEngine.swift:479-487`
```swift
#if os(iOS)
if isPocketTTS(request.model), UIDevice.current.userInterfaceIdiom == .phone {
    logger.error("Pocket TTS disabled on iPhone for \(request.title) due to memory pressure risk")
    onStatusMessageChange?("Using system speech on iPhone to avoid memory crashes.")
    isUsingFallbackEngine = true
    await fallbackEngine.speak(request: request)
    return
}
#endif
```

**After**
```swift
if !request.model.isSupported(on: .current) {
    logger.error("\(request.model.id) not supported on \(TTSDeviceProfile.current.deviceClass)")
    onStatusMessageChange?("Using system speech: \(request.model.displayName) needs more memory than this device offers.")
    isUsingFallbackEngine = true
    await fallbackEngine.speak(request: request)
    return
}
```

You can also delete the `isPocketTTS(_:)` helper at `SpeechEngine.swift:1183-1185`.

**For model picker UIs**: when ReadMeBook shows the user a list of TTS
models to choose from, filter by device profile so the user can't pick a
model that won't run:
```swift
let available = TTSMLX.supportedModels.filter { $0.isSupported(on: .current) }
// or pick automatically:
let pick = TTSMLX.recommendedModel(for: .current)
```

### 3.3 Replace the text chunker

**Before** — `SpeechEngine.swift:1187-1237` (the entire `streamingChunks(for:)` function)

**After** — delete the function. Use the chunker directly where it's called:
```swift
private let chunker = TTSTextChunker(
    firstChunkCharacterLimit: 80,
    followupChunkCharacterLimit: 220
)
// callsite:
let chunkInfos = chunker.chunkInfos(for: request.text)
```

Note: use `chunkInfos(for:)`, not `chunks(for:)` — the former preserves
character ranges into the original text, which step 3.6 uses for
highlighting.

### 3.4 Replace the cache plumbing

**Before** — `SpeechEngine.swift:1134-1280` (≈150 lines: `resolvedCacheURL`,
`candidateCacheURLs`, `cachePayload`, `temporaryCacheURL`, `removeCacheArtifacts`,
`finalizeCacheFile`, `isUsableCacheFile`, `removeInvalidCacheFiles`).

**After** — construct once, use the actor API:
```swift
private let audioCache: TTSAudioCache

init() {
    let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let cacheDir = baseDirectory
        .appendingPathComponent("PagePod", isDirectory: true)
        .appendingPathComponent("AudioCache", isDirectory: true)
    self.audioCache = try! TTSAudioCache(directoryURL: cacheDir)
    // ... rest of init
}
```

Then at call sites:
```swift
// Look up:
let key = await audioCache.key(modelID: request.model.id,
                                voice: request.modelVoice,
                                text: request.text)
if let cachedURL = await audioCache.cachedURL(forKey: key) {
    playCachedAudio(from: cachedURL, title: request.title)
    return
}

// Write while streaming (replaces the .part file dance):
let handle = await audioCache.reserveWrite(forKey: key)
var audioFile: AVAudioFile?
for try await chunk in stream {
    let buffer = chunk.buffer
    if audioFile == nil {
        let format = buffer.format
        audioFile = try AVAudioFile(
            forWriting: handle.temporaryURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }
    try audioFile?.write(from: buffer)
    // Also schedule on the player so playback follows generation.
}
audioFile = nil
let finalURL = try await audioCache.finalize(handle)

// Eviction (call periodically or from a settings UI):
await audioCache.prune(toMaxBytes: 500_000_000)
```

`audioCache.key(...)` matches the SHA-256 of `modelID|voice|text` with the
same normalization (CRLF → LF, trim) used by ReadMeBook today, so existing
cache files are still findable. Legacy `.caf` / `.caf.wav` are no longer
detected by `cachedURL(forKey:)` — if you want to migrate them, write a
one-shot migration that re-keys those files.

### 3.5 Replace the prefetch task

**Before** — `SpeechEngine.swift:382-445` (`prefetch(requests:)`, the
`generationID`/`prefetchGenerationID` plumbing, the manual `cacheOnly(...)`
method at `SpeechEngine.swift:1282-1341`).

**After**
```swift
private lazy var prefetchQueue = TTSPrefetchQueue(
    synthesizer: synthesizer,
    cache: audioCache,
    policy: TTSPrefetchPolicy(
        thermalCutoff: .serious,
        pauseOnLowPowerMode: true,
        maxQueuedItems: 32
    )
)

func prefetch(requests: [SpeechRequest]) async {
    let prefetchRequests = requests.map { req in
        TTSPrefetchRequest(
            text: req.text,
            model: req.model,
            voice: req.modelVoice,
            options: TTSSynthesisOptions(
                voice: req.modelVoice,
                streamingInterval: 0.22
            )
        )
    }
    await prefetchQueue.enqueue(prefetchRequests)
}

func updateScenePhase(_ phase: ScenePhase) {
    // ...
    if phase != .active {
        Task { await prefetchQueue.cancelAll() }
    }
}
```

The queue automatically:
- Skips items already in the cache
- Pauses on `.serious` thermal state (no manual `ProcessInfo` checks)
- Pauses on Low Power Mode
- Logs to `os.Logger` subsystem `technology.fil.ttsmlx`

You can delete: `prefetchTask`, `prefetchGenerationID`, `prefetchingCachePayload`,
`cacheOnly(...)`. The whole "cancel matching generation ID" machinery
becomes `await prefetchQueue.cancelAll()`.

### 3.6 Add highlight sync via chunk diagnostics

Today ReadMeBook approximates the "currently spoken" position with
`(elapsed / duration) * totalCharCount` math at `SpeechEngine.swift:1083-1100`.
The new diagnostic gives you the exact character range.

**Add** — listen for `.chunkStarted` (per the handler in 3.1):
```swift
// In ReaderStore or wherever the highlight state lives:
NotificationCenter.default.addObserver(
    forName: .ttsmlxChunkStarted,
    object: nil,
    queue: .main
) { [weak self] note in
    guard let range = note.userInfo?["range"] as? Range<Int> else { return }
    self?.currentlyReadingCharacterRange = range
}
```

Then convert the `Range<Int>` (character offsets in the original text) back
to whatever the highlight UI expects:
```swift
let start = request.text.index(request.text.startIndex, offsetBy: range.lowerBound)
let end = request.text.index(request.text.startIndex, offsetBy: range.upperBound)
let highlightedSubstring = request.text[start..<end]
```

For **word-level** highlighting within a chunk, interpolate on the app
side: when a chunk starts at time `t0` and ends at `t1` (you'll know `t1`
from `.chunkFinished`), use the player's current time to interpolate
across the words. The library deliberately doesn't try to model phoneme
timing because MLX TTS models don't expose it consistently.

### 3.7 Typed error handling

**Before** — `SpeechEngine.swift:599-610`
```swift
} catch is CancellationError {
    // ...
} catch {
    self.logger.error("Generation failed for \(request.title): \(error.localizedDescription)")
    self.removeCacheArtifacts(for: cacheURL)
    self.playbackTask = nil
    // blanket fallback to system speech
    self.isUsingFallbackEngine = true
    await self.fallbackEngine.speak(request: request)
}
```

**After**
```swift
} catch is CancellationError {
    self.finishPlayback(resetState: true)
} catch let error as TTSError {
    switch error {
    case .networkUnavailable:
        self.onStateChange?(.failed("No internet — the model needs to download first."))
    case .outOfMemory:
        await self.synthesizer.handleMemoryWarning()
        self.isUsingFallbackEngine = true
        await self.fallbackEngine.speak(request: request)
    case .modelLoadFailed:
        self.isUsingFallbackEngine = true
        await self.fallbackEngine.speak(request: request)
    case .generationFailed:
        // Retry once, then fall back.
        // (or just fall back immediately — your call)
        self.isUsingFallbackEngine = true
        await self.fallbackEngine.speak(request: request)
    case .deviceUnsupported(_, let reason):
        self.onStateChange?(.failed(reason))
    default:
        self.isUsingFallbackEngine = true
        await self.fallbackEngine.speak(request: request)
    }
} catch {
    self.isUsingFallbackEngine = true
    await self.fallbackEngine.speak(request: request)
}
```

### 3.8 Wire memory warnings

**Add** to `PagePodApp.swift` or wherever the `SpeechEngine` lives:
```swift
#if os(iOS)
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil,
    queue: .main
) { _ in
    Task {
        await speechEngine.synthesizer.handleMemoryWarning()
        await speechEngine.prefetchQueue.cancelAll()
    }
}
#endif
```

### 3.9 Pre-warm on preparePlayback

**Before** — `SpeechEngine.swift:367-380`
```swift
func preparePlayback(for model: TTSModelDescriptor) async {
    do {
        let modelStore = await synthesizer.modelStoreInstance()
        _ = try await modelStore.ensureDownloaded(model, hfToken: nil, progressHandler: nil)
        onStatusMessageChange?(nil)
    } catch {
        // ...
    }
}
```

**After** (also pre-generates first paragraph if you can supply one):
```swift
func preparePlayback(for model: TTSModelDescriptor, firstParagraph: String? = nil) async {
    do {
        if let firstParagraph, !firstParagraph.isEmpty {
            // Warm AND cache the first chunk → first tap on Play is instant.
            _ = try await synthesizer.prepareForPlayback(
                using: model,
                initialText: firstParagraph,
                options: TTSSynthesisOptions(streamingInterval: 0.22),
                cache: audioCache
            )
        } else {
            // Just warm the model.
            _ = try await synthesizer.warmUp(model)
        }
        onStatusMessageChange?(nil)
    } catch {
        onStateChange?(.failed("Could not prepare \(model.displayName)."))
    }
}
```

### 3.10 Replace the AVAudioEngine graph + add speed control

**Before** — the bespoke graph at `SpeechEngine.swift:292-365, 900-961`
(engine, playerNode, scheduleBuffer, schedule duration tracking, etc.).

**After** — `TTSPlaybackController` owns the graph and exposes speed
control. The controller is `@MainActor`, matching where `AVAudioEngine`
wants to live.

```swift
private let playback = TTSPlaybackController(rate: 1.0)

// settings:
playback.rate = 1.25  // pitch-preserving 1.25× speed

// streaming:
let stream = try await synthesizer.synthesizeLong(
    request.text,
    using: request.model,
    options: TTSSynthesisOptions(voice: request.modelVoice, streamingInterval: 0.28)
)
try await playback.play(stream: stream) {
    self.finishPlayback(resetState: true)
}

// cached file:
try playback.play(file: cachedURL) {
    self.finishPlayback(resetState: true)
}

// pause/resume/stop:
playback.pause()
playback.resume()
playback.stop()
```

What you keep doing on the app side:
- `AVAudioSession.setCategory(.playback, mode: .default, options: .duckOthers)`
  — that's app policy, the library deliberately doesn't touch it
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` — also app policy
- Cache eviction triggers (e.g. settings screen "Clear audio cache" button)

### 3.11 Settings: add a speed picker

Bonus from 3.10. The library already supports 0.5×-2.0× pitch-preserving.
Surface it:
```swift
@AppStorage("playbackRate") var playbackRate: Double = 1.0
// in your settings view:
Picker("Playback speed", selection: $playbackRate) {
    Text("0.8×").tag(0.8)
    Text("1.0×").tag(1.0)
    Text("1.25×").tag(1.25)
    Text("1.5×").tag(1.5)
}
// then propagate to engine:
.onChange(of: playbackRate) { newValue in
    Task { @MainActor in speechEngine.playback.rate = Float(newValue) }
}
```

---

## What does NOT change (and shouldn't)

- `MPNowPlayingInfoCenter` setup (`SpeechEngine.swift:1448-1465`) — app policy
- `MPRemoteCommandCenter` (`SpeechEngine.swift:1365-1401`) — app policy
- `AVAudioSession.setCategory` / `setActive` — app policy
- `AVSpeechSynthesizer` fallback path (`SystemSpeechEngine`) — keep it as a fallback
- Cache directory choice — apps pick their own
- Anything in `ReaderStore` / view layer

---

## Step 4 — validation checklist

After the migration, run through these manually on a real device (the
simulator can't reproduce thermal or memory pressure realistically):

1. **Cold launch → play a chapter.** First buffer should arrive within
   ~1 second on M-class iPad / Mac, ~2-3 seconds on iPhone (model permitting).
2. **Pause / resume / stop.** State machine in `TTSPlaybackController`
   should behave identically to the old graph.
3. **Speed picker.** 0.8× → 1.0× → 1.25× → 1.5× transitions should sound
   pitch-stable (no chipmunk effect).
4. **Backgrounding mid-playback.** Cache should not corrupt; coming back
   to foreground should resume cleanly.
5. **Low Power Mode.** Enable it → prefetch should stop within a few
   seconds (check `os_log` filter on subsystem `technology.fil.ttsmlx`
   category `Prefetch`).
6. **Thermal throttling.** Generate continuously for ~5 minutes. Prefetch
   should pause when thermal state hits `.serious`.
7. **Memory warning.** Use the simulator menu (Debug → Simulate Memory
   Warning) → `handleMemoryWarning()` should fire; subsequent playback
   should still work (will re-warm).
8. **Network unavailable.** Airplane mode + un-cached chapter → error
   should be `.networkUnavailable`, surfaced to the UI as such.
9. **Highlighting.** The currently-speaking range should track the audio,
   visibly chunk-by-chunk. Word-level interpolation is on you.
10. **Cache invalidation.** Switch voice → next playback should regenerate
    (different cache key, automatically).

---

## Open questions to report back

After the migration, write up answers to these for the TTSMLX maintainer:

1. **Where does TTSMLX still feel awkward from the app's side?** Are any
   APIs missing a needed parameter, returning the wrong type, or forcing
   redundant work? Concrete code snippets > vague impressions.

2. **Is `TTSChunkInfo.characterRange` enough granularity for highlighting,
   or does the app need an intermediate hook (e.g., word-level callbacks)?**
   If interpolation works fine in practice, say so; if it's choppy or
   diverges from the audio, describe how.

3. **Does `TTSPrefetchQueue.cancel(where:)` need a more ergonomic API?**
   For instance, should it take a Set of cache keys to cancel rather than
   a predicate? What patterns does the app actually use?

4. **Does the `TTSPlaybackController` need additional features?** Common
   asks: scrub-to-time, current-time observation, mix-with-others, ducking
   policy hooks. Note any you needed and had to work around.

5. **Are there iOS-specific perf wins still missing?** Examples: should the
   library auto-call `handleMemoryWarning()` on its own thermal/memory
   observation? Should it expose a "preferred quality given current battery
   state" helper?

6. **Did the device-class catalog values (`peakMemoryMB`,
   `minimumDeviceClass`) match reality?** If Marvis OOMed on iPhone 12 with
   `peakMemoryMB: 400`, that's the kind of empirical correction the catalog
   needs.

---

## Reference: minimal new-API cheat sheet

```swift
import TTSMLX

// 1. Construct
let cache = try TTSAudioCache(directoryURL: cacheDir)
let synthesizer = TTSSpeechSynthesizer(
    diagnosticHandler: { event in /* observe lifecycle */ }
)

// 2. Device-aware model pick
let model = TTSMLX.recommendedModel(for: .current) ?? TTSMLX.supportedModels[0]
guard model.isSupported(on: .current) else {
    // fall back
}

// 3. Warm + first-chunk preload
_ = try await synthesizer.prepareForPlayback(
    using: model,
    initialText: firstParagraph,
    cache: cache
)

// 4. On-demand streaming with highlighting
let stream = try await synthesizer.synthesizeLong(
    text,
    using: model,
    options: TTSSynthesisOptions(voice: .tara, streamingInterval: 0.28),
    chunker: TTSTextChunker()
)

// 5. Pre-generate full chapter for offline
_ = try await synthesizer.synthesizeAll(
    text,
    using: model,
    options: TTSSynthesisOptions(voice: .tara),
    into: outputURL
)

// 6. Background prefetch
let queue = TTSPrefetchQueue(synthesizer: synthesizer, cache: cache)
await queue.enqueue([
    TTSPrefetchRequest(text: nextChapter, model: model, voice: .tara)
])

// 7. Playback with pitch-preserving speed
let playback = TTSPlaybackController(rate: 1.0)
playback.rate = 1.25
try await playback.play(stream: stream) { /* on end */ }

// 8. Lifecycle
await synthesizer.handleMemoryWarning()
```
