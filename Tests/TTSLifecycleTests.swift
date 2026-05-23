import Foundation
import Testing
@testable import TTSMLX

/// These tests verify the warmed-state tracking and diagnostic emission on
/// the synthesizer's lifecycle API without actually invoking MLX. We can't
/// run a real model in unit tests (no GPU, no network for downloads), so we
/// poke the actor's state-tracking surface directly.
@Suite("TTSSpeechSynthesizer lifecycle")
struct TTSLifecycleTests {
    @Test("isLoaded reflects the warmed set")
    func warmedSet() async {
        let synth = TTSSpeechSynthesizer()
        let id = "fake/model"
        #expect(!(await synth.isLoaded(id)))
        await synth.markWarmedForTesting(id)
        #expect(await synth.isLoaded(id))
        await synth.unload(id)
        #expect(!(await synth.isLoaded(id)))
    }

    @Test("unload emits a modelUnloaded diagnostic only when a model was warmed")
    func unloadEmitsOnceWhenPresent() async {
        let collector = DiagnosticCollector()
        let synth = TTSSpeechSynthesizer(diagnosticHandler: { event in
            collector.append(event)
        })

        await synth.unload("never-warmed")
        #expect(collector.snapshot().isEmpty)

        await synth.markWarmedForTesting("foo")
        await synth.unload("foo")
        let events = collector.snapshot()
        #expect(events.count == 1)
        if case .modelUnloaded(let id) = events[0] {
            #expect(id == "foo")
        } else {
            Issue.record("expected modelUnloaded, got \(events[0])")
        }
    }

    @Test("unloadAll emits one diagnostic per warmed model")
    func unloadAllEmitsForEach() async {
        let collector = DiagnosticCollector()
        let synth = TTSSpeechSynthesizer(diagnosticHandler: { event in
            collector.append(event)
        })

        for id in ["a", "b", "c"] {
            await synth.markWarmedForTesting(id)
        }
        await synth.unloadAll()
        let unloads = collector.snapshot().compactMap { event -> String? in
            if case .modelUnloaded(let id) = event { return id }
            return nil
        }
        #expect(Set(unloads) == ["a", "b", "c"])
        #expect(!(await synth.isLoaded("a")))
    }

    @Test("handleMemoryWarning clears warmed set")
    func memoryWarning() async {
        let synth = TTSSpeechSynthesizer()
        await synth.markWarmedForTesting("hot-model")
        await synth.handleMemoryWarning()
        #expect(!(await synth.isLoaded("hot-model")))
    }

    @Test("setDiagnosticHandler swaps the receiver at runtime")
    func swapHandler() async {
        let firstCollector = DiagnosticCollector()
        let secondCollector = DiagnosticCollector()

        let synth = TTSSpeechSynthesizer(diagnosticHandler: { event in
            firstCollector.append(event)
        })

        await synth.markWarmedForTesting("x")
        await synth.unload("x")
        #expect(firstCollector.snapshot().count == 1)

        await synth.setDiagnosticHandler { event in
            secondCollector.append(event)
        }
        await synth.markWarmedForTesting("y")
        await synth.unload("y")
        #expect(secondCollector.snapshot().count == 1)
        // First collector should be unchanged.
        #expect(firstCollector.snapshot().count == 1)
    }
}

// MARK: - Helpers

/// Thread-safe collector for diagnostics. Each `append` is synchronized via
/// `NSLock`. Tests grab a snapshot to assert.
final class DiagnosticCollector: @unchecked Sendable {
    private var events: [TTSDiagnostic] = []
    private let lock = NSLock()

    func append(_ event: TTSDiagnostic) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [TTSDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

extension TTSSpeechSynthesizer {
    /// Test-only: bypasses the real download/load pipeline so the lifecycle
    /// API can be exercised without touching the filesystem or MLX.
    func markWarmedForTesting(_ id: String) {
        // Re-uses the same internal storage as warmUp() does.
        // We can do this because the test target uses @testable import.
        _markWarmedInternal(id)
    }
}
