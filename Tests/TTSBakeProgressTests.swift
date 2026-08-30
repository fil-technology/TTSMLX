import Foundation
import Testing
@testable import TTSMLX

/// Covers the resumable-bake visibility API.
///
/// Baking is already resumable — chunks are written as they finish and skipped
/// on a later pass — but an app could not see how far it had got, so it could
/// not tell the user "open the app to finish preparing this article" or decide
/// whether a bundle was playable offline.
@Suite("Narration bake progress")
struct TTSBakeProgressTests {

    private func makeBundle(
        chunkCount: Int,
        present: [Int],
        chunkDuration: TimeInterval = 2.0
    ) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = TTSPreparedNarration.subBundleURL(in: bundle, voice: nil, language: nil)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let chunks = (0 ..< chunkCount).map { index in
            TTSPreparedNarrationManifest.ChunkEntry(
                index: index,
                audioFile: "chunks/\(index).wav",
                characterRange: .init(start: index * 10, end: (index + 1) * 10),
                text: "chunk \(index) text",
                duration: chunkDuration,
                wordTimings: []
            )
        }
        let manifest = TTSPreparedNarrationManifest(
            modelID: "test/model", voice: nil, language: nil,
            sourceText: String(repeating: "word ", count: chunkCount * 2),
            sampleRate: 48_000, chunks: chunks
        )
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("manifest.json"))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("chunks", isDirectory: true),
            withIntermediateDirectories: true
        )
        for index in present {
            try Data(repeating: 0, count: 128)
                .write(to: root.appendingPathComponent("chunks/\(index).wav"))
        }
        return bundle
    }

    @Test("reports partial progress for an interrupted bake")
    func partialBakeReportsProgress() throws {
        let bundle = try makeBundle(chunkCount: 5, present: [0, 1])
        defer { try? FileManager.default.removeItem(at: bundle) }

        let progress = try #require(TTSPreparedNarration.bakeProgress(at: bundle))
        #expect(progress.completedChunks == 2)
        #expect(progress.totalChunks == 5)
        #expect(!progress.isComplete)
        #expect(abs(progress.fractionCompleted - 0.4) < 1e-9)
        #expect(abs(progress.bakedDuration - 4.0) < 1e-9, "two 2s chunks")
    }

    @Test("reports completion when every chunk is on disk")
    func completeBakeIsComplete() throws {
        let bundle = try makeBundle(chunkCount: 3, present: [0, 1, 2])
        defer { try? FileManager.default.removeItem(at: bundle) }

        let progress = try #require(TTSPreparedNarration.bakeProgress(at: bundle))
        #expect(progress.isComplete)
        #expect(progress.fractionCompleted == 1.0)
    }

    /// A chunk interrupted mid-write leaves a zero-byte file. Counting it would
    /// make a bundle look ready and then play silence.
    @Test("a zero-byte chunk counts as not baked")
    func truncatedChunkIsNotCounted() throws {
        let bundle = try makeBundle(chunkCount: 3, present: [0, 1])
        defer { try? FileManager.default.removeItem(at: bundle) }
        let root = TTSPreparedNarration.subBundleURL(in: bundle, voice: nil, language: nil)
        try Data().write(to: root.appendingPathComponent("chunks/2.wav"))

        let progress = try #require(TTSPreparedNarration.bakeProgress(at: bundle))
        #expect(progress.completedChunks == 2, "zero-byte chunk must not count")
        #expect(!progress.isComplete)
    }

    @Test("no manifest means nothing baked yet")
    func missingBundleReportsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(TTSPreparedNarration.bakeProgress(at: missing) == nil)
    }

    @Test("progress is per voice variant")
    func progressIsVariantScoped() throws {
        let bundle = try makeBundle(chunkCount: 2, present: [0, 1])
        defer { try? FileManager.default.removeItem(at: bundle) }
        // The baked variant is the default one; a different voice has its own
        // sub-bundle and has not been baked at all.
        #expect(TTSPreparedNarration.bakeProgress(at: bundle)?.isComplete == true)
        #expect(TTSPreparedNarration.bakeProgress(at: bundle, voice: "en_news") == nil)
    }
}
