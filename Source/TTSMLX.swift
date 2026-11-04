import Foundation

public enum TTSMLX {
    /// Languages the Qwen3-TTS family advertises. Shared by every Qwen3-TTS
    /// catalog entry so the list stays consistent across size/quant variants.
    /// Built-in speakers of the Qwen3-TTS CustomVoice builds (config
    /// `talker_config.spk_id`). Pass one as the voice, optionally followed by
    /// a style instruction: `"ryan"` or `"ryan, speak slowly and warmly"`.
    /// `eric` and `dylan` speak Sichuan / Beijing dialect respectively.
    static let qwen3CustomVoiceSpeakers: [TTSVoice] = [
        "ryan", "serena", "vivian", "aiden", "ono_anna", "sohee", "uncle_fu", "eric", "dylan"
    ]

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
        "en_news", "en_2", "en_3", "en_4", "en_6", "en_7", "en_8"
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

    static let kokoroLanguages: [TTSLanguage] = [
        .english, .spanish, .french, .hindi, .italian, .japanese, .portuguese, .chinese
    ]

    static let kokoroVoices: [TTSVoice] = kokoroVoiceNames.map { TTSVoice($0) }

    /// The checkpoint plus every voice embedding, so a background download
    /// leaves nothing for the first synthesis to fetch.
    static let kokoroFiles: [String] = ["config.json", "kokoro-v1_0.safetensors"]
        + kokoroVoiceNames.map { "voices/\($0).safetensors" }

    /// MeloTTS English accents (the checkpoint's speaker ids).
    static let meloTTSVoices: [TTSVoice] = ["EN-US", "EN-BR", "EN_INDIA", "EN-AU", "EN-Default"]

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
                supportedLanguages: Self.qwen3TTSLanguages,
                suggestedVoices: [.enUS1],
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
                    minimumDeviceClass: .iPhone
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
                suggestedVoices: [.enUS1],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .balanced,
                    peakMemoryMB: 700,
                    minimumDeviceClass: .iPhone
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
                suggestedVoices: [.enUS1],
                capabilities: .init(
                    isRuntimeSupported: true,
                    supportsReferenceAudio: false,
                    supportsLanguageList: true,
                    supportedLanguages: Self.qwen3TTSLanguages,
                    defaultGenerationProfile: .highQuality,
                    // Estimate only (not measured). 1.7B @ 4-bit ≈ 0.9GB weights
                    // plus codec/speaker-encoder/tokenizer + activations.
                    peakMemoryMB: 2_800,
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
                    minimumDeviceClass: .iPhone
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
            supportStage: .implemented,
            supportedLanguages: Self.mossTTSNanoLanguages,
            runtimeNotes: """
                Routes to upstream's moss_tts_nano loader (runtime 0.1.8-tts.3+: backbone, \
                MOSS-Audio-Tokenizer-Nano decoder and encoder). The fork adds the bundled \
                voices, a codebook dial the generation profiles drive (fast 8, balanced 12, \
                highQuality all 16) and sentence-by-sentence decoding, because the codec's \
                deepest stage attends over frames x 32 positions and a whole-passage decode is \
                quadratic in length. Pass `referenceAudio` (48 kHz is native; other rates are \
                encoded as-is) to clone a voice, or a bundled voice name; with neither it reads \
                as `en_news`. Known behaviour: at the model's own sampling defaults it \
                occasionally misses end-of-audio and fills the 375-frame budget with silence \
                (one of five macOS runs); the text chunker bounds the damage to one chunk. \
                About 0.7x realtime in a debug build on an M-series Mac. peakMemoryMB is the \
                macOS measurement of the previous port; re-measure on device before promoting.
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
                    peakMemoryMB: 1_600,
                    minimumDeviceClass: .iPhone
                ),
                modelURL: URL(string: "https://huggingface.co/mlx-community/MOSS-TTS-Nano-100M")
            )
        ),

        // MARK: Discovery-only entries. The 0.1.8-tts.3 runtime routes to every
        // family below, but none has been synthesized end to end through TTSMLX
        // yet, so they carry no descriptor: apps can list them, not select them.
        // Reasons are in runtimeNotes; see Docs/model-support.md for the full
        // leaderboard matrix.
        .init(
            id: "mlx-community/chatterbox-turbo-fp16",
            displayName: "Chatterbox Turbo",
            summary: "Resemble AI Chatterbox Turbo (~350M T3 over S3 tokens, one-step S3Gen): #3 on the tts-bench board. English, voice cloning, bundled default voice, `[laugh]`/`[cough]` tags. MIT.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the chatterbox loader (companion repo mlx-community/S3TokenizerV2). Not validated here: the fp16 checkpoint is 3 GB and this machine's disk could not hold it during the 0.10.0 cycle; the 4-bit build (chatterbox-turbo-4bit) is the one to validate first.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-turbo-fp16"),
            projectURL: URL(string: "https://github.com/resemble-ai/chatterbox")
        ),
        .init(
            id: "mlx-community/chatterbox-fp16",
            displayName: "Chatterbox",
            summary: "Resemble AI Chatterbox (~0.5B T3 Llama over S3 tokens, flow-matching S3Gen): #2 on the tts-bench board. Cloning from a clip, exaggeration and CFG knobs. MIT.",
            supportStage: .implemented,
            supportedLanguages: [.english],
            runtimeNotes: "Routes to the chatterbox loader. Not validated here for the same disk reason as Chatterbox Turbo; the multilingual v3 weights are a separate repo.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/chatterbox-fp16"),
            projectURL: URL(string: "https://github.com/resemble-ai/chatterbox")
        ),
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
            id: "mlx-community/Ming-3.0-tts-0.5B-bf16",
            displayName: "Ming-3.0-TTS 0.5B",
            summary: "Ant Group Ming-3.0-TTS (Qwen2.5-0.5B + flow-matching head, 44.1 kHz): #14 on the board. 7 languages, 100+ voices, cloning, voice design, emotion/speed/pitch tags. MIT.",
            supportStage: .implemented,
            supportedLanguages: [.chinese, .english, .japanese, .korean, .german, .french, .spanish],
            runtimeNotes: "Routes to the dense (Ming) loader; fetches CAM++ speaker weights from mlx-community/Step-Audio-2-token2wav. Not validated here: 3 GB download.",
            modelURL: URL(string: "https://huggingface.co/mlx-community/Ming-3.0-tts-0.5B-bf16"),
            projectURL: URL(string: "https://github.com/inclusionAI/Ming")
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
