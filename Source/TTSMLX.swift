import Foundation

public enum TTSMLX {
    public static let defaultModels: [TTSModelDescriptor] = [
        .init(
            id: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit",
            displayName: "Marvis",
            summary: "Balanced default model.",
            supportedLanguages: [.english],
            suggestedVoices: []
        ),
        .init(
            id: "mlx-community/pocket-tts",
            displayName: "Pocket TTS",
            summary: "Small and fast.",
            supportedLanguages: [.english],
            suggestedVoices: [.alba, .marius]
        ),
        .init(
            id: "mlx-community/Soprano-80M-bf16",
            displayName: "Soprano",
            summary: "Compact MLX voice model.",
            supportedLanguages: [.english],
            suggestedVoices: []
        ),
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
            displayName: "Qwen3 TTS",
            summary: "Higher quality multilingual model.",
            supportedLanguages: [.english, .spanish, .french, .german, .italian, .portuguese, .dutch, .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi],
            suggestedVoices: [.enUS1]
        )
    ]
}
