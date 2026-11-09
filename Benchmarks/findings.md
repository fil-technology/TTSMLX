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
- **VoxCPM 1.5 is the fast VoxCPM, and still not a phone model.** On the
  M1 Pro in Release the 4-bit build runs at 1.2x realtime on every fixture
  with 3.2 s to first audio (narration path; no streaming), against 0.62x
  for VoxCPM2. Its MLX peak grows with the take: 3.6 GB on a sentence,
  5.4 GB on a paragraph, 7.2 GB over the long-form fixture, with 2.1 GB
  resident under the cache cap; the 44.1 kHz AudioVAE decode is the
  transient, as it is for VoxCPM2. Long form stalled for up to 10 s of
  pre-roll. English and Chinese only, no voice design.
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
