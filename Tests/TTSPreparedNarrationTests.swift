#if canImport(AVFoundation)
import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TTSMLX

/// Tests for the v0.5 narration-bundle additions.
///
/// These tests assemble bundles by hand (without invoking the MLX model)
/// because the runtime side — import → play → highlight — should not depend
/// on MLX. The author-time `synthesizer.prepareNarration` path is exercised
/// indirectly: we build the same on-disk shape it would produce and verify
/// the import + playback path accepts it.
@MainActor
@Suite("TTSPreparedNarration")
struct TTSPreparedNarrationTests {
    @Test("export → import round-trip preserves the manifest")
    func roundTrip() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model",
            voice: "tara",
            language: "en",
            sourceText: "Hello world from TTSMLX.",
            sampleRate: 22_050,
            chunks: [
                .init(
                    index: 0,
                    audioFile: "chunks/000.wav",
                    characterRange: .init(start: 0, end: 23),
                    text: "Hello world from TTSMLX",
                    duration: 1.5,
                    wordTimings: [
                        .init(characterRange: .init(start: 0, end: 5), offset: 0.0, duration: 0.5),
                        .init(characterRange: .init(start: 6, end: 11), offset: 0.5, duration: 0.5),
                        .init(characterRange: .init(start: 12, end: 16), offset: 1.0, duration: 0.2),
                        .init(characterRange: .init(start: 17, end: 23), offset: 1.2, duration: 0.3)
                    ]
                )
            ]
        )
        let original = TTSPreparedNarration(manifest: manifest, baseURL: bundleURL)
        try original.writeManifest()
        try Self.writeSineChunk(at: bundleURL.appendingPathComponent("chunks/000.wav"),
                                durationSeconds: 1.5)

        let imported = try TTSPreparedNarration(importing: bundleURL)
        #expect(imported.manifest.modelID == "test/model")
        #expect(imported.manifest.voice == "tara")
        #expect(imported.manifest.chunks.count == 1)
        #expect(imported.manifest.chunks[0].wordTimings.count == 4)
        #expect(imported.totalDuration == 1.5)
    }

    @Test("import rejects bundles with a schemaVersion newer than supported")
    func rejectsFutureSchema() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manifest = TTSPreparedNarrationManifest(
            schemaVersion: 999,
            modelID: "m",
            sourceText: "x",
            sampleRate: 22_050,
            chunks: []
        )
        let bundle = TTSPreparedNarration(manifest: manifest, baseURL: bundleURL)
        try bundle.writeManifest()

        var caught = false
        do { _ = try TTSPreparedNarration(importing: bundleURL) }
        catch TTSPreparedNarrationError.schemaVersionTooNew(let bv, let sv) {
            caught = true
            #expect(bv == 999)
            #expect(sv == TTSPreparedNarrationManifest.currentSchemaVersion)
        } catch { Issue.record("wrong error: \(error)") }
        #expect(caught)
    }

    @Test("import fails fast when a referenced chunk audio file is missing")
    func failsOnMissingAudio() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        // Pre-create the chunks subdir but don't write the wav.
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("chunks"),
            withIntermediateDirectories: true
        )

        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            sourceText: "x",
            sampleRate: 22_050,
            chunks: [.init(
                index: 0,
                audioFile: "chunks/000.wav",
                characterRange: .init(start: 0, end: 1),
                text: "x",
                duration: 0.1,
                wordTimings: []
            )]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()

        var caught = false
        do { _ = try TTSPreparedNarration(importing: bundleURL) }
        catch TTSPreparedNarrationError.chunkAudioMissing(let idx, _) {
            caught = true
            #expect(idx == 0)
        } catch { Issue.record("wrong error: \(error)") }
        #expect(caught)
    }

    @Test("flattenedWordTimeline re-anchors character ranges to original text")
    func flattenReanchors() {
        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            sourceText: "abcdefghij",
            sampleRate: 22_050,
            chunks: [
                .init(
                    index: 0,
                    audioFile: "chunks/000.wav",
                    characterRange: .init(start: 0, end: 5),
                    text: "abcde",
                    duration: 0.5,
                    wordTimings: [
                        // Chunk-local 0..5 → original 0..5
                        .init(characterRange: .init(start: 0, end: 5), offset: 0, duration: 0.5)
                    ]
                ),
                .init(
                    index: 1,
                    audioFile: "chunks/001.wav",
                    characterRange: .init(start: 5, end: 10),
                    text: "fghij",
                    duration: 0.5,
                    wordTimings: [
                        // Chunk-local 0..5 → original 5..10
                        .init(characterRange: .init(start: 0, end: 5), offset: 0, duration: 0.5)
                    ]
                )
            ]
        )
        let narration = TTSPreparedNarration(
            manifest: manifest,
            baseURL: URL(fileURLWithPath: "/tmp/x")
        )
        let timeline = narration.flattenedWordTimeline()
        #expect(timeline.count == 2)
        #expect(timeline[0].characterRange == 0..<5)
        #expect(timeline[0].offset == 0)
        #expect(timeline[1].characterRange == 5..<10) // re-anchored
        #expect(timeline[1].offset == 0.5)            // cumulative offset
    }

    @Test("play(narration:) reports total duration across all chunks")
    func playReportsTotalDuration() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let narration = try Self.makeTwoChunkBundle(at: bundleURL,
                                                    chunk0: 0.4, chunk1: 0.6)
        let playback = TTSPlaybackController()
        try playback.play(narration: narration)
        let dur = try #require(playback.duration)
        #expect(abs(dur - 1.0) < 0.01)
        playback.stop()
        #expect(playback.duration == nil)
    }

    @Test("play(narration:onWord:) fires every word in declaration order")
    func playFiresOnWord() async throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let narration = try Self.makeTwoChunkBundle(at: bundleURL,
                                                    chunk0: 0.3, chunk1: 0.3)
        let playback = TTSPlaybackController()

        let firedCounter = WordCounter()
        try playback.play(narration: narration) { word in
            Task { await firedCounter.record(word.characterRange) }
        }
        // Poll until every word has fired (or a generous ceiling) rather than a
        // fixed sleep: the audio engine's start-up latency varies — a tight
        // margin flakes on loaded/headless CI where no callbacks land in time.
        let expected = narration.flattenedWordTimeline().map { $0.characterRange }
        let fired = await waitForWords(firedCounter, expecting: expected.count)
        #expect(fired == expected)
    }

    @Test("subBundleSlug sanitizes voice and language components")
    func subBundleSlugSanitizes() {
        #expect(TTSPreparedNarration.subBundleSlug(voice: "Jean Valjean", language: nil) == "jean_valjean.auto")
        #expect(TTSPreparedNarration.subBundleSlug(voice: nil, language: nil) == "auto.auto")
        #expect(TTSPreparedNarration.subBundleSlug(voice: "alba", language: "en-US") == "alba.en-US".lowercased())
        #expect(TTSPreparedNarration.subBundleSlug(voice: "tara", language: "en") == "tara.en")
    }

    @Test("availableVariants returns each sub-bundle written under voices/")
    func availableVariantsListsSubBundles() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try Self.writeMinimalSubBundle(at: bundleURL, voice: "jean", language: "en")
        try Self.writeMinimalSubBundle(at: bundleURL, voice: "alba", language: "en")
        try Self.writeMinimalSubBundle(at: bundleURL, voice: nil, language: nil)

        let variants = TTSPreparedNarration.availableVariants(at: bundleURL)
        #expect(variants.count == 3)
        let pairs = Set(variants.map { "\($0.voice ?? "nil"):\($0.language ?? "nil")" })
        #expect(pairs.contains("jean:en"))
        #expect(pairs.contains("alba:en"))
        #expect(pairs.contains("nil:nil"))
    }

    @Test("availableVariants returns empty for a bundle without voices/ dir")
    func availableVariantsEmptyWhenMissing() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        #expect(TTSPreparedNarration.availableVariants(at: bundleURL).isEmpty)
    }

    @Test("init(importing:voice:language:) resolves the correct sub-bundle")
    func initWithVoiceResolvesSubBundle() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try Self.writeMinimalSubBundle(at: bundleURL, voice: "jean", language: "en")
        try Self.writeMinimalSubBundle(at: bundleURL, voice: "alba", language: "en")

        let jean = try TTSPreparedNarration(importing: bundleURL, voice: "jean", language: "en")
        #expect(jean.manifest.voice == "jean")
        #expect(jean.manifest.language == "en")
        let alba = try TTSPreparedNarration(importing: bundleURL, voice: "alba", language: "en")
        #expect(alba.manifest.voice == "alba")
    }

    @Test("legacy init(importing:) still reads root-level manifests")
    func legacyInitStillWorks() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            voice: "v",
            sourceText: "x",
            sampleRate: 22_050,
            chunks: []
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()

        let imported = try TTSPreparedNarration(importing: bundleURL)
        #expect(imported.manifest.voice == "v")
        #expect(imported.baseURL == bundleURL)
    }

    @Test("init(importing:voice:language:) auto-migrates a matching legacy bundle")
    func initWithVoiceMigratesLegacy() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Build legacy layout: manifest.json + chunks/000.wav at root.
        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            voice: "jean",
            language: "en",
            sourceText: "x",
            sampleRate: 22_050,
            chunks: [.init(
                index: 0,
                audioFile: "chunks/000.wav",
                characterRange: .init(start: 0, end: 1),
                text: "x",
                duration: 0.1,
                wordTimings: []
            )]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()
        try Self.writeSineChunk(at: bundleURL.appendingPathComponent("chunks/000.wav"),
                                durationSeconds: 0.1)

        let imported = try TTSPreparedNarration(importing: bundleURL, voice: "jean", language: "en")
        #expect(imported.manifest.voice == "jean")
        let sub = TTSPreparedNarration.subBundleURL(in: bundleURL, voice: "jean", language: "en")
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("chunks/000.wav").path))
        #expect(!FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
    }

    @Test("init(importing:voice:language:) leaves mismatched legacy alone and errors")
    func initWithVoiceLeavesMismatchedLegacy() throws {
        let bundleURL = try Self.makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let manifest = TTSPreparedNarrationManifest(
            modelID: "m",
            voice: "jean",
            language: "en",
            sourceText: "x",
            sampleRate: 22_050,
            chunks: []
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: bundleURL).writeManifest()

        var caught = false
        do { _ = try TTSPreparedNarration(importing: bundleURL, voice: "alba", language: "en") }
        catch TTSPreparedNarrationError.manifestMissing { caught = true }
        catch { Issue.record("wrong error: \(error)") }
        #expect(caught)
        // Legacy manifest untouched.
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
    }

    // MARK: - Helpers

    /// Writes a minimal valid sub-bundle (manifest + one tiny wav) at
    /// `bundleURL/voices/<slug>/` for the given `(voice, language)`.
    static func writeMinimalSubBundle(
        at bundleURL: URL,
        voice: String?,
        language: String?
    ) throws {
        let subURL = TTSPreparedNarration.subBundleURL(in: bundleURL, voice: voice, language: language)
        try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model",
            voice: voice,
            language: language,
            sourceText: "x",
            sampleRate: 22_050,
            chunks: [.init(
                index: 0,
                audioFile: "chunks/000.wav",
                characterRange: .init(start: 0, end: 1),
                text: "x",
                duration: 0.1,
                wordTimings: []
            )]
        )
        try TTSPreparedNarration(manifest: manifest, baseURL: subURL).writeManifest()
        try writeSineChunk(at: subURL.appendingPathComponent("chunks/000.wav"),
                           durationSeconds: 0.1)
    }

    static func makeTempBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-narration-\(UUID().uuidString).ttsnarration", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeSineChunk(
        at url: URL,
        durationSeconds: Double,
        sampleRate: Double = 22_050
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let frames = AVAudioFrameCount(durationSeconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                channel[i] = Float(sin(Double(i) / sampleRate * 2 * .pi * 440) * 0.1)
            }
        }
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)
    }

    /// Bundle with two chunks: chunk 0 covers "Hello world" (range 0..11) and
    /// chunk 1 covers "from TTSMLX" (range 12..23) of the source text.
    static func makeTwoChunkBundle(
        at bundleURL: URL,
        chunk0: Double,
        chunk1: Double
    ) throws -> TTSPreparedNarration {
        let sourceText = "Hello world from TTSMLX"
        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model",
            voice: "tara",
            sourceText: sourceText,
            sampleRate: 22_050,
            chunks: [
                .init(
                    index: 0,
                    audioFile: "chunks/000.wav",
                    characterRange: .init(start: 0, end: 11),
                    text: "Hello world",
                    duration: chunk0,
                    wordTimings: [
                        .init(characterRange: .init(start: 0, end: 5),
                              offset: 0, duration: chunk0 * 0.5),
                        .init(characterRange: .init(start: 6, end: 11),
                              offset: chunk0 * 0.5, duration: chunk0 * 0.5)
                    ]
                ),
                .init(
                    index: 1,
                    audioFile: "chunks/001.wav",
                    characterRange: .init(start: 12, end: 23),
                    text: "from TTSMLX",
                    duration: chunk1,
                    wordTimings: [
                        .init(characterRange: .init(start: 0, end: 4),
                              offset: 0, duration: chunk1 * 0.4),
                        .init(characterRange: .init(start: 5, end: 11),
                              offset: chunk1 * 0.4, duration: chunk1 * 0.6)
                    ]
                )
            ]
        )
        let narration = TTSPreparedNarration(manifest: manifest, baseURL: bundleURL)
        try narration.writeManifest()
        try writeSineChunk(at: bundleURL.appendingPathComponent("chunks/000.wav"),
                           durationSeconds: chunk0)
        try writeSineChunk(at: bundleURL.appendingPathComponent("chunks/001.wav"),
                           durationSeconds: chunk1)
        return try TTSPreparedNarration(importing: bundleURL)
    }
}

actor WordCounter {
    private(set) var values: [Range<Int>] = []
    func record(_ range: Range<Int>) {
        values.append(range)
    }
}

/// Poll `counter` until it has recorded `expecting` words or a generous ceiling
/// elapses (default ~5s), checking every 50ms. Returns whatever fired. Replaces
/// fixed-duration sleeps in playback highlight tests, which flake on CI when the
/// audio engine is slow to start — the poll exits the instant every word lands,
/// so it stays fast on a warm machine while tolerating a cold one.
func waitForWords(
    _ counter: WordCounter,
    expecting count: Int,
    maxPolls: Int = 100,
    pollNanoseconds: UInt64 = 50_000_000
) async -> [Range<Int>] {
    var fired = await counter.values
    var polls = 0
    while fired.count < count, polls < maxPolls {
        try? await Task.sleep(nanoseconds: pollNanoseconds)
        fired = await counter.values
        polls += 1
    }
    return fired
}
#endif
