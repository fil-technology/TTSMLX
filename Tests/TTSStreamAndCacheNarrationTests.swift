#if canImport(AVFoundation)
import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TTSMLX

/// Tests for `TTSSpeechSynthesizer.streamAndCacheNarration(...)`.
///
/// The full-replay path doesn't invoke MLX — that's the property we verify:
/// pre-bake a bundle by hand (no model needed), then call the helper and
/// confirm every chunk comes back via the AsyncThrowingStream without
/// touching the synthesizer's model loading path.
///
/// Partial-cache / mismatch / corrupt-file paths are validated by inspecting
/// what's left in the bundle directory after the call, since exercising
/// generation requires MLX.
@MainActor
@Suite("streamAndCacheNarration")
struct TTSStreamAndCacheNarrationTests {
    @Test("full-cache call replays every chunk without invoking MLX")
    func fullReplay() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Pre-bake a 2-chunk bundle by hand.
        let modelID = "test/model"
        let voice = "tara"
        let sourceText = "Hello world from TTSMLX"
        try Self.buildHandBundle(
            at: bundleURL,
            modelID: modelID,
            voice: voice,
            sourceText: sourceText
        )

        // Construct the synthesizer with NO real model in the catalog; the
        // call should succeed entirely from cache.
        let synthesizer = TTSSpeechSynthesizer()

        // Use a model descriptor with matching id so the manifest check
        // passes. The descriptor itself is never loaded.
        let model = TTSModelDescriptor(id: modelID, capabilities: .init(isRuntimeSupported: true))

        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 11,
            followupChunkCharacterLimit: 11
        )

        let stream = try await synthesizer.streamAndCacheNarration(
            sourceText,
            using: model,
            options: TTSSynthesisOptions(voice: TTSVoice(voice)),
            cacheBundleAt: bundleURL,
            chunker: chunker
        )

        var bufferCount = 0
        for try await chunk in stream {
            #expect(chunk.buffer.frameLength > 0)
            bufferCount += 1
        }
        #expect(bufferCount == 2)
    }

    @Test("manifest mismatch wipes bundle and treats as fresh")
    func manifestMismatchWipes() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Bundle was baked for one source text.
        try Self.buildHandBundle(
            at: bundleURL,
            modelID: "test/model",
            voice: "tara",
            sourceText: "Hello world from TTSMLX"
        )
        // Verify chunks exist on disk pre-call.
        let chunksDir = bundleURL.appendingPathComponent("chunks")
        let preCount = (try? FileManager.default.contentsOfDirectory(atPath: chunksDir.path).count) ?? 0
        #expect(preCount > 0)

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))

        // Call with DIFFERENT source text — should trigger wipe + fresh start
        // attempt. The call will fail when it tries to invoke synthesizeStream
        // (no MLX). We only care that the old chunks are gone.
        do {
            let stream = try await synthesizer.streamAndCacheNarration(
                "Totally different text now",
                using: model,
                options: TTSSynthesisOptions(voice: TTSVoice("tara")),
                cacheBundleAt: bundleURL
            )
            for try await _ in stream { /* will throw before yielding */ }
        } catch { /* expected — MLX not available in tests */ }

        // The old chunk files should be wiped. A new (empty) chunks/ dir is fine.
        let postFiles = (try? FileManager.default.contentsOfDirectory(atPath: chunksDir.path)) ?? []
        #expect(!postFiles.contains("000.wav") || preCount != postFiles.count,
                "Old cached chunks should have been wiped on mismatch")
    }

    @Test("rejects empty text without touching the bundle directory")
    func rejectsEmptyText() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))

        var threw = false
        do {
            _ = try await synthesizer.streamAndCacheNarration(
                "   \n\t ",
                using: model,
                cacheBundleAt: bundleURL
            )
        } catch TTSError.emptyText {
            threw = true
        }
        #expect(threw)
    }

    @Test("diagnostics emitted from cache replay match generated-path shape")
    func replayEmitsDiagnostics() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Self.buildHandBundle(
            at: bundleURL,
            modelID: "test/model",
            voice: "tara",
            sourceText: "Hello world from TTSMLX"
        )

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))
        let events = await synthesizer.events()

        // Drain the stream in one task, collect events in another.
        let collector = Task { @MainActor () -> [TTSDiagnostic] in
            var collected: [TTSDiagnostic] = []
            for await event in events {
                collected.append(event)
                // 2 chunks × 3 events (started, finished, timings) = 6
                if collected.count >= 6 { break }
            }
            return collected
        }

        let stream = try await synthesizer.streamAndCacheNarration(
            "Hello world from TTSMLX",
            using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL,
            chunker: TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)
        )
        for try await _ in stream { /* drain */ }

        let events_ = await collector.value
        let starts = events_.filter { if case .chunkStarted = $0 { return true }; return false }
        let finishes = events_.filter { if case .chunkFinished = $0 { return true }; return false }
        let timings = events_.filter { if case .chunkTimings = $0 { return true }; return false }
        #expect(starts.count == 2)
        #expect(finishes.count == 2)
        #expect(timings.count == 2)
    }

    @Test("voice round-trip: switching back to a cached voice replays without MLX")
    func voiceRoundTrip() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let modelID = "test/model"
        let sourceText = "Hello world from TTSMLX"

        // Pre-bake voice A in its sub-bundle.
        try Self.buildHandSubBundle(
            at: bundleURL,
            modelID: modelID,
            voice: "jean",
            language: nil,
            sourceText: sourceText
        )
        // Pre-bake voice B in its sub-bundle.
        try Self.buildHandSubBundle(
            at: bundleURL,
            modelID: modelID,
            voice: "alba",
            language: nil,
            sourceText: sourceText
        )

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: modelID, capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        // Call with voice A — replay.
        let streamA = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("jean")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var aCount = 0
        for try await _ in streamA { aCount += 1 }
        #expect(aCount == 2)

        // Switch to voice B — replay (no MLX).
        let streamB = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("alba")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var bCount = 0
        for try await _ in streamB { bCount += 1 }
        #expect(bCount == 2)

        // Switch back to A — should still hit cache (no wipe).
        let streamA2 = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("jean")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var a2Count = 0
        for try await _ in streamA2 { a2Count += 1 }
        #expect(a2Count == 2)

        // Both sub-bundles exist side by side.
        let variants = TTSPreparedNarration.availableVariants(at: bundleURL)
        let voices = Set(variants.compactMap(\.voice))
        #expect(voices.contains("jean"))
        #expect(voices.contains("alba"))
    }

    @Test("language round-trip: switching back to a cached language replays without MLX")
    func languageRoundTrip() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let modelID = "test/model"
        let sourceText = "Hello world from TTSMLX"

        try Self.buildHandSubBundle(
            at: bundleURL, modelID: modelID,
            voice: "tara", language: "en", sourceText: sourceText
        )
        try Self.buildHandSubBundle(
            at: bundleURL, modelID: modelID,
            voice: "tara", language: "es", sourceText: sourceText
        )

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: modelID, capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        // EN replay.
        let stream1 = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(language: TTSLanguage("en"), voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var count1 = 0
        for try await _ in stream1 { count1 += 1 }
        #expect(count1 == 2)

        // Switch to ES, then back to EN — still cached.
        let stream2 = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(language: TTSLanguage("es"), voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var count2 = 0
        for try await _ in stream2 { count2 += 1 }
        #expect(count2 == 2)

        let stream3 = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(language: TTSLanguage("en"), voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var count3 = 0
        for try await _ in stream3 { count3 += 1 }
        #expect(count3 == 2)
    }

    @Test("cache: overload writes into the cache-managed location and supports voice switching")
    func cacheOverloadManagedLocation() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-managedcache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = try TTSAudioCache(directoryURL: cacheDir)

        let modelID = "test/model"
        let sourceText = "Hello world from TTSMLX"
        let managedURL = cache.narrationBundle(modelID: modelID, text: sourceText)

        // Pre-bake voice A in the cache-managed bundle's sub-bundle.
        try FileManager.default.createDirectory(
            at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Self.buildHandSubBundle(
            at: managedURL, modelID: modelID, voice: "jean",
            language: nil, sourceText: sourceText
        )
        try Self.buildHandSubBundle(
            at: managedURL, modelID: modelID, voice: "alba",
            language: nil, sourceText: sourceText
        )

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: modelID, capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        // Voice A — full replay via cache: overload.
        let streamA = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("jean")),
            cache: cache, chunker: chunker
        )
        var aCount = 0
        for try await _ in streamA { aCount += 1 }
        #expect(aCount == 2)

        // Switch to voice B — replay, both variants preserved.
        let streamB = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("alba")),
            cache: cache, chunker: chunker
        )
        var bCount = 0
        for try await _ in streamB { bCount += 1 }
        #expect(bCount == 2)

        let variants = await cache.availableVariants(modelID: modelID, text: sourceText)
        let voices = Set(variants.compactMap(\.voice))
        #expect(voices.contains("jean"))
        #expect(voices.contains("alba"))
    }

    @Test("legacy layout is auto-migrated into the matching sub-bundle")
    func legacyLayoutMigrates() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let modelID = "test/model"
        let sourceText = "Hello world from TTSMLX"
        // Build legacy on-disk layout at root.
        try Self.buildHandBundle(
            at: bundleURL, modelID: modelID, voice: "tara", sourceText: sourceText
        )

        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: modelID, capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        let stream = try await synthesizer.streamAndCacheNarration(
            sourceText, using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker
        )
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 2)

        // Legacy artifacts gone from root, sub-bundle now populated.
        let fm = FileManager.default
        let sub = TTSPreparedNarration.subBundleURL(in: bundleURL, voice: "tara", language: nil)
        #expect(fm.fileExists(atPath: sub.appendingPathComponent("manifest.json").path))
        #expect(fm.fileExists(atPath: sub.appendingPathComponent("chunks/000.wav").path))
        #expect(!fm.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        #expect(!fm.fileExists(atPath: bundleURL.appendingPathComponent("chunks").path))
    }

    @Test("startCharacterOffset=0 is a no-op: every chunk yielded")
    func startOffsetZeroNoOp() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Self.buildHandBundle(
            at: bundleURL, modelID: "test/model", voice: "tara",
            sourceText: "Hello world from TTSMLX"
        )
        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        let stream = try await synthesizer.streamAndCacheNarration(
            "Hello world from TTSMLX", using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker,
            startCharacterOffset: 0
        )
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 2)
    }

    @Test("startCharacterOffset within first chunk yields both chunks")
    func startOffsetWithinFirstChunk() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Self.buildHandBundle(
            at: bundleURL, modelID: "test/model", voice: "tara",
            sourceText: "Hello world from TTSMLX"
        )
        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        // Offset 5: chunk 0 ends at upperBound=11 > 5, so it straddles and gets yielded.
        let stream = try await synthesizer.streamAndCacheNarration(
            "Hello world from TTSMLX", using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker,
            startCharacterOffset: 5
        )
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 2)
    }

    @Test("startCharacterOffset past first chunk skips it; second chunk yields")
    func startOffsetSkipsFirstChunk() async throws {
        let bundleURL = try Self.tempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Self.buildHandBundle(
            at: bundleURL, modelID: "test/model", voice: "tara",
            sourceText: "Hello world from TTSMLX"
        )
        let synthesizer = TTSSpeechSynthesizer()
        let model = TTSModelDescriptor(id: "test/model", capabilities: .init(isRuntimeSupported: true))
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 11, followupChunkCharacterLimit: 11)

        // Subscribe to events BEFORE call so we can assert no chunkStarted for index 0.
        let events = await synthesizer.events()
        let collector = Task { @MainActor () -> [Int] in
            var startedIndices: [Int] = []
            for await event in events {
                if case let .chunkStarted(_, idx, _) = event {
                    startedIndices.append(idx)
                }
                if case .streamingFinished = event { break }
            }
            return startedIndices
        }

        // chunk 0 upperBound=11; offset=12 makes 11 <= 12 → skip. chunk 1 yielded.
        let stream = try await synthesizer.streamAndCacheNarration(
            "Hello world from TTSMLX", using: model,
            options: TTSSynthesisOptions(voice: TTSVoice("tara")),
            cacheBundleAt: bundleURL, chunker: chunker,
            startCharacterOffset: 12
        )
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 1)

        // Skipped chunks emit no chunkStarted. The only chunkStarted seen
        // should be for index 1.
        // Synthesizer doesn't emit streamingFinished for streamAndCacheNarration,
        // so we cancel the collector explicitly.
        collector.cancel()
        let startedIndices = await collector.value
        #expect(!startedIndices.contains(0))

        // Skipped chunk's cached file stays on disk for future offset=0 calls.
        let fm = FileManager.default
        let sub = TTSPreparedNarration.subBundleURL(in: bundleURL, voice: "tara", language: nil)
        #expect(fm.fileExists(atPath: sub.appendingPathComponent("chunks/000.wav").path))
    }

    // MARK: - Helpers

    static func tempBundle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-streamcache-\(UUID().uuidString).ttsnarration",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a hand-baked bundle inside `bundleURL/voices/<slug>/` for the
    /// given `(voice, language)` — the new sub-bundle layout.
    static func buildHandSubBundle(
        at bundleURL: URL,
        modelID: String,
        voice: String?,
        language: String?,
        sourceText: String
    ) throws {
        let subURL = TTSPreparedNarration.subBundleURL(
            in: bundleURL, voice: voice, language: language
        )
        try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        try buildHandBundleInternal(
            at: subURL,
            modelID: modelID,
            voice: voice,
            language: language,
            sourceText: sourceText
        )
    }

    static func buildHandBundle(
        at bundleURL: URL,
        modelID: String,
        voice: String,
        sourceText: String
    ) throws {
        try buildHandBundleInternal(
            at: bundleURL,
            modelID: modelID,
            voice: voice,
            language: nil,
            sourceText: sourceText
        )
    }

    private static func buildHandBundleInternal(
        at bundleURL: URL,
        modelID: String,
        voice: String?,
        language: String?,
        sourceText: String
    ) throws {
        // Two chunks: "Hello world" (0..<11), "from TTSMLX" (12..<23)
        let chunk0Text = "Hello world"
        let chunk1Text = "from TTSMLX"
        let chunk0Duration: TimeInterval = 0.3
        let chunk1Duration: TimeInterval = 0.3

        let manifest = TTSPreparedNarrationManifest(
            modelID: modelID,
            voice: voice,
            language: language,
            sourceText: sourceText,
            sampleRate: 22_050,
            chunks: [
                .init(
                    index: 0,
                    audioFile: "chunks/000.wav",
                    characterRange: .init(start: 0, end: 11),
                    text: chunk0Text,
                    duration: chunk0Duration,
                    wordTimings: [
                        .init(characterRange: .init(start: 0, end: 5), offset: 0, duration: 0.15),
                        .init(characterRange: .init(start: 6, end: 11), offset: 0.15, duration: 0.15)
                    ]
                ),
                .init(
                    index: 1,
                    audioFile: "chunks/001.wav",
                    characterRange: .init(start: 12, end: 23),
                    text: chunk1Text,
                    duration: chunk1Duration,
                    wordTimings: [
                        .init(characterRange: .init(start: 0, end: 4), offset: 0, duration: 0.12),
                        .init(characterRange: .init(start: 5, end: 11), offset: 0.12, duration: 0.18)
                    ]
                )
            ]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()
        try TTSPreparedNarrationTests.writeSineChunk(
            at: bundleURL.appendingPathComponent("chunks/000.wav"),
            durationSeconds: chunk0Duration
        )
        try TTSPreparedNarrationTests.writeSineChunk(
            at: bundleURL.appendingPathComponent("chunks/001.wav"),
            durationSeconds: chunk1Duration
        )
    }
}
#endif
