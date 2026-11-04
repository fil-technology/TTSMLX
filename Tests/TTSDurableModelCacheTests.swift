import Foundation
import HuggingFace
import Testing
@testable import TTSMLX

@Suite("Durable model cache (URGENT item 4)")
struct TTSDurableModelCacheTests {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    var caches: URL { home.appendingPathComponent("Library/Caches/huggingface/hub", isDirectory: true) }
    var support: URL { home.appendingPathComponent("Library/Application Support/huggingface/hub", isDirectory: true) }

    @Test("iOS-family roots lead with Application Support and keep Caches for lookup")
    func purgeablePlatformRoots() {
        let roots = TTSModelStore.modelCacheRoots(
            platformPurgesCaches: true, environment: [:], home: home, runtimeCache: caches)
        #expect(roots.map(\.path) == [support.path, caches.path])
        #expect(!TTSModelStore.isPurgeable(roots[0]) && TTSModelStore.isPurgeable(roots[1]))
    }

    @Test("an explicit HF_HOME / HF_HUB_CACHE keeps the runtime's cache first")
    func explicitLocationWins() {
        let runtime = URL(fileURLWithPath: "/x/hub", isDirectory: true)
        let roots = TTSModelStore.modelCacheRoots(
            platformPurgesCaches: true, environment: ["HF_HOME": "/x"], home: home, runtimeCache: runtime)
        #expect(roots.first?.path == runtime.path)
    }

    @Test("macOS roots are unchanged: runtime cache first, then the conventional locations")
    func macRoots() {
        let runtime = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let roots = TTSModelStore.modelCacheRoots(
            platformPurgesCaches: false, environment: [:], home: home, runtimeCache: runtime)
        #expect(roots.map(\.path) == [runtime.path, caches.path, support.path])
        let sandboxed = TTSModelStore.modelCacheRoots(
            platformPurgesCaches: false, environment: ["APP_SANDBOX_CONTAINER_ID": "x"], home: home, runtimeCache: caches)
        #expect(sandboxed.map(\.path) == [caches.path, support.path])
    }

    private func makeTree() throws -> (base: URL, legacy: URL, durable: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-durable-\(UUID().uuidString)", isDirectory: true)
        let legacy = base.appendingPathComponent("Library/Caches/huggingface/hub", isDirectory: true)
        let durable = base.appendingPathComponent("Library/Application Support/huggingface/hub", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("mlx-audio/acme_voice"), withIntermediateDirectories: true)
        try Data("{\"model_type\":\"soprano\"}".utf8).write(to: legacy.appendingPathComponent("mlx-audio/acme_voice/config.json"))
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("models--acme--other/snapshots"), withIntermediateDirectories: true)
        return (base, legacy, durable)
    }

    @Test("installs in a purgeable root move into the durable root on first lookup")
    func legacyInstallsMigrate() async throws {
        let (base, legacy, durable) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = TTSModelStore(cacheRoots: [durable, legacy])
        let location = await store.modelCacheLocation(for: "acme/voice")
        #expect(location?.standardizedFileURL.path == durable.appendingPathComponent("mlx-audio/acme_voice").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: durable.appendingPathComponent("mlx-audio/acme_voice/config.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("mlx-audio/acme_voice").path))
        #expect(FileManager.default.fileExists(atPath: durable.appendingPathComponent("models--acme--other/snapshots").path))
        let values = try durable.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("a durable copy wins and the stale purgeable copy is removed")
    func durableCopyWins() async throws {
        let (base, legacy, durable) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let kept = durable.appendingPathComponent("mlx-audio/acme_voice/config.json")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"model_type\":\"durable\"}".utf8).write(to: kept)
        let store = TTSModelStore(cacheRoots: [durable, legacy])
        _ = await store.modelCacheLocation(for: "acme/voice")
        #expect(String(decoding: try Data(contentsOf: kept), as: UTF8.self).contains("durable"))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("mlx-audio/acme_voice").path))
    }

    @Test("nothing moves when the first root is itself purgeable")
    func noMigrationIntoPurgeableRoot() async throws {
        let (base, legacy, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = TTSModelStore(cacheRoots: [legacy])
        let location = await store.modelCacheLocation(for: "acme/voice")
        #expect(location?.standardizedFileURL.path == legacy.appendingPathComponent("mlx-audio/acme_voice").standardizedFileURL.path)
    }

    @Test("background downloads land in the store's first default root")
    func backgroundDownloadsAgreeWithStore() {
        let expected = TTSModelStore.defaultModelCacheRoots().first!
            .appendingPathComponent("mlx-audio/acme_voice", isDirectory: true)
        #expect(TTSBackgroundModelDownloader.destinationDirectory(for: "acme/voice").standardizedFileURL.path
                == expected.standardizedFileURL.path)
    }
}
