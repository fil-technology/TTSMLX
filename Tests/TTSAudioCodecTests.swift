#if canImport(AVFoundation)
import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TTSMLX

/// Tests for the v0.7 compressed-narration-audio feature: the ``TTSAudioCodec``
/// config surface, the AAC/ALAC encoder, flat-cache recognition of compressed
/// files, back-compat with legacy WAV manifests, playback parity, and the
/// WAV→AAC migration API.
///
/// Like the other bundle tests, these assemble audio by hand (no MLX model):
/// generation produces PCM buffers, and everything on-disk downstream of that
/// is codec plumbing we can exercise directly with a synthetic sine buffer.
@MainActor
@Suite("TTSAudioCodec")
struct TTSAudioCodecTests {

    // MARK: - Config surface

    @Test("audioCodec defaults to .wav so existing behavior is unchanged")
    func defaultCodecIsWav() {
        #expect(TTSSynthesisOptions().audioCodec == .wav)
    }

    @Test("codec metadata: extensions and manifest tags")
    func codecMetadata() {
        #expect(TTSAudioCodec.wav.fileExtension == "wav")
        #expect(TTSAudioCodec.aacLC(bitrate: 32_000).fileExtension == "m4a")
        #expect(TTSAudioCodec.appleLossless.fileExtension == "m4a")
        #expect(TTSAudioCodec.wav.manifestTag == "wav")
        #expect(TTSAudioCodec.aacLC(bitrate: 32_000).manifestTag == "aac-lc@32000")
        #expect(TTSAudioCodec.appleLossless.manifestTag == "alac")
    }

    // MARK: - Size

    @Test("AAC chunk is under 20% of the WAV equivalent for the same PCM")
    func aacSizeRatio() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = Self.makeSine(seconds: 2.0)

        let wavURL = dir.appendingPathComponent("chunk.wav")
        let aacURL = dir.appendingPathComponent("chunk.m4a")
        try Self.encode(buffer, to: wavURL, codec: .wav)
        try Self.encode(buffer, to: aacURL, codec: .aacLC(bitrate: 32_000))

        let wavSize = Self.size(wavURL)
        let aacSize = Self.size(aacURL)
        #expect(wavSize > 0)
        #expect(aacSize > 0)
        #expect(Double(aacSize) < Double(wavSize) * 0.2,
                "AAC \(aacSize) should be < 20% of WAV \(wavSize)")
    }

    @Test("Apple Lossless is smaller than WAV and still decodes")
    func alacSize() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = Self.makeSine(seconds: 2.0)

        let wavURL = dir.appendingPathComponent("chunk.wav")
        let alacURL = dir.appendingPathComponent("chunk.m4a")
        try Self.encode(buffer, to: wavURL, codec: .wav)
        try Self.encode(buffer, to: alacURL, codec: .appleLossless)

        #expect(Self.size(alacURL) < Self.size(wavURL))
        let decoded = try AVAudioFile(forReading: alacURL)
        #expect(decoded.length > 0)
    }

    @Test("an encoded chunk decodes back to ~the same duration")
    func decodeDurationParity() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sampleRate = 24_000.0
        let buffer = Self.makeSine(seconds: 1.0, sampleRate: sampleRate)
        let url = dir.appendingPathComponent("chunk.m4a")
        try Self.encode(buffer, to: url, codec: .aacLC(bitrate: 32_000))

        let decoded = try AVAudioFile(forReading: url)
        let originalSeconds = Double(buffer.frameLength) / sampleRate
        let decodedSeconds = Double(decoded.length) / decoded.processingFormat.sampleRate
        // AAC adds encoder priming/padding; gapless metadata keeps the audible
        // length close. Tolerate ~60 ms of frame-count drift.
        #expect(abs(decodedSeconds - originalSeconds) < 0.06,
                "decoded \(decodedSeconds)s vs original \(originalSeconds)s")
    }

    // MARK: - Manifest back-compat

    @Test("a manifest without a codec field decodes as nil (legacy WAV)")
    func legacyManifestNoCodec() throws {
        let json = """
        {
          "schemaVersion": 1,
          "createdAt": "2024-01-01T00:00:00Z",
          "modelID": "m",
          "sourceText": "x",
          "sampleRate": 24000,
          "chunks": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TTSPreparedNarrationManifest.self, from: Data(json.utf8))
        #expect(manifest.codec == nil)
    }

    @Test("the codec tag round-trips through encode/decode")
    func codecTagRoundTrips() throws {
        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            sourceText: "x",
            sampleRate: 24_000,
            codec: TTSAudioCodec.aacLC(bitrate: 32_000).manifestTag,
            chunks: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TTSPreparedNarrationManifest.self, from: data)
        #expect(decoded.codec == "aac-lc@32000")
    }

    @Test("a legacy WAV bundle (no codec field) still imports and plays")
    func legacyWavBundlePlays() async throws {
        let bundleURL = try TTSPreparedNarrationTests.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let narration = try TTSPreparedNarrationTests.makeTwoChunkBundle(
            at: bundleURL, chunk0: 0.3, chunk1: 0.3
        )
        #expect(narration.manifest.codec == nil) // legacy: field absent
        let playback = TTSPlaybackController()
        try playback.play(narration: narration)
        try await Task.sleep(nanoseconds: 800_000_000)
        playback.stop()
    }

    // MARK: - Flat-cache accounting

    @Test("the flat cache recognizes and accounts for a .m4a entry")
    func cacheRecognizesM4A() async throws {
        let cacheDir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = try TTSAudioCache(directoryURL: cacheDir)
        let key = await cache.key(modelID: "m", voice: nil, text: "hi")

        #expect(await cache.cachedURL(forKey: key) == nil)

        // Encode a real AAC file, then place its bytes at the reserved temp URL
        // and finalize — mirroring what a compressed write would leave behind.
        let scratch = cacheDir.appendingPathComponent("scratch.m4a")
        try Self.encode(Self.makeSine(seconds: 1.0), to: scratch, codec: .aacLC(bitrate: 32_000))
        let bytes = try Data(contentsOf: scratch)
        try FileManager.default.removeItem(at: scratch)

        let handle = await cache.reserveWrite(forKey: key, fileExtension: "m4a")
        try bytes.write(to: handle.temporaryURL)
        let finalURL = try await cache.finalize(handle)
        #expect(finalURL.pathExtension == "m4a")

        // Recognized as usable, counted in total size.
        let cached = await cache.cachedURL(forKey: key)
        #expect(cached == finalURL)
        let total = await cache.totalSizeBytes()
        #expect(total == Int64(bytes.count))
    }

    @Test("prune evicts .m4a entries and still purges .part stragglers")
    func prunePurgesM4AAndParts() async throws {
        let cacheDir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = try TTSAudioCache(directoryURL: cacheDir)

        // A finalized .m4a entry.
        let key = await cache.key(payload: "song")
        let scratch = cacheDir.appendingPathComponent("scratch.m4a")
        try Self.encode(Self.makeSine(seconds: 1.0), to: scratch, codec: .aacLC(bitrate: 32_000))
        let bytes = try Data(contentsOf: scratch)
        try FileManager.default.removeItem(at: scratch)
        let handle = await cache.reserveWrite(forKey: key, fileExtension: "m4a")
        try bytes.write(to: handle.temporaryURL)
        _ = try await cache.finalize(handle)

        // An abandoned .part straggler.
        let leaked = await cache.reserveWrite(forKey: cache.key(payload: "leak"), fileExtension: "m4a")
        try Data(repeating: 0, count: 2048).write(to: leaked.temporaryURL)

        let removed = await cache.prune(toMaxBytes: 0)
        #expect(removed >= Int64(bytes.count) + 2048)
        #expect(await cache.cachedURL(forKey: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: leaked.temporaryURL.path))
    }

    // MARK: - Playback parity

    @Test("an AAC bundle plays start-to-finish and fires every word")
    func aacBundlePlaysAndHighlights() async throws {
        let bundleURL = try TTSPreparedNarrationTests.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let narration = try Self.makeTwoChunkBundle(
            at: bundleURL, codec: .aacLC(bitrate: 32_000)
        )
        #expect(narration.manifest.codec == "aac-lc@32000")
        #expect(narration.manifest.chunks.allSatisfy { $0.audioFile.hasSuffix(".m4a") })

        let counter = WordCounter()
        let playback = TTSPlaybackController()
        try playback.play(narration: narration) { word in
            Task { await counter.record(word.characterRange) }
        }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let fired = await counter.values
        let expected = narration.flattenedWordTimeline().map { $0.characterRange }
        #expect(fired == expected)
    }

    @Test("a bundle mixing .wav and .m4a chunks imports and plays")
    func mixedCodecBundle() async throws {
        let bundleURL = try TTSPreparedNarrationTests.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // chunk 0 as WAV, chunk 1 as AAC — the resume-across-codec-switch case.
        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model",
            voice: "tara",
            sourceText: "Hello world from TTSMLX",
            sampleRate: 24_000,
            codec: "wav",
            chunks: [
                .init(index: 0, audioFile: "chunks/000.wav",
                      characterRange: .init(start: 0, end: 11), text: "Hello world",
                      duration: 0.3,
                      wordTimings: [
                          .init(characterRange: .init(start: 0, end: 5), offset: 0, duration: 0.15),
                          .init(characterRange: .init(start: 6, end: 11), offset: 0.15, duration: 0.15)
                      ]),
                .init(index: 1, audioFile: "chunks/001.m4a",
                      characterRange: .init(start: 12, end: 23), text: "from TTSMLX",
                      duration: 0.3,
                      wordTimings: [
                          .init(characterRange: .init(start: 0, end: 4), offset: 0, duration: 0.12),
                          .init(characterRange: .init(start: 5, end: 11), offset: 0.12, duration: 0.18)
                      ])
            ]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()
        try Self.encode(Self.makeSine(seconds: 0.3), to: bundleURL.appendingPathComponent("chunks/000.wav"), codec: .wav)
        try Self.encode(Self.makeSine(seconds: 0.3), to: bundleURL.appendingPathComponent("chunks/001.m4a"), codec: .aacLC(bitrate: 32_000))

        let narration = try TTSPreparedNarration(importing: bundleURL)
        let playback = TTSPlaybackController()
        let dur = try { () -> TimeInterval in
            try playback.play(narration: narration)
            return try #require(playback.duration)
        }()
        #expect(dur > 0)
        playback.stop()
    }

    // MARK: - Migration

    @Test("recompress shrinks a WAV bundle, preserves timings, and is idempotent")
    func recompressBundle() async throws {
        let bundleURL = try TTSPreparedNarrationTests.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        // Build a WAV bundle with real (1s) audio so the size delta is clear.
        let narration = try Self.makeTwoChunkBundle(
            at: bundleURL, codec: .wav, chunkSeconds: 1.0
        )
        let originalTimelines = narration.manifest.chunks.map { $0.wordTimings }
        let originalDurations = narration.manifest.chunks.map { $0.duration }

        let (before, after) = try await TTSPreparedNarration.recompress(
            bundleAt: bundleURL, to: .aacLC(bitrate: 32_000)
        )
        #expect(before > 0)
        #expect(after < before, "recompressed \(after) should be < original \(before)")

        // Manifest now points at .m4a chunks tagged AAC; timings untouched.
        let migrated = try TTSPreparedNarration(importing: bundleURL)
        #expect(migrated.manifest.codec == "aac-lc@32000")
        #expect(migrated.manifest.chunks.allSatisfy { $0.audioFile.hasSuffix(".m4a") })
        #expect(migrated.manifest.chunks.map { $0.wordTimings } == originalTimelines)
        #expect(migrated.manifest.chunks.map { $0.duration } == originalDurations)
        // Old WAV files are gone.
        #expect(!FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("chunks/000.wav").path))

        // Still plays.
        let playback = TTSPlaybackController()
        try playback.play(narration: migrated)
        playback.stop()

        // Idempotent: a second pass is a no-op (before == after, nothing left to shrink).
        let second = try await TTSPreparedNarration.recompress(
            bundleAt: bundleURL, to: .aacLC(bitrate: 32_000)
        )
        #expect(second.before == second.after)
    }

    @Test("store-wide recompressAllBundles sweeps every cache-managed bundle")
    func recompressAllBundles() async throws {
        let cacheDir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = try TTSAudioCache(directoryURL: cacheDir)

        // Two WAV bundles at cache-managed locations.
        for text in ["chapter one text", "chapter two text"] {
            let bundleURL = cache.narrationBundle(modelID: "m", text: text)
            _ = try Self.makeTwoChunkBundle(at: bundleURL, codec: .wav, chunkSeconds: 1.0)
        }

        let progressCalls = ProgressRecorder()
        let (before, after) = try await cache.recompressAllBundles(to: .aacLC(bitrate: 32_000)) { done, total in
            Task { await progressCalls.record(done, total) }
        }
        #expect(before > 0)
        #expect(after < before)
        // Give the detached progress tasks a beat to land.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await progressCalls.count == 2)
    }

    // MARK: - Helpers

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-codec-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSine(seconds: Double, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = Float(sin(Double(i) / sampleRate * 2 * .pi * 440) * 0.2)
        }
        return buffer
    }

    static func encode(_ buffer: AVAudioPCMBuffer, to url: URL, codec: TTSAudioCodec) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var file: AVAudioFile? = try TTSAudioEncoder.makeFile(
            at: url, codec: codec, sourceFormat: buffer.format
        )
        try TTSAudioEncoder.write(buffer, to: file!)
        file = nil // flush / finalize before the caller measures the file
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }

    /// A two-chunk bundle written in `codec` with real encoded audio. Mirrors
    /// `TTSPreparedNarrationTests.makeTwoChunkBundle` but parameterizes the
    /// codec and chunk length so migration/size tests get meaningful bytes.
    static func makeTwoChunkBundle(
        at bundleURL: URL,
        codec: TTSAudioCodec,
        chunkSeconds: Double = 0.3
    ) throws -> TTSPreparedNarration {
        let ext = codec.fileExtension
        let sourceText = "Hello world from TTSMLX"
        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model",
            voice: "tara",
            sourceText: sourceText,
            sampleRate: 24_000,
            codec: codec.manifestTag,
            chunks: [
                .init(index: 0, audioFile: "chunks/000.\(ext)",
                      characterRange: .init(start: 0, end: 11), text: "Hello world",
                      duration: chunkSeconds,
                      wordTimings: [
                          .init(characterRange: .init(start: 0, end: 5), offset: 0, duration: chunkSeconds * 0.5),
                          .init(characterRange: .init(start: 6, end: 11), offset: chunkSeconds * 0.5, duration: chunkSeconds * 0.5)
                      ]),
                .init(index: 1, audioFile: "chunks/001.\(ext)",
                      characterRange: .init(start: 12, end: 23), text: "from TTSMLX",
                      duration: chunkSeconds,
                      wordTimings: [
                          .init(characterRange: .init(start: 0, end: 4), offset: 0, duration: chunkSeconds * 0.4),
                          .init(characterRange: .init(start: 5, end: 11), offset: chunkSeconds * 0.4, duration: chunkSeconds * 0.6)
                      ])
            ]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()
        try encode(makeSine(seconds: chunkSeconds), to: bundleURL.appendingPathComponent("chunks/000.\(ext)"), codec: codec)
        try encode(makeSine(seconds: chunkSeconds), to: bundleURL.appendingPathComponent("chunks/001.\(ext)"), codec: codec)
        return try TTSPreparedNarration(importing: bundleURL)
    }
}

actor ProgressRecorder {
    private(set) var count = 0
    private(set) var last: (Int, Int)?
    func record(_ done: Int, _ total: Int) {
        count += 1
        last = (done, total)
    }
}
#endif
