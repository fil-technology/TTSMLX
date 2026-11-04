import Foundation
import Testing
@testable import TTSMLX

@Suite("Narration toolkit")
struct TTSNarrationToolkitTests {
    @Test("pause markers split the text and add up")
    func pauseTags() {
        let parts = TTSPauseTag.split("Breathe in. [pause 0.8s] Hold. [pause 500ms][pause 0.5s] Out.")
        #expect(parts.map(\.text) == ["Breathe in.", "Hold.", "Out."])
        #expect(parts.map(\.pauseAfter) == [0.8, 1.0, 0])
        #expect(TTSPauseTag.split("No tags").map(\.text) == ["No tags"])
        #expect(TTSPauseTag.split("[pause 1s] Lead-in silence").map(\.pauseAfter) == [1, 0])
        #expect(TTSPauseTag.contains("a [PAUSE 2S] b") && !TTSPauseTag.contains("a [pause] b"))
        #expect(TTSPauseTag.marker(0.8) == "[pause 0.80s]")
    }

    @Test("analysis reports peak, level and silences")
    func analysis() {
        let rate = 1000
        var samples = [Float](repeating: 0, count: 250)          // 0.25 s lead
        samples += (0..<1000).map { 0.5 * sinf(Float($0) * 0.3) }  // 1 s tone, peak 0.5
        samples += [Float](repeating: 0, count: 500)              // 0.5 s tail
        let a = TTSAudioAnalysis.analyze(samples: samples, sampleRate: rate)
        #expect(abs(a.duration - 1.75) < 0.001)
        #expect(abs(a.peak - 0.5) < 0.01 && abs(a.peakDBFS - (-6.02)) < 0.1)
        #expect(a.rmsDBFS < a.peakDBFS && a.rmsDBFS > -20)
        #expect(abs(a.leadingSilence - 0.25) < 0.01 && abs(a.trailingSilence - 0.5) < 0.01)
        let empty = TTSAudioAnalysis.analyze(samples: [], sampleRate: rate)
        #expect(empty.duration == 0 && empty.peak == 0)
    }

    @Test("time-stretch changes the length, not the pitch, and clamps the ratio")
    func timeStretch() throws {
        let rate = 24_000
        let tone = (0..<rate).map { 0.4 * sinf(2 * .pi * 220 * Float($0) / Float(rate)) }
        let faster = try TTSAudioProcessing.timeStretch(tone, sampleRate: rate, rate: 2)
        #expect(abs(Double(faster.count) / Double(rate) - 0.5) < 0.05)
        let slower = try TTSAudioProcessing.timeStretch(tone, sampleRate: rate, rate: 0.8)
        #expect(abs(Double(slower.count) / Double(rate) - 1.25) < 0.05)
        #expect(try TTSAudioProcessing.timeStretch(tone, sampleRate: rate, rate: 1).count == tone.count)
        let peak = faster.map(abs).max() ?? 0
        #expect(peak > 0.2 && peak < 0.6)
    }

    @Test("rate and target duration are applied by the timing pass")
    func timingPass() throws {
        let rate = 24_000
        let tone = (0..<rate * 2).map { 0.3 * sinf(Float($0) * 0.05) }
        let model = TTSMLX.modelCatalog.first { $0.id == "mlx-community/chatterbox-4bit" }!.descriptor!
        let fit = try TTSSpeechSynthesizer.applyTiming(tone, sampleRate: rate, options: .init(targetDuration: 1.0), model: model)
        #expect(abs(Double(fit.count) / Double(rate) - 1.0) < 0.05)
        let fast = try TTSSpeechSynthesizer.applyTiming(tone, sampleRate: rate, options: .init(speed: .fast), model: model)
        #expect(fast.count < tone.count)
        // Kokoro applies the rate itself, so the pass leaves the samples alone.
        let kokoro = TTSMLX.modelCatalog.first { $0.id == "mlx-community/Kokoro-82M-bf16" }!.descriptor!
        #expect(try TTSSpeechSynthesizer.applyTiming(tone, sampleRate: rate, options: .init(rate: 1.5), model: kokoro).count == tone.count)
    }

    @Test("options expose the new knobs and key the cache on them")
    func options() {
        let o = TTSSynthesisOptions(speed: .slow, rate: 1.1, targetDuration: 2.8, seed: 7, expressiveness: 0.3, voiceGuidance: 0.6)
        #expect(o.hasControls && o.effectiveRate == 1.1)
        #expect(TTSSynthesisOptions(speed: .slow).effectiveRate == TTSSpeed.slow.rate)
        #expect(o.controlsCacheSuffix.contains("seed=7") && o.controlsCacheSuffix.contains("target=2.8"))
        #expect(TTSSynthesisOptions().controlsCacheSuffix.isEmpty)
        let chatterbox = TTSMLX.modelCatalog.first { $0.id == "mlx-community/chatterbox-4bit" }!.descriptor!
        #expect(chatterbox.capabilities.maxCharactersPerTake == 300)
    }

    @Test("synthesized audio converts to a PCM buffer and reports segments")
    func synthesizedAudio() throws {
        let audio = TTSSynthesizedAudio(
            samples: [Float](repeating: 0.1, count: 2400), sampleRate: 24_000,
            analysis: .analyze(samples: [Float](repeating: 0.1, count: 2400), sampleRate: 24_000),
            segments: [TTSSegment(index: 0, text: "a", start: 0, duration: 0.1)], modelID: "x/y", generationDuration: 0)
        #expect(audio.pcmBuffer?.frameLength == 2400)
        #expect(abs(audio.duration - 0.1) < 0.001 && audio.segments[0].end == 0.1)
    }
}
