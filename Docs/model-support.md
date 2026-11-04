# Model support matrix

Status of every model on the [tts-bench](https://github.com/5uck1ess/tts-bench)
leaderboard (Elo ranking as of 2026-11-03) against what TTSMLX can run, and
what is blocked and why. Verified 2026-11-03 from the Hugging Face model
cards, the upstream `Blaizzy/mlx-audio-swift` v0.1.8 source tree and Python
`mlx-audio` v0.6.4; statuses updated 2026-11-04 after the runtime migration
shipped in TTSMLX 0.10.0.

## The one fact that decides most rows

TTSMLX runs models through `fil-technology/mlx-audio-swift`. Until 0.9.1 that
fork was cut from upstream **v0.1.3** plus 11 commits, 421 commits behind an
upstream that had meanwhile added about 25 TTS families, 9 codecs and a G2P
target. **Since 0.10.0 the fork is cut from upstream v0.1.8** (`0.1.8-tts.4`)
and adds only `TTSModelRegistry`, one model-type alias and the MOSS-TTS-Nano
voice pack, so every family upstream implements loads through the same
`TTSSpeechSynthesizer` API. What remains per model is validation (an
end-to-end run, memory and throughput on device) and licence review, not
porting.

Legend for the **Status** column:

| Code | Meaning |
|---|---|
| ✅ | Catalog entry with a descriptor: TTSMLX has synthesized with it end to end (`.implemented`; `.validated` once measured on device) |
| ✅ (runtime) | The runtime loads the family, but no catalog entry yet (licence, size or no suitable weights) |
| **D** | Discovery-only catalog entry: the runtime routes to it, TTSMLX has not synthesized with it yet; `runtimeNotes` says why |
| ⛔ | Blocked for reasons the runtime does not fix (stated per row) |

## Leaderboard

| # | Model | Elo | Status | Licence (commercial?) | Architecture · codec · size · SR | Features we can expose | Why not today / what is missing |
|---|---|---|---|---|---|---|---|
| 1 | Kokoro 82M | 1341 | ✅ (0.10.0) | Apache-2.0 (yes) | StyleTTS2-derived, non-autoregressive, ISTFTNet · 82M · 24 kHz | 54 preset voices, 8 languages, fast | Catalog entry `mlx-community/Kokoro-82M-bf16` (`.implemented`, all 54 voices listed); synthesizes end to end on macOS, 1.5 s to first audio. English G2P weights come from `beshkenadze/kitten-tts-g2p` (9 MB, prefetched as a companion repo); other languages fetch an IPA lexicon on first use. |
| 2 | Chatterbox | 1317 | ✅ (0.10.2) | MIT (yes) | T3 Llama ~0.5B over S3 tokens → S3Gen flow matching (10 steps) + HiFT-GAN · 24 kHz | Cloning from a wav, exaggeration/CFG knobs, 23 languages, `[laughter]` `[sigh]` tags | Catalog entry `mlx-community/chatterbox-4bit` (`.implemented`; multilingual weights, 612 MB + 495 MB `S3TokenizerV2`). Needs runtime `0.1.8-tts.4`: upstream decoded this checkpoint (no `t3` block) as English-only and tokenized text without the reference's `punc_norm`, lowercase/NFKD, `[SPACE]` word boundaries and `[xx]` language tag; the fork adds all of that and reads the tag from `TTSSynthesisOptions.language`. Synthesizes end to end on macOS in English, French and German (default voice) and English with a 48 kHz reference clip. zh/ja/he/ko/ru lack the reference's script rewrites. Memory: MLX peak active 2.5 GB (3.0 GB with a clip); cache grows to 14 GB per run unless capped (512 MB cap → 3.3 GB footprint). T3 ~40 tok/s warm in debug with the cap; S3Gen adds ~2.5 s per chunk. |
| 3 | Chatterbox Turbo | 1257 | ✅ (0.10.1) | MIT (yes) | GPT-2-medium T3 ~350M + one-step distilled S3Gen · 24 kHz · English | Cloning, bundled default voice, `[laugh]` `[chuckle]` `[sigh]` `[cough]` `[gasp]` tags | Catalog entry `mlx-community/chatterbox-turbo-4bit` (`.implemented`; 417 MB + 495 MB `S3TokenizerV2` companion). Synthesizes end to end on macOS with the bundled voice and with a 48 kHz reference clip; tags render. Slow in a debug build: T3 runs ~12 tokens/s (25 tokens per second of audio) and the runtime generates each chunk whole, so first audio arrives after about 2x the chunk duration. Memory: MLX peak active 2.5 GB; the buffer cache grows to 7 GB per run unless capped (512 MB cap → 3.2 GB process footprint). fp16 (3 GB) and 8-bit (0.7 GB) builds not run. |
| 4 | Higgs Audio v3 TTS | 1196 | **D** ⚠️ | Boson research / **non-commercial** | ~4B Qwen3-style AR over Higgs tokenizer (8 codebooks @ 25 fps) · 24 kHz | 100+ languages, cloning, 21 emotion + style/SFX tags, streaming | Runtime routes to it; discovery-only entry `bosonai/higgs-tts-3-4b` flagged research-only. Licence forbids commercial use; ~8 GB bf16, no mlx-community quant yet. |
| 5 | Supertonic 3 | 1192 | ⛔ | OpenRAIL-M weights, MIT code (use-restricted) | ONNX-only: text encoder + duration predictor + flow-matching estimator + vocoder · ~99M · 44.1 kHz | 31 languages, preset voices, 10 tags | No MLX implementation anywhere (Python or Swift). Weights exist only as ONNX graphs plus a third-party JSON/NPZ dump; the latent-flow + speech-autoencoder pipeline would be a from-scratch port with a weight conversion. Candidate for a later dedicated effort, not this cycle. |
| 6 | Pocket-TTS v4 | 1172 | ✅ | CC-BY-4.0 weights (yes) | ~100M transformer → Mimi · 24 kHz | 7 languages, 26 voices, cloning, ~200 ms streaming | Catalog entry `mlx-community/pocket-tts`; re-validated on the 0.1.8 runtime (0.8 s to first audio), which includes upstream's Mimi context-window and `resetState` fixes (#357, #368). |
| 7 | Soprano 1.1 80M | 1155 | ✅ (0.9.1) | Apache-2.0 (yes) | Qwen3-arch LM 80M + custom decoder · 32 kHz · English | One voice, streaming | Catalog entry `mlx-community/Soprano-1.1-80M-bf16` (`.implemented`); synthesizes end to end on macOS, on-device validation pending. |
| 8 | OmniVoice | 1148 | **D** ⚠️ | Code Apache-2.0, weights **CC-BY-NC** | Bidirectional diffusion-LM over Qwen3-0.6B, 9 RVQ codebooks via Higgs v2 codec · ~1B · 24 kHz | 600+ languages, cloning, voice design, `[laughter]` | Runtime routes to it; discovery-only entry `mlx-community/OmniVoice` flagged research-only (weights are non-commercial). |
| 9 | Orpheus-TTS 3B | 1146 | ✅ | Apache-2.0 (yes, gated) | Llama-3B AR over SNAC · 24 kHz · English | 8 voices, `<laugh>` `<sigh>` … tags, streaming | Catalog entry `mlx-community/orpheus-3b-0.1-ft-bf16`. Tags pass through unchanged today; see "Features to expose" below. |
| 10 | Voxtral 4B TTS | 1122 | **D** ⚠️ | **CC-BY-NC-4.0** | Ministral-3B backbone + Voxtral audio decoder · ~4B · 24 kHz | 9 languages, 20 preset voices, cloning, streaming | Runtime routes to it; discovery-only entry `mlx-community/Voxtral-4B-TTS-2603-mlx-4bit` flagged research-only. Upstream's streaming fix (#370) landed after v0.1.8. |
| 11 | dots.tts (soar) | 1121 | ⛔ | Apache-2.0 (yes) | Qwen2.5-1.5B + AR flow-matching DiT head over a 48 kHz AudioVAE · 2B | 24 languages, cloning | No implementation in Python mlx-audio or upstream Swift; third-party `dots-tts-mlx` weights have no runtime. Architecturally near VoxCPM2/Ming (which upstream has), so a port is plausible later. |
| 12 | LongCat-AudioDiT 3.5B | 1112 | **D** | MIT (yes) | Non-AR DiT in Wav-VAE latent space, UMT5 text encoder · 3.8B · 24 kHz | zh + en, cloning, ≤ 30 s utterances | Runtime routes to it; the 1B has a discovery-only entry, the 3.5B (`mlx-community/LongCat-AudioDiT-3.5B-*`) loads through the same loader. Non-streaming by design. |
| 13 | Phonon 31m | 1110 | ✅ (0.10.0) | Apache-2.0 (yes) | Pocket-TTS derivative: flow-matching transformer → Mimi · 31M · 24 kHz | ~100 voices (`gradium/phonon-voices`), streaming | Catalog entry `gradium/phonon-31m-en` (`.implemented`); synthesizes end to end on macOS, 0.8 s to first audio. Needed a fork fix: the checkpoint's `model_type` is `gradium_phonon_tts`, which upstream's loader did not map. |
| 14 | Ming-3.0-TTS 0.5B | 1100 | **D** | MIT (yes) | Qwen2.5-0.5B + flow-matching DiT head + audio VAE, CAM++ · 1.5B · 44.1 kHz | 7 languages, 100+ voices, cloning, voice design, emotion/speed/pitch, 14 tags | Runtime routes to it; discovery-only entry `mlx-community/Ming-3.0-tts-0.5B-bf16` (3 GB, not validated here). |
| 15 | LFM2.5-Audio 1.5B | 1094 | ⛔ (for now) | LFM Open License v1.0 (read before shipping) | LFM2-1.2B hybrid + RQ-transformer → 8 Mimi-compatible codebooks → ISTFT detokenizer · 24 kHz | 4 voices via system prompt, token streaming | Upstream keeps it under `MLXAudioSTS`, not as a `SpeechGenerationModel`; TTSMLX would need an adapter in `TTSSpeechSynthesizer`. |
| 16 | Maya1 | 1092 | **D** | Apache-2.0 (yes) | Llama-style 3.3B AR over SNAC (7 tokens/frame) · 24 kHz | Natural-language voice description, 20 emotion tags, streaming | Discovery-only entry `mlx-community/maya1-4bit` (Llama + SNAC path). Needs the `<description="…">` prompt format wired through the voice option, then validation. |
| 17 | Sesame CSM-1B | 1092 | **D** | Apache-2.0 (yes, gated) | Llama-1B backbone + small AR audio decoder over Mimi · 24 kHz | Speaker id, context turns (cloning via a prior turn) | Discovery-only entry `mlx-community/csm-1b-8bit`; routes to the Marvis/CSM loader. Validate the load and speaker-id mapping, then add a descriptor. |
| 18 | MiraTTS | 1077 | ⛔ | **CC-BY-NC-SA-4.0** on HF (bench says MIT; HF wins) | Qwen2 0.5B + FastBiCodec + FlashSR upsampler · 48 kHz | en + zh, cloning | Non-commercial, LMDeploy-only runtime, no MLX port anywhere; needs a BiCodec variant and FlashSR. |
| 19 | OuteTTS 1.0 1B | 1070 | **D** ⚠️ | **CC-BY-NC-SA-4.0** + Llama 3.2 | Llama-3.2-1B AR over IBM DAC-speech (2 codebooks) · 24 kHz | 12+ languages, default speaker + cloning profiles | Discovery-only entry `mlx-community/Llama-OuteTTS-1.0-1B-fp16` flagged research-only (non-commercial). |
| 20 | Phonon 40m | 1055 | ✅ (runtime) ⚠️ | **CC-BY-NC-4.0** (gated) | As #13 · 40M | As #13 | Same loader as #13; no catalog entry because the weights are gated and non-commercial. |
| 21 | LongCat-AudioDiT 1B | 1047 | **D** | MIT (yes) | As #12 · 1.4B | As #12 | Discovery-only entry `mlx-community/LongCat-AudioDiT-1B-bf16` (5.7 GB bf16; validate the 4-bit build on phones). |
| 22 | Vaniq-Edge | 1027 | ⛔ | MIT (yes) | Compressed VITS with built-in waveform decoder · 8.9M · 24 kHz | One voice, speed knob | No MLX implementation; needs a VITS port (posterior/flow + HiFi-GAN-style decoder). Tiny; a reasonable later port alongside MeloTTS. |
| 23 | Ming-3.0-TTS tiny | 1023 | ✅ (runtime) | MIT (yes) | Ling V3 MoE ~8B total / ~1.3B active + DiT head · 44.1 kHz | As #14 plus podcast dialogue | Runtime routes to it (`lingv3_tts`); no catalog entry yet, memory-heavy for phones (MoE weights are all resident). |
| 24 | LFM3-Audio 2B | 1021 | ⛔ (for now) | LFM Open License v1.0 | LFM3-1.7B + LiquidCodec (12 tokens / 80 ms) · 24 kHz | 18 languages, male/female via system prompt, streaming | Python `sts/lfm3_audio` exists; **no Swift implementation** upstream yet (README covers LFM2.5 only). Needs the LiquidCodec decoder in Swift. |
| 25 | DramaBox | 999 | ⛔ | LTX-2 Community (non-commercial per bench) | 3.3B audio-only DiT + VAE + Gemma-3-12B text encoder · 48 kHz | Prompt-described voice, cloning | ~24 GB working set; impractical on device regardless of runtime. Not in upstream Swift. |
| 26 | KittenTTS 2 | 998 | ⛔ (for now) | Stellon Labs Community (free up to $1M revenue) | 1.7B Qwen3-arch LM (ternary-packed) → S3 tokens → decoder · 24 kHz | 16 languages, 115 voices, cloning, emotion tags (beta) | Neither Python nor Swift mlx-audio has it; needs a ternary weight unpacker and the S3-token decoder (upstream S3Gen may fit; unverified). |
| 27 | VibeVoice Realtime 0.5B | 994 | **D** | MIT (yes) | Qwen2.5-0.5B + 40M diffusion head + σ-VAE tokenizer · 24 kHz | 25 preset voices, streaming | Discovery-only entry `mlx-community/VibeVoice-Realtime-0.5B-8bit`. |
| 28 | Inflect-Micro v2 | 993 | ⛔ | Apache-2.0 (yes) | Compressed VITS · 9.4M | One voice, speed/variation | VITS port needed (see #22). |
| 29 | Hojo-TTS-Light 40M | 992 | ⛔ | Apache-2.0 (yes) | ONNX three-stage token LM over a 50 Hz codec · ~80M | zh + en, 15 voices | ONNX-only release; no MLX port anywhere. |
| 30 | KittenTTS Nano 0.8 | 990 | ⛔ (checkpoint) | Apache-2.0 (yes) | StyleTTS2 / ISTFTNet · 15M · 24 kHz | 8 voices | Entry `mlx-community/kitten-tts-mini-0.8` stays discovery-only: the loader requires `voices.safetensors` and the mlx-community checkpoint ships only `voices.npz`, which upstream rejects by design ("convert with scripts/convert_voices_npz.py"). Needs a converted voices file. |
| 31 | Audio8 TTS 0.6B | 973 | **D** | Apache-2.0 (yes) | Dual-AR + bundled 44.1 kHz 10-codebook codec | 11 languages, cloning | Discovery-only entry `mlx-community/Audio8-TTS-Preview-0.6b-bf16`. |
| 32 | Magpie-TTS 357M | 973 | ⛔ | NVIDIA Open Model License (commercial OK, gated) | Encoder-decoder + local transformer over NanoCodec · 22.05 kHz | 12 languages, 5 voices | Needs NanoCodec; no mlx-audio port. Third-party MLX weights only. |
| 33 | Inflect-Nano v2 | 966 | ⛔ | Apache-2.0 | VITS · 4M | As #28 | VITS port needed. |
| 34 | StyleTTS 2 (generic) | 957 | ⛔ | MIT code, voice-use conditions | Style diffusion + PL-BERT + iSTFTNet · ~148M | Cloning via reference style | Upstream has the StyleTTS2 stack only as used by Kokoro/Kitten; the style-diffusion sampler and PL-BERT are missing. |
| 35 | Miso TTS 8B | 954 | ✅ (runtime, maybe) | "modified MIT" (terms unverified) | CSM-style Llama-8B + 300M decoder over Mimi · 24 kHz | Continuation cloning | Routes to the Marvis/CSM path upstream; 8B is too large for most devices. |
| 36 | VoxCPM2 2B | 948 | **D** | Apache-2.0 (yes) | MiniCPM-4 + LocDiT local diffusion + AudioVAE v2 · 48 kHz | 30 languages, cloning, voice design, streaming | Discovery-only entry `mlx-community/VoxCPM2-4bit`. |
| 37 | Parler-TTS Mini v1 | 944 | ⛔ | Apache-2.0 (yes) | T5 encoder + AR decoder over DAC · 0.9B · 44.1 kHz | Description prompting, 34 named speakers | No port in current upstream trees. |
| 38 | Scylla's Band | 938 | ⛔ | Apache-2.0 (yes) | Duration predictor + rectified-flow latent generator + Vocos · ~103M | 14 voices / 7 locales | We have Vocos; the flow latent generator is missing and there is no mlx-audio port. |
| 39 | Qwen3-TTS 0.6B CustomVoice | 937 | ✅ (0.9.1) | Apache-2.0 (yes) | Qwen3 talker + 12 Hz tokenizer · 24 kHz | 9 built-in speakers (`ryan`, `serena`, …) via the voice option, optional style instruction after a comma, 10 languages, streaming | Catalog entries for 0.6B and 1.7B CustomVoice. Needed a runtime fix (fork 0.1.7-tts.2): the config's `spk_id` table did not decode and speakers were never selected. The 4-bit 0.6B build occasionally emits a near-silent chunk that runs to the token cap; prefer 8-bit once published. |
| 40 | Dia 1.6B | 927 | **D** | Apache-2.0 (yes) | Encoder-decoder AR over 9 DAC codebooks with CFG · 44.1 kHz | `[S1]`/`[S2]` dialogue, ~20 nonverbal tags, cloning | Discovery-only entry `mlx-community/Dia-1.6B` (+ `mlx-community/descript-audio-codec-44khz`). |
| 41 | MeloTTS | 918 | ✅ (0.10.0) | MIT (yes) | VITS + BERT prosody + HiFi-GAN · ~52M · 44.1 kHz | 5 English accents | Catalog entry `mlx-community/MeloTTS-English-MLX` (`.implemented`, 5 accents); synthesizes end to end on macOS, 0.5 s to first audio. Frontend resources (g2p_en, NLTK) come from GitHub at first load. |
| 42 | SteerTTS | 889 | ⛔ | **CC-BY-NC-4.0** weights | FastPitch-style + bidirectional Mamba + Vocos · 23–41M | 2,825 voices, 12 knobs, 51 tags | Non-commercial; no port; Mamba blocks are not in mlx-audio. |
| 43 | Coqui XTTS-v2 | 880 | ⛔ | CPML (**non-commercial**) | GPT-2 AR + HiFi-GAN decoder · ~750M · 24 kHz | 17 languages, 6 s cloning | Non-commercial; no port. |
| 44 | AuroraTTS-100K | 874 | ⛔ | Apache-2.0 | FastPitch-like + DSP harmonic/noise synth · 96K params | One voice | No port; quality below our smallest supported model. |
| 45 | Mars5-TTS | 811 | ⛔ | AGPL-3.0 (copyleft) | AR 750M + NAR diffusion 450M over Encodec, Vocos | Cloning | AGPL is incompatible with closed-source apps consuming TTSMLX; no port. |
| 46 | Piper | 809 | ⛔ | GPL-3.0 (copyleft) | VITS ONNX · ~15M · 22.05 kHz | Many languages/voices | GPL plus no port. |
| 47 | SupraTTS 0.1 Beta | 739 | ⛔ | MIT | Glow-TTS + HiFi-GAN · 43.5M | One voice | No port; beta quality. |
| 48 | sanoTTS | 729 / 701 | ⛔ | GPL-3.0 | Tiny numpy duration + acoustic + iSTFT · ≤ 1.5M | One voice | GPL plus no port. |

Marvis-250M (`Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit`), VyvoTTS-EN-Beta and
MOSS-TTS-Nano are supported today but are not on the leaderboard.

## Features to expose per family (on the TTSMLX API)

These are things the models already understand and TTSMLX currently drops or
does not surface. Each is an additive option on `TTSSynthesisOptions` or a
catalog capability flag:

- **Inline tags** — Orpheus / Maya1 (`<laugh>`, `<sigh>`, `<chuckle>`, …),
  Chatterbox Turbo (`[laugh]`), Dia (`(laughs)` family), Higgs v3, Ming,
  Supertonic. Today tags pass through as text and work on Orpheus; the chunker
  must never split inside a tag and a `supportsTags` capability should let apps
  show a palette. Documented list per model to ship with the catalog entry.
- **Style / instruct text** — Qwen3-TTS CustomVoice (done in 0.9.1: `"speaker, instruction"` in the voice option) and VoiceDesign, Maya1
  (`<description=…>`), Ming, VoxCPM2, OmniVoice, LFM (system prompt voice). New
  `TTSSynthesisOptions.styleInstruction` routed to the family's prompt format.
- **Reference-audio cloning** — Chatterbox, Higgs v3, OmniVoice, Voxtral,
  LongCat, Ming, Pocket-TTS, Maya-style continuation (CSM), Qwen3-TTS Base,
  Orpheus. `referenceAudio` / `referenceText` already exist on the options;
  the catalog flags need auditing (`Qwen3-TTS Base` is the cloning variant and
  is currently flagged `supportsReferenceAudio: false`).
- **Preset voices** — Kokoro (54), Voxtral (20), VibeVoice (25), Ming (100+),
  Phonon (~100), Pocket (26). `TTSVoice` lists are per catalog entry.
- **Languages** — exposed through `supportsLanguageList` today; the
  discovery-only families are mostly multilingual and need their language
  tables audited when they get descriptors.

## The migration, as shipped in 0.10.0

1. **mlx-swift fork at 0.33.0** — `fil-technology/mlx-swift` tag `0.33.100`
   (branch `tts-bg-safe-0.33.0`): upstream 0.33.0 with the `mlx` submodule at
   `fil-technology/mlx` `v0.33.0-tts-bg-safe.1`. The background-safe patch
   moved from `check_error()` in `eval.cpp` to the command-buffer completion
   handler in `device.cpp`, where upstream now records Metal errors. The tag
   is a normal version (prerelease tags are excluded from `from: "0.33.0"`
   ranges) with a reserved patch number, which closes the URGENT.md re-tag
   follow-up. Details: `Docs/mlx-swift-bg-safe-fork.md`.
2. **mlx-audio-swift fork restarted from v0.1.8** — branch `tts/0.1.8`, tag
   `0.1.8-tts.4`. Kept from the old fork: `TTSModelRegistry` (now a thin view
   over upstream's loader switch, with a companion-repository table covering
   SNAC, the MOSS codec, S3TokenizerV2, the Kokoro/Kitten G2P weights, DAC
   and others) and the MOSS-TTS-Nano voice pack, codebook dial and per-chunk
   decoding. Dropped because upstream has them: the Mimi reset fix, the
   Qwen3-TTS CustomVoice speaker fix, the old MOSS port. Added: the
   `gradium_phonon_tts` model-type alias.
3. **TTSMLX adaptation** — `GenerateParameters` from `MLXAudioCore`,
   `MaterializedArray` at the `SpeechGenerationModel` boundary, `mlx-swift-lm`
   removed, `swift-huggingface` 0.12.0, CI on `macos-26` (Swift 6.3
   toolchain). Public TTSMLX API unchanged.
4. **Catalog + validation** — re-validated Pocket-TTS, Soprano, Marvis and
   MOSS; added Kokoro, Phonon 31M and MeloTTS with descriptors; added
   discovery-only rows for the rest of the routable leaderboard. Validation
   on this machine was gated by disk (about 3 GB free at the end of the
   cycle), which is why Chatterbox, Ming, LongCat and the 3 GB-class models
   were still **D**. 0.10.1 validated Chatterbox Turbo 4-bit (1 GB-class);
   0.10.2 validated regular Chatterbox 4-bit (multilingual) after fixing its
   text pipeline in the fork.

## Next, in leaderboard order

Each needs an end-to-end run plus a descriptor; none needs model code:
Ming-3.0-TTS 0.5B
(#14, 3 GB), LongCat-AudioDiT 1B 4-bit (#21), CSM-1B 8-bit (#17), Maya1 4-bit
(#16, needs the description prompt), VibeVoice Realtime (#27), VoxCPM2 (#36),
Dia (#40, needs dialogue-script formatting), Audio8 (#31). Research-only
(non-commercial weights): Higgs v3, OmniVoice, Voxtral, OuteTTS.
