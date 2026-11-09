# VoxCPM2 in TTSMLX: audit, runtime choice and work plan

Phase 0 of the "Integrate VoxCPM2 with full feature support" task
(2026-11-09). Everything below was read from the code and the upstream
sources on that date; nothing here has been measured yet on this round.

## What exists today

- **Catalog.** `mlx-community/VoxCPM2-4bit` has been a descriptor-bearing
  `.implemented` entry since 0.16.0, gated to the Mac (measured MLX peak
  6.4 GB on the M1 Pro, 0.62x realtime in Release, `Docs/benchmarks.md`).
  VoxCPM 1.5 joins it in this branch on the fork's `voxcpm` loader; the two
  share the design (MiniCPM backbone, local encoder, DiT, AudioVAE) but not
  the configuration or the weight layout, and the fork keeps two model
  classes (`VoxCPMModel`, `VoxCPM2Model`) for that reason. 1.5 has no
  voice design, no style text and two languages; nothing in the 1.x code
  path carries over to the VoxCPM2 feature list.
- **Runtime.** The fork `fil-technology/mlx-audio-swift` 0.1.8-tts.5 holds a
  native Swift/MLX VoxCPM2 port (`Sources/MLXAudioTTS/Models/VoxCPM2`,
  2 600 lines): MiniCPM-4 LM, residual LM, encoder, DiT, AudioVAE v2 with
  the 16 kHz encoder and 48 kHz decoder. It loads, generates and clones from
  a clip. It is Apache-2.0 like the upstream code and the mlx-community
  weights.
- **TTSMLX wiring.** Loader routing, download, install check, lifecycle,
  cache cap, cancellation, chunked narration, `prepareNarration`, the
  benchmark harness and the demo app all work for VoxCPM2 today because
  they are model-agnostic. The controls layer
  (`TTSSpeechSynthesizer+Controls.swift`) has no VoxCPM2 case: a caller who
  wants voice design must write the parenthesised description into the
  text; `instruction`, `emotion` and `speed` are reported as ignored.

## Runtime selection

| Option | Verdict | Why |
|---|---|---|
| A. llama.cpp-omni GGUF through a C/C++ bridge | not chosen | A second inference runtime and build system in the package; upstream reports RTF 1.76 (slower than realtime) at Q8_0 on an M4 Pro, so it would also be slower than the MLX port on this hardware. Keep as a reference for numerical checks only. |
| B. Native Swift MLX in the fork | **chosen** | Already runs, no Python at runtime, one runtime for every TTSMLX model, Metal through MLX, the place where TTSMLX's memory safeguards already apply. Every missing feature below is a change in the fork's port plus a TTSMLX mapping. |
| C. PyTorch/MPS reference | test fixture only | Needed to produce reference audio and to compare seeds and latents; it is not shipped. It needs ~6 GB of disk for the environment and weights, which this Mac does not have at the moment (3 GB free). |

## Feature parity matrix

"Upstream" is the PyTorch `voxcpm` package at OpenBMB/VoxCPM; "Swift port"
is the fork at 0.1.8-tts.5; "TTSMLX" is what a caller of
`TTSSpeechSynthesizer` gets today.

| Feature | Upstream | Swift port | TTSMLX today | Work |
|---|---|---|---|---|
| Ordinary TTS, 30 languages, no language tag | yes | yes | yes (15 languages listed in the catalog) | list all 30 in `voxCPM2Languages`; test RTL (Hebrew, Arabic) text |
| Native 48 kHz output | yes | yes | yes | – |
| Voice design (parenthesised description, no clip) | yes | yes, as text | yes if the caller writes the parentheses | VoxCPM2 case in the controls layer: compile `instruction`/`emotion`/`speed`/structured controls into the leading description; keep the compiled text in the result for reproducibility |
| Reference cloning (clip only) | yes | yes (`refAudio`) | yes (`referenceAudio`) | reference validation, mono/resample (exists), silence check, trimming |
| High-fidelity continuation cloning (clip + exact transcript) | yes (`prompt_wav_path` + `prompt_text`) | **no**: `refText` is accepted by `generate` but never enters the prompt | no (the transcript is dropped silently) | port the prompt-text path in the fork; TTSMLX must stop reporting `referenceText` as honoured until then |
| Controllable cloning (clip + style text, isolated reference) | yes (`reference_wav_path` + style text) | **partial**: the port has the isolated-reference tokens (103/104) but no style-text input | no | add style text to the port's prompt; map to `instruction`/`emotion`/`speed` |
| Second clip for timbre next to a transcript clip | yes | no | no | after the above; low priority |
| Streaming audio from fixed text | yes, per LM step (160 ms) with a 3-patch sliding decode window | **no**: `generateStream` wraps `generate` and yields one event | no (take whole; first audio = generation time) | implement incremental VAE decoding over the sliding window in the port; TTSMLX already consumes `AsyncThrowingStream<AudioGeneration>` |
| Incremental text input during generation | no | no | no (sentence orchestration above the engine via `synthesizeLong`) | document as unsupported; the narration path is the orchestration |
| CFG scale, diffusion timesteps per call | yes | **no**: read from `config` (`cfgScale`, `inferenceTimesteps`) | no | per-call parameters in the port; `voiceGuidance` and a new `diffusionSteps` option in TTSMLX; profiles fast / balanced / high quality map onto them |
| Seed | yes | no | `TTSSynthesisOptions.seed` exists but is not applied for VoxCPM2 | `MLXRandom.seed` around the call in the port; verify two runs match |
| Temperature / top-p | not model knobs (the LM emits latents, not tokens) | no | reported as ignored | keep unsupported; do not fake |
| Max tokens / runaway guard | `max_len` | `maxTokens` | yes (`maxCharactersPerTake` 300 + `maxTokens`) | add a frame budget like MOSS's: the 4-bit stop head is unreliable (port README) |
| Quantisation choice | – | 4-bit weights only in the README; 8-bit (3.2 GB) and bf16 (5.0 GB) exist | one catalog entry | add 8-bit as a second entry once measured |
| Voice presets (reusable configuration) | – | – | `TTSPreparedVoice` exists for cloned conditioning on other models | a `TTSVoiceProfile` type (designed / cloned / high-fidelity) persisted locally with description, clip reference, transcript, language, defaults, seed, model id and revision, consent metadata |
| Learned speaker embeddings | no such thing in VoxCPM2 | – | – | document: profiles are configurations, not embeddings |
| iOS | – | loads, but 6.4 GB MLX peak on the Mac | Mac-gated | after streaming decode (which also bounds the VAE transient) re-measure on the iPhone 17; until then not iOS |

## Plan, in order

1. **Fork: per-call CFG, timesteps and seed** (small, unblocks advanced
   settings and reproducibility). Verify a fixed seed reproduces audio.
2. **Fork: prompt-text continuation and style text** (high-fidelity and
   controllable cloning). Compare against the PyTorch reference on the
   same clip and text.
3. **Fork: streaming decode** per LM step with the sliding window; measure
   first audio and the MLX peak, which should fall because the VAE no
   longer decodes the whole take at once.
4. **TTSMLX: controls layer case for VoxCPM2** compiling structured
   controls plus free text into the description, with the compiled prompt
   returned on the result; `referenceText` honoured; `diffusionSteps` and
   `voiceGuidance` wired; profiles fast / balanced / high quality.
5. **TTSMLX: voice profiles** (`TTSVoiceProfile`, local store, consent
   field) and reference-audio validation (channels, rate, silence, trim).
6. **Languages**: all 30 in the catalog; tests for English, Russian, Hebrew,
   German, French, Spanish, Italian, Japanese, Chinese; Ukrainian as an
   explicit unsupported-language experiment.
7. **Benchmarks** through the existing harness (load, cold and warm first
   audio, RTF, peaks, stalls) plus new similarity and intelligibility
   checks (Whisper WER is already in the preview tooling's reach).
8. **Docs and demo**: examples for the ten scenarios; demo tab for voice
   design, cloning modes and streaming on top of the existing demo app.

## Blockers on 2026-11-09

- **Disk.** 3.1 GB free on the Data volume. A framework build, the test
  build the harness needs, the 2.3 GB VoxCPM2 weights (the local copy was
  removed) and the PyTorch reference do not fit. Nothing TTSMLX-owned is
  left to delete.
- Everything in the plan touches the runtime fork first; a new fork tag
  (0.1.8-tts.6) and a pin bump in `Package.swift` follow.
