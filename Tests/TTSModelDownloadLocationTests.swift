import Foundation
import Testing
import HuggingFace
@testable import TTSMLX

/// Regression coverage for the model-download bugs reported from a consuming
/// app: direct downloads 404ing on Hugging Face, a finished download reported
/// as "not installed", and load failures surfacing with an empty message.
@Suite("Model download locations and URLs", .serialized)
struct TTSModelDownloadLocationTests {

    // MARK: - Direct download URLs

    /// Hugging Face serves file bytes only under `resolve/<rev>/`; the bare
    /// `<repo>/<file>` path is the HTML site and answers 404 for every file.
    @Test("direct downloads from a Hugging Face repo use the resolve endpoint")
    func huggingFaceDirectURLUsesResolve() throws {
        let base = try #require(URL(string: "https://huggingface.co/mlx-community/Soprano-80M-4bit"))
        #expect(TTSModelStore.directFileURL(baseURL: base, file: "README.md").absoluteString
                == "https://huggingface.co/mlx-community/Soprano-80M-4bit/resolve/main/README.md")
        #expect(TTSModelStore.directFileURL(baseURL: base, file: "embeddings/alba.safetensors").absoluteString
                == "https://huggingface.co/mlx-community/Soprano-80M-4bit/resolve/main/embeddings/alba.safetensors")
    }

    @Test("a static mirror keeps plain path appending")
    func staticMirrorURLIsUnchanged() throws {
        let base = try #require(URL(string: "https://r2.my-weights-mirror.com/pocket-tts"))
        #expect(TTSModelStore.directFileURL(baseURL: base, file: "config.json").absoluteString
                == "https://r2.my-weights-mirror.com/pocket-tts/config.json")
    }

    @Test("a Hugging Face URL already inside resolve/ is left alone")
    func alreadyRawURLIsUnchanged() throws {
        let base = try #require(URL(string: "https://huggingface.co/mlx-community/pocket-tts/resolve/v1"))
        #expect(TTSModelStore.directFileURL(baseURL: base, file: "config.json").absoluteString
                == "https://huggingface.co/mlx-community/pocket-tts/resolve/v1/config.json")
    }

    // MARK: - One cache for download, load and lookup

    /// The runtime downloads into `HubCache.default`; if the store did not look
    /// there first, a model could download completely and then be reported as
    /// not installed.
    @Test("default lookup roots lead with the runtime's cache directory")
    func defaultRootsLeadWithRuntimeCache() {
        let roots = TTSModelStore.defaultModelCacheRoots()
        #expect(roots.first?.standardizedFileURL.path == HubCache.default.cacheDirectory.standardizedFileURL.path)
        // No duplicates: the conventional locations are filtered against it.
        #expect(Set(roots.map(\.standardizedFileURL.path)).count == roots.count)
    }

    @Test("a custom cache root is where the store downloads to and loads from")
    func customRootDrivesHubCache() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-root-\(UUID().uuidString)", isDirectory: true)
        let store = TTSModelStore(cacheRoots: [root])
        #expect(store.modelCacheDirectory.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(store.hubCache.cacheDirectory.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test("no cache roots falls back to the runtime's default cache")
    func emptyRootsFallBackToDefault() {
        let store = TTSModelStore(cacheRoots: [])
        #expect(store.modelCacheDirectory.standardizedFileURL.path
                == HubCache.default.cacheDirectory.standardizedFileURL.path)
    }

    // MARK: - installedModels() after a download

    /// Soprano's config says `model_type: soprano` / `SopranoForCausalLM` —
    /// no "tts" anywhere — and the 4-bit build is not in the validated default
    /// list. The runtime registry loads it, so it must still be listed.
    @Test("a runtime-supported model without 'tts' in its config is listed as installed")
    func runtimeSupportedModelIsListed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-installed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelID = "mlx-community/Soprano-80M-4bit"
        let dir = root
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model_type": "soprano", "architectures": ["SopranoForCausalLM"]}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 16).write(to: dir.appendingPathComponent("model.safetensors"))

        let store = TTSModelStore(cacheRoots: [root])
        #expect(await store.isInstalled(modelID))
        let listed = try await store.installedModels()
        #expect(listed.map(\.id) == [modelID])
        #expect(listed.first?.descriptor.capabilities.isRuntimeSupported == true)
    }

    /// The registry maps `llama` → Orpheus and `qwen3` → Qwen3-TTS for
    /// loading, but those are also plain language-model types. An LLM that
    /// mlx-lm left in the shared hub cache (plain `models--` layout, not in
    /// the catalog) must not be listed as an installed voice, while a catalog
    /// Soprano in the TTS runtime's `mlx-audio/` layout next to it still is.
    @Test("an ordinary language model in the hub cache is not listed as a TTS model")
    func plainLanguageModelIsNotListed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-llm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (dir, config) in [
            ("models--mlx-community--Llama-3.2-1B-Instruct-4bit",
             #"{"model_type": "llama", "architectures": ["LlamaForCausalLM"]}"#),
            ("models--mlx-community--Qwen3-0.6B-4bit",
             #"{"model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]}"#),
        ] {
            let url = root.appendingPathComponent(dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: url.appendingPathComponent("config.json"))
            try Data(repeating: 0, count: 16).write(to: url.appendingPathComponent("model.safetensors"))
        }
        let sopranoID = "mlx-community/Soprano-80M-4bit"
        let soprano = root
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(sopranoID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: soprano, withIntermediateDirectories: true)
        try Data(#"{"model_type": "soprano", "architectures": ["SopranoForCausalLM"]}"#.utf8)
            .write(to: soprano.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 16).write(to: soprano.appendingPathComponent("model.safetensors"))

        let store = TTSModelStore(cacheRoots: [root])
        let listed = try await store.installedModels().map(\.id)
        #expect(listed == [sopranoID])
        #expect(!listed.contains("mlx-community/Llama-3.2-1B-Instruct-4bit"))
        #expect(!listed.contains("mlx-community/Qwen3-0.6B-4bit"))
    }

    // MARK: - Error text

    private struct BlankError: LocalizedError {
        var errorDescription: String? { "" }
    }

    /// Runtime failures can carry an empty `localizedDescription`; the wrapped
    /// error must still say something a user (and a bug report) can act on.
    @Test("load failures never surface with an empty message")
    func loadFailureMessageIsNeverEmpty() {
        let wrapped = TTSError.wrap(BlankError(), modelID: "mlx-community/VyvoTTS-EN-Beta-4bit", stage: .loadingModel)
        guard case .modelLoadFailed = wrapped else {
            Issue.record("expected modelLoadFailed, got \(wrapped)"); return
        }
        let message = wrapped.errorDescription ?? ""
        #expect(message.contains("Loading mlx-community/VyvoTTS-EN-Beta-4bit failed: "))
        #expect(message.contains("BlankError"))
    }
}
