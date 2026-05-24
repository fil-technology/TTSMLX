# Debugging TTSMLX

When the framework "stops generating audio" or behaves unexpectedly, the
first move is to read the logs. TTSMLX uses `os.Logger` end-to-end, so
every phase boundary, error, and unusual condition shows up in **Console.app**
on macOS and in the device log on iOS — no extra setup needed.

## Quick reference

Subsystem: `technology.fil.ttsmlx`

| Category | What it covers |
|---|---|
| `Synthesizer` | `synthesize`, `synthesizeStream`, `synthesizeLong`, `prepareNarration`, `prepareModel`, `prepareForPlayback`, `warmUp`/`unload` |
| `Playback` | `TTSPlaybackController` engine lifecycle, scheduling, seek, narration playback |
| `Prefetch` | `TTSPrefetchQueue` enqueue/replace/drain, thermal/LPM pauses |

## Console.app filter

On macOS or with an iOS device tethered:

1. Open **Console.app**
2. Choose the device (or "All Messages" for Mac runs)
3. Search bar → `subsystem:technology.fil.ttsmlx`
4. Optional category filter: `category:Synthesizer`
5. Set **Action → Include Info Messages** and **Include Debug Messages** to see everything (defaults hide them)

The log is structured. The most useful lines start with one of:
- `ENTRY` — public entry point of a method
- `FIRST BUFFER` — the model emitted its first audible PCM buffer
- `FINISHED` — a phase completed successfully
- `FINISHED WITH ZERO BUFFERS` — **the most likely "stopped generating" symptom** (see below)
- `ERROR <site>:` — a catch site fired
- `download STARTED`/`download FINISHED` — model snapshot transfer
- `MLX load STARTED`/`MLX load FINISHED` — weights materialization

## Reading a healthy synthesis trace

A successful `synthesizeStream` call against a warmed model looks roughly
like this:

```
[Synthesizer] synthesizeStream: ENTRY model=mlx-community/pocket-tts chars=120 voice=alba interval=2.0s
[Synthesizer] prepareModel: ENTRY mlx-community/pocket-tts wasWarmed=true
[Synthesizer] prepareModel: resolved mlx-community/pocket-tts installed=true in 0.01s
[Synthesizer] prepareModel: MLX load STARTED for mlx-community/pocket-tts
[Synthesizer] prepareModel: MLX load FINISHED for mlx-community/pocket-tts in 0.34s sampleRate=24000
[Synthesizer] synthesizeStream[mlx-community/pocket-tts]: FIRST BUFFER at 0.91s, frameLength=24000
[Playback]    connectIfNeeded: initial connect sr=24000.0 ch=1
[Playback]    connectIfNeeded: engine.start() OK
[Playback]    schedule: buffer #1 frameLength=24000 sampleRate=24000
[Playback]    schedule: playerNode.play() invoked; state=playing
[Synthesizer] synthesizeStream[mlx-community/pocket-tts]: FINISHED total=4 buffers (empty=0 skipped) in 3.21s
```

If you don't see `ENTRY`, the framework was never called → app-side issue.
If you see `ENTRY` but no `FIRST BUFFER`, see below.

## Diagnosing "stopped generating"

The most common failure is **`FINISHED WITH ZERO BUFFERS`** in the
`Synthesizer` category. The framework emits this warning when MLX
generation completed without emitting any audible PCM. Three usual causes:

1. **Text contained only punctuation / whitespace.** Try generating with
   plain English first to confirm the rest of the path works.
2. **MLX runtime issue on this device.** Try the same text against a
   different model (e.g. Soprano if you were using Pocket-TTS). If
   different models all fail the same way, the issue is upstream of the
   wrapper.
3. **Model loaded but the `generate` path is mis-wired upstream.** Less
   common; would also affect the demo app. Worth filing upstream.

If you see `ERROR` before `FINISHED`, the catch site name tells you
which phase failed:

| Site | Phase that failed |
|---|---|
| `prepareModel.ensureDownloaded` | Model download / network |
| `prepareModel.MLXLoad` | Weight materialization |
| `synthesize.generate` | Non-streaming sample production |
| `synthesizeStream.upstream` | Streaming buffer production |
| `synthesizeLong.chunkLoop` | Long-form chunk orchestration |

The `underlying=` portion of the error line gives the raw error
description (whatever MLX or `URLSession` or `AVAudioFile` actually said).

If `synthesize*` `ENTRY` fires but you never see `prepareModel: ENTRY`,
the synthesizer is hung before the first await. Almost always a deadlock
in the caller's actor — make sure you're not waiting for the synthesizer
from a context the synthesizer is also waiting on.

## Diagnosing "no sound but logs look fine"

If `synthesizeStream` finishes with N buffers and `play(stream:)` shows
`stream drained, N buffers scheduled` but you don't hear anything:

1. Check **`engine.start() OK`** appeared in the Playback log. If it
   logged `engine.start() FAILED`, the underlying error tells you why —
   usually the app didn't configure `AVAudioSession` for `.playback`.
2. Check **`playerNode.play() invoked; state=playing`** appeared. If it
   didn't, the controller never transitioned out of `.paused`.
3. Check the **device's mute switch and volume**. Yes, really — easy to
   forget on a real device.
4. If the buffers' `sampleRate=` log line shows an unexpected value (e.g.
   `8000`), the model is emitting at a sample rate the engine can play
   but the device may not have appropriate output routing for. This is
   rare with modern models.

## State snapshot

For ad-hoc inspection, the synthesizer exposes a read-only snapshot:

```swift
let snap = await synthesizer.snapshot()
print(snap.warmedModelIDs)            // [String]
print(snap.eventStreamSubscriberCount) // Int
print(snap.hasClosureHandler)          // Bool
```

The call also writes itself to the `Synthesizer` log, so it shows up
alongside synthesis activity when you're trying to correlate.

## Capturing logs to a file

When you need to share logs with the maintainer:

```bash
# On macOS, capture the last 5 minutes of TTSMLX activity
log show --predicate 'subsystem == "technology.fil.ttsmlx"' \
         --info --debug --last 5m > tts-debug.log
```

On iOS, use Console.app with the device tethered, filter to subsystem,
and **File → Save As…**

## Severity used in this framework

- `logger.debug` — high-frequency, off by default in Console
- `logger.info` — phase boundaries, healthy progress
- `logger.warning` — unusual but non-fatal (e.g. zero-buffer finish,
  thermal pause)
- `logger.error` — caught error, will throw upward

All `logger.error` lines use the standardized shape:
`ERROR <site>: modelID=<id> stage=<stage> underlying=<localizedDescription>`
so they're easy to grep.
