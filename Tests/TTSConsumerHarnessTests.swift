#if canImport(AVFoundation)
import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TTSMLX

/// Consumer-style end-to-end harness for the v0.5 additions.
///
/// These tests don't load an MLX model — they're not benchmarks. They drive
/// the public surface the way ReadMeBook (or any downstream app) would, to
/// catch ergonomics regressions: bad defaults, missing parameters, async
/// edges that bite at the call site.
///
/// Each test mirrors a real consumer flow rather than a single API.
@MainActor
@Suite("Consumer harness — v0.5 additions")
struct TTSConsumerHarnessTests {
    /// Scenario: app shows a scrubber UI for a chapter that was pre-generated
    /// to a single file. It needs `duration`, a time pulse, and `seek(to:)`.
    @Test("file scrubber flow: duration, timePulse, seek round-trip")
    func fileScrubberFlow() async throws {
        let url = try TTSPlaybackControllerTests.makeSineFile(durationSeconds: 1.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let playback = TTSPlaybackController(rate: 1.0)
        try playback.play(file: url)

        // 1. Duration should be available immediately for UI binding.
        let duration = try #require(playback.duration)
        #expect(abs(duration - 1.5) < 0.05)

        // 2. timePulse drives the scrubber. Collect a few ticks.
        let pulse = playback.timePulse(interval: 0.05)
        var ticks: [TimeInterval] = []
        let collector = Task { @MainActor () -> [TimeInterval] in
            for await t in pulse {
                ticks.append(t)
                if ticks.count >= 3 { break }
            }
            return ticks
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let collected = await collector.value
        #expect(collected.count >= 1)

        // 3. User drags the scrubber forward. Seek must succeed and not crash.
        try playback.seek(to: 0.8)
        #expect(playback.currentTime >= 0)

        // 4. User drags to the end → playback should finish gracefully.
        var ended = false
        try playback.play(file: url) { ended = true }
        try playback.seek(to: 999)
        #expect(ended)
        #expect(playback.state == .idle)
    }

    /// Scenario: app needs word-level highlighting against the chunks emitted
    /// by `synthesizeLong`. Without running the model, validate the helper
    /// produces well-formed timings that tile the chunk duration exactly.
    @Test("highlight flow: chunkInfos → wordTimings tile exactly")
    func highlightFlow() {
        let text = "The quick brown fox jumps over the lazy dog. Then it rests."
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 30,
            followupChunkCharacterLimit: 40
        )
        let chunks = chunker.chunkInfos(for: text)
        #expect(!chunks.isEmpty)

        for chunk in chunks {
            // Simulate "this chunk played for 1.234s" → ask for word timings.
            let timings = chunk.wordTimings(forDuration: 1.234)
            guard !timings.isEmpty else { continue }
            // Ranges fall inside the chunk's own range in the original text.
            for t in timings {
                #expect(t.characterRange.lowerBound >= chunk.characterRange.lowerBound)
                #expect(t.characterRange.upperBound <= chunk.characterRange.upperBound)
            }
            // Last timing's end equals the chunk's reported duration.
            let last = timings.last!
            #expect(abs((last.offset + last.duration) - 1.234) < 1e-9)
        }
    }

    /// Scenario: SwiftUI consumer wires the event stream into an `.task {}`
    /// modifier instead of using NotificationCenter. The stream must deliver
    /// every emitted event in order, and finish cleanly when the consumer
    /// breaks out.
    @Test("SwiftUI flow: events() stream delivers ordered diagnostics")
    func swiftUIEventsFlow() async {
        let synthesizer = TTSSpeechSynthesizer()
        let stream = await synthesizer.events()

        let collector = Task { @MainActor () -> [String] in
            var ids: [String] = []
            for await event in stream {
                if case let .modelUnloaded(id) = event {
                    ids.append(id)
                }
                if ids.count >= 3 { break }
            }
            return ids
        }

        for id in ["alpha", "beta", "gamma"] {
            await synthesizer._markWarmedInternal(id)
            await synthesizer.unload(id)
        }

        let ids = await collector.value
        #expect(ids == ["alpha", "beta", "gamma"])
    }

    /// Scenario: app uses both the closure handler (legacy) AND the events()
    /// stream (new). Both should receive every event without one starving the
    /// other. This guards against an implementation where the stream replaces
    /// the closure instead of augmenting it.
    @Test("dual-subscriber flow: closure + events() both fire")
    func dualSubscriberFlow() async {
        let counter = TestCounter()
        let synthesizer = TTSSpeechSynthesizer(diagnosticHandler: { _ in
            Task { await counter.increment() }
        })
        let stream = await synthesizer.events()
        let streamCollector = Task {
            for await _ in stream { return }
        }

        await synthesizer._markWarmedInternal("m")
        await synthesizer.unload("m")
        _ = await streamCollector.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        let closureCount = await counter.value
        #expect(closureCount == 1)
    }
}

/// Actor-isolated counter for the dual-subscriber test. Avoids `@MainActor` /
/// `@Sendable` impedance inside the legacy closure handler.
actor TestCounter {
    var value: Int = 0
    func increment() { value += 1 }
}
#endif
