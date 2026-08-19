import Foundation
import Testing
@preconcurrency import MLX
@testable import TTSMLX

/// Exercises the shape a news app uses MOSS in: a batch of briefs generated
/// back to back, then replayed from cache. What this is looking for is not
/// speed but *stability* — memory that climbs across articles is what turns
/// into a jetsam kill on device after the tenth one.
///
/// Enabled the same way as MossIntegrationTests (see `isEnabled` there).
@Suite("MOSS news workload", .serialized)
struct MossNewsWorkloadTests {
    static let articles: [String] = [
        """
        Global markets closed higher on Tuesday after the central bank signalled \
        it would hold interest rates steady through the end of the year.
        """,
        """
        Negotiators worked past midnight on a draft agreement, though officials \
        cautioned that several provisions remain unresolved.
        """,
        """
        The regulator opened an inquiry into the merger, citing concerns about \
        competition in regional distribution networks.
        """,
        """
        Researchers reported a measurable improvement in early detection rates, \
        based on a trial that followed patients for three years.
        """,
        """
        Heavy rainfall closed two motorways overnight. Transport authorities \
        expect delays to continue through the morning commute.
        """,
    ]

    @Test("briefs batch: memory stays flat across articles")
    func briefsBatchDoesNotAccumulateMemory() async throws {
        guard MossIntegrationTests.isEnabled else { return }
        let descriptor = try MossIntegrationTests.descriptor
        let synthesizer = TTSSpeechSynthesizer()

        var perArticle: [(seconds: Double, elapsed: Double, activeMB: Double, peakMB: Double)] = []

        for (index, article) in Self.articles.enumerated() {
            MLX.GPU.resetPeakMemory()
            let started = Date()
            var frames = 0

            let stream = try await synthesizer.synthesizeLong(
                article, using: descriptor, options: .init()
            )
            for try await chunk in stream {
                frames += Int(chunk.buffer.frameLength)
            }

            let elapsed = Date().timeIntervalSince(started)
            let seconds = Double(frames) / 48000.0
            perArticle.append((
                seconds: seconds,
                elapsed: elapsed,
                activeMB: Double(MLX.Memory.activeMemory) / 1_048_576.0,
                peakMB: Double(MLX.GPU.peakMemory) / 1_048_576.0
            ))
            print(String(
                format: "[moss-briefs] #%d audio=%.1fs in %.1fs (%.2fx) active=%.0fMB peak=%.0fMB",
                index + 1, seconds, elapsed, seconds / elapsed,
                perArticle[index].activeMB, perArticle[index].peakMB
            ))
            #expect(seconds > 1.0, "article \(index + 1) produced \(seconds)s")
        }

        // The model is loaded once and reused, so steady-state active memory
        // should not drift upward article to article. A rising floor is the
        // signal that decoded buffers or KV caches are being retained.
        let firstActive = perArticle[0].activeMB
        let lastActive = perArticle[perArticle.count - 1].activeMB
        let growth = lastActive - firstActive
        print(String(format: "[moss-briefs] active memory drift across %d articles: %+.0f MB",
                     perArticle.count, growth))
        #expect(growth < 250, "active memory grew \(growth) MB across the batch")

        let worstPeak = perArticle.map(\.peakMB).max() ?? 0
        print(String(format: "[moss-briefs] worst peak across batch: %.0f MB", worstPeak))
    }
}
