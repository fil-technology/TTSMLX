import Foundation

public enum TTSMLX {
    /// Languages the Qwen3-TTS family advertises. Shared by every Qwen3-TTS
    /// catalog entry so the list stays consistent across size/quant variants.
    /// Built-in speakers of the Qwen3-TTS CustomVoice builds (config
    /// `talker_config.spk_id`). Pass one as the voice, optionally followed by
    /// a style instruction: `"ryan"` or `"ryan, speak slowly and warmly"`.
    /// `eric` and `dylan` speak Sichuan / Beijing dialect respectively.
    static let qwen3CustomVoiceSpeakers: [TTSVoice] = [
        TTSVoice("ryan", displayName: "Ryan", language: .english, gender: .male, summary: "Energetic, conversational"),
        TTSVoice("serena", displayName: "Serena", language: .chinese, gender: .female, summary: "Warm, gentle"),
        TTSVoice("vivian", displayName: "Vivian", language: .chinese, gender: .female, summary: "Bright, young"),
        TTSVoice("aiden", displayName: "Aiden", language: .english, gender: .male, summary: "Sunny American"),
        TTSVoice("ono_anna", displayName: "Ono Anna", language: .japanese, gender: .female, summary: "Playful"),
        TTSVoice("sohee", displayName: "Sohee", language: .korean, gender: .female, summary: "Warm, emotional"),
        TTSVoice("uncle_fu", displayName: "Uncle Fu", language: .chinese, gender: .male, summary: "Seasoned, resonant"),
        TTSVoice("eric", displayName: "Eric", language: .chinese, gender: .male, summary: "Sichuan dialect"),
        TTSVoice("dylan", displayName: "Dylan", language: .chinese, gender: .male, summary: "Beijing dialect"),
    ]

    static let orpheusVoices: [TTSVoice] = [
        TTSVoice("tara", displayName: "Tara", language: .english, gender: .female, summary: "Default, conversational"),
        TTSVoice("leah", displayName: "Leah", language: .english, gender: .female),
        TTSVoice("jess", displayName: "Jess", language: .english, gender: .female),
        TTSVoice("leo", displayName: "Leo", language: .english, gender: .male),
        TTSVoice("dan", displayName: "Dan", language: .english, gender: .male),
        TTSVoice("mia", displayName: "Mia", language: .english, gender: .female),
        TTSVoice("zac", displayName: "Zac", language: .english, gender: .male),
        TTSVoice("zoe", displayName: "Zoe", language: .english, gender: .female),
    ]

    /// Orpheus renders these inline tags (`<laugh>` and friends).
    static let orpheusEventTags: [TTSEventTag: String] = [
        .laugh: "<laugh>", .chuckle: "<chuckle>", .sigh: "<sigh>", .cough: "<cough>",
        .sniffle: "<sniffle>", .groan: "<groan>", .yawn: "<yawn>", .gasp: "<gasp>",
    ]

    static let pocketTTSVoices: [TTSVoice] = [
        TTSVoice("alba", displayName: "Alba", language: .english), TTSVoice("marius", displayName: "Marius", language: .english),
        TTSVoice("javert", displayName: "Javert", language: .english), TTSVoice("jean", displayName: "Jean", language: .english),
    ]

    static let mingVoices: [TTSVoice] = [
        TTSVoice("UK_George", displayName: "George", language: .english, gender: .male, summary: "British. Audiobooks and formal announcements"),
        TTSVoice("US_Emma", displayName: "Emma", language: .english, gender: .female, summary: "American. Assistants, narration, product dialogue"),
        TTSVoice("UK_Charlotte", displayName: "Charlotte", language: .english, gender: .female, summary: "British. Audiobooks, measured narration"),
        TTSVoice("灵小柔", displayName: "灵小柔", language: .chinese, gender: .female, summary: "Clear, sweet, patient. Customer service"),
        TTSVoice("灵楷", displayName: "灵楷", language: .chinese, gender: .male, summary: "Warm, resonant. Radio, documentary, audiobooks"),
        TTSVoice("灵小萌", displayName: "灵小萌", language: .chinese, gender: .female, summary: "Bright, brisk. Audiobook narration"),
        TTSVoice("灵阅川", displayName: "灵阅川", language: .chinese, gender: .male, summary: "Deep, composed documentary narrator"),
        TTSVoice("灵妩月", displayName: "灵妩月", language: .chinese, gender: .female, summary: "Gentle, thoughtful companion"),
    ]

    /// Ming-3.0 paralinguistic tags (case-sensitive, brackets included).
    static let mingEventTags: [TTSEventTag: String] = [
        .laugh: "[Laughter]", .sigh: "[Sigh]", .cough: "[Cough]", .breath: "[Breathing]", .hesitation: "[Uhm]",
    ]

    /// Chatterbox Turbo's documented event tags.
    static let chatterboxTurboEventTags: [TTSEventTag: String] = [
        .laugh: "[laugh]", .chuckle: "[chuckle]", .sigh: "[sigh]", .cough: "[cough]", .gasp: "[gasp]", .groan: "[groan]",
    ]

    /// The regular (multilingual) Chatterbox weights react to a smaller set.
    static let chatterboxEventTags: [TTSEventTag: String] = [.laugh: "[laughter]", .sigh: "[sigh]"]

    static let qwen3TTSLanguages: [TTSLanguage] = [
        .english, .spanish, .french, .german, .italian, .portuguese, .dutch,
        .polish, .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi
    ]

    /// Languages MOSS-TTS-Nano advertises (19 of the 20 it lists map onto
    /// existing ``TTSLanguage`` constants).
    static let mossTTSNanoLanguages: [TTSLanguage] = [
        .chinese, .english, .german, .spanish, .french, .japanese, .italian,
        .hungarian, .korean, .russian, .persian, .arabic, .polish,
        .portuguese, .czech, .danish, .swedish, .greek, .turkish
    ]

    /// MOSS has no speaker embeddings: these name pre-encoded reference clips
    /// bundled with the runtime fork, not voices baked into the checkpoint.
    /// `en_news` (a newsreader read) is the runtime's default.
    static let mossTTSNanoVoices: [TTSVoice] = [
        TTSVoice("en_news", displayName: "News", language: .english, summary: "Newsreader"),
        TTSVoice("en_2", language: .english), TTSVoice("en_3", language: .english), TTSVoice("en_4", language: .english),
        TTSVoice("en_6", language: .english), TTSVoice("en_7", language: .english), TTSVoice("en_8", language: .english),
    ]

    /// Kokoro's 54 preset voices, named `<lang><gender>_<name>`: `a`merican /
    /// `b`ritish English, `e`spañol, `f`rançais, `h`indi, `i`taliano, `j`apanese,
    /// `p`ortuguês, `z`hongwen; `f`emale / `m`ale. The language is inferred from
    /// the prefix, so a Spanish voice reads Spanish text without a language option.
    static let kokoroVoiceNames: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole",
        "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir",
        "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "em_santa", "ff_siwis", "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
        "pf_dora", "pm_alex", "pm_santa",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang"
    ]

    /// The 23 languages of the Chatterbox multilingual checkpoint, as `[xx]` tags
    /// in its tokenizer: ar da de el en es fi fr he hi it ja ko ms nl no pl pt
    /// ru sv sw tr zh.
    /// Ming-3.0-TTS target languages. Chinese and English need no language
    /// option; the other five are passed to the runtime as a target-language
    /// line in the prompt (`TTSSynthesisOptions.language`).
    static let mingLanguages: [TTSLanguage] = [.chinese, .english, .japanese, .korean, .german, .french, .spanish]

    static let chatterboxLanguages: [TTSLanguage] = [
        .english, .french, .german, .spanish, .italian, .portuguese, .dutch, .polish,
        .turkish, .russian, .japanese, .korean, .chinese, .arabic, .hindi, .danish,
        .swedish, .greek, "Finnish", "Hebrew", "Malay", "Norwegian", "Swahili"
    ]

    static let kokoroLanguages: [TTSLanguage] = [
        .english, .spanish, .french, .hindi, .italian, .japanese, .portuguese, .chinese
    ]

    static let kokoroVoices: [TTSVoice] = kokoroVoiceNames.map(kokoroVoice)

    static let kokoroVoiceLanguages: [Character: (TTSLanguage, String)] = [
        "a": (.english, "American"), "b": (.english, "British"), "e": (.spanish, "Spanish"), "f": (.french, "French"),
        "h": (.hindi, "Hindi"), "i": (.italian, "Italian"), "j": (.japanese, "Japanese"), "p": (.portuguese, "Brazilian Portuguese"),
        "z": (.chinese, "Mandarin"),
    ]

    /// Decodes Kokoro's `<lang><gender>_<name>` convention into voice metadata.
    static func kokoroVoice(_ name: String) -> TTSVoice {
        let parts = name.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let prefix = parts.first, prefix.count == 2 else { return TTSVoice(name) }
        let language = kokoroVoiceLanguages[prefix.first!]
        let gender: TTSVoiceGender? = prefix.last == "f" ? .female : prefix.last == "m" ? .male : nil
        return TTSVoice(name, displayName: parts[1].capitalized, language: language?.0, gender: gender, summary: language?.1)
    }

    /// The checkpoint plus every voice embedding, so a background download
    /// leaves nothing for the first synthesis to fetch.
    static let kokoroFiles: [String] = ["config.json", "kokoro-v1_0.safetensors"]
        + kokoroVoiceNames.map { "voices/\($0).safetensors" }

    /// MeloTTS English accents (the checkpoint's speaker ids).
    static let meloTTSVoices: [TTSVoice] = [
        TTSVoice("EN-US", displayName: "American", language: .english), TTSVoice("EN-BR", displayName: "British", language: .english),
        TTSVoice("EN_INDIA", displayName: "Indian", language: .english), TTSVoice("EN-AU", displayName: "Australian", language: .english),
        TTSVoice("EN-Default", displayName: "Default", language: .english),
    ]

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
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
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
                suggestedVoices: pocketTTSVoices,
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
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
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
                    minimumDeviceClass: .iPhone,
                    sampleRate: 32_000
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
                suggestedVoices: [TTSVoice("en-us-1", displayName: "Default", language: .english)],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 500,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
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
                suggestedVoices: orpheusVoices,
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
                    minimumDeviceClass: .mac,
                    eventTags: orpheusEventTags,
                    sampleRate: 24_000
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/orpheus-3b-0.1-ft-bf16")
        ),
        validatedEntry(
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                displayName: "Qwen3 TTS",
                summary: "Higher quality multilingual model.",
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: [TTSVoice("en-us-1", displayName: "Default", language: .english)],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .highQuality,
                    // Qwen3-TTS 0.6B at 8-bit peaks ~800MB resident. That fits
                    // comfortably on any modern iPhone (6–8GB RAM); the
                    // `physicalMemoryMB` check is the right gate. The previous
                    // hard `minimumDeviceClass: .iPad` had no documented
                    // non-memory reason and inherited the same conservative
                    // paranoia that regressed Pocket TTS for iPhone users.
                    peakMemoryMB: 800,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
                )
            ),
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")
        ),
        // ── Additional multilingual / fast variants ───────────────────────
        // All of the following route to a loader the backend already ships
        // (verified via config.json `model_type`: qwen3_tts → Qwen3TTSModel,
        // soprano → SopranoModel), so they generate end to end. They are staged
        // `.implemented` rather than `.validated` only because they have not yet
        // been run + memory-profiled on a physical iPhone in this repo; the
        // `peakMemoryMB` values below are conservative estimates, not measured
        // peaks. Promote to `.validated` (move into `validatedEntry`) after an
        // on-device pass confirms audio + resident peak. `.implemented` entries
        // carry a full descriptor, so apps can select and synthesize them today
        // — they are simply excluded from `supportedModels` / `recommendedModel`
        // defaults until validated.
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit",
            displayName: "Qwen3 TTS 0.6B (4-bit)",
            summary: "Smaller-footprint 4-bit build of the multilingual Qwen3 TTS 0.6B — lower download/RAM than the 8-bit default.",
            supportStage: .implemented,
            supportedLanguages: Self.qwen3TTSLanguages,
            runtimeNotes: "Routes to the qwen3_tts loader (same architecture as the validated 0.6B-8bit). Pending on-device validation + memory profiling.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit"),
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit",
                displayName: "Qwen3 TTS 0.6B (4-bit)",
                summary: "Smaller-footprint multilingual Qwen3 TTS.",
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: [TTSVoice("en-us-1", displayName: "Default", language: .english)],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 700,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
                )
            )
        ),
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit",
            displayName: "Qwen3 TTS 1.7B",
            summary: "Higher-quality multilingual Qwen3 TTS (1.7B) at 4-bit — better prosody than 0.6B; best on 6GB+ iPhones.",
            supportStage: .implemented,
            supportedLanguages: Self.qwen3TTSLanguages,
            runtimeNotes: "Routes to the qwen3_tts loader. ~2.3GB download. Pending on-device validation + memory profiling; estimated resident peak is conservative.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"),
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit",
                displayName: "Qwen3 TTS 1.7B",
                summary: "Higher-quality multilingual Qwen3 TTS.",
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: [TTSVoice("en-us-1", displayName: "Default", language: .english)],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .highQuality,
                    // Estimate only (not measured). 1.7B @ 4-bit ≈ 0.9GB weights
                    // plus codec/speaker-encoder/tokenizer + activations.
                    peakMemoryMB: 2_800,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
                )
            )
        ),
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
            displayName: "Qwen3 TTS 1.7B (Custom Voice)",
            summary: "Multilingual Qwen3 TTS 1.7B with custom-voice / reference-audio conditioning for voice design and cloning.",
            supportStage: .implemented,
            supportedLanguages: Self.qwen3TTSLanguages,
            runtimeNotes: "Routes to the qwen3_tts loader (CustomVoice build, runtime 0.1.8-tts.3+; earlier runtimes failed to decode its config). Pick a built-in speaker with the voice option (\"serena\", or \"serena, whisper softly\"). Reference-audio wiring is pending validation.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"),
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
                displayName: "Qwen3 TTS 1.7B (Custom Voice)",
                summary: "Multilingual Qwen3 TTS with built-in speakers.",
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: Self.qwen3CustomVoiceSpeakers,
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: true,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .highQuality,
                    peakMemoryMB: 2_800,
                    minimumDeviceClass: .iPhone,
                    features: [.instruction, .emotion, .speed],
                    sampleRate: 24_000
                )
            )
        ),
        .init(
            id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
            displayName: "Qwen3 TTS 0.6B (Custom Voice)",
            summary: "Multilingual Qwen3 TTS 0.6B CustomVoice build — the variant on the public tts-bench leaderboard; lighter than the 1.7B.",
            supportStage: .implemented,
            supportedLanguages: Self.qwen3TTSLanguages,
            runtimeNotes: "Routes to the qwen3_tts loader (CustomVoice build, runtime 0.1.8-tts.3+). Pick a built-in speaker with the voice option (\"serena\", or \"serena, whisper softly\" to add a style instruction). Loads and synthesizes end to end on macOS; this 4-bit build occasionally emits a near-silent chunk that runs to the token cap, so prefer an 8-bit build when one is published. Pending on-device validation.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit"),
            descriptor: .init(
                id: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
                displayName: "Qwen3 TTS 0.6B (Custom Voice)",
                summary: "Multilingual Qwen3 TTS, custom-voice build.",
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: Self.qwen3CustomVoiceSpeakers,
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 1_200,
                    minimumDeviceClass: .iPhone,
                    features: [.instruction, .emotion, .speed],
                    sampleRate: 24_000
                )
            )
        ),
        .init(
            id: "mlx-community/Soprano-80M-4bit",
            displayName: "Soprano (4-bit)",
            summary: "Tiny 4-bit Soprano (~60MB) — fastest start and lowest memory; ideal for snappy English reading on any iPhone.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the soprano loader (same architecture as the validated Soprano-80M-bf16, 4-bit quantized). Pending on-device validation.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-80M-4bit"),
            descriptor: .init(
                id: "mlx-community/Soprano-80M-4bit",
                displayName: "Soprano (4-bit)",
                summary: "Tiny, fast English voice model.",
                supportedLanguages: [.english],
                suggestedVoices: [],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .fast,
                    peakMemoryMB: 150,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 32_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-80M-4bit"),
                files: [
                    "config.json",
                    "README.md",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "model.safetensors",
                    "model.safetensors.index.json"
                ]
            )
        ),
        .init(
            id: "mlx-community/Soprano-1.1-80M-bf16",
            displayName: "Soprano 1.1",
            summary: "Soprano 1.1 (80M, bf16) — the current Soprano release; rated above the 1.0 weights on public listening tests.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the soprano loader (same architecture as the validated Soprano-80M-bf16, newer weights). Loads and synthesizes end to end on macOS; pending on-device validation.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-1.1-80M-bf16"),
            descriptor: .init(
                id: "mlx-community/Soprano-1.1-80M-bf16",
                displayName: "Soprano 1.1",
                summary: "Compact English voice model, 1.1 weights.",
                supportedLanguages: [.english],
                suggestedVoices: [],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 220,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 32_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/Soprano-1.1-80M-bf16"),
                files: [
                    "config.json",
                    "generation_config.json",
                    "README.md",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "model.safetensors",
                    "model.safetensors.index.json"
                ]
            )
        ),
        .init(
            id: "mlx-community/Kokoro-82M-bf16",
            displayName: "Kokoro 82M",
            summary: "Kokoro (82M, bf16): the top-rated open model on the tts-bench Elo board. Non-autoregressive StyleTTS2 descendant with 54 preset voices across 8 languages at 24 kHz.",
            supportStage: .implemented,
            supportedLanguages: Self.kokoroLanguages,
            runtimeNotes: """
                Routes to the kokoro loader (runtime 0.1.8-tts.3+). Pick a voice by name \
                (`af_heart` is the default); the language follows the voice prefix. The \
                English G2P weights (`beshkenadze/kitten-tts-g2p`, 9 MB) are fetched at first \
                load and prefetched by the background downloader; other languages fetch their \
                IPA lexicon on first use. Loads and synthesizes end to end on macOS, 1.5 s to \
                first audio and roughly realtime in a debug build. peakMemoryMB is an \
                estimate from the weight size, not a measurement; pending on-device validation.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16"),
            projectURL: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M"),
            descriptor: .init(
                id: "mlx-community/Kokoro-82M-bf16",
                displayName: "Kokoro 82M",
                summary: "54 preset voices, 8 languages, fast.",
                supportedLanguages: Self.kokoroLanguages,
                suggestedVoices: Self.kokoroVoices,
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.kokoroLanguages,
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 500,
                    minimumDeviceClass: .iPhone,
                    features: [.speed],
                    sampleRate: 24_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16"),
                files: Self.kokoroFiles
            )
        ),
        .init(
            id: "gradium/phonon-31m-en",
            displayName: "Phonon 31M",
            summary: "Gradium Phonon (31M): a Pocket-TTS derivative with speaker and duration conditioning. English, 24 kHz, streams.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: """
                Routes to the pocket_tts loader (runtime 0.1.8-tts.3+, which also maps the \
                checkpoint's `gradium_phonon_tts` model type). Ships one bundled voice \
                (`default-voice.safetensors`); other voices are `.safetensors` embeddings passed \
                as the voice option by path or `hf://owner/repo/file.safetensors`. Loads and \
                synthesizes end to end on macOS, 0.8 s to first audio. peakMemoryMB is an \
                estimate; pending on-device validation. The 40M variants are gated and \
                CC-BY-NC.
                """,
            modelURL: URL(string: "https://huggingface.co/gradium/phonon-31m-en"),
            projectURL: URL(string: "https://huggingface.co/gradium"),
            descriptor: .init(
                id: "gradium/phonon-31m-en",
                displayName: "Phonon 31M",
                summary: "Tiny English model with a bundled default voice.",
                supportedLanguages: [.english],
                suggestedVoices: ["default"],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 300,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 24_000
                ),
                modelURL: URL(string: "https://huggingface.co/gradium/phonon-31m-en"),
                files: [
                    "config.json",
                    "generation_config.json",
                    "processor_config.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "default-voice.safetensors",
                    "model.safetensors"
                ]
            )
        ),
        .init(
            id: "mlx-community/MeloTTS-English-MLX",
            displayName: "MeloTTS English",
            summary: "MeloTTS English: VITS with BERT prosody features and a HiFi-GAN vocoder. Five English accents at 44.1 kHz; MIT licensed.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: """
                Routes to the melotts loader (runtime 0.1.8-tts.3+). The voice option picks an \
                accent (`EN-US`, `EN-BR`, `EN_INDIA`, `EN-AU`, `EN-Default`). English frontend \
                resources (g2p_en checkpoint, CMU dictionary, NLTK tagger) are fetched from \
                GitHub at first load, outside the Hugging Face cache, so the first run needs \
                network access even after the model is downloaded. Input must fit 510 BERT \
                wordpieces per chunk, which the text chunker keeps well under. Loads and \
                synthesizes end to end on macOS, 0.5 s to first audio. peakMemoryMB is an \
                estimate (the BERT weights are float32); pending on-device validation.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/MeloTTS-English-MLX"),
            projectURL: URL(string: "https://github.com/myshell-ai/MeloTTS"),
            descriptor: .init(
                id: "mlx-community/MeloTTS-English-MLX",
                displayName: "MeloTTS English",
                summary: "Five English accents at 44.1 kHz.",
                supportedLanguages: [.english],
                suggestedVoices: Self.meloTTSVoices,
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 1_000,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 44_100
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/MeloTTS-English-MLX"),
                files: ["config.json", "model.safetensors", "bert_weights.npz"]
            )
        ),
        .init(
            id: "mlx-community/kitten-tts-mini-0.8",
            displayName: "Kitten TTS",
            summary: "Compact Kitten TTS family model that the runtime can route to, but the published MLX checkpoint cannot be loaded yet.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Discovery-only. The kitten_tts loader (runtime 0.1.8-tts.3) requires `voices.safetensors`, while mlx-community/kitten-tts-mini-0.8 ships only `voices.npz`, which the loader rejects by design; load fails with \"No voices file found\". Needs a converted voices file in the repo or a conversion step at download time.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/kitten-tts-mini-0.8")
        ),
        .init(
            id: "mlx-community/MOSS-TTS-Nano-100M",
            displayName: "MOSS TTS Nano",
            summary: "Tiny 0.1B multilingual model from OpenMOSS that outputs 48 kHz audio. Voice-cloning only — it has no speaker embeddings, so it always reads in the voice of a reference clip: one of the bundled voices, or your own audio.",
            supportStage: .validated,
            supportedLanguages: Self.mossTTSNanoLanguages,
            runtimeNotes: """
                Routes to upstream's moss_tts_nano loader (runtime 0.1.8-tts.3+: backbone, \
                MOSS-Audio-Tokenizer-Nano decoder and encoder). The fork adds the bundled \
                voices, a codebook dial the generation profiles drive (fast 8, balanced 12, \
                highQuality all 16) and sentence-by-sentence decoding, because the codec's \
                deepest stage attends over frames x 32 positions and a whole-passage decode is \
                quadratic in length. Pass `referenceAudio` (resampled to 48 kHz) to clone a \
                voice, or a bundled voice name; with neither it reads as `en_news`. Validated \
                on an iPhone 17 (iOS 27.2, debug build, Reader path over 60-word passages): \
                first audio 2.4-3.1 s warm (18 s cold, including the load), 1.3x realtime, \
                MLX peak 1.0-1.2 GB, process footprint up to 1.2 GB, no end-of-audio miss in \
                42 chunks; the model landed in Application Support. On an M-series Mac the \
                same run is 0.85x realtime with first audio in 4-6 s and MLX peak 1.6 GB. \
                Known behaviour: at the model's own sampling defaults it can miss end-of-audio \
                and fill the 375-frame budget with silence (seen once in five runs on an \
                earlier port, not in 84 chunks here); the text chunker bounds the damage to one \
                chunk.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/MOSS-TTS-Nano-100M"),
            projectURL: URL(string: "https://github.com/OpenMOSS/MOSS-TTS-Nano"),
            descriptor: .init(
                id: "mlx-community/MOSS-TTS-Nano-100M",
                displayName: "MOSS TTS Nano",
                summary: "Multilingual 48 kHz stereo voice cloning.",
                supportedLanguages: Self.mossTTSNanoLanguages,
                suggestedVoices: Self.mossTTSNanoVoices,
                capabilities: .init(
                    isRuntimeSupported: true,
                    // Upstream's port carries the codec encoder, so a caller's
                    // clip is encoded at generation time; the bundled voices
                    // are pre-encoded prompt codes and skip that step.
                    supportsReferenceAudio: true,
                    supportsLanguageList: true,
                    supportedLanguages: Self.mossTTSNanoLanguages,
                    defaultGenerationProfile: .balanced,
                    // Measured on macOS via MLX.GPU.peakMemory across a
                    // ~17s generation at the default chunk budget (1.36-1.53GB
                    // observed). Rounded up; re-measure on device.
                    peakMemoryMB: 1_300,
                    minimumDeviceClass: .iPhone,
                    sampleRate: 48_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/MOSS-TTS-Nano-100M")
            )
        ),

        .init(
            id: "mlx-community/chatterbox-turbo-4bit",
            displayName: "Chatterbox Turbo 4-bit",
            summary: "Resemble AI Chatterbox Turbo (~350M GPT-2 T3 over S3 tokens, one-step distilled S3Gen): #3 on the tts-bench board. English, 24 kHz, bundled default voice, cloning from a clip, `[laugh]`/`[chuckle]`/`[sigh]`-style event tags. MIT upstream.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: """
                Routes to the chatterbox loader (runtime 0.1.8-tts.3+). The loader fetches the \
                companion `mlx-community/S3TokenizerV2` repo (495 MB) at first load on top of \
                the 417 MB checkpoint; `TTSBackgroundModelDownloader` plans both. Voice is \
                either the bundled `conds.safetensors` default (`default`) or a reference clip \
                through `TTSSynthesisOptions.referenceAudio` (any sample rate; resampled to \
                16 kHz, first 10-15 s used). Event tags such as `[laugh]`, `[chuckle]`, \
                `[sigh]`, `[cough]`, `[gasp]` go inline in the text. Loads and synthesizes end \
                to end on macOS with both the default voice and a 48 kHz reference clip. \
                Latency: the runtime generates a chunk whole (no token-level streaming), and the \
                T3 stage runs about 12 tokens/s in a debug build (25 tokens = 1 s of audio), so \
                the first audio of a chunk arrives after roughly twice the chunk's duration; \
                S3Gen and the vocoder add about 1 s warm. Memory on macOS: MLX peak active \
                2.5 GB for a two-sentence chunk, but the MLX buffer cache grows to 7 GB over a \
                run unless the app caps it (`MLX.Memory.cacheLimit`; 512 MB held the \
                process footprint at 3.2 GB) or calls `releaseRuntimeBuffers()` between \
                utterances. Pending on-device validation. fp16 (3 GB) and 8-bit (0.7 GB) \
                checkpoints exist but have not been run here.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-turbo-4bit"),
            projectURL: URL(string: "https://github.com/resemble-ai/chatterbox"),
            descriptor: .init(
                id: "mlx-community/chatterbox-turbo-4bit",
                displayName: "Chatterbox Turbo 4-bit",
                summary: "English model with a bundled default voice, reference-clip cloning and inline event tags.",
                supportedLanguages: [.english],
                suggestedVoices: ["default"],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: true,
                    supportsLanguageList: true,
                    supportedLanguages: [.english],
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 2_500,
                    minimumDeviceClass: .iPhone,
                    eventTags: chatterboxTurboEventTags,
                    sampleRate: 24_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-turbo-4bit"),
                files: [
                    "config.json",
                    "conds.safetensors",
                    "model.safetensors",
                    "model.safetensors.index.json",
                    "added_tokens.json",
                    "merges.txt",
                    "special_tokens_map.json",
                    "tokenizer_config.json",
                    "vocab.json"
                ]
            )
        ),

        .init(
            id: "mlx-community/chatterbox-4bit",
            displayName: "Chatterbox 4-bit",
            summary: "Resemble AI Chatterbox (~0.5B Llama T3 over S3 tokens, 10-step flow-matching S3Gen): #2 on the tts-bench board. Multilingual weights (23 languages), 24 kHz, bundled default voice, cloning from a clip, inline `[laughter]`/`[sigh]`-style tags. MIT upstream.",
            supportStage: .implemented,
            supportedLanguages: chatterboxLanguages,
            runtimeNotes: """
                Routes to the chatterbox loader (runtime 0.1.8-tts.4+, which adds the \
                reference text pipeline for the regular model: punctuation normalisation, \
                lowercase + NFKD for the multilingual vocabulary, `[SPACE]` word boundaries, \
                and a leading `[xx]` language tag taken from `TTSSynthesisOptions.language`; \
                upstream alone drops every space and ignores the language). Companion repo \
                `mlx-community/S3TokenizerV2` (495 MB) on top of the 612 MB checkpoint. \
                Voice: bundled `conds.safetensors` default (`default`) or a reference clip \
                through `referenceAudio`. Chinese, Japanese, Hebrew, Korean and Russian skip \
                the reference's script-specific rewrites (Cangjie, kana, niqqud, stress \
                marks), so expect lower quality there. Loads and synthesizes end to end on \
                macOS in English, French and German with the default voice and in English with \
                a 48 kHz reference clip. Generation is whole-chunk; T3 runs about 40 tokens/s \
                in a debug build with the MLX cache capped (25 tokens = 1 s of audio) and \
                S3Gen's 10 steps add about 2.5 s per chunk. Memory on macOS: MLX peak active \
                2.5 GB (3.0 GB with a reference clip); the MLX buffer cache grows to 14 GB per \
                run unless capped (`MLX.Memory.cacheLimit`; 512 MB held the process at 3.3 GB). \
                Pending on-device validation. fp16 (2.6 GB) and 8-bit (0.9 GB) siblings exist; \
                the `Chatterbox-TTS-*` repos are the older English-only v1 weights without a \
                bundled voice.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-4bit"),
            projectURL: URL(string: "https://github.com/resemble-ai/chatterbox"),
            descriptor: .init(
                id: "mlx-community/chatterbox-4bit",
                displayName: "Chatterbox 4-bit",
                summary: "Multilingual model with a bundled default voice, reference-clip cloning and inline event tags.",
                supportedLanguages: chatterboxLanguages,
                suggestedVoices: ["default"],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: true,
                    supportsLanguageList: true,
                    supportedLanguages: chatterboxLanguages,
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 3_000,
                    minimumDeviceClass: .iPhone,
                    features: [.emotion],
                    eventTags: chatterboxEventTags,
                    sampleRate: 24_000
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-4bit"),
                files: [
                    "config.json",
                    "conds.safetensors",
                    "model.safetensors",
                    "model.safetensors.index.json",
                    "tokenizer.json",
                    "Cangjie5_TC.json"
                ]
            )
        ),

        .init(
            id: "mlx-community/Ming-3.0-tts-0.5B-bf16",
            displayName: "Ming-3.0-TTS 0.5B",
            summary: "Ant Group Ming-3.0-TTS (Qwen2.5-0.5B + flow-matching DiT head over a 44.1 kHz audio VAE): #14 on the tts-bench board. 7 languages, built-in English and Chinese voices, cloning from a clip, voice design and delivery controls. MIT.",
            supportStage: .implemented,
            supportedLanguages: mingLanguages,
            runtimeNotes: """
                Routes to the dense (Ming) loader. The mlx-community checkpoint bundles its \
                CAM++ speaker encoder (`campplus.safetensors`), so nothing else is fetched; the \
                runtime lists `mlx-community/Step-Audio-2-token2wav` as a companion only for \
                checkpoints without it. Voices: `UK_George`, `US_Emma`, `UK_Charlotte` and the \
                Chinese voices (`灵小柔`, `灵楷`, …) through the voice option; with no voice the \
                model picks its own speaker. Cloning from a clip through `referenceAudio` \
                (resampled to 44.1 kHz; add `referenceText` to condition on the clip's words \
                too). Chinese and English need no language option; German, Spanish, French, \
                Japanese and Korean are passed as the prompt's target-language line from \
                `TTSSynthesisOptions.language`. Uniform controls: `instruction` (free-form \
                delivery or voice design; replaces the built-in voice), `emotion` and `speed` \
                (Ming's structured instruction) and the `TTSEventTag` markers (`[Laughter]`, \
                `[Sigh]`, `[Cough]`, `[Breathing]`, `[Uhm]`). Validated end to end on macOS: \
                built-in voices in English, French and Chinese, no voice, a 48 kHz reference \
                clip, emotion, a free-form instruction and event tags. Generation runs per text \
                fragment (about 24 words) and yields no audio before a fragment completes: \
                8-10 s of audio takes 25-50 s warm in a debug build (0.2-0.35x realtime), and a \
                streaming request delivers everything at the end. Memory on macOS: MLX peak \
                4.2 GB (active 2.85 GB); the buffer cache grows to 2 GB per run unless capped \
                (`MLX.Memory.cacheLimit`; 512 MB held the process at 4.6-4.9 GB). bf16 weights, \
                3 GB download; plan on an 8 GB device. Keep to one event tag per sentence: \
                two tags inside one ~24-word fragment made the model loop (27 s of audio for \
                a 20-word sentence), while the same tags in separate sentences behave. Pending \
                on-device validation.
                """,
            modelURL: URL(string: "https://huggingface.co/mlx-community/Ming-3.0-tts-0.5B-bf16"),
            projectURL: URL(string: "https://github.com/inclusionAI/Ming-3.0-tts"),
            descriptor: .init(
                id: "mlx-community/Ming-3.0-tts-0.5B-bf16",
                displayName: "Ming-3.0-TTS 0.5B",
                summary: "Multilingual 44.1 kHz model with built-in English and Chinese voices and reference-clip cloning.",
                supportedLanguages: mingLanguages,
                suggestedVoices: mingVoices,
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: true,
                    supportsLanguageList: true,
                    supportedLanguages: mingLanguages,
                    defaultGenerationProfile: .balanced,
                    // bf16 0.5B LLM + DiT + VAE: 2.85 GB active, 4.2 GB MLX peak on
                    // macOS. Fits 8 GB devices; the memory check keeps 4 GB ones out.
                    peakMemoryMB: 4_500,
                    minimumDeviceClass: .iPhone,
                    features: [.instruction, .emotion, .speed, .voiceDesign],
                    eventTags: mingEventTags,
                    sampleRate: 44_100
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/Ming-3.0-tts-0.5B-bf16"),
                files: [
                    "config.json",
                    "configuration.json",
                    "model.safetensors",
                    "model.safetensors.index.json",
                    "campplus.safetensors",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "vocab.json",
                    "merges.txt",
                    "added_tokens.json",
                    "special_tokens_map.json"
                ]
            )
        ),

        // MARK: Discovery-only entries. The 0.1.8-tts.3 runtime routes to every
        // family below, but none has been synthesized end to end through TTSMLX
        // yet, so they carry no descriptor: apps can list them, not select them.
        // Reasons are in runtimeNotes; see Docs/model-support.md for the full
        // leaderboard matrix.
        .init(
            id: "bosonai/higgs-tts-3-4b",
            displayName: "Higgs Audio v3 TTS",
            summary: "Boson AI Higgs Audio v3 (~4B): #4 on the board. 100+ languages, cloning, emotion and style tags, streaming. Research licence, non-commercial.",
            supportStage: .implemented,
            supportedLanguages: [.english, .chinese, .spanish, .french, .german, .japanese, .korean],
            runtimeNotes: "Routes to the higgs_audio_v3 loader. Listed for research use only: the weights forbid commercial use, and at ~8 GB bf16 with no mlx-community quantization yet they exceed what phones can hold.",
            modelURL: URL(string: "https://huggingface.co/bosonai/higgs-tts-3-4b"),
            projectURL: URL(string: "https://github.com/boson-ai/higgs-audio")
        ),
        .init(
            id: "mlx-community/OmniVoice",
            displayName: "OmniVoice",
            summary: "OmniVoice (~1B diffusion LM over Qwen3-0.6B with the Higgs v2 codec): #8 on the board. 600+ languages, cloning, voice design. Weights are CC-BY-NC.",
            supportStage: .implemented,
            supportedLanguages: [.english, .chinese, .spanish, .french, .german, .japanese],
            runtimeNotes: "Routes to the omnivoice loader (3.3 GB incl. the bundled audio tokenizer). Listed for research use only because the weights are non-commercial; not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/OmniVoice"),
            projectURL: URL(string: "https://github.com/k2-fsa/OmniVoice")
        ),
        .init(
            id: "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit",
            displayName: "Voxtral 4B TTS",
            summary: "Mistral Voxtral TTS (Ministral-3B backbone, 4-bit): #10 on the board. 9 languages, 20 preset voices, cloning, streaming. CC-BY-NC-4.0.",
            supportStage: .implemented,
            supportedLanguages: [.english, .french, .german, .spanish, .italian, .portuguese, .dutch, .hindi, .arabic],
            runtimeNotes: "Routes to the voxtral_tts loader (2.5 GB). Listed for research use only because the weights are non-commercial; not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Voxtral-4B-TTS-2603-mlx-4bit"),
            projectURL: URL(string: "https://huggingface.co/mistralai/Voxtral-4B-TTS-2603")
        ),
        .init(
            id: "mlx-community/LongCat-AudioDiT-1B-bf16",
            displayName: "LongCat-AudioDiT 1B",
            summary: "Meituan LongCat-AudioDiT (1.4B non-autoregressive DiT): #21 on the board (the 3.5B is #12). Chinese and English, cloning, utterances up to 30 s. MIT.",
            supportStage: .implemented,
            supportedLanguages: [.chinese, .english],
            runtimeNotes: "Routes to the longcat_audiodit loader. Not validated here: 5.7 GB bf16 download; the 4-bit build is the candidate for phones. Non-streaming by design, so time to first audio equals the whole chunk.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/LongCat-AudioDiT-1B-bf16"),
            projectURL: URL(string: "https://github.com/meituan-longcat/LongCat-AudioDiT")
        ),
        .init(
            id: "mlx-community/maya1-4bit",
            displayName: "Maya1",
            summary: "Maya Research Maya1 (3.3B Llama-style AR over SNAC, 4-bit): #16 on the board. Natural-language voice description, 20 emotion tags, streaming. Apache-2.0.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the llama_tts (Orpheus) loader with the SNAC companion repo. Needs the `<description=\"…\">` prompt format wired through the voice option before it is useful; not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/maya1-4bit"),
            projectURL: URL(string: "https://huggingface.co/maya-research/maya1")
        ),
        .init(
            id: "mlx-community/csm-1b-8bit",
            displayName: "Sesame CSM-1B",
            summary: "Sesame CSM-1B (Llama-1B backbone + audio decoder over Mimi, 8-bit): #17 on the board. Speaker id and context turns. Apache-2.0.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the csm loader shared with Marvis. Not validated here; validate the load and the speaker-id voice mapping before adding a descriptor.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/csm-1b-8bit"),
            projectURL: URL(string: "https://github.com/SesameAILabs/csm")
        ),
        .init(
            id: "mlx-community/Llama-OuteTTS-1.0-1B-fp16",
            displayName: "OuteTTS 1.0 1B",
            summary: "OuteAI OuteTTS 1.0 (Llama-3.2-1B over IBM DAC-speech): #19 on the board. 12+ languages, default speaker and cloning profiles. CC-BY-NC-SA-4.0.",
            supportStage: .implemented,
            supportedLanguages: [.english, .chinese, .japanese, .korean, .german, .french, .spanish, .italian, .portuguese, .dutch, .arabic, .russian],
            runtimeNotes: "Routes to the outetts loader with the mlx-community/dac-speech-24khz-1.5kbps companion repo. Listed for research use only because the weights are non-commercial; not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Llama-OuteTTS-1.0-1B-fp16"),
            projectURL: URL(string: "https://github.com/edwko/OuteTTS")
        ),
        .init(
            id: "mlx-community/VibeVoice-Realtime-0.5B-8bit",
            displayName: "VibeVoice Realtime 0.5B",
            summary: "Microsoft VibeVoice Realtime (Qwen2.5-0.5B + diffusion head, 8-bit): #27 on the board. 25 preset voices, streaming. MIT.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the vibevoice_streaming loader. Not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/VibeVoice-Realtime-0.5B-8bit"),
            projectURL: URL(string: "https://github.com/microsoft/VibeVoice")
        ),
        .init(
            id: "mlx-community/Audio8-TTS-Preview-0.6b-bf16",
            displayName: "Audio8 TTS 0.6B",
            summary: "Audio8 TTS Preview (dual-AR with a bundled 44.1 kHz codec): #31 on the board. 11 languages, cloning. Apache-2.0.",
            supportStage: .implemented,
            supportedLanguages: [.english, .chinese, .japanese, .korean, .german, .french, .spanish, .italian, .portuguese, .russian, .arabic],
            runtimeNotes: "Routes to the arktts (Audio8) loader. Not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Audio8-TTS-Preview-0.6b-bf16"),
            projectURL: URL(string: "https://huggingface.co/Audio8")
        ),
        .init(
            id: "mlx-community/VoxCPM2-4bit",
            displayName: "VoxCPM2",
            summary: "OpenBMB VoxCPM2 (MiniCPM-4 + local diffusion, 48 kHz, 4-bit): #36 on the board. 30 languages, cloning, voice design, streaming. Apache-2.0.",
            supportStage: .implemented,
            supportedLanguages: [.chinese, .english, .japanese, .korean, .german, .french, .spanish, .italian, .portuguese, .russian],
            runtimeNotes: "Routes to the voxcpm2 loader. Not validated here.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/VoxCPM2-4bit"),
            projectURL: URL(string: "https://github.com/OpenBMB/VoxCPM")
        ),
        .init(
            id: "mlx-community/Dia-1.6B",
            displayName: "Dia 1.6B",
            summary: "Nari Labs Dia (encoder-decoder over DAC with CFG, 44.1 kHz): #40 on the board. `[S1]`/`[S2]` dialogue, nonverbal tags, cloning. Apache-2.0.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the dia loader with the mlx-community/descript-audio-codec-44khz companion repo. Not validated here; dialogue-script prompting needs its own text formatting before it suits narration.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Dia-1.6B"),
            projectURL: URL(string: "https://github.com/nari-labs/dia")
        ),
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
