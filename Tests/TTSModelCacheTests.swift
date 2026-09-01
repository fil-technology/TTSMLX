import Foundation
import Testing
@preconcurrency import MLX
@preconcurrency import MLXLMCommon
import MLXAudioCore
import MLXAudioTTS
@testable import TTSMLX

/// Tests for the in-memory model-cache management API added for consumers that
/// hold a long-lived synthesizer: `preload`, `unloadCachedModels`, and the
/// `maxResidentModels` LRU residency cap.
///
/// The real load path needs MLX/Metal, which `swift test` cannot bring up, so
/// these exercise the lifecycle bookkeeping through the same kind of test seam
/// the existing lifecycle tests use — no model weights are loaded.
@Suite("TTSSpeechSynthesizer model cache")
struct TTSModelCacheTests {

    @Test("unloadCachedModels drops the warmed set and emits one diagnostic each")
    func unloadCachedModelsEmitsForEach() async {
        let collector = DiagnosticCollector()
        let synth = TTSSpeechSynthesizer(diagnosticHandler: { collector.append($0) })

        for id in ["a", "b", "c"] {
            await synth._markWarmedInternal(id)
        }
        await synth.unloadCachedModels()

        let unloaded = collector.snapshot().compactMap { event -> String? in
            if case .modelUnloaded(let id) = event { return id }
            return nil
        }
        #expect(Set(unloaded) == ["a", "b", "c"])
        #expect(!(await synth.isLoaded("a")))
    }

    @Test("the maxResidentModels init parameter is optional and defaults safely")
    func initParamIsAdditive() async {
        // Existing call shapes still compile (no breaking change).
        _ = TTSSpeechSynthesizer()
        _ = TTSSpeechSynthesizer(diagnosticHandler: { _ in })
        // New knob.
        let synth = TTSSpeechSynthesizer(maxResidentModels: 3)
        let snap = await synth.snapshot()
        #expect(snap.warmedModelIDs.isEmpty)
    }

    @Test("residency cap of 1 evicts the least-recently-used model on a second load")
    func residencyCapOne() async {
        let collector = DiagnosticCollector()
        let synth = TTSSpeechSynthesizer(diagnosticHandler: { collector.append($0) })

        await synth._insertLoadedModelForTesting("model-a", StubSpeechModel())
        #expect(await synth.isLoaded("model-a"))

        // Loading a second model with the default cap (1) evicts the first.
        await synth._insertLoadedModelForTesting("model-b", StubSpeechModel())
        #expect(await synth.isLoaded("model-b"))
        #expect(!(await synth.isLoaded("model-a")))

        let unloaded = collector.snapshot().compactMap { event -> String? in
            if case .modelUnloaded(let id) = event { return id }
            return nil
        }
        #expect(unloaded.contains("model-a"))
    }

    @Test("a higher cap keeps multiple models resident and evicts LRU beyond it")
    func residencyCapMultiple() async {
        let synth = TTSSpeechSynthesizer(maxResidentModels: 2)

        await synth._insertLoadedModelForTesting("a", StubSpeechModel())
        await synth._insertLoadedModelForTesting("b", StubSpeechModel())
        // a and b both resident.
        #expect(await synth.isLoaded("a"))
        #expect(await synth.isLoaded("b"))

        // Touch "a" so "b" becomes the least-recently-used, then load "c":
        // "b" should be evicted, "a" and "c" kept.
        await synth._insertLoadedModelForTesting("a", StubSpeechModel())
        await synth._insertLoadedModelForTesting("c", StubSpeechModel())
        #expect(await synth.isLoaded("a"))
        #expect(await synth.isLoaded("c"))
        #expect(!(await synth.isLoaded("b")))
    }
}

/// Minimal `SpeechGenerationModel` that never generates — only used to occupy a
/// residency slot. Its generation members are unreachable in these tests.
final class StubSpeechModel: SpeechGenerationModel, @unchecked Sendable {
    var sampleRate: Int { 24_000 }
    var defaultGenerationParameters: GenerateParameters { fatalError("unused in cache tests") }

    func generate(
        text: String, voice: String?, refAudio: MLXArray?, refText: String?,
        language: String?, generationParameters: GenerateParameters
    ) async throws -> MLXArray { fatalError("unused in cache tests") }

    func generateStream(
        text: String, voice: String?, refAudio: MLXArray?, refText: String?,
        language: String?, generationParameters: GenerateParameters
    ) -> AsyncThrowingStream<AudioGeneration, Error> { fatalError("unused in cache tests") }

    func generateStream(
        text: String, voice: String?, refAudio: MLXArray?, refText: String?,
        language: String?, generationParameters: GenerateParameters, streamingInterval: Double
    ) -> AsyncThrowingStream<AudioGeneration, Error> { fatalError("unused in cache tests") }
}
