import Foundation

public enum TTSMLX {
    public static let supportedModels: [TTSModelDescriptor] = [
        .init(
            id: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
            displayName: "Marvis",
            summary: "Balanced default model.",
            supportedLanguages: [.english],
            suggestedVoices: [],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .balanced
            )
        ),
        .init(
            id: "mlx-community/pocket-tts",
            displayName: "Pocket TTS",
            summary: "Small and fast.",
            supportedLanguages: [.english],
            suggestedVoices: [.alba, .marius, .javert, .jean],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .fast
            )
        ),
        .init(
            id: "mlx-community/echo-tts-base",
            displayName: "Echo TTS",
            summary: "Reference-audio cloning model added in mlx-audio-swift 0.1.2.",
            supportedLanguages: [.english],
            suggestedVoices: [],
            capabilities: .init(
                supportsReferenceAudio: true,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .balanced
            )
        ),
        .init(
            id: "mlx-community/Soprano-80M-bf16",
            displayName: "Soprano",
            summary: "Compact MLX voice model.",
            supportedLanguages: [.english],
            suggestedVoices: [],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .balanced
            )
        ),
        .init(
            id: "mlx-community/VyvoTTS-EN-Beta-4bit",
            displayName: "VyvoTTS",
            summary: "English Qwen3-based model with a small footprint.",
            supportedLanguages: [.english],
            suggestedVoices: [.enUS1],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .balanced
            )
        ),
        .init(
            id: "mlx-community/orpheus-3b-0.1-ft-bf16",
            displayName: "Orpheus",
            summary: "Higher-capacity LlamaTTS model with multiple built-in voices.",
            supportedLanguages: [.english],
            suggestedVoices: [.tara, .leah, .jess, .leo, .dan, .mia, .zac, .zoe],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english],
                defaultGenerationProfile: .highQuality
            )
        ),
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
            displayName: "Qwen3 TTS",
            summary: "Higher quality multilingual model.",
            supportedLanguages: [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi],
            suggestedVoices: [.enUS1],
            capabilities: .init(
                supportsReferenceAudio: false,
                supportsLanguageList: true,
                supportedLanguages: [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi],
                defaultGenerationProfile: .highQuality
            )
        )
    ]

    public static let defaultModels: [TTSModelDescriptor] = supportedModels
}
