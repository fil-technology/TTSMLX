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
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 400,
                    minimumDeviceClass: .iPhone
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
                    defaultGenerationProfile: .fast,
                    // Pocket TTS peaks ~600MB resident during generation. That
                    // fits comfortably on modern iPhones (6–8GB RAM) so the
                    // `physicalMemoryMB` check is the right gate; the previous
                    // hard `minimumDeviceClass: .iPad` was overly conservative
                    // and regressed iPhone users who ran Pocket TTS fine in 0.3.
                    peakMemoryMB: 600,
                    minimumDeviceClass: .iPhone
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/pocket-tts"),
                files: [
                    "config.json",
                    "README.md",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "model.safetensors",
                    "embeddings/alba.safetensors",
                    "embeddings/azelma.safetensors",
                    "embeddings/cosette.safetensors",
                    "embeddings/eponine.safetensors",
                    "embeddings/fantine.safetensors",
                    "embeddings/javert.safetensors",
                    "embeddings/jean.safetensors",
                    "embeddings/marius.safetensors"
                ]
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
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 220,
                    minimumDeviceClass: .iPhone
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-80M-bf16"),
                files: [
                    "config.json",
                    "README.md",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "model.safetensors",
                    "model.safetensors.index.json"
                ]
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
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 500,
                    minimumDeviceClass: .iPhone
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
                    defaultGenerationProfile: .highQuality,
                    // 3B params in bf16 → ~6GB resident peak.
                    //
                    // `.mac` gate is intentional and NOT redundant with
                    // `peakMemoryMB`: on an 8GB iPhone or iPad, 6GB resident
                    // leaves ~1GB headroom for the OS + app + audio buffers,
                    // which iOS will jetsam-kill under background memory
                    // pressure even though `physicalMemoryMB` nominally fits.
                    // Lift this gate only after empirical iOS-side validation
                    // shows the app survives a full chapter at peak.
                    peakMemoryMB: 6_000,
                    minimumDeviceClass: .mac
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
                    defaultGenerationProfile: .highQuality,
                    // Qwen3-TTS 0.6B at 8-bit peaks ~800MB resident. That fits
                    // comfortably on any modern iPhone (6–8GB RAM); the
                    // `physicalMemoryMB` check is the right gate. The previous
                    // hard `minimumDeviceClass: .iPad` had no documented
                    // non-memory reason and inherited the same conservative
                    // paranoia that regressed Pocket TTS for iPhone users.
                    peakMemoryMB: 800,
                    minimumDeviceClass: .iPhone
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

    /// Pick the most capable validated model that fits the device profile.
    ///
    /// "Most capable" is approximated by ranking on `defaultGenerationProfile`
    /// (`highQuality` > `balanced` > `fast`) and then by `peakMemoryMB`
    /// (larger model wins as a tiebreaker, since it fit). Returns `nil` only
    /// if the catalog is empty.
    public static func recommendedModel(for profile: TTSDeviceProfile) -> TTSModelDescriptor? {
        let candidates = supportedModels.filter { $0.isSupported(on: profile) }
        let pool = candidates.isEmpty ? supportedModels : candidates

        let qualityRank: (TTSGenerationProfile) -> Int = { profile in
            switch profile {
            case .fast: return 0
            case .balanced: return 1
            case .highQuality: return 2
            }
        }

        return pool.max { a, b in
            let qa = qualityRank(a.capabilities.defaultGenerationProfile)
            let qb = qualityRank(b.capabilities.defaultGenerationProfile)
            if qa != qb { return qa < qb }
            return (a.capabilities.peakMemoryMB ?? 0) < (b.capabilities.peakMemoryMB ?? 0)
        }
    }

#if canImport(AVFoundation)
    /// One-call author-time helper: bake a narration bundle without
    /// constructing a ``TTSSpeechSynthesizer`` and without picking a model.
    /// Uses ``recommendedModel(for:)`` against the current device, then
    /// delegates to
    /// ``TTSSpeechSynthesizer/prepareNarration(_:using:options:into:chunker:progressHandler:)``.
    ///
    /// Intended for build scripts and dev panels that only want a one-liner
    /// to produce an onboarding bundle. Callers that need to pin a specific
    /// model (or share a single synthesizer with the live playback path)
    /// should still use the synthesizer-instance API.
    ///
    /// Throws ``TTSError/unsupportedModel(_:)`` when the device has no
    /// validated model that fits (extremely unlikely — even a 1GB device
    /// will fit Soprano at 220MB peak).
    public static func bake(
        _ text: String,
        voice: TTSVoice? = nil,
        options: TTSSynthesisOptions = .init(),
        into bundleURL: URL,
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSPreparedNarration {
        let profile = TTSDeviceProfile.current
        guard let model = recommendedModel(for: profile) else {
            throw TTSError.unsupportedModel("No validated model fits the current device for bake().")
        }
        var bakeOptions = options
        if let voice { bakeOptions.voice = voice }
        let synthesizer = TTSSpeechSynthesizer()
        return try await synthesizer.prepareNarration(
            text,
            using: model,
            options: bakeOptions,
            into: bundleURL,
            chunker: chunker,
            progressHandler: progressHandler
        )
    }
#endif
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
