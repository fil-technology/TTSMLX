import Foundation
import HuggingFace
import MLXAudioCore

public actor TTSModelStore {
    private let fileManager: FileManager
    private let session: URLSession
    private let defaultModels: [TTSModelDescriptor]
    private let cacheRoots: [URL]

    public init(
        defaultModels: [TTSModelDescriptor] = TTSMLX.defaultModels,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        cacheRoots: [URL]? = nil
    ) {
        self.defaultModels = defaultModels
        self.session = session
        self.fileManager = fileManager
        self.cacheRoots = cacheRoots ?? Self.defaultModelCacheRoots()
    }

    public func recommendedModels() -> [TTSModelDescriptor] {
        defaultModels
    }

    public func searchModels(query: String, limit: Int = 20) async throws -> [TTSModelDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://huggingface.co/api/models")
        components?.queryItems = [
            .init(name: "search", value: trimmed),
            .init(name: "limit", value: String(max(1, min(limit * 2, 50))))
        ]

        guard let url = components?.url else {
            throw TTSError.invalidModelQuery
        }

        let (data, response) = try await session.data(from: url)
        try Self.validate(response: response, data: data)

        let apiModels = try JSONDecoder().decode([HuggingFaceModel].self, from: data)
        let unique = Self.deduplicate(apiModels)
        let filtered = unique.filter(Self.isSupportedSearchResult)
        let ranked = filtered.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }

        return ranked.prefix(limit).map { searchModel in
            let metadata = Self.metadata(from: searchModel)
            let fallback = defaultModel(for: searchModel.id)
            let fallbackLanguages = fallback?.supportedLanguages ?? []
            let metadataLanguages = Self.languages(from: metadata.languageIdentifiers)
            let capabilities = Self.capabilities(
                for: searchModel.id,
                modelTags: searchModel.tags ?? [],
                fallback: fallback,
                discoveredLanguages: metadataLanguages,
                metadata: metadata
            )
            let supportedLanguages = capabilities.supportedLanguages

            return TTSModelDescriptor(
                id: searchModel.id,
                displayName: searchModel.id.components(separatedBy: "/").last ?? searchModel.id,
                summary: searchModel.pipelineTag,
                supportedLanguages: supportedLanguages.isEmpty ? fallbackLanguages : supportedLanguages,
                suggestedVoices: Self.suggestedVoices(for: searchModel.id, fallback: fallback),
                capabilities: capabilities,
                metadata: metadata
            )
        }
    }

    public func fetchMetadata(for modelID: String) async throws -> TTSModelMetadata {
        let apiMetadata = try await fetchRemoteModel(modelID: modelID)
        let config = try await fetchConfig(modelID: modelID)
        let base = Self.metadata(from: apiMetadata)
        return Self.merge(metadata: base, config: config)
    }

    public func installedModels() throws -> [TTSInstalledModel] {
        try discoverInstalledModels()
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public func isInstalled(_ modelID: String) -> Bool {
        modelCacheLocation(for: modelID) != nil
    }

    @discardableResult
    public func ensureDownloaded(
        _ descriptor: TTSModelDescriptor,
        hfToken: String? = nil,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSInstalledModel {
        guard descriptor.capabilities.isRuntimeSupported else {
            throw TTSError.unsupportedModel(descriptor.id)
        }

        if let installedLocation = modelCacheLocation(for: descriptor.id) {
            let installed = TTSInstalledModel(
                descriptor: descriptor,
                location: installedLocation,
                sizeBytes: directorySize(at: installedLocation)
            )
            if let progressHandler {
                await progressHandler(.init(
                    stage: .completed,
                    fractionCompleted: 1,
                    message: "Model already available locally."
                ))
            }
            return installed
        }

        if let progressHandler {
            await progressHandler(.init(
                stage: .resolvingModel,
                message: "Resolving model metadata..."
            ))
        }

        try await downloadModelSnapshot(
            descriptor: descriptor,
            hfToken: hfToken,
            progressHandler: progressHandler
        )

        if let progressHandler {
            await progressHandler(.init(
                stage: .loadingModel,
                message: "Loading model files..."
            ))
        }

        _ = try await MLXTTSModelLoader.load(descriptor: descriptor, hfToken: hfToken)
        guard let location = modelCacheLocation(for: descriptor.id) else {
            throw TTSError.modelNotFound(descriptor.id)
        }

        let installed = TTSInstalledModel(
            descriptor: descriptor,
            location: location,
            sizeBytes: directorySize(at: location)
        )

        if let progressHandler {
            await progressHandler(.init(
                stage: .completed,
                fractionCompleted: 1,
                message: "Model ready."
            ))
        }

        return installed
    }

    public func removeModel(id: String) throws {
        guard let location = modelCacheLocation(for: id) else {
            throw TTSError.modelNotFound(id)
        }
        try fileManager.removeItem(at: location)
    }
}

private extension TTSModelStore {
    struct HuggingFaceModel: Decodable {
        let id: String
        let pipelineTag: String?
        let tags: [String]?
        let downloads: Int?
        let likes: Int?
        let usedStorage: Int64?

        enum CodingKeys: String, CodingKey {
            case id
            case pipelineTag = "pipeline_tag"
            case tags
            case downloads
            case likes
            case usedStorage
        }
    }

    struct ModelConfig: Decodable {
        let modelType: String?
        let architectures: [String]?
        let sampleRate: Int?
        let samplingRate: Int?
        let languages: [String]?
        let language: String?
        let lang: String?
        let license: String?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case architectures
            case sampleRate = "sample_rate"
            case samplingRate = "sampling_rate"
            case languages
            case language
            case lang
            case license
        }
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TTSError.httpError(statusCode: httpResponse.statusCode, body: data)
        }
    }

    static func isSupportedSearchResult(_ model: HuggingFaceModel) -> Bool {
        let id = model.id.lowercased()
        let pipeline = model.pipelineTag?.lowercased() ?? ""
        let tags = (model.tags ?? []).map { $0.lowercased() }
        let supportedType = supportedModelType(
            id: id,
            tags: tags,
            modelType: nil,
            architectures: []
        )

        if let supportedType {
            switch supportedType {
            case "soprano", "llama_tts", "csm", "pocket_tts":
                return true
            case "qwen3_tts":
                return true
            case "qwen3":
                return id.contains("vyvotts")
            default:
                return false
            }
        }

        let explicitTTS = pipeline == "text-to-speech"
        let hasLanguageHints = tags.contains { $0.hasPrefix("language:") }
            || tags.contains { languageTagMap[$0] != nil }
        let hasReferenceAudioHints = tags.contains("voice-cloning")
            || tags.contains("voice_cloning")
        let isKnownUnsupportedTTSFamily = knownUnsupportedTTSModelFamily(id: id, tags: tags)
        let looksLikeMLXRepo = id.contains("mlx")

        if explicitTTS && (looksLikeMLXRepo || hasLanguageHints || hasReferenceAudioHints || isKnownUnsupportedTTSFamily) {
            return true
        }

        return false
    }

    static func supportedModelType(
        id: String,
        tags: [String],
        modelType: String?,
        architectures: [String]
    ) -> String? {
        if let normalized = normalizedSupportedModelType(modelType) {
            return normalized
        }

        if let inferred = inferredSupportedModelType(from: architectures) {
            return inferred
        }

        return inferredSupportedModelType(id: id, tags: tags)
    }

    static func normalizedSupportedModelType(_ modelType: String?) -> String? {
        guard let modelType else { return nil }

        let trimmed = modelType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "soprano", "soprano_tts":
            return "soprano"
        case "llama_tts", "llama3_tts", "llama3", "llama", "orpheus", "orpheus_tts":
            return "llama_tts"
        case "csm", "sesame":
            return "csm"
        case "pocket_tts":
            return "pocket_tts"
        case "qwen3_tts":
            return "qwen3_tts"
        case "qwen3", "qwen":
            return "qwen3"
        default:
            return nil
        }
    }

    static func inferredSupportedModelType(from architectures: [String]) -> String? {
        for architecture in architectures {
            let lower = architecture.lowercased()

            if lower.contains("qwen3tts") {
                return "qwen3_tts"
            }
            if lower.contains("qwen3") {
                return "qwen3"
            }
            if lower.contains("soprano") {
                return "soprano"
            }
            if lower.contains("llamatts") || lower.contains("orpheus") {
                return "llama_tts"
            }
            if lower.contains("marvis") || lower.contains("csm") || lower.contains("sesame") {
                return "csm"
            }
            if lower.contains("pockettts") {
                return "pocket_tts"
            }
        }

        return nil
    }

    static func inferredSupportedModelType(id: String, tags: [String]) -> String? {
        let normalizedTags = Set(tags.map { $0.lowercased() })

        if id.contains("qwen3_tts")
            || id.contains("qwen3-tts")
            || normalizedTags.contains("qwen3_tts")
        {
            return "qwen3_tts"
        }

        if id.contains("qwen3")
            || id.contains("qwen")
            || normalizedTags.contains("qwen3")
            || normalizedTags.contains("qwen")
        {
            return "qwen3"
        }

        if id.contains("soprano") || normalizedTags.contains("soprano_tts") || normalizedTags.contains("soprano") {
            return "soprano"
        }

        if id.contains("orpheus")
            || id.contains("llama")
            || normalizedTags.contains("llama_tts")
            || normalizedTags.contains("llama3_tts")
            || normalizedTags.contains("orpheus")
            || normalizedTags.contains("orpheus_tts")
        {
            return "llama_tts"
        }

        if id.contains("marvis")
            || id.contains("sesame")
            || id.contains("csm")
            || normalizedTags.contains("csm")
            || normalizedTags.contains("sesame")
        {
            return "csm"
        }

        if id.contains("pocket-tts")
            || id.contains("pocket_tts")
            || normalizedTags.contains("pocket_tts")
        {
            return "pocket_tts"
        }

        return nil
    }

    static func knownUnsupportedTTSModelFamily(id: String, tags: [String]) -> Bool {
        let haystack = [id] + tags
        return haystack.contains { value in
            value.contains("irodori")
                || value.contains("hume")
                || value.contains("tada")
                || value.contains("kugel")
                || value.contains("voxtral-4b-tts")
                || value.contains("voxtral_tts")
                || value.contains("vibevoice")
                || value.contains("voicevoice")
        }
    }

    static func deduplicate(_ models: [HuggingFaceModel]) -> [HuggingFaceModel] {
        var seen = Set<String>()
        var output: [HuggingFaceModel] = []

        for model in models {
            let key = model.id
                .lowercased()
                .replacingOccurrences(of: "-8bit", with: "")
                .replacingOccurrences(of: "-6bit", with: "")
                .replacingOccurrences(of: "-4bit", with: "")
                .replacingOccurrences(of: "-bf16", with: "")
                .replacingOccurrences(of: "-fp16", with: "")
                .replacingOccurrences(of: "-int8", with: "")

            guard seen.insert(key).inserted else { continue }
            output.append(model)
        }

        return output
    }

    func defaultModel(for modelID: String) -> TTSModelDescriptor? {
        let normalized = modelID.lowercased()
        return defaultModels.first(where: { $0.id.lowercased() == normalized })
    }

    static func suggestedVoices(for modelID: String, fallback: TTSModelDescriptor?) -> [TTSVoice] {
        let key = modelID.lowercased()

        if key.contains("pocket-tts") {
            return [.alba, .marius, .javert, .jean]
        }

        if key.contains("orpheus") || key.contains("llama") {
            return [.tara, .leah, .jess, .leo, .dan, .mia, .zac, .zoe]
        }

        if key.contains("qwen3") || key.contains("vyvotts") {
            return [.enUS1]
        }

        return fallback?.suggestedVoices ?? []
    }

    static func capabilities(
        for modelID: String,
        modelTags: [String],
        fallback: TTSModelDescriptor?,
        discoveredLanguages: [TTSLanguage],
        metadata: TTSModelMetadata
    ) -> TTSModelCapabilities {
        let id = modelID.lowercased()
        let supportedType = supportedModelType(
            id: id,
            tags: modelTags.map { $0.lowercased() },
            modelType: metadata.modelType,
            architectures: metadata.architectures
        )

        let fallbackProfile = fallback?.capabilities.defaultGenerationProfile ?? .balanced
        let defaultGenerationProfile: TTSGenerationProfile
        switch supportedType {
        case "csm", "pocket_tts":
            defaultGenerationProfile = .fast
        case "llama_tts", "qwen3_tts":
            defaultGenerationProfile = .highQuality
        case "soprano":
            defaultGenerationProfile = .balanced
        default:
            defaultGenerationProfile = fallbackProfile
        }

        let inferredLanguages: [TTSLanguage] = discoveredLanguages.isEmpty
            ? (fallback?.capabilities.supportedLanguages ?? [])
            : discoveredLanguages

        return TTSModelCapabilities(
            isRuntimeSupported: supportedType != nil,
            supportsReferenceAudio: fallback?.capabilities.supportsReferenceAudio ?? false,
            supportsLanguageList: !inferredLanguages.isEmpty || !metadata.languageIdentifiers.isEmpty,
            supportedLanguages: inferredLanguages,
            defaultGenerationProfile: defaultGenerationProfile
        )
    }

    static func metadata(from model: HuggingFaceModel) -> TTSModelMetadata {
        let languageIdentifiers = extractLanguageIdentifiers(from: model.tags ?? [])
        let license = extractLicense(from: model.tags ?? [])

        return TTSModelMetadata(
            pipelineTag: model.pipelineTag,
            tags: model.tags ?? [],
            downloads: model.downloads,
            likes: model.likes,
            storageSizeBytes: model.usedStorage,
            languageIdentifiers: languageIdentifiers,
            license: license
        )
    }

    static func merge(metadata: TTSModelMetadata, config: ModelConfig?) -> TTSModelMetadata {
        guard let config else { return metadata }

        let configLanguages = (config.languages ?? []) + [config.language, config.lang].compactMap { $0 }
        let mergedLanguages = Array(Set(metadata.languageIdentifiers + configLanguages)).sorted()

        return TTSModelMetadata(
            pipelineTag: metadata.pipelineTag,
            tags: metadata.tags,
            downloads: metadata.downloads,
            likes: metadata.likes,
            storageSizeBytes: metadata.storageSizeBytes,
            languageIdentifiers: mergedLanguages,
            license: config.license ?? metadata.license,
            modelType: config.modelType,
            architectures: config.architectures ?? [],
            sampleRate: config.sampleRate ?? config.samplingRate,
            extra: metadata.extra
        )
    }

    static func extractLanguageIdentifiers(from tags: [String]) -> [String] {
        let mapped = tags.compactMap { tag -> String? in
            if tag.hasPrefix("language:") {
                return String(tag.dropFirst("language:".count))
            }
            return Self.languageTagMap[tag.lowercased()]
        }
        return Array(Set(mapped)).sorted()
    }

    static func extractLicense(from tags: [String]) -> String? {
        tags.first { $0.lowercased().hasPrefix("license:") }?
            .replacingOccurrences(of: "license:", with: "")
    }

    static func languages(from identifiers: [String]) -> [TTSLanguage] {
        identifiers.map { identifier in
            let normalized = identifier.lowercased()
            return TTSLanguage(languageTagMap[normalized] ?? identifier)
        }
    }

    static let languageTagMap: [String: String] = [
        "en": "English",
        "english": "English",
        "es": "Spanish",
        "spanish": "Spanish",
        "fr": "French",
        "french": "French",
        "de": "German",
        "german": "German",
        "it": "Italian",
        "italian": "Italian",
        "pt": "Portuguese",
        "portuguese": "Portuguese",
        "nl": "Dutch",
        "dutch": "Dutch",
        "pl": "Polish",
        "polish": "Polish",
        "tr": "Turkish",
        "turkish": "Turkish",
        "ru": "Russian",
        "russian": "Russian",
        "ja": "Japanese",
        "japanese": "Japanese",
        "ko": "Korean",
        "korean": "Korean",
        "zh": "Chinese",
        "chinese": "Chinese",
        "ar": "Arabic",
        "arabic": "Arabic",
        "hi": "Hindi",
        "hindi": "Hindi"
    ]

    func discoverInstalledModels() throws -> [TTSInstalledModel] {
        var models: [TTSInstalledModel] = []
        var seen = Set<String>()

        for root in modelCacheRoots() where fileManager.fileExists(atPath: root.path) {
            let entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for entry in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }

                if entry.lastPathComponent.hasPrefix("models--") {
                    let repoID = String(entry.lastPathComponent.dropFirst("models--".count))
                        .replacingOccurrences(of: "--", with: "/")
                    guard seen.insert(repoID).inserted else { continue }
                    guard let descriptor = makeInstalledDescriptor(for: repoID, location: entry) else { continue }
                    models.append(.init(descriptor: descriptor, location: entry, sizeBytes: directorySize(at: entry)))
                    continue
                }

                if entry.lastPathComponent == "mlx-audio" {
                    let legacyEntries = try fileManager.contentsOfDirectory(
                        at: entry,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )

                    for legacyEntry in legacyEntries {
                        let legacyValues = try legacyEntry.resourceValues(forKeys: [.isDirectoryKey])
                        guard legacyValues.isDirectory == true else { continue }

                        let repoID = legacyEntry.lastPathComponent.replacingOccurrences(of: "_", with: "/")
                        guard seen.insert(repoID).inserted else { continue }
                        guard let descriptor = makeInstalledDescriptor(for: repoID, location: legacyEntry) else { continue }
                        models.append(.init(descriptor: descriptor, location: legacyEntry, sizeBytes: directorySize(at: legacyEntry)))
                    }
                }
            }
        }

        return models
    }

    func makeInstalledDescriptor(for repoID: String, location: URL) -> TTSModelDescriptor? {
        let fallback = defaultModel(for: repoID)
        let config = loadLocalConfig(from: location)
        let metadata = Self.merge(
            metadata: .init(),
            config: config
        )

        let supportedType = Self.supportedModelType(
            id: repoID.lowercased(),
            tags: [],
            modelType: metadata.modelType,
            architectures: metadata.architectures
        )

        let looksLikeTTS = fallback != nil
            || metadata.modelType?.lowercased().contains("tts") == true
            || metadata.architectures.contains(where: { $0.lowercased().contains("tts") })

        guard looksLikeTTS else {
            return nil
        }

        let discoveredLanguages = Self.languages(from: metadata.languageIdentifiers)
        let capabilities = Self.capabilities(
            for: repoID,
            modelTags: [],
            fallback: fallback,
            discoveredLanguages: discoveredLanguages,
            metadata: metadata
        )

        return fallback ?? .init(
            id: repoID,
            displayName: repoID.components(separatedBy: "/").last ?? repoID,
            supportedLanguages: capabilities.supportedLanguages,
            suggestedVoices: Self.suggestedVoices(for: repoID, fallback: fallback),
            capabilities: TTSModelCapabilities(
                isRuntimeSupported: supportedType != nil,
                supportsReferenceAudio: capabilities.supportsReferenceAudio,
                supportsLanguageList: capabilities.supportsLanguageList,
                supportedLanguages: capabilities.supportedLanguages,
                defaultGenerationProfile: capabilities.defaultGenerationProfile,
                supportsStreaming: capabilities.supportsStreaming
            ),
            metadata: metadata
        )
    }

    func modelCacheLocation(for modelID: String) -> URL? {
        let legacyKey = modelID.replacingOccurrences(of: "/", with: "_")
        let hubKey = "models--" + modelID.replacingOccurrences(of: "/", with: "--")

        for root in modelCacheRoots() {
            let legacyLocation = root.appendingPathComponent("mlx-audio/\(legacyKey)", isDirectory: true)
            if fileManager.fileExists(atPath: legacyLocation.path) {
                return legacyLocation
            }

            let hubLocation = root.appendingPathComponent(hubKey, isDirectory: true)
            if fileManager.fileExists(atPath: hubLocation.path) {
                return hubLocation
            }
        }

        return nil
    }

    static func defaultModelCacheRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            home.appendingPathComponent("Library/Caches/huggingface/hub", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/huggingface/hub", isDirectory: true)
        ]
    }

    func modelCacheRoots() -> [URL] {
        cacheRoots
    }

    func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    func downloadModelSnapshot(
        descriptor: TTSModelDescriptor,
        hfToken: String?,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)?
    ) async throws {
        guard let repoID = Repo.ID(rawValue: descriptor.id) else {
            throw TTSError.modelNotFound(descriptor.id)
        }

        let client: HubClient
        if let hfToken, !hfToken.isEmpty {
            client = HubClient(host: HubClient.defaultHost, bearerToken: hfToken, cache: .default)
        } else {
            client = HubClient(cache: .default)
        }

        let cache = client.cache ?? .default
        let modelDirectory = cache.cacheDirectory
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(descriptor.id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let requiredExtension = inferredRequiredExtension(for: descriptor.id)
        let allowedExtensions = [
            "*.\(requiredExtension)",
            "*.safetensors",
            "*.json",
            "*.txt",
            "*.wav"
        ]

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: modelDirectory,
            revision: "main",
            matching: allowedExtensions,
            progressHandler: { progress in
                guard let progressHandler else { return }
                let fraction = progress.totalUnitCount > 0
                    ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    : nil
                progressHandler(.init(
                    stage: .downloadingModel,
                    fractionCompleted: fraction,
                    message: Self.downloadMessage(progress: progress)
                ))
            }
        )
    }

    func inferredRequiredExtension(for modelID: String) -> String {
        let lower = modelID.lowercased()
        if lower.contains("qwen3-tts") || lower.contains("qwen3_tts") {
            return "safetensors"
        }
        if lower.contains("soprano") {
            return "safetensors"
        }
        if lower.contains("pocket-tts") || lower.contains("pocket_tts") {
            return "safetensors"
        }
        if lower.contains("marvis") || lower.contains("csm") || lower.contains("sesame") {
            return "safetensors"
        }
        if lower.contains("llama") || lower.contains("orpheus") {
            return "safetensors"
        }
        return "safetensors"
    }

    static func downloadMessage(progress: Progress) -> String {
        if progress.totalUnitCount > 0 {
            let percent = Int((Double(progress.completedUnitCount) / Double(progress.totalUnitCount)) * 100)
            return "Downloading model files... \(percent)%"
        }
        return "Downloading model files..."
    }

    func fetchRemoteModel(modelID: String) async throws -> HuggingFaceModel {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID)") else {
            throw TTSError.invalidModelQuery
        }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(HuggingFaceModel.self, from: data)
    }

    func fetchConfig(modelID: String) async throws -> ModelConfig? {
        let localConfigURL = modelCacheLocation(for: modelID)?.appendingPathComponent("config.json")
        if let localConfigURL {
            return loadConfig(at: localConfigURL)
        }

        guard let encodedID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/\(encodedID)/resolve/main/config.json") else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(httpResponse.statusCode) else { return nil }
        return try? JSONDecoder().decode(ModelConfig.self, from: data)
    }

    func loadLocalConfig(from modelDirectory: URL) -> ModelConfig? {
        loadConfig(at: modelDirectory.appendingPathComponent("config.json"))
    }

    func loadConfig(at url: URL) -> ModelConfig? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelConfig.self, from: data)
    }
}
