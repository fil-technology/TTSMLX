import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSModelStore", .serialized)
struct TTSModelStoreTests {
    @Test("search filters, deduplicates, and ranks TTS models")
    func searchModelsFiltersAndRanks() async throws {
        let session = makeSession { request in
            let url = try #require(request.url)
            #expect(url.absoluteString.contains("/api/models"))

            return try httpJSONResponse(
                url: url,
                body: [
                    [
                        "id": "mlx-community/pocket-tts",
                        "tags": ["en"],
                        "downloads": 100,
                        "likes": 10,
                        "usedStorage": 240_000_000
                    ],
                    [
                        "id": "mlx-community/pocket-tts-8bit",
                        "tags": ["en"],
                        "downloads": 10
                    ],
                    [
                        "id": "mlx-community/orpheus-3b-0.1-ft-bf16",
                        "tags": ["english"],
                        "downloads": 90
                    ],
                    [
                        "id": "mlx-community/echo-tts-base",
                        "tags": ["voice-cloning", "english"],
                        "downloads": 95
                    ],
                    [
                        "id": "someone/not-tts",
                        "tags": ["tts"],
                        "downloads": 80
                    ],
                    [
                        "id": "someone/real-tts",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["kokoro"],
                        "downloads": 70
                    ],
                    [
                        "id": "mlx-community/kitten-tts-mini-0.8",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["language:en", "kitten_tts"],
                        "downloads": 74
                    ],
                    [
                        "id": "mlx-community/kokoro-82m-4bit",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["kokoro"],
                        "downloads": 85
                    ],
                    [
                        "id": "custom/qwen3-tts-demo",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["qwen3_tts"],
                        "downloads": 75
                    ],
                    [
                        "id": "mlx-community/Irodori-TTS-JP-4bit",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["language:ja", "irodori_tts"],
                        "downloads": 73
                    ],
                    [
                        "id": "mlx-community/Voxtral-4B-TTS-2603-8bit",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["voxtral_tts", "language:en"],
                        "downloads": 72
                    ],
                    [
                        "id": "OpenMOSS-Team/MOSS-TTS-Nano",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["moss_tts", "language:en", "language:zh"],
                        "downloads": 71
                    ],
                    [
                        "id": "someone/asr-model",
                        "pipeline_tag": "automatic-speech-recognition",
                        "downloads": 999
                    ]
                ]
            )
        }

        let store = TTSModelStore(session: session, cacheRoots: [])
        let results = try await store.searchModels(query: "tts", limit: 10)

        #expect(results.map(\.id) == [
            "mlx-community/pocket-tts",
            "mlx-community/orpheus-3b-0.1-ft-bf16",
            "mlx-community/kokoro-82m-4bit",
            "custom/qwen3-tts-demo",
            "mlx-community/kitten-tts-mini-0.8",
            "mlx-community/Irodori-TTS-JP-4bit",
            "mlx-community/Voxtral-4B-TTS-2603-8bit",
            "OpenMOSS-Team/MOSS-TTS-Nano",
        ])
        #expect(results.first?.suggestedVoices.contains(.alba) == true)
        #expect(results.first(where: { $0.id == "mlx-community/orpheus-3b-0.1-ft-bf16" })?.suggestedVoices.contains(.tara) == true)
        #expect(results.contains { $0.id == "mlx-community/kitten-tts-mini-0.8" } == true)
        #expect(results.first(where: { $0.id == "mlx-community/kitten-tts-mini-0.8" })?.capabilities.isRuntimeSupported == false)
        #expect(results.contains { $0.id == "mlx-community/echo-tts-base" } == false)
        #expect(results.first(where: { $0.id == "mlx-community/Irodori-TTS-JP-4bit" })?.capabilities.isRuntimeSupported == false)
        #expect(results.first(where: { $0.id == "mlx-community/Voxtral-4B-TTS-2603-8bit" })?.capabilities.isRuntimeSupported == false)
        #expect(results.first(where: { $0.id == "mlx-community/kokoro-82m-4bit" })?.capabilities.isRuntimeSupported == false)
        #expect(results.first(where: { $0.id == "OpenMOSS-Team/MOSS-TTS-Nano" })?.capabilities.isRuntimeSupported == false)
        #expect(results.contains { $0.id == "someone/asr-model" } == false)
        #expect(results.contains { $0.id == "mlx-community/pocket-tts-8bit" } == false)
        #expect(results.contains { $0.id == "someone/real-tts" } == false)
        #expect(results.contains { $0.id == "someone/not-tts" } == false)
    }

    @Test("search inference uses fallback metadata and capabilities")
    func searchModelsUsesFallbackMetadataAndCapabilities() async throws {
        let session = makeSession { request in
            let url = try #require(request.url)
            #expect(url.absoluteString.contains("/api/models"))

            return try httpJSONResponse(
                url: url,
                body: [
                    [
                        "id": "mlx-community/pocket-tts",
                        "tags": ["tts"],
                        "downloads": 300
                    ],
                    [
                        "id": "custom/qwen3-tts-mini",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["qwen3_tts"],
                        "downloads": 120
                    ]
                ]
            )
        }

        let store = TTSModelStore(session: session, cacheRoots: [])
        let results = try await store.searchModels(query: "tts", limit: 10)

        let pocket = try #require(results.first(where: { $0.id == "mlx-community/pocket-tts" }))
        #expect(pocket.capabilities.isRuntimeSupported)
        #expect(pocket.supportedLanguages == [.english])
        #expect(pocket.capabilities.defaultGenerationProfile == .fast)

        let unknown = try #require(results.first(where: { $0.id == "custom/qwen3-tts-mini" }))
        #expect(unknown.capabilities.isRuntimeSupported)
        #expect(unknown.capabilities.supportsReferenceAudio == false)
        #expect(unknown.supportedLanguages.isEmpty == true)
        #expect(unknown.capabilities.supportedLanguages.isEmpty == true)
    }

    @Test("search maps language tags into capabilities")
    func searchModelsMapsLanguageTagsToCapabilities() async throws {
        let session = makeSession { request in
            let url = try #require(request.url)
            #expect(url.absoluteString.contains("/api/models"))

            return try httpJSONResponse(
                url: url,
                body: [
                    [
                        "id": "custom/echo-tts-multilingual",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["language:en", "language:fr", "voice-cloning", "echo_tts"],
                        "downloads": 50
                    ]
                ]
            )
        }

        let store = TTSModelStore(session: session, cacheRoots: [])
        let results = try await store.searchModels(query: "tts", limit: 10)

        let model = try #require(results.first)
        #expect(model.id == "custom/echo-tts-multilingual")
        #expect(model.capabilities.isRuntimeSupported == false)
        #expect(model.capabilities.supportedLanguages.map(\.identifier) == ["English", "French"])
        #expect(model.capabilities.supportsLanguageList)
    }

    @Test("metadata fetch merges Hugging Face fields with config.json")
    func fetchMetadataMergesRemoteAndConfig() async throws {
        let session = makeSession { request in
            let url = try #require(request.url)

            if url.absoluteString.contains("/api/models/") {
                return try httpJSONResponse(
                    url: url,
                    body: [
                        "id": "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
                        "pipeline_tag": "text-to-speech",
                        "tags": ["language:en", "license:apache-2.0", "qwen3_tts"],
                        "downloads": 1234,
                        "likes": 55,
                        "usedStorage": 987_654_321
                    ]
                )
            }

            if url.absoluteString.contains("/resolve/main/config.json") {
                return try httpJSONResponse(
                    url: url,
                    body: [
                        "model_type": "qwen3_tts",
                        "architectures": ["Qwen3TTSModel"],
                        "sample_rate": 24_000,
                        "languages": ["fr"],
                        "language": "de",
                        "license": "cc-by-4.0"
                    ]
                )
            }

            throw TestHTTPError.unhandledRequest(url.absoluteString)
        }

        let store = TTSModelStore(session: session, cacheRoots: [])
        let metadata = try await store.fetchMetadata(for: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit")

        #expect(metadata.pipelineTag == "text-to-speech")
        #expect(metadata.downloads == 1234)
        #expect(metadata.likes == 55)
        #expect(metadata.storageSizeBytes == 987_654_321)
        #expect(metadata.modelType == "qwen3_tts")
        #expect(metadata.architectures == ["Qwen3TTSModel"])
        #expect(metadata.sampleRate == 24_000)
        #expect(Set(metadata.languageIdentifiers) == Set(["en", "fr", "de"]))
        #expect(metadata.license == "cc-by-4.0")
    }

    @Test("installed model discovery supports hub and legacy cache layouts")
    func installedModelsDiscoverHubAndLegacyLayouts() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let hubModel = temporaryRoot
            .appendingPathComponent("models--mlx-community--pocket-tts", isDirectory: true)
        let legacyRoot = temporaryRoot
            .appendingPathComponent("mlx-audio", isDirectory: true)
        let duplicateLegacyModel = legacyRoot
            .appendingPathComponent("mlx-community_pocket-tts", isDirectory: true)
        let legacyOnlyModel = legacyRoot
            .appendingPathComponent("custom_echo-tts-demo", isDirectory: true)
        let unsupportedLegacyModel = legacyRoot
            .appendingPathComponent("mlx-community_kitten-tts-mini-0.8", isDirectory: true)

        try FileManager.default.createDirectory(at: hubModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicateLegacyModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyOnlyModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unsupportedLegacyModel, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 12).write(to: hubModel.appendingPathComponent("weights.safetensors"))
        try Data(repeating: 2, count: 8).write(to: duplicateLegacyModel.appendingPathComponent("weights.safetensors"))
        try Data(repeating: 3, count: 20).write(to: legacyOnlyModel.appendingPathComponent("weights.safetensors"))
        try Data("""
        {
          "model_type": "echo_tts",
          "languages": ["en"]
        }
        """.utf8).write(to: legacyOnlyModel.appendingPathComponent("config.json"))
        try Data("""
        {
          "model_type": "kitten_tts"
        }
        """.utf8).write(to: unsupportedLegacyModel.appendingPathComponent("config.json"))

        let store = TTSModelStore(cacheRoots: [temporaryRoot])
        let installed = try await store.installedModels()

        #expect(installed.map(\.id) == ["custom/echo-tts-demo", "mlx-community/kitten-tts-mini-0.8", "mlx-community/pocket-tts"])

        let custom = try #require(installed.first)
        #expect(custom.sizeBytes > 20)
        #expect(custom.descriptor.capabilities.isRuntimeSupported == false)

        let kitten = try #require(installed.first(where: { $0.id == "mlx-community/kitten-tts-mini-0.8" }))
        #expect(kitten.descriptor.capabilities.isRuntimeSupported == false)

        let pocket = try #require(installed.last)
        #expect(pocket.descriptor.displayName == "Pocket TTS")
        #expect(pocket.descriptor.capabilities.isRuntimeSupported)
        #expect([8, 12].contains(pocket.sizeBytes))
    }

    @Test("public model catalog separates validated implemented and planned models")
    func modelCatalogExposesSupportStages() throws {
        #expect(TTSMLX.supportedModels.count == TTSMLX.validatedModels.count)
        #expect(TTSMLX.validatedModels.allSatisfy { $0.supportStage == .validated })
        #expect(TTSMLX.implementedModels.contains { $0.id == "mlx-community/kitten-tts-mini-0.8" })

        let moss = try #require(TTSMLX.plannedModels.first(where: { $0.id == "OpenMOSS-Team/MOSS-TTS-Nano" }))
        #expect(moss.supportStage == .planned)
        #expect(moss.projectURL?.absoluteString == "https://github.com/OpenMOSS/MOSS-TTS-Nano")
        #expect(moss.modelURL?.absoluteString == "https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano")
        #expect(moss.supportedLanguages.contains(.greek))
    }
}

private enum TestHTTPError: Error {
    case missingHandler
    case unhandledRequest(String)
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TestHTTPError.missingHandler)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func httpJSONResponse(url: URL, body: Any) throws -> (HTTPURLResponse, Data) {
    let data = try JSONSerialization.data(withJSONObject: body)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    return (response, data)
}
