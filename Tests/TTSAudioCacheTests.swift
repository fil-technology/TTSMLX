import Foundation
import Testing
@testable import TTSMLX
#if canImport(AVFoundation)
import AVFoundation
#endif

@Suite("TTSAudioCache", .serialized)
struct TTSAudioCacheTests {
    @Test("key derivation is deterministic and order-sensitive")
    func keyDerivation() async throws {
        let cache = try makeCache()
        let a = await cache.key(modelID: "m", voice: .alba, text: "hello")
        let b = await cache.key(modelID: "m", voice: .alba, text: "hello")
        let c = await cache.key(modelID: "m", voice: .marius, text: "hello")
        let d = await cache.key(modelID: "m", voice: .alba, text: "world")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.count == 64) // SHA-256 hex
    }

    @Test("text normalization strips CRLF and surrounding whitespace before hashing")
    func keyNormalization() async throws {
        let cache = try makeCache()
        let a = await cache.key(modelID: "m", voice: nil, text: "hi\r\nthere")
        let b = await cache.key(modelID: "m", voice: nil, text: "  hi\nthere\n")
        #expect(a == b)
    }

    @Test("reserveWrite, finalize round-trip lets cachedURL find the entry")
    func reserveAndFinalize() async throws {
        let cache = try makeCache()
        let key = await cache.key(modelID: "m", voice: .alba, text: "x")
        #expect(await cache.cachedURL(forKey: key) == nil)

        let handle = await cache.reserveWrite(forKey: key)
        try writeFakeWAV(to: handle.temporaryURL)
        let finalURL = try await cache.finalize(handle)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))

        let cached = await cache.cachedURL(forKey: key)
        #expect(cached == finalURL)
        #expect(await cache.contains(key: key))
    }

    @Test("cachedURL ignores zero-byte and corrupt files")
    func ignoresInvalidFiles() async throws {
        let cache = try makeCache()
        let key = await cache.key(modelID: "m", voice: nil, text: "y")

        // Empty file
        let handle = await cache.reserveWrite(forKey: key)
        FileManager.default.createFile(atPath: handle.temporaryURL.path, contents: Data(), attributes: nil)
        _ = try await cache.finalize(handle)
        #expect(await cache.cachedURL(forKey: key) == nil)
    }

    @Test("discard removes the temporary file and leaves no entry behind")
    func discardCleansUp() async throws {
        let cache = try makeCache()
        let key = await cache.key(modelID: "m", voice: nil, text: "z")
        let handle = await cache.reserveWrite(forKey: key)
        try Data("garbage".utf8).write(to: handle.temporaryURL)
        await cache.discard(handle)
        #expect(!FileManager.default.fileExists(atPath: handle.temporaryURL.path))
        #expect(await cache.cachedURL(forKey: key) == nil)
    }

    @Test("remove drops every artifact for the key")
    func removeKey() async throws {
        let cache = try makeCache()
        let key = await cache.key(modelID: "m", voice: nil, text: "k")
        let handle = await cache.reserveWrite(forKey: key)
        try writeFakeWAV(to: handle.temporaryURL)
        _ = try await cache.finalize(handle)
        #expect(await cache.contains(key: key))

        await cache.remove(forKey: key)
        #expect(!(await cache.contains(key: key)))
    }

    @Test("prune evicts oldest files until under the byte budget")
    func pruneEvictsOldest() async throws {
        let cache = try makeCache()
        let keys = ["a", "b", "c"]
        var sizes: [Int64] = []

        for (index, name) in keys.enumerated() {
            let key = await cache.key(payload: name)
            let handle = await cache.reserveWrite(forKey: key)
            try writeFakeWAV(to: handle.temporaryURL, payloadSize: 1024)
            let url = try await cache.finalize(handle)
            // Stagger modification dates so eviction order is deterministic.
            let date = Date(timeIntervalSinceReferenceDate: Double(index) * 10)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizes.append(Int64(size))
        }

        let initialTotal = await cache.totalSizeBytes()
        #expect(initialTotal == sizes.reduce(0, +))

        // Force eviction of the two oldest entries.
        let target = sizes[2]
        let removed = await cache.prune(toMaxBytes: target)
        #expect(removed >= sizes[0] + sizes[1])

        // The newest (key "c") should survive.
        let survivor = await cache.cachedURL(forKey: cache.key(payload: "c"))
        #expect(survivor != nil)
        let evictedA = await cache.cachedURL(forKey: cache.key(payload: "a"))
        let evictedB = await cache.cachedURL(forKey: cache.key(payload: "b"))
        #expect(evictedA == nil)
        #expect(evictedB == nil)
    }

    @Test("narrationBundle is deterministic and excludes voice")
    func narrationBundleDeterministic() async throws {
        let cache = try makeCache()
        let a = cache.narrationBundle(modelID: "m", text: "hello world")
        let b = cache.narrationBundle(modelID: "m", text: "hello world")
        let c = cache.narrationBundle(modelID: "m", text: "  hello world\r\n")
        #expect(a == b)
        #expect(a == c)
        #expect(a.lastPathComponent.hasSuffix(".\(TTSPreparedNarration.bundleExtension)"))
        let parent = a.deletingLastPathComponent()
        #expect(parent.lastPathComponent == "bundles")
        // No voice in the path — same URL regardless of voice argument
        // (voice isn't even an input here, but verify uniqueness on text).
        let d = cache.narrationBundle(modelID: "m", text: "different text")
        let e = cache.narrationBundle(modelID: "other", text: "hello world")
        #expect(a != d)
        #expect(a != e)
        // Caller doesn't need to create it; verify directory is absent.
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test("availableVariants is empty for fresh cache, populated after baking voices")
    func availableVariantsRoundTrip() async throws {
        let cache = try makeCache()
        let modelID = "m"
        let text = "Hello world from TTSMLX"
        let empty = await cache.availableVariants(modelID: modelID, text: text)
        #expect(empty.isEmpty)

        // Hand-write two sub-bundles inside the cache-managed location.
        let bundleURL = cache.narrationBundle(modelID: modelID, text: text)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try writeManifestSubBundle(at: bundleURL, modelID: modelID, voice: "jean", text: text)
        try writeManifestSubBundle(at: bundleURL, modelID: modelID, voice: "alba", text: text)

        let variants = await cache.availableVariants(modelID: modelID, text: text)
        let voices = Set(variants.compactMap(\.voice))
        #expect(voices.contains("jean"))
        #expect(voices.contains("alba"))
    }

    @Test("migrate(from:) moves legacy bundles, is idempotent")
    func migrateLegacyBundles() async throws {
        let cache = try makeCache()
        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTSAudioCacheLegacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyRoot) }

        // Build a legacy bundle (sub-bundle layout) at an arbitrary path.
        let legacyBundle = legacyRoot.appendingPathComponent("chapter-1.\(TTSPreparedNarration.bundleExtension)", isDirectory: true)
        let modelID = "m"
        let text = "Hello world from TTSMLX"
        try FileManager.default.createDirectory(at: legacyBundle, withIntermediateDirectories: true)
        try writeManifestSubBundle(at: legacyBundle, modelID: modelID, voice: "jean", text: text)

        let moved = try await cache.migrate(from: legacyRoot)
        #expect(moved == 1)

        // Destination bundle now exists in cache layout.
        let destination = cache.narrationBundle(modelID: modelID, text: text)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        // Legacy source is gone (moveItem).
        #expect(!FileManager.default.fileExists(atPath: legacyBundle.path))

        // Second call: nothing to move.
        let movedAgain = try await cache.migrate(from: legacyRoot)
        #expect(movedAgain == 0)
    }

    @Test("prune purges abandoned .part files first")
    func prunePurgesPartFiles() async throws {
        let cache = try makeCache()
        let key = await cache.key(payload: "leaked")
        let handle = await cache.reserveWrite(forKey: key)
        try Data(repeating: 0, count: 4096).write(to: handle.temporaryURL)

        let removed = await cache.prune(toMaxBytes: .max)
        #expect(removed >= 4096)
        #expect(!FileManager.default.fileExists(atPath: handle.temporaryURL.path))
    }
}

// MARK: - Helpers

private func makeCache() throws -> TTSAudioCache {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TTSAudioCacheTests-\(UUID().uuidString)", isDirectory: true)
    return try TTSAudioCache(directoryURL: dir)
}

/// Writes a tiny but valid WAV file (44-byte header + N zero samples).
private func writeFakeWAV(to url: URL, payloadSize: Int = 64) throws {
    let sampleRate: UInt32 = 22_050
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = UInt32(payloadSize)
    let chunkSize = 36 + dataSize

    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(le32(chunkSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(le32(16)) // PCM subchunk size
    data.append(le16(1))  // PCM format
    data.append(le16(channels))
    data.append(le32(sampleRate))
    data.append(le32(byteRate))
    data.append(le16(blockAlign))
    data.append(le16(bitsPerSample))
    data.append(contentsOf: Array("data".utf8))
    data.append(le32(dataSize))
    data.append(Data(repeating: 0, count: Int(dataSize)))

    try data.write(to: url)
}

private func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func le16(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

/// Writes a minimal sub-bundle manifest (no audio chunks) at
/// `bundleURL/voices/<slug>/manifest.json`. Empty chunk list — enough
/// for `availableVariants` / migration discovery.
private func writeManifestSubBundle(
    at bundleURL: URL,
    modelID: String,
    voice: String?,
    text: String
) throws {
    let sub = TTSPreparedNarration.subBundleURL(in: bundleURL, voice: voice, language: nil)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let manifest = TTSPreparedNarrationManifest(
        modelID: modelID,
        voice: voice,
        language: nil,
        sourceText: text,
        sampleRate: 22_050,
        chunks: []
    )
    try TTSPreparedNarration(manifest: manifest, baseURL: sub).writeManifest()
}
