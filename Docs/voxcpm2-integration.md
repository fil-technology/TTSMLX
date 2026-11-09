# VoxCPM2 in TTSMLX: audit, runtime choice, work plan and results

The "Integrate VoxCPM2 with full feature support" task (2026-11-09). The
audit and plan below were written first; the **Status** section at the end
records what shipped the same day and what it measured. Usage examples:
`Docs/voxcpm2.md`.

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
- **Runtime.** The fork `fil-technology/mlx-audio-swift` 0.1.8-tts.5 held a
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
is the fork at 0.1.8-tts.5 (before this work); "TTSMLX" is what a caller of
`TTSSpeechSynthesizer` got then. The Status section says what changed.

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

## Status (2026-11-09, runtime 0.1.8-tts.6)

Steps 1 to 5 and 7 of the plan shipped the same day; the fork gained
`VoxCPM2Prompt`, `VoxCPM2GenerationParameters` and a real `generateStream`,
TTSMLX gained the controls case, the two options, all 30 languages,
`TTSVoiceProfile` / `TTSVoiceDesign` / `TTSVoiceProfileStore`, the demo app
its delivery controls, and the validation test
`Tests/VoxCPM2ValidationTests.swift` (`TTS_VOXCPM2=1`) records the evidence
below in `Benchmarks/validation/voxcpm2-M1Pro-2026-11-09.json`.

| Acceptance item | Evidence (M1 Pro, Release) |
|---|---|
| Loads on Apple silicon, no Python | catalog entry, benchmark harness, demo app; weights verified against the Hub's sha256 |
| Ordinary synthesis, native 48 kHz audio | every validation take; Whisper large-v3-turbo transcribes the English takes with WER 0.00 |
| Voice design (free text and `TTSVoiceDesign` controls) | `design-narrator`, `design-anchor`: 6.1 s and 5.3 s of speech, WER 0.00; the compiled description is `(…)` at the front of the text |
| Reference cloning (clip only) | `clone-reference`: WER 0.00 on new text |
| Controllable cloning (clip + style text) | `clone-controllable` ("whispering, urgent", fast): WER 0.00 |
| High-fidelity continuation (clip + exact transcript) | `clone-hifi`: WER 0.00; the transcript now enters the prompt (it was dropped before 0.1.8-tts.6) |
| Streaming audio | first buffer after 0.32–0.40 s on both the stream and narration paths, one 160 ms patch per event (51 buffers for an 8 s take); before: the whole take, 8 s |
| Russian and Hebrew | `lang-ru`, `lang-he`: WER 0.00 with Whisper large-v3-turbo; Ukrainian (unsupported) WER 0.62 with mispronounced words |
| Structured controls translated | `VoxCPM2ControlsTests`, `TTSVoiceProfileTests` (unit) |
| Advanced settings have observable effects | `diffusionSteps` and `guidanceScale` reach the DiT per call (`callParameters`); seed 42 reproduces a take with a maximum sample difference of 0.0, seed 43 gives a different take |
| Voice profiles reusable | `TTSVoiceProfile.apply(to:)`, `TTSVoiceProfileStore` round trip, consent required for cloned kinds |
| Existing engines unchanged | 279 unit tests green; VoxCPM 1.5, Kokoro, Pocket TTS and the rest untouched |
| Tests and benchmarks | `Docs/benchmarks.md` VoxCPM2 rows re-measured on 0.1.8-tts.6 |

**Memory and speed after streaming.** The decoder no longer renders a
whole take at once, so the MLX peak fell from 6.4 GB to 3.1–3.4 GB on the
M1 Pro (resident 2.9 GB with the cache cap). The per-step windowed decode
costs about a quarter of the throughput: 0.50–0.55x realtime against 0.62x
for the old whole-take path. The gate stays `.mac`: 2.3 GB of weights plus
a 2.9 GB resident footprint do not fit the iPhone 17's budget (about 3 GB).

**Limitations, kept explicit.**
- Text is fixed per take; there is no incremental text input. Sentence
  orchestration above the engine (`synthesizeLong`, `TTSRealtimeSession`)
  is the supported way to speak live text.
- `temperature`, `topP`, `voiceGuidance` and `expressiveness` do nothing on
  VoxCPM2 and are reported through `controlsIgnored`.
- Speaker similarity and style preservation are not scored (no speaker
  embedding model in the runtime); the validation WAVs are kept for
  listening. Intelligibility is scored with Whisper large-v3-turbo through
  the fork's `mlx-audio-swift-stt` tool, run as a subprocess because linking
  the STT library into the Release test bundle crashes the linker.
- The fast / high-quality profiles (6 / 16 diffusion steps) are TTSMLX's
  choices; only balanced (10) is upstream's default. They are not yet
  measured for quality.
- Still a Mac model; a stateful causal-conv streaming decoder (upstream's
  `StreamingVAEDecoder`) would remove the windowed re-decode and is the
  next optimisation, together with an iPhone measurement on a 12 GB device.
- A streamed chunk was briefly a view into a recycled buffer (non-finite
  samples from the fifth patch on, seen once with seed 43); 0.1.8-tts.6
  copies each chunk out. The validation test checks every take for
  non-finite samples.
