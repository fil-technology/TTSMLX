import Foundation
import HuggingFace
import MLXAudioCore

public actor TTSModelStore {
    private let fileManager: FileManager
    private let session: URLSession
    private let defaultModels: [TTSModelDescriptor]

    public init(
        defaultModels: [TTSModelDescriptor] = TTSMLX.defaultModels,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.defaultModels = defaultModels
        self.session = session
        self.fileManager = fileManager
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
        let filtered = unique.filter(Self.isRelevantTTSModel)
        let ranked = filtered.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }

        return ranked.prefix(limit).map {
            let metadata = Self.metadata(from: $0)
            return TTSModelDescriptor(
                id: $0.id,
                displayName: $0.id.components(separatedBy: "/").last ?? $0.id,
                summary: $0.pipelineTag,
                supportedLanguages: Self.languages(from: metadata.languageIdentifiers),
                suggestedVoices: Self.suggestedVoices(for: $0.id),
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

        enum CodingKeys: String, CodingKey {
            case id
            case pipelineTag = "pipeline_tag"
            case tags
            case downloads
            case likes
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

    static func isRelevantTTSModel(_ model: HuggingFaceModel) -> Bool {
        let id = model.id.lowercased()
        let pipeline = model.pipelineTag?.lowercased() ?? ""
        let tags = (model.tags ?? []).map { $0.lowercased() }

        let explicitTTS = pipeline == "text-to-speech"
            || id.contains("tts")
            || tags.contains(where: { $0.contains("text-to-speech") || $0 == "tts" })

        let likelyMLX = id.contains("mlx")
            || id.contains("marvis")
            || id.contains("soprano")
            || id.contains("pocket-tts")
            || id.contains("qwen3-tts")

        return explicitTTS || likelyMLX
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

    static func suggestedVoices(for modelID: String) -> [TTSVoice] {
        let key = modelID.lowercased()

        if key.contains("pocket-tts") {
            return [.alba, .marius]
        }

        if key.contains("orpheus") || key.contains("llama") {
            return [.tara, .leo]
        }

        if key.contains("qwen3") || key.contains("vyvotts") {
            return [.enUS1]
        }

        return []
    }

    static func metadata(from model: HuggingFaceModel) -> TTSModelMetadata {
        let languageIdentifiers = extractLanguageIdentifiers(from: model.tags ?? [])
        let license = extractLicense(from: model.tags ?? [])

        return TTSModelMetadata(
            pipelineTag: model.pipelineTag,
            tags: model.tags ?? [],
            downloads: model.downloads,
            likes: model.likes,
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
        identifiers.map { TTSLanguage($0) }
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
                    let descriptor = defaultModels.first(where: { $0.id == repoID }) ?? .init(id: repoID)
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
                        let descriptor = defaultModels.first(where: { $0.id == repoID }) ?? .init(id: repoID)
                        models.append(.init(descriptor: descriptor, location: legacyEntry, sizeBytes: directorySize(at: legacyEntry)))
                    }
                }
            }
        }

        return models
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

    func modelCacheRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            home.appendingPathComponent("Library/Caches/huggingface/hub", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/huggingface/hub", isDirectory: true)
        ]
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
        if let localConfigURL, fileManager.fileExists(atPath: localConfigURL.path) {
            let data = try Data(contentsOf: localConfigURL)
            return try? JSONDecoder().decode(ModelConfig.self, from: data)
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
}
