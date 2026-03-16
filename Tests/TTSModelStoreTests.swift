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
            "mlx-community/echo-tts-base",
            "mlx-community/orpheus-3b-0.1-ft-bf16",
            "custom/qwen3-tts-demo"
        ])
        #expect(results.first?.suggestedVoices.contains(.alba) == true)
        #expect(results[2].suggestedVoices.contains(.tara) == true)
        #expect(results.contains { $0.id == "someone/asr-model" } == false)
        #expect(results.contains { $0.id == "mlx-community/pocket-tts-8bit" } == false)
        #expect(results.contains { $0.id.contains("kokoro") } == false)
        #expect(results.contains { $0.id == "someone/not-tts" } == false)
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
            .appendingPathComponent("custom_demo-model", isDirectory: true)

        try FileManager.default.createDirectory(at: hubModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicateLegacyModel, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyOnlyModel, withIntermediateDirectories: true)

        try Data(repeating: 1, count: 12).write(to: hubModel.appendingPathComponent("weights.safetensors"))
        try Data(repeating: 2, count: 8).write(to: duplicateLegacyModel.appendingPathComponent("weights.safetensors"))
        try Data(repeating: 3, count: 20).write(to: legacyOnlyModel.appendingPathComponent("weights.safetensors"))

        let store = TTSModelStore(cacheRoots: [temporaryRoot])
        let installed = try await store.installedModels()

        #expect(installed.map(\.id) == ["custom/demo-model", "mlx-community/pocket-tts"])

        let custom = try #require(installed.first)
        #expect(custom.sizeBytes == 20)

        let pocket = try #require(installed.last)
        #expect(pocket.descriptor.displayName == "Pocket TTS")
        #expect([8, 12].contains(pocket.sizeBytes))
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
