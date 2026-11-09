# Model research: Priority A candidates (audited 2026-11-05)

Phase 1 of the expansion spec: for each candidate, what it is, what it is
licensed for, how it streams, and what it would take to run natively in
TTSMLX. Numbers are tagged **[upstream]** (the authors' claim), **[third
party]** (someone else's measurement on named hardware) or **[TTSMLX]**
(measured with this repo's harness; see `Docs/benchmarks.md`). Anything
untagged is a fact from the model card, config or source code, with the
source linked.

Legend for the status column of the summary table: *loadable* means a
TTSMLX descriptor exists and the runtime (our `mlx-audio-swift` fork,
0.1.8-tts.6) has a loader; *no port* means nothing in the fork, in upstream
`mlx-audio-swift`, or in Python `mlx-audio` runs it.

| Model | Params / disk (MLX) | Languages | Cloning | Audio streaming (reference impl.) | Progressive text input | Weights licence | Commercial | TTSMLX status |
|---|---|---|---|---|---|---|---|---|
| Qwen3-TTS 0.6B (Base 8-bit) | 0.9 B incl. codec / 2.0 GB | 10 | Yes, 3 s clip + transcript | Architecture is causal (320 ms packets) but the released code has no streaming API | No ("only simulates streaming text input") | Apache-2.0 | Yes | loadable, validated |
| VibeVoice Realtime 0.5B (8-bit) | ~1 B / 1.2 GB | en + 9 experimental | No (encoder withheld) | Yes, one 7.5 Hz latent (133 ms) at a time | No: full text sliced into 5-token windows; upstream TODO still open | MIT (card says research-intended, advisory) | Yes by licence | loadable (this release), benchmarked |
| Fun-CosyVoice3 0.5B | ~0.9 B total / 1.2 GB (4-bit) – 2.2 GB (bf16) | 9 + 18 zh dialects | Yes, zero-shot and cross-lingual | Yes, 25-token (~1 s) chunks growing 25 → 50 → 100 | **Yes**, genuine bistream (5 text : 15 speech tokens) | Apache-2.0 | Yes | no port in the fork; Swift/MLX port exists in `soniqo/speech-swift` (Apache-2.0); `mlx-community/Fun-CosyVoice3-0.5B-2512-4bit` weights exist |
| Pocket TTS (Kyutai) | 100 M / 240 MB | en (+ fr, de, it, es, pt, nl upstream) | Yes, from a clip (upstream); presets in the MLX repo | Yes, per 80 ms Mimi frame | No, sentence chunks of the full text | CC-BY-4.0 (gated upstream); presets carry their own licences | Yes with credit; `cosette` and `jean` presets are CC-BY-NC | loadable, validated |
| Chatterbox Turbo (4-bit) | 350 M / 416 MB + 472 MB S3 tokenizer | en | Yes, clip > 5 s | No, a take is generated whole | No | MIT (project retired Aug 2026) | Yes | loadable, validated |
| Kokoro-82M (bf16) | 82 M / 390 MB | 9 | No | No, whole segment per call | No | Apache-2.0 | Yes | loadable |
| Supertonic 3 | 99 M / 397 MB fp32 ONNX | 31 | No (hosted Voice Builder only, shutting down) | No, whole chunk (non-autoregressive) | No | OpenRAIL-M weights, MIT code; **repo archived 2026-07** | Yes with OpenRAIL-M obligations | no port; ONNX Runtime Swift sample upstream, three Core ML conversions, MLX weights by third parties |
| VoxCPM2 (4-bit) | 2 B / 2.3 GB | 30 + 9 zh dialects | Yes, clip (+ transcript) | Upstream yes, per LM step (160 ms); **the Swift port yields the take whole** | No | Apache-2.0 | Yes | loadable (this release), benchmarked |

The two models the fork cannot run today are CosyVoice 3 and Supertonic 3;
the integration cost for each is at the end of this document.

---

## Qwen3-TTS 0.6B

- **Identity.** `Qwen/Qwen3-TTS-12Hz-0.6B-Base` and `-CustomVoice`, released 2026-01-22; no newer models in the collection as of this audit. Hugging Face metadata counts 0.9 B parameters for the "0.6B" models because the 0.2 B `Qwen3-TTS-Tokenizer-12Hz` (12.5 Hz, 16 codebooks, causal ConvNet decoder) is bundled. Report: arXiv 2601.15621. [https://github.com/QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)
- **MLX checkpoints** (`mlx-community`, converted with mlx-audio 0.3.0): 0.6B-Base-8bit 1.3 GB model + 0.68 GB speech tokenizer = 2.0 GB; 0.6B-Base-4bit 1.7 GB; 0.6B-CustomVoice-4bit 1.7 GB; 1.7B-Base-4bit 2.3 GB; 1.7B-CustomVoice-4bit 2.3 GB.
- **Languages and voices.** zh, en, ja, ko, de, fr, ru, pt, es, it. CustomVoice has nine presets with instruction control; Base clones from a 3 s clip with transcript (or x-vector only); VoiceDesign (1.7B only) builds a voice from a description.
- **Streaming.** The decoder is purely causal and the report describes 320 ms speech packets, but the released Python has no streaming API and the tokenizer decodes whole batches. The `non_streaming_mode` docstring says the flag "only simulates streaming text input". Our fork's Qwen3TTS loader streams at the TTSMLX level by chunk.
- **Licence.** Apache-2.0 for code, weights and tokenizer. No usage policy.
- **Latency.** [upstream] 97 ms first packet with vLLM + CUDA graphs on an unnamed GPU. [third party] vllm-omni-mlx 4-bit on M4 base: 68 ms first audio, RTF 0.34 (their RTF is wall/audio, so about 3x realtime); soniqo on M5 Pro: 0.6B 8-bit RTF 0.76 (wall/audio) with WER 9.7 %.
- **TTSMLX.** Validated default; see `Docs/benchmarks.md` for this repo's numbers.

## VibeVoice Realtime 0.5B

- **Identity.** `microsoft/VibeVoice-Realtime-0.5B`, open-sourced 2025-12-03, experimental languages added 2025-12-16. No newer realtime TTS checkpoint in 2026 (all 2026 VibeVoice releases are ASR). Qwen2.5-0.5B backbone, σ-VAE acoustic tokenizer at 7.5 Hz (3200x downsampling of 24 kHz), 4-layer diffusion head; metadata counts about 1 B parameters including the 340 M decoder. [https://github.com/microsoft/VibeVoice](https://github.com/microsoft/VibeVoice)
- **MLX checkpoints.** 8-bit 1.22 GB, 4-bit 0.73 GB, fp16 2.14 GB. The text tokenizer is not in the repo; the loader fetches `Qwen/Qwen2.5-0.5B` (a few MB, Apache-2.0) at first load.
- **Voices.** 25 preset caches (`voices/*.safetensors`): 7 English, 1 Indian English, 2 each for de, fr, it, ja, ko, nl, pl, pt, es. No cloning: Microsoft withheld the acoustic encoder "to avoid users creating embeddings on their own". No instruction, emotion or speed controls.
- **Streaming output.** Yes. The reference decodes one latent at a time (133 ms) into an audio streamer. The Swift port yields audio every `streamingInterval` seconds while the token loop runs.
- **Progressive text input: not in the released code.** `generate()` takes the full token tensor and slices it into 5-text-token / 6-latent windows internally; the websocket demo takes one complete text per connection; the docs TODO "feed new tokens while audio is still being generated" is unchecked. The architecture would allow it; nobody has implemented it. Do not describe VibeVoice as accepting streamed text.
- **Licence.** MIT for code and weights. The card says the model is intended for research and not recommended for commercial use "without further testing"; that is advice, not a licence term. The card also says outputs carry an imperceptible watermark and an audible "This segment was generated by AI" disclaimer. In the TTSMLX harness the 12-word sentence fixture produced 3.6–4.4 s of audio through the MLX checkpoint, which leaves no room for a spoken disclaimer (the audio was not transcribed; `Benchmarks/results/audio/` has the clips to listen to), so treat the audible-disclaimer claim as describing Microsoft's hosted demo rather than the weights.
- **Latency.** [upstream] 200–300 ms to first audible chunk, realtime on an M4 Pro in PyTorch. No published MLX numbers; [TTSMLX] numbers are in `Docs/benchmarks.md`.

## Fun-CosyVoice3 0.5B

- **Identity.** `FunAudioLLM/Fun-CosyVoice3-0.5B-2512` (base plus an RL-tuned `llm.rl.pt`), released December 2025; the paper's 1.5B variant is not public. arXiv 2505.17589. [https://github.com/FunAudioLLM/CosyVoice](https://github.com/FunAudioLLM/CosyVoice)
- **Architecture** (from `cosyvoice3.yaml`): Qwen2.5-0.5B text-speech LM over a 6561-entry FSQ token space at 25 Hz; S3-Tokenizer v3 (242 M, ONNX, only needed to tokenise the prompt clip); `CausalMaskedDiffWithDiT` flow matching (DiT 1024-d, 22 layers, 10 Euler steps, CFG 0.7, 3-token look-ahead); `CausalHiFTGenerator` vocoder (HiFi-GAN + NSF + iSTFT) at 24 kHz; CAM++ speaker embedding (28 MB ONNX). Text normalisation uses `ttsfrd` (closed, Linux-only wheel) or `wetext`; the LM was trained on raw text so raw passthrough is acceptable.
- **Sizes.** Upstream repo 9.75 GB of `.pt` and ONNX. Community: `mlx-community/Fun-CosyVoice3-0.5B-2512-4bit` 1.22 GB (made with mlx-audio-plus), `aufklarer/CosyVoice3-0.5B-MLX-bf16` 2.1 GB (for speech-swift), GGUF bundles down to 745 MB.
- **Capabilities.** 9 languages plus 18 Chinese dialects; zero-shot cloning with transcript, cross-lingual cloning without, voice conversion, natural-language instructions (`inference_instruct2`), inline `[breath]`/`[laughter]`/`<strong>` tags, pinyin and CMU pronunciation inpainting. No preset voices.
- **Streaming output.** Yes: the LM runs in a worker thread and flow + vocoder decode 25-token (1 s) hops that grow to 50 and 100, with mel cache and a 3-token look-ahead. First audio needs about 28 speech tokens plus one flow and vocoder pass.
- **Progressive text input: yes, genuinely.** `inference_bistream` interleaves 5 text tokens with 15 speech tokens and emits a fill token to request more text; a Python generator of text is consumed as it arrives. This is the only Priority A model with real incremental text input.
- **Licence.** Apache-2.0 code and weights; the "academic purposes" line on the card refers to the demo samples.
- **Latency.** [upstream] "as low as 150 ms" on GPU, no RTF. [third party] soniqo speech-swift 4-bit on M5 Pro: RTF 0.59 (wall/audio), about 1.9 GB; on M2 Max RTF about 0.5 with 13 ms per LM token, 370–520 ms per DiT chunk and 50–170 ms per vocoder call.
- **Feasibility.** No loader in the fork, upstream `mlx-audio-swift`, or Python `mlx-audio`. `soniqo/speech-swift` (Apache-2.0, Swift 6, macOS 15 / iOS 18) has a complete Swift/MLX port (LM, DiT and HiFi-GAN in MLX, CAM++ in Core ML) with streaming, cloning and instructions; that plus the aufklarer bf16 weights is the reference to validate against. Porting into the fork means: Qwen2 LM with the speech vocabulary and bistream loop (small; Qwen2 exists), the causal DiT estimator (the big piece, similar in kind to the MOSS and VoxCPM flow code already in the fork), the causal HiFT vocoder (none exists in the fork), S3-Tokenizer v3 for the prompt clip (MLX port or Core ML), CAM++ (tiny). Expect 1.5–2 GB resident; Mac first, iPhone 15 Pro and later plausible if the tokenizer and CAM++ are unloaded after prompt encoding. ONNX or Core ML for the whole pipeline is not realistic (autoregressive LM with KV cache, bespoke DiT); MLX is the right runtime.

## Pocket TTS

- **Identity.** Kyutai CALM model, about 100 M parameters (6-layer transformer d=1024, flow head, Mimi codec at 24 kHz / 12.5 Hz). arXiv 2509.06926. The upstream repo is gated and now ships many revisions (`english_2026-10` is the default, plus small 2 M–18 M English models and 6/24-layer fr, de, it, es, pt, nl models); `mlx-community/pocket-tts` (240 MB) corresponds to the January 2026 checkpoint. [https://github.com/kyutai-labs/pocket-tts](https://github.com/kyutai-labs/pocket-tts)
- **Capabilities.** 26 presets upstream, cloning from any WAV upstream; the MLX repo bundles eight preset embeddings and the fork does not expose cloning. No instruction, emotion or speed control.
- **Streaming output.** Yes, per 80 ms frame with a 12-frame decoder warm-up; chunk size depends on how many frames are queued.
- **Progressive text input.** No: the full text is split into sentences of up to 50 tokens and run sequentially.
- **Licence, three layers.** Code MIT; weights CC-BY-4.0 (credit Kyutai, link the licence, state modifications; commercial use allowed) with a prohibited-use clause (no cloning without consent, no deception). **Each preset carries the licence of its source corpus** (`kyutai/tts-voices`): `alba`, `azelma`, `eponine`, `fantine` CC-BY-4.0; `javert`, `marius` CC0; **`cosette` (Expresso) and `jean` (EARS) CC-BY-NC-4.0**, so those two presets are non-commercial even though the model is not. TTSMLX now labels each voice accordingly and lists the two non-commercial ones last.
- **Latency.** [upstream] about 200 ms to first chunk and 6x realtime on an M4 Air CPU (two cores). [TTSMLX] see `Docs/benchmarks.md`.

## Chatterbox Turbo

- **Identity.** Resemble AI, 350 M parameters: GPT-2-medium T3 backbone over 6563 speech tokens, S3Gen decoder distilled from 10 to 1 step (meanflow), 24 kHz. Collection dated 2025-12-15. **The project was retired in August 2026** ("no support, updates"); Chatterbox-Multilingual V3 (500 M, 23 languages, MIT, released 2026-06-10, `mlx-community/chatterbox-multilingual-v3` exists) is the successor. [https://github.com/resemble-ai/chatterbox](https://github.com/resemble-ai/chatterbox)
- **MLX checkpoint.** `mlx-community/chatterbox-turbo-4bit` 416 MB plus the `mlx-community/S3TokenizerV2` companion (472 MB). The mlx-community card says Apache-2.0, which conflicts with the upstream MIT card; MIT is the authoritative weights licence.
- **Capabilities.** English only; built-in default voice plus zero-shot cloning from a clip longer than 5 s; `[laugh]`, `[chuckle]`, `[cough]`, `[sigh]`, `[gasp]` tags. `exaggeration`, `cfg_weight` and `min_p` are accepted and ignored by Turbo.
- **Streaming.** None in the reference: T3 runs to completion, then S3Gen. No progressive text. The fork behaves the same, so first audio equals the take's generation time.
- **Licence.** MIT code and weights. The Perth watermarker is applied unconditionally in the Python `generate()`; the Perth repo is MIT and states no restriction on removal, and nothing in the licence requires watermarking. The Swift port does not watermark.
- **Latency.** No upstream Turbo numbers. [TTSMLX] see `Docs/benchmarks.md`.

## Kokoro-82M

- **Identity.** `hexgrad/Kokoro-82M` v1.0 (2025-01-27, last change April 2025), StyleTTS 2 + ISTFTNet decoder, no diffusion, 24 kHz. No release in 2026; v1.1-zh (February 2025) is a separate en+zh model, "not a strict upgrade". [https://huggingface.co/hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)
- **Capabilities.** 54 voices across en-US, en-GB, es, fr, hi, it, ja, pt-BR, zh; no cloning, no instruction or emotion; `speed` only. Non-English support is thin by the author's own description.
- **Streaming.** No intra-utterance streaming; the pipeline yields whole audio per text split. No progressive text.
- **Licence.** Apache-2.0 for weights and the bundled voices; the author explicitly welcomes commercial use. `misaki` G2P is Apache-2.0; **the espeak-ng fallback is GPL-3.0**. The fork uses the `beshkenadze/kitten-tts-g2p` weights for English and IPA lexicons for other languages, so no espeak-ng is bundled.
- **Latency.** [third party] MLX bf16 on M3 Max: 41x realtime, 126 ms to first chunk, about 200 MB peak. [TTSMLX] see `Docs/benchmarks.md`.

## Supertonic 3

- **Identity.** `Supertone/supertonic-3`, released 2026-04-29 (31 languages, v2-compatible ONNX assets). Non-autoregressive flow matching: four ONNX graphs (text encoder 36 MB, duration predictor 4 MB, vector estimator 257 MB, vocoder 101 MB) plus a 65 536-entry Unicode indexer (no G2P), 44.1 kHz output, 8 Euler steps by default. About 99 M parameters. **The GitHub repository was archived on 2026-07-23** with no further updates or support, and the hosted Voice Builder (the only cloning route) stops on 2026-08-31; mirrors exist under `supertone-oss-archive`. [https://github.com/supertone-inc/supertonic](https://github.com/supertone-inc/supertonic)
- **Capabilities.** 10 preset voices (M1–M5, F1–F5) as style vectors; no open cloning; `speed` 0.7–2.0; 10 inline expression tags, which one third-party guide reports as effectively cloud-only.
- **Streaming.** None: each chunk (≤300 characters) is synthesised whole; long text is split at sentence boundaries and joined with 0.3 s of silence. No progressive text.
- **Licence.** MIT code; **weights and voice styles under BigScience OpenRAIL-M**: commercial and hosted use allowed, but Attachment A use restrictions must be passed downstream, machine-generated content must be disclosed, notices retained and modified files marked. Converted weights inherit the same restrictions.
- **Ports.** Official ONNX Runtime samples in Swift (SPM, macOS 13+) and an iOS SwiftUI app (RTF 0.30 wall/audio on an unnamed device, [upstream]). Core ML conversions: `aufklarer/Supertonic-3-CoreML` (fp32, iOS 18+), `Reza2kn/supertonic-3-coreml` (fp16, ANE, fixed 22 s bucket), and one author who found coremltools' ONNX path unreliable and recommends ONNX Runtime with the Core ML execution provider. MLX weights: `tinytrashlabs/supertonic-3-mlx` (397 MB safetensors, built for an `mlx-audio-swift` `SupertonicModel` that is not on upstream `main`), `mlx-community/supertonic-3` (JSON graph + NPZ for a Python interpreter). Nothing in the fork.
- **Latency.** [upstream] M4 Pro CPU RTF 0.015 (two steps); WER en 2.06. [third party] int8 ONNX on Apple Silicon: peak RSS 327 MB vs 1026 MB fp32; soniqo Core ML on iPhone 16 Pro RTF 0.15; community ORT server on M4 Pro first byte 450–650 ms.
- **Feasibility.** Smallest integration of the eight: four feed-forward graphs with no KV cache. An MLX port in the fork is realistic (two independent conversions already match ONNX Runtime to 1e-4) and keeps TTSMLX on one runtime; ONNX Runtime on CPU is the zero-effort fallback with official Swift samples. The risks are the archived project (10 voices forever, no fixes) and the OpenRAIL-M downstream obligations.

## VoxCPM2

- **Identity.** OpenBMB, released April 2026, report arXiv 2606.06928. Tokenizer-free diffusion-autoregressive model: MiniCPM-4 backbone (28 layers, 2048-d), residual LM (8 layers), local encoder and DiT (12 layers each), AudioVAE V2 (16 kHz in, **48 kHz out**, 25 Hz latents, patch size 4 so the LM steps at 6.25 Hz). 2 B parameters. [https://github.com/OpenBMB/VoxCPM](https://github.com/OpenBMB/VoxCPM)
- **MLX checkpoint.** `mlx-community/VoxCPM2-4bit` 2.3 GB: only the LM layers are quantised, VAE and DiT stay full precision. 8-bit 3.2 GB and bf16 5.0 GB also exist.
- **Capabilities.** 30 languages and 9 Chinese dialects with no language tag; no preset voices; zero-shot cloning from a clip, optionally with its transcript; voice design, emotion and pace through a parenthesised natural-language description in front of the text.
- **Streaming.** Upstream `generate_streaming()` yields once per LM step (160 ms at 48 kHz) by re-decoding a sliding window of three patches. **The Swift port generates the take whole and yields it as a single audio event**, so in TTSMLX first audio equals generation time; the descriptor says `supportsStreaming: false` for that reason. No progressive text.
- **Licence.** Apache-2.0 code and weights, "free for commercial use"; a non-binding usage policy forbids impersonation and asks for AI labelling.
- **Latency.** [upstream] RTF 0.30 (wall/audio) on an RTX 4090; llama.cpp-omni Q8_0 on an M4 Pro RTF 1.76 (slower than realtime). [third party] the mlx-community card on unnamed Apple Silicon: 4-bit 0.90x where above 1 is faster than realtime. [TTSMLX] see `Docs/benchmarks.md`.

### VoxCPM 1.5 (added 2026-11-09)

- **Identity.** OpenBMB, released December 2025, the "stable" release in the VoxCPM repository next to the legacy 0.5B (September 2025) and VoxCPM2. Same tokenizer-free diffusion-autoregressive design on a MiniCPM-4 0.5B backbone, 0.8 B parameters in all; AudioVAE at **44.1 kHz**, patch size 4 so the LM steps at 6.25 Hz (the 0.5B stepped at 12.5 Hz over a 16 kHz VAE).
- **MLX checkpoint.** `mlx-community/VoxCPM1.5-4bit` 620 MB (LM quantised, group size 64); fp16 and 8-bit also exist. The fork's `voxcpm` loader (runtime 0.1.8-tts.5) accepts all three.
- **Capabilities.** English and Chinese; upstream says other languages are not guaranteed. No preset voices, no voice design, no style text: cloning is "continuation only", a reference clip plus its exact transcript. Phoneme input (`{HH AH0 L OW1}`) exists upstream but is not exposed here.
- **Streaming.** As VoxCPM2: the Swift port generates the take whole and yields one audio event.
- **Licence.** Apache-2.0 code and weights.
- **Latency.** [upstream] RTF 0.15–0.17 on an RTX 4090; about 6 GB of VRAM. [TTSMLX, M1 Pro, Release, 2026-11-09] 1.2x realtime on every fixture, 3.2 s to first audio on a sentence (narration path; the model does not stream), MLX peak 3.6 GB sentence / 5.4 GB paragraph / 7.2 GB long form, resident 2.1 GB with the cache cap; stalls on long form (8.5 s of pre-roll). Three times smaller on disk than VoxCPM2 and twice as fast, but the AudioVAE transient keeps it a Mac model. `Docs/benchmarks.md`.

---

## Integration cost for the two models without a port

| | CosyVoice 3 | Supertonic 3 |
|---|---|---|
| New runtime code | Qwen2 LM with speech vocabulary and bistream loop; causal DiT estimator; causal HiFT vocoder; S3-Tokenizer v3 (prompt only); CAM++ | Unicode indexer and chunker; text encoder; duration predictor; vector estimator with host-side CFG and Euler loop; vocoder |
| Existing Swift reference | `soniqo/speech-swift` (Apache-2.0), full port with streaming | Official ONNX Runtime Swift and iOS samples; three Core ML conversions |
| Weights ready for MLX | `mlx-community/Fun-CosyVoice3-0.5B-2512-4bit`, `aufklarer/...-MLX-bf16` | `tinytrashlabs/supertonic-3-mlx`, `mlx-community/supertonic-3` |
| Runtime choice | MLX only (autoregressive, KV cache, bespoke DiT) | MLX port is small; ONNX Runtime CPU is the trivial fallback |
| Expected footprint | 1.5–2 GB resident, Mac first | 200–400 MB, iPhone-class |
| What you get | The only model here with real incremental text input, plus cloning, instructions and 9 languages | 31 languages at very low cost, 10 voices, no cloning, archived upstream |
| Licence risk | None (Apache-2.0) | OpenRAIL-M obligations on every downstream build |

Recommendation: CosyVoice 3 is the one worth porting into the fork, because
it is the only candidate that delivers what "agent streaming speech" needs
(audio before the text is finished). Supertonic 3 is cheap but its project is
archived and its weights carry use restrictions; if 31-language coverage at
tiny cost matters, run it through ONNX Runtime from the official Swift sample
rather than spending fork effort on it.
