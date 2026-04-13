import Foundation

public enum TTSMLX {
    public static let modelCatalog: [TTSModelCatalogEntry] = [
        validatedEntry(
            descriptor: .init(
                id: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
                displayName: "Marvis",
                summary: "Balanced default model.",
                supportedLanguages: [.english],
                suggestedVoices: [],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced
                )
            ),
            modelURL: URL(string: "https://huggingface.co/Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/pocket-tts",
                displayName: "Pocket TTS",
                summary: "Small and fast.",
                supportedLanguages: [.english],
                suggestedVoices: [.alba, .marius, .javert, .jean],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .fast
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/pocket-tts")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/Soprano-80M-bf16",
                displayName: "Soprano",
                summary: "Compact MLX voice model.",
                supportedLanguages: [.english],
                suggestedVoices: [],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-80M-bf16")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/VyvoTTS-EN-Beta-4bit",
                displayName: "VyvoTTS",
                summary: "English Qwen3-based model with a small footprint.",
                supportedLanguages: [.english],
                suggestedVoices: [.enUS1],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/VyvoTTS-EN-Beta-4bit")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/orpheus-3b-0.1-ft-bf16",
                displayName: "Orpheus",
                summary: "Higher-capacity LlamaTTS model with multiple built-in voices.",
                supportedLanguages: [.english],
                suggestedVoices: [.tara, .leah, .jess, .leo, .dan, .mia, .zac, .zoe],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .highQuality
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-bf16")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                displayName: "Qwen3 TTS",
                summary: "Higher quality multilingual model.",
                supportedLanguages: [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi],
                suggestedVoices: [.enUS1],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi],
                    defaultGenerationProfile: .highQuality
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")
        ),
        .init(
            id: "mlx-community/kitten-tts-mini-0.8",
            displayName: "Kitten TTS",
            summary: "Compact Kitten TTS family model that the backend can identify, but the wrapper does not synthesize end to end yet.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Tracked as implementation-in-progress. The current TTSMLX wrapper still treats Kitten TTS as discovery-only until generation and streaming are validated end to end.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/kitten-tts-mini-0.8")
        ),
        .init(
            id: "OpenMOSS-Team/MOSS-TTS-Nano",
            displayName: "MOSS-TTS-Nano",
            summary: "Tiny 0.1B multilingual realtime TTS model from OpenMOSS with CPU-friendly streaming and 48 kHz stereo output.",
            supportStage: .planned,
            supportedLanguages: [.chinese, .english, .german, .spanish, .french, .japanese, .italian, .hungarian, .korean, .russian, .persian, .arabic, .polish, .portuguese, .czech, .danish, .swedish, .greek, .turkish],
            runtimeNotes: "Tracked for future support. TTSMLX cannot load MOSS-TTS-Nano yet because the underlying MLXAudioTTS runtime does not currently ship a MOSS TTS loader.",
            modelURL: URL(string: "https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano"),
            projectURL: URL(string: "https://github.com/OpenMOSS/MOSS-TTS-Nano")
        )
    ]

    public static let supportedModels: [TTSModelDescriptor] = modelCatalog.compactMap { entry in
        guard entry.supportStage == .validated else { return nil }
        return entry.descriptor
    }

    public static let validatedModels: [TTSModelCatalogEntry] = modelCatalog.filter { $0.supportStage == .validated }
    public static let implementedModels: [TTSModelCatalogEntry] = modelCatalog.filter { $0.supportStage == .implemented }
    public static let plannedModels: [TTSModelCatalogEntry] = modelCatalog.filter { $0.supportStage == .planned }

    public static let defaultModels: [TTSModelDescriptor] = supportedModels
}

private extension TTSMLX {
    static func validatedEntry(
        descriptor: TTSModelDescriptor,
        modelURL: URL?
    ) -> TTSModelCatalogEntry {
        TTSModelCatalogEntry(
            id: descriptor.id,
            displayName: descriptor.displayName,
            summary: descriptor.summary ?? descriptor.displayName,
            supportStage: .validated,
            supportedLanguages: descriptor.supportedLanguages,
            runtimeNotes: "Validated against the current TTSMLX wrapper and local MLXAudioTTS runtime.",
            modelURL: modelURL,
            descriptor: descriptor
        )
    }
}
