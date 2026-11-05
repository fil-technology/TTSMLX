## Findings

Read with the tables above; Release builds are the headline, the debug
tables are kept because earlier validation notes in this repository quote
debug numbers.

- **Debug builds understate every model by 2–4x.** Qwen3-TTS 0.6B went from
  0.63x realtime (128 stalls over the long-form fixture) in debug to 2.2x and
  zero stalls in Release on the same Mac; VibeVoice from 0.64x to 1.6x. Any
  latency claim without a build label is meaningless.
- **The MLX buffer cache must be capped.** Uncapped, one long-form Kokoro run
  reached 24 GB resident on the Mac and pushed the machine into swap. With
  the 512 MB cap (now the synthesizer default) every model settles near its
  weight size; the "resident peak" column is what an app sees with the cap.
- **Kokoro's MLX peak is 2.3–2.6 GB for an 82 M model** because the ISTFTNet
  decoder allocates attention buffers proportional to the square of the take
  length; a whole paragraph as one take peaks higher than chunked narration
  (1.7 GB). The catalog now says 2 000 MB, not 500 MB.
- **"Streaming" is three different things.** Pocket TTS streams per 80 ms
  frame (first audio 0.28 s on the Mac); VibeVoice yields every
  `streamingInterval` seconds while generating (0.6 s); Qwen3 yields chunks
  (0.5 s); Chatterbox Turbo and Kokoro produce a take whole, so the stream
  path only helps when the take is short; VoxCPM2's Swift port yields the
  whole take, 8 s after the call. None of the six accepts text appended
  mid-generation; the narration path's sentence chunking is what makes
  long text feel streamed.
- **Thermal state moved to "fair" during the Mac runs and "serious" on the
  phone during Chatterbox Turbo.** Sustained runs on a phone will throttle;
  the per-trial JSON carries the thermal state so a slow trial can be
  explained.
- **Cancellations on the phone were the device, not the models.** The first
  phone pass lost Pocket TTS and VibeVoice to `CancellationError` and the
  app was later killed during a download: the phone had been locked, which
  backgrounds the app, and iOS refuses Metal compute there. The demo app now
  keeps the screen awake, shows a status screen, logs scene-phase changes,
  and the harness retries a cancelled trial and keeps partial reports.
- **A half-downloaded model counted as installed.** The killed Qwen3
  download left a directory the store reported as available; the runtime
  then re-downloaded inside the first synthesize call. The store now checks
  the file list before calling a directory installed.
- **VoxCPM2 is not interactive on this hardware.** 0.62x realtime in
  Release, 6.4 GB MLX peak, 51 s of pre-roll for the long-form fixture. It
  stays Mac-only and suits offline rendering (`prepareNarration`), where its
  48 kHz output and 30 languages are the point.

## Default engines by use case

Based on the Release tables; "first audio" is the warm stream-path number
for a sentence unless noted.

| Use case | Default | Why | Alternative |
|---|---|---|---|
| Fast English TTS on iPhone | Kokoro-82M | 9.7x realtime on the iPhone 17, 0.5 s first audio, no stalls, 54 voices, Apache-2.0 | Pocket TTS: 0.28 s first audio and 4.2x on the iPhone 17 at 0.8 GB resident (vs 2.0 GB), per-frame streaming, but one language and CC-BY credit |
| Multilingual TTS on iPhone | MOSS-TTS-Nano | validated on the iPhone 17 at 1.3x realtime with 19 languages and streaming (0.12.0) | Qwen3-TTS 0.6B 8-bit once its phone numbers land (2.2x on the Mac, 3.1 GB resident) |
| Fast conversational TTS on Mac | Pocket TTS | 0.28 s first audio, streams per frame, 4–7x realtime, 870 MB | VibeVoice Realtime for a choice of 25 voices (0.62 s, 1.6x) |
| High-quality expressive TTS on Mac | Chatterbox Turbo | cloning from a clip, event tags, 2.2–2.5x realtime, 1.9 s to first audio | Ming-3.0 for instruction, emotion and voice design (validated, not in this pass) |
| Long-form narration | Kokoro-82M (English), Qwen3-TTS 0.6B (multilingual) | 11x and 2.3x realtime with zero stalls over 275 words; both work through `prepareNarration` for background playback | VoxCPM2 for offline 48 kHz rendering on a Mac |
| Agent streaming speech | Pocket TTS | 0.28 s first audio on both the Mac and the iPhone 17 with true per-frame output; turns are sentence-sized so the lack of incremental text input costs little | CosyVoice 3 once ported: the only candidate with genuine bistream text input (`Docs/model-research.md`) |

Numbers for VibeVoice Realtime and Qwen3-TTS on the iPhone are added when
the phone pass completes.
