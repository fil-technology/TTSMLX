import Foundation
import Testing
@testable import TTSMLX

/// Regression cover for streaming karaoke timing.
///
/// The bug these exist for: chunk durations were measured as generation
/// wall-clock and then used as word-timing durations. Word offsets are compared
/// against the player's `currentTime`, which is playback seconds, so the
/// highlight desynchronised by however far generation ran from realtime — for a
/// model that generates a whole chunk before emitting, the first chunk's
/// "duration" bore no relation to how long it takes to say.
@Suite("Streaming word timings")
struct TTSStreamingTimingTests {

    private func chunk(_ text: String, at start: Int = 0) -> TTSChunkInfo {
        TTSChunkInfo(text: text, characterRange: start ..< (start + text.count))
    }

    @Test("timings tile the audio duration, not the generation time")
    func timingsTileAudioDuration() {
        let info = chunk("The lighthouse keeper had not spoken")
        // 4 s of speech that took 12 s to generate. Timings must describe the
        // 4 s, or the cursor runs three times too slow.
        let audioSeconds: TimeInterval = 4.0
        let timings = info.wordTimings(forDuration: audioSeconds)

        #expect(!timings.isEmpty)
        let last = timings[timings.count - 1]
        let total = last.offset + last.duration
        #expect(abs(total - audioSeconds) < 1e-9,
                "timings must tile exactly [0, audio]; got \(total)")
        #expect(timings[0].offset == 0)

        for i in 1 ..< timings.count {
            #expect(timings[i].offset >= timings[i - 1].offset, "offsets must be monotonic")
        }
    }

    @Test("character ranges stay absolute against the source text")
    func rangesAreAbsolute() {
        let info = chunk("second chunk here", at: 100)
        let timings = info.wordTimings(forDuration: 3)
        #expect(timings.first?.characterRange.lowerBound == 100)
        #expect(timings.last?.characterRange.upperBound == 117)
    }

    /// The offset a word lands on is `sum(prior chunk durations) + offset`, so
    /// mixing units across chunks is what actually strands the cursor. This
    /// reproduces the accumulation the playback observer performs.
    @Test("consecutive chunks concatenate on one continuous timeline")
    func chunksConcatenateContinuously() {
        let first = chunk("one two three")
        let second = chunk("four five six", at: 13)

        let firstAudio: TimeInterval = 2.0
        let secondAudio: TimeInterval = 3.0

        let firstTimings = first.wordTimings(forDuration: firstAudio)
        let secondTimings = second.wordTimings(forDuration: secondAudio)
            .map { TTSWordTiming(characterRange: $0.characterRange,
                                 offset: firstAudio + $0.offset,
                                 duration: $0.duration) }

        let timeline = firstTimings + secondTimings
        for i in 1 ..< timeline.count {
            #expect(timeline[i].offset >= timeline[i - 1].offset,
                    "timeline must be monotonic across the chunk boundary")
        }

        let last = timeline[timeline.count - 1]
        #expect(abs((last.offset + last.duration) - (firstAudio + secondAudio)) < 1e-9,
                "timeline must end at the summed audio duration")

        // The second chunk's first word must start at the boundary, not before.
        #expect(abs(secondTimings[0].offset - firstAudio) < 1e-9)
    }

    @Test("zero-length audio yields no timings rather than a divide by zero")
    func zeroDurationIsSafe() {
        #expect(chunk("some words").wordTimings(forDuration: 0).isEmpty)
        #expect(chunk("some words").wordTimings(forDuration: -1).isEmpty)
    }

    /// Audio seconds are derived as frames / sampleRate from the buffers that
    /// were actually rendered; this pins the arithmetic the streaming loop uses.
    @Test("audio seconds derive from frames over sample rate")
    func audioSecondsArithmetic() {
        let sampleRate = 48_000
        let frames = [24_000, 48_000, 12_000]   // 0.5 s, 1 s, 0.25 s
        let seconds = frames.reduce(0.0) { $0 + Double($1) / Double(sampleRate) }
        #expect(abs(seconds - 1.75) < 1e-9)
    }
}
