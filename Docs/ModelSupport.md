# Model Support

`TTSMLX` separates model tracking into three stages:

- `validated`: confirmed to synthesize end to end through the current `TTSMLX` wrapper.
- `implemented`: a model family has backend wiring or partial integration, but the wrapper does not advertise it as ready yet.
- `planned`: tracked for future support, but not loadable through the current runtime.

The same data is available in code through `TTSMLX.modelCatalog`.

## Validated

| Model | Description | Get It |
| --- | --- | --- |
| `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit` | Balanced default model for general English synthesis. | [Hugging Face](https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit) |
| `mlx-community/pocket-tts` | Small and fast English model with built-in speaker presets. | [Hugging Face](https://huggingface.co/mlx-community/pocket-tts) |
| `mlx-community/Soprano-80M-bf16` | Compact MLX voice model for lightweight local use. | [Hugging Face](https://huggingface.co/mlx-community/Soprano-80M-bf16) |
| `mlx-community/VyvoTTS-EN-Beta-4bit` | English Qwen3-based model with a smaller footprint. | [Hugging Face](https://huggingface.co/mlx-community/VyvoTTS-EN-Beta-4bit) |
| `mlx-community/orpheus-3b-0.1-ft-bf16` | Higher-capacity LlamaTTS model with expressive built-in English voices. | [Hugging Face](https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-bf16) |
| `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit` | Higher-quality multilingual model for broader language coverage. | [Hugging Face](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit) |

## Implemented

| Model | Description | Get It |
| --- | --- | --- |
| `mlx-community/kitten-tts-mini-0.8` | Kitten TTS is recognized by the backend, but `TTSMLX` still treats it as discovery-only until audio generation and streaming are validated end to end. | [Hugging Face](https://huggingface.co/mlx-community/kitten-tts-mini-0.8) |

## Planned

| Model | Description | Get It |
| --- | --- | --- |
| `OpenMOSS-Team/MOSS-TTS-Nano` | OpenMOSS 0.1B multilingual realtime TTS model with CPU-friendly streaming and 48 kHz stereo output. Tracked for future support; not loadable through the current `MLXAudioTTS` runtime yet. | [Hugging Face](https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano), [Project](https://github.com/OpenMOSS/MOSS-TTS-Nano) |

## Notes

- `MOSS-TTS-Nano` support depends on adding a MOSS-family loader to `mlx-audio-swift` first, then validating it through `TTSMLX`.
- Search can still surface unsupported families as discovery-only results when the repository metadata clearly identifies them as TTS models.
