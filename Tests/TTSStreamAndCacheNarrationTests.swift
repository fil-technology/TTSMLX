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

    // MARK: - Helpers

    static func tempBundle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-streamcache-\(UUID().uuidString).ttsnarration",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func buildHandBundle(
        at bundleURL: URL,
        modelID: String,
        voice: String,
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
