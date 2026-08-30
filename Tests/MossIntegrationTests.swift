import Foundation
import Testing
@preconcurrency import MLX
@testable import TTSMLX

/// Reproduces the demo app's Reader path for MOSS-TTS-Nano on the host, so
/// failures surface here instead of only as a truncated string on device.
@Suite("MOSS-TTS-Nano integration", .serialized)
struct MossIntegrationTests {
    static let modelID = "mlx-community/MOSS-TTS-Nano-100M"

    /// These tests download ~375 MB and need MLX's Metal library, which is
    /// only present under `xcodebuild` — plain `swift test` has no metallib
    /// and would abort the whole run. They are therefore off by default.
    ///
    /// Enable with either:
    ///   * `MOSS_INTEGRATION=1` (works under `swift test`, which forwards the
    ///     environment), or
    ///   * an empty marker file at `Tests/.moss-integration` (works under
    ///     `xcodebuild`, which does not forward the environment for this
    ///     scheme). The marker is gitignored.
    ///
    /// The model must also already be cached; these never trigger a download
    /// as a side effect of an ordinary test run.
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment["MOSS_INTEGRATION"] == "1"
        let marker = FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent(".moss-integration").path
        )
        guard env || marker else { return false }
        return modelIsCached
    }

    static var modelIsCached: Bool {
        let weights = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent("mlx-community_MOSS-TTS-Nano-100M")
            .appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: weights.path)
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
        guard Self.isEnabled else { return }
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
        guard Self.isEnabled else { return }
        let descriptor = try Self.descriptor
        let synthesizer = TTSSpeechSynthesizer()

        let text = """
            Global markets closed higher on Tuesday after the central bank             signalled it would hold interest rates steady through the end of             the year. Analysts said the decision eased fears of a prolonged             slowdown, though several cautioned that inflation remains above             target. The index gained one point two percent on the session.
            """

        let chunker = TTSTextChunker()
        let plannedChunks = chunker.chunks(for: text)

        MLX.GPU.resetPeakMemory()
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
        let peakMB = Double(MLX.GPU.peakMemory) / 1_048_576.0
        let activeMB = Double(MLX.Memory.activeMemory) / 1_048_576.0
        let cacheMB = Double(MLX.Memory.cacheMemory) / 1_048_576.0
        print(String(
            format: "[moss-reader] planned=%d emitted=%d firstAudio=%.2fs total=%.2fs audio=%.2fs "
                  + "peak=%.0fMB active=%.0fMB cache=%.0fMB",
            plannedChunks.count, chunkCount, firstAudioAt ?? -1, elapsed, seconds,
            peakMB, activeMB, cacheMB
        ))

        #expect(chunkCount > 0, "stream produced no audio")
        #expect(firstAudioAt != nil)
    }

    /// The model store used to keep its own table of loadable model types,
    /// parallel to the runtime's registry. When that copy fell behind, an
    /// installed and perfectly loadable model was reported as "unsupported by
    /// the current MLX runtime" in the Synthesize tab. It now defers to the
    /// registry; this guards the regression for MOSS and for every other
    /// family the registry knows about.
    @Test("installed-model discovery agrees with the runtime registry")
    func installedDescriptorIsRuntimeSupported() throws {
        let resolved = TTSModelStore.runtimeSupportedModelType(
            id: Self.modelID.lowercased(),
            tags: [],
            modelType: "moss_tts_nano",
            architectures: ["MossTTSNanoForCausalLM"]
        )
        #expect(resolved == "moss_tts_nano", "store resolved \(String(describing: resolved))")

        // Architecture alone must be enough — a locally discovered model may
        // have a config.json without a usable model_type.
        let fromArchitecture = TTSModelStore.runtimeSupportedModelType(
            id: "someone/local-copy", tags: [], modelType: nil,
            architectures: ["MossTTSNanoForCausalLM"]
        )
        #expect(fromArchitecture == "moss_tts_nano",
                "architecture lookup gave \(String(describing: fromArchitecture))")

        // And the families that were already wired must keep resolving.
        for (type, expected) in [
            ("qwen3_tts", "qwen3_tts"), ("soprano", "soprano"),
            ("pocket_tts", "pocket_tts"), ("kitten_tts", "kitten_tts"),
            ("csm", "csm"), ("llama_tts", "llama_tts"),
        ] {
            #expect(TTSModelStore.runtimeSupportedModelType(
                id: "x/y", tags: [], modelType: type, architectures: []
            ) == expected, "\(type) regressed")
        }
    }

    /// End-to-end check for the timing bug: the `.chunkFinished` durations the
    /// playback observer builds its timeline from must sum to the audio that
    /// was actually produced. They previously reported generation wall-clock,
    /// so the karaoke cursor ran at whatever ratio generation happened to hit.
    @Test("emitted chunk durations equal the audio produced")
    func chunkDurationsMatchAudio() async throws {
        guard Self.isEnabled else { return }
        let descriptor = try Self.descriptor
        let synthesizer = TTSSpeechSynthesizer()

        let text = """
            Global markets closed higher on Tuesday. Analysts said the decision             eased fears of a prolonged slowdown, though several cautioned that             inflation remains above target.
            """

        // Collect the diagnostics the playback controller would consume.
        let events = await synthesizer.events()
        let collector = Task { () -> (durations: [Int: TimeInterval], timings: [TTSWordTiming]) in
            var durations: [Int: TimeInterval] = [:]
            var timings: [TTSWordTiming] = []
            for await event in events {
                switch event {
                case let .chunkFinished(_, index, duration): durations[index] = duration
                case let .chunkTimings(_, _, chunkTimings): timings.append(contentsOf: chunkTimings)
                case .streamingFinished: return (durations, timings)
                default: break
                }
            }
            return (durations, timings)
        }

        var audioFrames = 0
        let stream = try await synthesizer.synthesizeLong(text, using: descriptor, options: .init())
        for try await chunk in stream {
            audioFrames += Int(chunk.buffer.frameLength)
        }
        let audioSeconds = Double(audioFrames) / 48_000.0

        let collected = await collector.value
        let reported = collected.durations.values.reduce(0, +)

        print(String(format: "[moss-timing] audio=%.2fs reported=%.2fs words=%d",
                     audioSeconds, reported, collected.timings.count))

        #expect(audioSeconds > 1, "no audio produced")
        // Within a frame or two of rounding. Before the fix this compared
        // generation wall-clock against audio and was off by seconds.
        #expect(abs(reported - audioSeconds) < 0.05,
                "reported \(reported)s vs actual audio \(audioSeconds)s")

        // And the word timeline must end where the audio ends, so a scrubber
        // driven by it reaches 100%.
        if let last = collected.timings.max(by: { $0.offset < $1.offset }) {
            let end = last.offset + last.duration
            #expect(end <= audioSeconds + 0.05,
                    "timeline ends at \(end)s, past the audio's \(audioSeconds)s")
        }
    }
}
