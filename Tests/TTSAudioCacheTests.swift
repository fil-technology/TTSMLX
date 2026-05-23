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
