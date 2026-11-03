# Model support matrix

Status of every model on the [tts-bench](https://github.com/5uck1ess/tts-bench)
leaderboard (Elo ranking as of 2026-11-03) against what TTSMLX can run today,
what it could run after the planned runtime migration, and what is blocked and
why. Verified 2026-11-03 from the Hugging Face model cards, the upstream
`Blaizzy/mlx-audio-swift` v0.1.8 source tree, Python `mlx-audio` v0.6.4 and
the `fil-technology/mlx-audio-swift` fork TTSMLX is pinned to (`0.1.7-tts.1`).

## The one fact that decides most rows

TTSMLX runs models through `fil-technology/mlx-audio-swift`, a fork cut from
upstream **v0.1.3** (July 2026) plus 11 commits (Mimi/PocketTTS KV-cache reset,
companion-repository downloads, MOSS-TTS-Nano, `TTSModelRegistry`). Upstream
has since shipped v0.1.6–v0.1.8 (20 Oct – 2 Nov 2026), adding **about 25 TTS
families, 9 codecs and a G2P target** — 421 commits the fork does not have.
Upstream also dropped `MLXLMCommon`/`mlx-swift-lm` and now requires
`mlx-swift ≥ 0.33.0`, whereas TTSMLX pins a `0.31.5` fork of `mlx-swift` that
carries the iOS background-Metal crash fix (see
`Docs/mlx-swift-bg-safe-fork.md`).

So "add support for as much as possible" is **not** 25 Swift ports. It is one
runtime migration (tracked below as **M**), after which most of the top of the
leaderboard loads through the same `TTSSpeechSynthesizer` API. Re-implementing
those families inside the old fork would duplicate work upstream has already
done and tested.

Legend for the **Status** column:

| Code | Meaning |
|---|---|
| ✅ | Runs with TTSMLX today (catalog entry exists or the family loads) |
| **M** | Implemented upstream in mlx-audio-swift v0.1.8; available after the runtime migration, no model code to write |
| **M+** | As M, plus a small TTSMLX-side addition (catalog entry, prompt format, download rule) |
| ⛔ | Blocked for reasons that migration does not fix (stated per row) |

## Leaderboard

| # | Model | Elo | Status | Licence (commercial?) | Architecture · codec · size · SR | Features we can expose | Why not today / what is missing |
|---|---|---|---|---|---|---|---|
| 1 | Kokoro 82M | 1341 | **M** | Apache-2.0 (yes) | StyleTTS2-derived, non-autoregressive, ISTFTNet · 82M · 24 kHz | 54 preset voices, 8 languages, fast | Upstream `StyleTTS2/Kokoro` shares the stack with our KittenTTS but needs the multilingual G2P target (`MLXAudioG2P`) the fork lacks. MLX weights: `mlx-community/Kokoro-82M-{bf16,4,6,8bit}`. |
| 2 | Chatterbox | 1317 | **M** | MIT (yes) | T3 Llama ~0.5B over S3 tokens → S3Gen flow matching + HiFT-GAN · 24 kHz | Cloning from a wav, exaggeration/CFG knobs, 23 languages (v3) | Needs S3TokenizerV2, S3Gen, HiFT, CAMPPlus and the voice encoder — all present upstream, none in the fork. |
| 3 | Chatterbox Turbo | 1257 | **M** | MIT (yes) | GPT-2-medium T3 ~350M + one-step distilled S3Gen · 24 kHz · English | Cloning, bundled default voice, `[laugh]` `[cough]` tags | Same stack as Chatterbox. |
| 4 | Higgs Audio v3 TTS | 1196 | **M** ⚠️ | Boson research / **non-commercial** | ~4B Qwen3-style AR over Higgs tokenizer (8 codebooks @ 25 fps) · 24 kHz | 100+ languages, cloning, 21 emotion + style/SFX tags, streaming | Runtime-wise fine after M (upstream `HiggsAudio3TTS` + Higgs codec). Licence forbids commercial use; list it as research-only. ~8 GB bf16, no mlx-community quant yet. |
| 5 | Supertonic 3 | 1192 | ⛔ | OpenRAIL-M weights, MIT code (use-restricted) | ONNX-only: text encoder + duration predictor + flow-matching estimator + vocoder · ~99M · 44.1 kHz | 31 languages, preset voices, 10 tags | No MLX implementation anywhere (Python or Swift). Weights exist only as ONNX graphs plus a third-party JSON/NPZ dump; the latent-flow + speech-autoencoder pipeline would be a from-scratch port with a weight conversion. Candidate for a later dedicated effort, not this cycle. |
| 6 | Pocket-TTS v4 | 1172 | ✅ → **M+** | CC-BY-4.0 weights (yes) | ~100M transformer → Mimi · 24 kHz | 7 languages, 26 voices, cloning, ~200 ms streaming | Catalog entry `mlx-community/pocket-tts` runs today. The fork predates upstream's Mimi context-window and `resetState` fixes (#357, #368); M picks them up. |
| 7 | Soprano 1.1 80M | 1155 | ✅ (`Soprano-80M`) → **M+** | Apache-2.0 (yes) | Qwen3-arch LM 80M + custom decoder · 32 kHz · English | One voice, streaming | Our catalog lists `Soprano-80M-bf16/4bit`. 1.1 (`mlx-community/Soprano-1.1-80M-*`) is the same architecture; add the catalog entry and validate on device. |
| 8 | OmniVoice | 1148 | **M** ⚠️ | Code Apache-2.0, weights **CC-BY-NC** | Bidirectional diffusion-LM over Qwen3-0.6B, 9 RVQ codebooks via Higgs v2 codec · ~1B · 24 kHz | 600+ languages, cloning, voice design, `[laughter]` | Upstream has it; needs Higgs v2 codec + diffusion sampler. Weights are non-commercial. |
| 9 | Orpheus-TTS 3B | 1146 | ✅ | Apache-2.0 (yes, gated) | Llama-3B AR over SNAC · 24 kHz · English | 8 voices, `<laugh>` `<sigh>` … tags, streaming | Catalog entry `mlx-community/orpheus-3b-0.1-ft-bf16`. Tags pass through unchanged today; see "Features to expose" below. |
| 10 | Voxtral 4B TTS | 1122 | **M** ⚠️ | **CC-BY-NC-4.0** | Ministral-3B backbone + Voxtral audio decoder · ~4B · 24 kHz | 9 languages, 20 preset voices, cloning, streaming | Upstream `VoxtralTTS` (streaming landed on `main` after v0.1.8). Non-commercial. |
| 11 | dots.tts (soar) | 1121 | ⛔ | Apache-2.0 (yes) | Qwen2.5-1.5B + AR flow-matching DiT head over a 48 kHz AudioVAE · 2B | 24 languages, cloning | No implementation in Python mlx-audio or upstream Swift; third-party `dots-tts-mlx` weights have no runtime. Architecturally near VoxCPM2/Ming (which upstream has), so a port is plausible later. |
| 12 | LongCat-AudioDiT 3.5B | 1112 | **M** | MIT (yes) | Non-AR DiT in Wav-VAE latent space, UMT5 text encoder · 3.8B · 24 kHz | zh + en, cloning, ≤ 30 s utterances | Upstream `LongCatAudioDiT` (README lists the 1B; 3.5B weights exist as `mlx-community/LongCat-AudioDiT-3.5B-*`, needs validation). Non-streaming by design. |
| 13 | Phonon 31m | 1110 | **M+** | Apache-2.0 (yes) | Pocket-TTS derivative: flow-matching transformer → Mimi · 31M · 24 kHz | ~100 voices (`gradium/phonon-voices`), streaming | Upstream added Phonon conditioning to `PocketTTS` in v0.1.6 (PR #288). Our fork's PocketTTS predates it. No mlx-community weights; upstream loads the `gradium` repo directly, so a download rule is needed. |
| 14 | Ming-3.0-TTS 0.5B | 1100 | **M** | MIT (yes) | Qwen2.5-0.5B + flow-matching DiT head + audio VAE, CAM++ · 1.5B · 44.1 kHz | 7 languages, 100+ voices, cloning, voice design, emotion/speed/pitch, 14 tags | Upstream `Ming` (dense). Needs the Ming flow + VAE + CAMPPlus stack. |
| 15 | LFM2.5-Audio 1.5B | 1094 | ✅ (runtime) → **M+** | LFM Open License v1.0 (read before shipping) | LFM2-1.2B hybrid + RQ-transformer → 8 Mimi-compatible codebooks → ISTFT detokenizer · 24 kHz | 4 voices via system prompt, token streaming | The fork already contains `STS/LFMAudio`; TTSMLX does not route to it because it is not a `SpeechGenerationModel`. Needs an adapter in `TTSSpeechSynthesizer` — independent of M. |
| 16 | Maya1 | 1092 | **M+** (maybe ✅) | Apache-2.0 (yes) | Llama-style 3.3B AR over SNAC (7 tokens/frame) · 24 kHz | Natural-language voice description, 20 emotion tags, streaming | Same Llama + SNAC path as Orpheus. Needs the `<description="…">` prompt format and a catalog entry (`mlx-community/maya1-4bit`). Unverified on the fork; validate before listing. |
| 17 | Sesame CSM-1B | 1092 | **M+** (maybe ✅) | Apache-2.0 (yes, gated) | Llama-1B backbone + small AR audio decoder over Mimi · 24 kHz | Speaker id, context turns (cloning via a prior turn) | Our Marvis family is CSM-based and upstream routes `csm`/`sesame` to it. The fork has no `csm-1b` mapping; validate the load, then add a catalog entry. |
| 18 | MiraTTS | 1077 | ⛔ | **CC-BY-NC-SA-4.0** on HF (bench says MIT; HF wins) | Qwen2 0.5B + FastBiCodec + FlashSR upsampler · 48 kHz | en + zh, cloning | Non-commercial, LMDeploy-only runtime, no MLX port anywhere; needs a BiCodec variant and FlashSR. |
| 19 | OuteTTS 1.0 1B | 1070 | **M** ⚠️ | **CC-BY-NC-SA-4.0** + Llama 3.2 | Llama-3.2-1B AR over IBM DAC-speech (2 codebooks) · 24 kHz | 12+ languages, default speaker + cloning profiles | Upstream `OuteTTS` + Descript codec. Non-commercial. |
| 20 | Phonon 40m | 1055 | **M+** ⚠️ | **CC-BY-NC-4.0** (gated) | As #13 · 40M | As #13 | As #13; non-commercial variant. |
| 21 | LongCat-AudioDiT 1B | 1047 | **M** | MIT (yes) | As #12 · 1.4B | As #12 | Upstream's primary LongCat target. |
| 22 | Vaniq-Edge | 1027 | ⛔ | MIT (yes) | Compressed VITS with built-in waveform decoder · 8.9M · 24 kHz | One voice, speed knob | No MLX implementation; needs a VITS port (posterior/flow + HiFi-GAN-style decoder). Tiny; a reasonable later port alongside MeloTTS. |
| 23 | Ming-3.0-TTS tiny | 1023 | **M** | MIT (yes) | Ling V3 MoE ~8B total / ~1.3B active + DiT head · 44.1 kHz | As #14 plus podcast dialogue | Upstream `MingTiny`. Memory-heavy for phones (MoE weights are all resident). |
| 24 | LFM3-Audio 2B | 1021 | ⛔ (for now) | LFM Open License v1.0 | LFM3-1.7B + LiquidCodec (12 tokens / 80 ms) · 24 kHz | 18 languages, male/female via system prompt, streaming | Python `sts/lfm3_audio` exists; **no Swift implementation** upstream yet (README covers LFM2.5 only). Needs the LiquidCodec decoder in Swift. |
| 25 | DramaBox | 999 | ⛔ | LTX-2 Community (non-commercial per bench) | 3.3B audio-only DiT + VAE + Gemma-3-12B text encoder · 48 kHz | Prompt-described voice, cloning | ~24 GB working set; impractical on device regardless of runtime. Not in upstream Swift. |
| 26 | KittenTTS 2 | 998 | ⛔ (for now) | Stellon Labs Community (free up to $1M revenue) | 1.7B Qwen3-arch LM (ternary-packed) → S3 tokens → decoder · 24 kHz | 16 languages, 115 voices, cloning, emotion tags (beta) | Neither Python nor Swift mlx-audio has it; needs a ternary weight unpacker and the S3-token decoder (upstream S3Gen may fit; unverified). |
| 27 | VibeVoice Realtime 0.5B | 994 | **M** | MIT (yes) | Qwen2.5-0.5B + 40M diffusion head + σ-VAE tokenizer · 24 kHz | 25 preset voices, streaming | Upstream `VibeVoice`. |
| 28 | Inflect-Micro v2 | 993 | ⛔ | Apache-2.0 (yes) | Compressed VITS · 9.4M | One voice, speed/variation | VITS port needed (see #22). |
| 29 | Hojo-TTS-Light 40M | 992 | ⛔ | Apache-2.0 (yes) | ONNX three-stage token LM over a 50 Hz codec · ~80M | zh + en, 15 voices | ONNX-only release; no MLX port anywhere. |
| 30 | KittenTTS Nano 0.8 | 990 | ✅ | Apache-2.0 (yes) | StyleTTS2 / ISTFTNet · 15M · 24 kHz | 8 voices | Catalog entry `mlx-community/kitten-tts-mini-0.8`; nano/micro variants load through the same family. |
| 31 | Audio8 TTS 0.6B | 973 | **M** | Apache-2.0 (yes) | Dual-AR + bundled 44.1 kHz 10-codebook codec | 11 languages, cloning | Upstream `Audio8`. |
| 32 | Magpie-TTS 357M | 973 | ⛔ | NVIDIA Open Model License (commercial OK, gated) | Encoder-decoder + local transformer over NanoCodec · 22.05 kHz | 12 languages, 5 voices | Needs NanoCodec; no mlx-audio port. Third-party MLX weights only. |
| 33 | Inflect-Nano v2 | 966 | ⛔ | Apache-2.0 | VITS · 4M | As #28 | VITS port needed. |
| 34 | StyleTTS 2 (generic) | 957 | ⛔ | MIT code, voice-use conditions | Style diffusion + PL-BERT + iSTFTNet · ~148M | Cloning via reference style | Upstream has the StyleTTS2 stack only as used by Kokoro/Kitten; the style-diffusion sampler and PL-BERT are missing. |
| 35 | Miso TTS 8B | 954 | **M+** (maybe) | "modified MIT" (terms unverified) | CSM-style Llama-8B + 300M decoder over Mimi · 24 kHz | Continuation cloning | Routes to the Marvis/CSM path upstream; 8B is too large for most devices. |
| 36 | VoxCPM2 2B | 948 | **M** | Apache-2.0 (yes) | MiniCPM-4 + LocDiT local diffusion + AudioVAE v2 · 48 kHz | 30 languages, cloning, voice design, streaming | Upstream `VoxCPM2`. |
| 37 | Parler-TTS Mini v1 | 944 | ⛔ | Apache-2.0 (yes) | T5 encoder + AR decoder over DAC · 0.9B · 44.1 kHz | Description prompting, 34 named speakers | No port in current upstream trees. |
| 38 | Scylla's Band | 938 | ⛔ | Apache-2.0 (yes) | Duration predictor + rectified-flow latent generator + Vocos · ~103M | 14 voices / 7 locales | We have Vocos; the flow latent generator is missing and there is no mlx-audio port. |
| 39 | Qwen3-TTS 0.6B CustomVoice | 937 | ✅ (`1.7B-CustomVoice-4bit` listed) → **M+** | Apache-2.0 (yes) | Qwen3 talker + 12 Hz tokenizer · 24 kHz | 9 preset voices, 10 languages, instruct text, streaming | Our catalog lists the 0.6B/1.7B Base and the 1.7B CustomVoice. Add the 0.6B CustomVoice entry; instruct text is not yet exposed through `TTSSynthesisOptions` (see "Features to expose"). |
| 40 | Dia 1.6B | 927 | **M** | Apache-2.0 (yes) | Encoder-decoder AR over 9 DAC codebooks with CFG · 44.1 kHz | `[S1]`/`[S2]` dialogue, ~20 nonverbal tags, cloning | Upstream `Dia` + Descript codec. |
| 41 | MeloTTS | 918 | **M** | MIT (yes) | VITS + BERT prosody + HiFi-GAN · ~52M · 44.1 kHz | 5 English accents | Upstream `MeloTTS`. |
| 42 | SteerTTS | 889 | ⛔ | **CC-BY-NC-4.0** weights | FastPitch-style + bidirectional Mamba + Vocos · 23–41M | 2,825 voices, 12 knobs, 51 tags | Non-commercial; no port; Mamba blocks are not in mlx-audio. |
| 43 | Coqui XTTS-v2 | 880 | ⛔ | CPML (**non-commercial**) | GPT-2 AR + HiFi-GAN decoder · ~750M · 24 kHz | 17 languages, 6 s cloning | Non-commercial; no port. |
| 44 | AuroraTTS-100K | 874 | ⛔ | Apache-2.0 | FastPitch-like + DSP harmonic/noise synth · 96K params | One voice | No port; quality below our smallest supported model. |
| 45 | Mars5-TTS | 811 | ⛔ | AGPL-3.0 (copyleft) | AR 750M + NAR diffusion 450M over Encodec, Vocos | Cloning | AGPL is incompatible with closed-source apps consuming TTSMLX; no port. |
| 46 | Piper | 809 | ⛔ | GPL-3.0 (copyleft) | VITS ONNX · ~15M · 22.05 kHz | Many languages/voices | GPL plus no port. |
| 47 | SupraTTS 0.1 Beta | 739 | ⛔ | MIT | Glow-TTS + HiFi-GAN · 43.5M | One voice | No port; beta quality. |
| 48 | sanoTTS | 729 / 701 | ⛔ | GPL-3.0 | Tiny numpy duration + acoustic + iSTFT · ≤ 1.5M | One voice | GPL plus no port. |

Marvis-250M (`Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit`), VyvoTTS-EN-Beta and
MOSS-TTS-Nano are supported today but are not on the leaderboard.

## Features to expose per family (after M, on the TTSMLX API)

These are things the models already understand and TTSMLX currently drops or
does not surface. Each is an additive option on `TTSSynthesisOptions` or a
catalog capability flag:

- **Inline tags** — Orpheus / Maya1 (`<laugh>`, `<sigh>`, `<chuckle>`, …),
  Chatterbox Turbo (`[laugh]`), Dia (`(laughs)` family), Higgs v3, Ming,
  Supertonic. Today tags pass through as text and work on Orpheus; the chunker
  must never split inside a tag and a `supportsTags` capability should let apps
  show a palette. Documented list per model to ship with the catalog entry.
- **Style / instruct text** — Qwen3-TTS CustomVoice/VoiceDesign, Maya1
  (`<description=…>`), Ming, VoxCPM2, OmniVoice, LFM (system prompt voice). New
  `TTSSynthesisOptions.styleInstruction` routed to the family's prompt format.
- **Reference-audio cloning** — Chatterbox, Higgs v3, OmniVoice, Voxtral,
  LongCat, Ming, Pocket-TTS, Maya-style continuation (CSM), Qwen3-TTS Base,
  Orpheus. `referenceAudio` / `referenceText` already exist on the options;
  the catalog flags need auditing (`Qwen3-TTS Base` is the cloning variant and
  is currently flagged `supportsReferenceAudio: false`).
- **Preset voices** — Kokoro (54), Voxtral (20), VibeVoice (25), Ming (100+),
  Phonon (~100), Pocket (26). `TTSVoice` lists are per catalog entry.
- **Languages** — exposed through `supportsLanguageList` today; many M-tier
  families are multilingual and need their language tables added.

## The migration (M), concretely

1. **mlx-swift fork at 0.33.x.** Re-fork `ml-explore/mlx-swift` at the 0.33
   release upstream mlx-audio-swift v0.1.8 requires, point its `mlx` submodule
   at `fil-technology/mlx` rebased onto the matching upstream commit with the
   background-safe `check_error` patch re-applied, and tag it with a version
   upstream will never publish (e.g. `0.33.1-bgsafe.1`) so the pin can no
   longer be confused with upstream (closes the URGENT.md follow-up).
2. **mlx-audio-swift fork rebased on v0.1.8.** Re-apply only what upstream
   still lacks: companion-repository downloads (check whether upstream's
   loader covers SNAC / speech_tokenizer side repos now) and
   `TTSModelRegistry` (or replace its two call sites in TTSMLX with
   upstream's `TTSModel` loader). MOSS-TTS-Nano and the Mimi reset fixes exist
   upstream; drop the fork copies.
3. **TTSMLX adaptation.** Coupling is small: `GenerateParameters` moves from
   `MLXLMCommon` to the upstream audio package; `TTS.loadModel`,
   `generatePCMBufferStream` and `MossTTSNanoModel.codebookCount` need their
   upstream equivalents; `TTSModelRegistry` has two call sites
   (`TTSModelStore`, `TTSBackgroundModelDownloader`). Public TTSMLX API does
   not leak any of these types, so consumers are unaffected.
4. **Catalog + validation.** Add entries for the M-tier models in leaderboard
   order (Kokoro, Chatterbox, Chatterbox Turbo, Higgs v3 [research-only],
   Pocket v4, Soprano 1.1, OmniVoice [research-only], Voxtral [research-only],
   LongCat 1B/3.5B, Phonon, Ming 0.5B, Maya1, CSM-1B, …), each validated
   end-to-end on device before it moves from `.implemented` to `.validated`.
   Validation needs roughly 25 GB of free disk for the downloads.

Estimated effort: steps 1–3 are two to three days of focused work plus CI
time; step 4 is incremental and gated by disk and device time.

## Why not port models into the current fork instead

- Every top-10 model that is not already supported needs at least one codec
  or decoder the fork lacks (S3Gen + HiFT, Higgs tokenizer, Voxtral decoder,
  Mimi conditioning, G2P). Upstream has all of them, tested.
- The fork's base is 421 commits behind; every port would be done against
  APIs upstream has already refactored, doubling the eventual merge cost.
- The runtime migration also brings upstream's Qwen3-TTS sliding-window,
  Mimi and streaming fixes to the families we already ship.
