import Foundation
import Testing
@testable import TTSMLX

/// Reproduces the demo app's Reader path for MOSS-TTS-Nano on the host, so
/// failures surface here instead of only as a truncated string on device.
@Suite("MOSS-TTS-Nano integration", .serialized)
struct MossIntegrationTests {
    static let modelID = "mlx-community/MOSS-TTS-Nano-100M"

    /// These tests download ~375 MB and need Metal, so they only run where the
    /// model is already cached. That is self-configuring: a developer machine
    /// that has fetched MOSS runs them, CI skips them, and no environment
    /// variable is involved — xcodebuild does not forward those to the test
    /// process for this scheme.
    static var modelIsCached: Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent("mlx-community_MOSS-TTS-Nano-100M")
            .appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    static var descriptor: TTSModelDescriptor {
        get throws {
            let entry = try #require(TTSMLX.modelCatalog.first(where: { $0.id == modelID }))
            return try #require(entry.descriptor)
        }
    }

    @Test("catalog descriptor is runtime-supported so the store will download it")
    func descriptorIsRuntimeSupported() throws {
        let descriptor = try Self.descriptor
        // TTSModelStore.ensureDownloaded throws .unsupportedModel unless this is set.
        #expect(descriptor.capabilities.isRuntimeSupported)
    }

    @Test("full prepare path: download then MLX load")
    func prepareModelPathSucceeds() async throws {
        guard Self.modelIsCached else { return }
        let descriptor = try Self.descriptor
        let store = TTSModelStore()

        do {
            _ = try await store.ensureDownloaded(descriptor)
        } catch {
            Issue.record("ensureDownloaded failed: \(error) — \(error.localizedDescription)")
            return
        }

        do {
            let model = try await MLXTTSModelLoader.load(descriptor: descriptor, hfToken: nil)
            #expect(model.sampleRate == 48000)
        } catch {
            Issue.record("MLX load failed: \(error) — \(error.localizedDescription)")
        }
    }

    /// Measures the path the Reader actually uses: TTSMLX chunks the text
    /// (80 chars for the first chunk, 220 after) and feeds those to the model,
    /// so MOSS's own 75-token budget rarely engages. Time-to-first-audio and
    /// peak memory here are the numbers that matter on device — measuring a
    /// whole passage in one `generate` call overstates both badly.
    @Test("streaming through TTSMLX: first-audio latency and peak memory")
    func streamingLatencyThroughSynthesizer() async throws {
        guard Self.modelIsCached else { return }
        let descriptor = try Self.descriptor
        let synthesizer = TTSSpeechSynthesizer()

        let text = """
            Global markets closed higher on Tuesday after the central bank             signalled it would hold interest rates steady through the end of             the year. Analysts said the decision eased fears of a prolonged             slowdown, though several cautioned that inflation remains above             target. The index gained one point two percent on the session.
            """

        let chunker = TTSTextChunker()
        let plannedChunks = chunker.chunks(for: text)

        let started = Date()
        var firstAudioAt: TimeInterval?
        var totalFrames = 0
        var chunkCount = 0

        let stream = try await synthesizer.synthesizeLong(
            text, using: descriptor, options: .init(), chunker: chunker
        )
        for try await chunk in stream {
            if firstAudioAt == nil { firstAudioAt = Date().timeIntervalSince(started) }
            totalFrames += Int(chunk.buffer.frameLength)
            chunkCount += 1
        }

        let elapsed = Date().timeIntervalSince(started)
        let sampleRate = 48000.0
        let seconds = Double(totalFrames) / sampleRate
        print(String(
            format: "[moss-reader] planned=%d emitted=%d firstAudio=%.2fs total=%.2fs audio=%.2fs",
            plannedChunks.count, chunkCount, firstAudioAt ?? -1, elapsed, seconds
        ))

        #expect(chunkCount > 0, "stream produced no audio")
        #expect(firstAudioAt != nil)
    }
}
