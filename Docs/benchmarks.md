# Benchmarks

Measured with the shared harness in `Source/TTSBenchmark.swift` (`Tools/bench.sh`). Every number comes from this repository's own runs; nothing here is an upstream claim.

Definitions: **first audio** is the wall time from the synthesize call to the first non-padding buffer with the model already loaded; **RTF** is seconds of audio per wall second for the whole request (above 1 means faster than playback); **stalls** count the moments a player that started at first audio would have run dry, and **pre-roll** the seconds of audio it would have had to buffer before starting to avoid every stall; **MLX peak** is the runtime's active-memory high-water mark during the trial and **resident** the process's physical footprint afterwards. `narration` is `synthesizeLong` (the chunked article path); `stream` is `synthesizeStream`, one take through the model's own streaming path with a short interval. Medians over the warm trials; the cold trial is excluded.

Fixtures: `sentence` (12 words), `paragraph` (51 words), `longForm` (275 words, six paragraphs).

## MacBook Pro 14-inch 2021 (Apple M1 Pro) — macOS 27.0 (26A428), release build, 32 GB

| Model | Revision | Size | Cold: load / first audio | Warm load | Resident after load | sentence/stream first audio | paragraph/narration first audio | paragraph RTF | longForm RTF | longForm stalls | longForm pre-roll | MLX peak | Resident peak | CPU | Thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Kokoro-82M-bf16 | `a71e4d38` | 361 MB | 0.19s / 2.03s | 0.07s | 747 MB | 0.38s | 0.47s | 11.29x | 11.45x | 0 (0 overruns) | 0.0s | 2565 MB | 1984 MB | 0.68 | fair/nominal |
| MOSS-TTS-Nano-100M | `229a9c51` | 285 MB | 0.07s / 1.24s | 0.03s | 389 MB | 2.49s | 1.44s | 3.35x | 2.31x | 3 (1 overruns) | 0.8s | 1863 MB | 1483 MB | 0.88 | nominal |
| Qwen3-TTS-12Hz-0.6B-Base-4bit | `0d6bb6fe` | 1711 MB | 1.42s / 2.77s | 0.39s | 1784 MB | 0.48s | 0.84s | 2.34x | 2.38x | 0 (0 overruns) | 0.0s | 3946 MB | 2853 MB | 0.94 | nominal |
| Qwen3-TTS-12Hz-0.6B-Base-8bit | `50f45ef0` | 1996 MB | 0.94s / 2.30s | 0.36s | 2041 MB | 0.48s | 1.00s | 2.07x | 2.28x | 0 (0 overruns) | 0.0s | 4213 MB | 3100 MB | 0.82 | fair/nominal |
| VibeVoice-Realtime-0.5B-8bit | `ae6a233e` | 1220 MB | 1.06s / 3.17s | 0.54s | 1240 MB | 0.62s | 1.33s | 1.49x | 1.63x | 0 (0 overruns) | 0.0s | 1521 MB | 1851 MB | 1.12 | fair |
| VoxCPM2-4bit | `dc9e5c18` | 2302 MB | 1.13s / 7.51s | 0.39s | 2325 MB | – | 8.30s | 0.62x | 0.66x | 19 (0 overruns) | 50.8s | 6408 MB | 3693 MB | 0.51 | fair |
| chatterbox-turbo-4bit | `c6381772` | 418 MB | 0.74s / 2.56s | 0.40s | 1054 MB | 1.66s | 1.91s | 2.23x | 2.45x | 3 (0 overruns) | 0.6s | 2846 MB | 2354 MB | 0.91 | nominal |
| pocket-tts | `cbf71d5f` | 240 MB | 0.15s / 0.88s | 0.09s | 562 MB | 0.28s | 0.50s | 4.23x | 6.85x | 0 (0 overruns) | 0.0s | 876 MB | 869 MB | 0.50 | nominal |

- VoxCPM2-4bit: sentence/stream skipped: the model does not stream
- VoxCPM2-4bit: paragraph/stream skipped: the model does not stream

## iPhone 17 — iOS 27.2 (24B119), release build, 7 GB

| Model | Revision | Size | Cold: load / first audio | Warm load | Resident after load | sentence/stream first audio | paragraph/narration first audio | paragraph RTF | longForm RTF | longForm stalls | longForm pre-roll | MLX peak | Resident peak | CPU | Thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Kokoro-82M-bf16 | `a71e4d38` | 361 MB | 0.05s / 9.30s | 0.05s | 526 MB | 0.49s | 0.54s | 9.68x | 8.79x | 0 (0 overruns) | 0.0s | 2300 MB | 1957 MB | 0.53 | fair/nominal |
| MOSS-TTS-Nano-100M | `?` | 272 MB | 0.21s / 0.42s | 0.12s | 656 MB | 0.86s | 0.96s | 4.48x | 4.01x | 1 (6 overruns) | 0.0s | 1842 MB | 1476 MB | 0.85 | fair/serious |
| Qwen3-TTS-12Hz-0.6B-Base-4bit | `0d6bb6fe` | 1716 MB | 1.46s / 4.58s | 1.29s | 1768 MB | – | – | – | – | – | – | 3380 MB | 2275 MB | 0.90 | nominal |
| VibeVoice-Realtime-0.5B-8bit | `ae6a233e` | 1220 MB | 2.41s / 5.60s | 1.20s | 1169 MB | 0.97s | 2.09s | 0.94x | 1.07x | 5 (0 overruns) | 0.0s | 1521 MB | 1866 MB | 1.36 | nominal |
| chatterbox-turbo-4bit | `c6381772` | 416 MB | 0.44s / 4.24s | 0.30s | 1042 MB | 1.24s | 1.27s | 2.93x | 2.55x | 3 (0 overruns) | 0.7s | 2139 MB | 2409 MB | 0.88 | fair/serious |
| pocket-tts | `cbf71d5f` | 240 MB | 0.20s / 0.91s | 0.03s | 603 MB | 0.28s | 0.50s | 4.19x | 4.02x | 0 (0 overruns) | 0.0s | 566 MB | 819 MB | 0.20 | fair/serious |

- MOSS-TTS-Nano-100M: sentence/narration #0 was cancelled (app inactive?), retry 1
- MOSS-TTS-Nano-100M: sentence/narration #0 was cancelled (app inactive?), retry 2
- MOSS-TTS-Nano-100M: reconstructed from benchmark.log: the run completed but its JSON failed to encode (a cancelled cold trial analysed to -inf before 0.16.1 clamped it); characters per trial unknown
- Qwen3-TTS-12Hz-0.6B-Base-4bit: partial: iOS killed the process (signal 9) on the second sentence trial; no scene change was logged

## MacBook Pro 14-inch 2021 (Apple M1 Pro) — macOS 27.0 (26A428), debug build, 32 GB

| Model | Revision | Size | Cold: load / first audio | Warm load | Resident after load | sentence/stream first audio | paragraph/narration first audio | paragraph RTF | longForm RTF | longForm stalls | longForm pre-roll | MLX peak | Resident peak | CPU | Thermal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Kokoro-82M-bf16 | `a71e4d38` | 361 MB | 0.19s / – | 0.09s | 363 MB | 0.56s | 0.70s | 7.50x | 7.02x | 0 (0 overruns) | – | 2565 MB | 1095 MB | 1.00 | nominal |
| Qwen3-TTS-12Hz-0.6B-Base-8bit | `50f45ef0` | 1991 MB | 2.35s / 9.72s | 0.88s | 2057 MB | 1.59s | 3.04s | 0.68x | 0.62x | 128 (0 overruns) | – | 4213 MB | 2877 MB | 1.04 | fair/nominal |
| VibeVoice-Realtime-0.5B-8bit | `ae6a233e` | 1220 MB | 2.80s / 8.71s | 0.97s | 1213 MB | 1.29s | 3.25s | 0.60x | 0.64x | 114 (0 overruns) | – | 1525 MB | 1754 MB | 1.25 | fair |
| VoxCPM2-4bit | `dc9e5c18` | 2302 MB | 1.56s / 18.05s | 0.72s | 2289 MB | – | 10.09s | 0.40x | 0.30x | 27 (0 overruns) | 203.6s | 6410 MB | 3852 MB | 0.83 | fair |
| chatterbox-turbo-4bit | `c6381772` | 416 MB | 1.34s / 7.48s | 0.84s | 1033 MB | 3.16s | 3.32s | 1.15x | 1.12x | 4 (0 overruns) | – | 2870 MB | 1618 MB | 1.08 | nominal |
| pocket-tts | `cbf71d5f` | 240 MB | 0.15s / – | 0.07s | 273 MB | 0.39s | 0.71s | 2.85x | 2.89x | 0 (0 overruns) | – | 860 MB | 857 MB | 0.85 | nominal |

- VoxCPM2-4bit: sentence/stream skipped: the model does not stream
- VoxCPM2-4bit: paragraph/stream skipped: the model does not stream

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
- **VibeVoice Realtime is a Mac model in practice.** On the iPhone 17 it
  runs at 0.9–1.1x realtime with stalls on every fixture (1.0 s to first
  audio, 1.3 s pre-roll for a paragraph); on the M1 Pro it is 1.6x with no
  stalls. The catalog keeps the iPhone gate (it fits in 1.9 GB) but the
  recommendation table above does not put it on a phone.
- **`warmUp` used to be undone by the first voiced call.** The synthesizer
  reloaded weights whenever the voice or language differed from the last
  call (a guard for Marvis's stateful adapter), so warm-up followed by any
  call with a voice paid a second load; on the phone that double load of
  Qwen3-TTS ended the process. The reload is now Marvis-only.

- **Qwen3-TTS 0.6B at 8-bit does not belong on a phone.** On the iPhone 17
  a 12-word sentence ran at 0.6x realtime with 3.2–4 s to first audio
  (1.6 s on the stream path) and an MLX peak of 3.6 GB; the 51-word
  paragraph was killed by iOS (signal 9, no scene change logged, so not a
  lock). The catalog's 800 MB estimate was wrong by a factor of five; it now
  says 4 200 MB. The gate stays `.iPhone` so apps that ship it keep working.
- **The 4-bit build dies the same way.** Qwen3-TTS 0.6B 4-bit on the iPhone
  17: 1.6 GB active after load, MLX peak 3.4 GB on a 12-word sentence, 0.8x
  realtime, killed on the second trial (partial report kept). The transient
  is the speech-tokenizer decode, not the language model, so quantisation
  does not help; the runtime would need chunked codec decoding (as the fork
  did for MOSS) before Qwen3 is a phone model. Kokoro survived at a 2.3 GB
  peak, so the practical ceiling on an 8 GB iPhone sits near 3 GB.

- **MOSS-TTS-Nano runs away on short takes, and that was the phone killer
  for it too.** Before 0.16.1 a 12-word sentence came out as 13–14 s in
  two of three trials (the model misses its end-of-audio and runs to its
  375-frame budget); the codec decode of such a 30 s chunk peaks at
  3–3.5 GB, over the phone's ceiling. The synthesizer now bounds MOSS's
  frames to 1.6x the speech the text needs plus two seconds, and the
  narration paths cap MOSS takes at 140 characters (`maxCharactersPerTake`
  is honoured by `synthesizeLong` now, which it was not). Result on the
  M1 Pro: sentence 3.5–4.8 s, long-form overruns 9 → 1 with the tail capped
  at 12 s, MLX peak 3.5 GB → 1.85 GB, at the cost of some throughput
  (long-form 3.5x → 2.3x, more takes). MOSS's own `synthesizeStream` path
  yields a take whole (5–6 s to first audio for a paragraph), so the
  narration path is the one to use for MOSS. On the iPhone 17 with the
  bounds: 4.0–4.5x realtime, 1.0 s to first audio on the narration path,
  MLX peak 1.8 GB, resident 1.5 GB, six bounded overruns over the long-form
  fixture (8 s tails), and the run completed; before them the same phone
  killed the app at the long-form fixture with a 3.0 GB peak.
- **One unexplained kill remains.** A MOSS rerun on the phone was killed
  by iOS (signal 9) ten seconds after launch, right after a cold load at
  430 MB resident with 2.9 GB available and the scene still active, so
  neither memory nor a lock explains it. The device's own
  `JetsamEvent`/crash report (Settings → Privacy & Security → Analytics
  Data) is the next place to look; the harness keeps partial reports so a
  kill costs only the current trial.

## Default engines by use case

Based on the Release tables; "first audio" is the warm stream-path number
for a sentence unless noted.

| Use case | Default | Why | Alternative |
|---|---|---|---|
| Fast English TTS on iPhone | Kokoro-82M | 9.7x realtime on the iPhone 17, 0.5 s first audio, no stalls, 54 voices, Apache-2.0 | Pocket TTS: 0.28 s first audio and 4.2x on the iPhone 17 at 0.8 GB resident (vs 2.0 GB), per-frame streaming, but one language and CC-BY credit |
| Multilingual TTS on iPhone | MOSS-TTS-Nano | validated on the iPhone 17 at 1.3x realtime with 19 languages and streaming (0.12.0) | none of the Qwen3-TTS 0.6B builds: both are killed by iOS on the iPhone 17 (codec decode peaks above 3 GB) |
| Fast conversational TTS on Mac | Pocket TTS | 0.28 s first audio, streams per frame, 4–7x realtime, 870 MB | VibeVoice Realtime for a choice of 25 voices (0.62 s, 1.6x) |
| High-quality expressive TTS on Mac | Chatterbox Turbo | cloning from a clip, event tags, 2.2–2.5x realtime, 1.9 s to first audio | Ming-3.0 for instruction, emotion and voice design (validated, not in this pass) |
| Long-form narration | Kokoro-82M (English), Qwen3-TTS 0.6B (multilingual) | 11x and 2.3x realtime with zero stalls over 275 words; both work through `prepareNarration` for background playback | VoxCPM2 for offline 48 kHz rendering on a Mac |
| Agent streaming speech | Pocket TTS | 0.28 s first audio on both the Mac and the iPhone 17 with true per-frame output; turns are sentence-sized so the lack of incremental text input costs little | CosyVoice 3 once ported: the only candidate with genuine bistream text input (`Docs/model-research.md`) |

## Per-trial detail

Raw reports with every trial live in `Benchmarks/results/*.json`. The paragraph clip of every run is in `Benchmarks/samples/<device>/<model>.m4a` (AAC, `Tools/bench-samples.sh`); the full float32 WAVs stay local in `Benchmarks/results/audio/`.

