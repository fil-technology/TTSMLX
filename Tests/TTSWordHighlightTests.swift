import Foundation
import Testing
@testable import TTSMLX

/// Covers word-level highlight lookup: finding the word being spoken at an
/// arbitrary time, which is what a seek, a scrubber preview, or a view
/// reappearing mid-playback all need. Waiting for the next `onWord` callback
/// leaves the highlight stale or, after a backward seek, frozen entirely.
@Suite("Word highlight lookup")
struct TTSWordHighlightTests {

    /// "one two three four" tiled across 4 seconds, one word per second.
    private var timeline: [TTSWordTiming] {
        [
            TTSWordTiming(characterRange: 0..<3,   offset: 0, duration: 1),
            TTSWordTiming(characterRange: 4..<7,   offset: 1, duration: 1),
            TTSWordTiming(characterRange: 8..<13,  offset: 2, duration: 1),
            TTSWordTiming(characterRange: 14..<18, offset: 3, duration: 1),
        ]
    }

    @Test("finds the word being spoken at a given time")
    func findsCurrentWord() {
        let t = timeline
        #expect(TTSPlaybackController.indexOfWord(at: 0.0, in: t) == 0)
        #expect(TTSPlaybackController.indexOfWord(at: 0.9, in: t) == 0)
        #expect(TTSPlaybackController.indexOfWord(at: 1.0, in: t) == 1, "boundary belongs to the new word")
        #expect(TTSPlaybackController.indexOfWord(at: 2.5, in: t) == 2)
        #expect(TTSPlaybackController.indexOfWord(at: 3.999, in: t) == 3)
    }

    /// Before the first word there is nothing to highlight — distinct from
    /// "the first word", which would light the wrong thing at t=0 of a
    /// narration that opens with a pause.
    @Test("reports nothing before the first word")
    func nothingBeforeStart() {
        let t = [TTSWordTiming(characterRange: 0..<3, offset: 0.5, duration: 1)]
        #expect(TTSPlaybackController.indexOfWord(at: 0.0, in: t) == -1)
        #expect(TTSPlaybackController.indexOfWord(at: 0.49, in: t) == -1)
        #expect(TTSPlaybackController.indexOfWord(at: 0.5, in: t) == 0)
    }

    @Test("past the end stays on the last word")
    func clampsPastEnd() {
        #expect(TTSPlaybackController.indexOfWord(at: 99, in: timeline) == 3)
    }

    @Test("empty timeline is safe")
    func emptyTimeline() {
        #expect(TTSPlaybackController.indexOfWord(at: 1, in: []) == -1)
    }

    /// A backward seek is the case the forward-only cursor could not serve: it
    /// must land on an earlier word, not stay where it was.
    @Test("lookup moves backwards as well as forwards")
    func lookupIsBidirectional() {
        let t = timeline
        let forward = TTSPlaybackController.indexOfWord(at: 3.2, in: t)
        let backward = TTSPlaybackController.indexOfWord(at: 0.4, in: t)
        #expect(forward == 3)
        #expect(backward == 0, "seeking back to 0.4s must highlight the first word again")
    }

    /// The lookup is a binary search because an article's timeline is large;
    /// this pins correctness at scale rather than just on four words.
    @Test("scales to a long article's timeline")
    func scalesToLongTimeline() {
        let words = (0 ..< 5_000).map { i in
            TTSWordTiming(characterRange: (i * 5)..<(i * 5 + 4),
                          offset: Double(i) * 0.4,
                          duration: 0.4)
        }
        #expect(TTSPlaybackController.indexOfWord(at: 0, in: words) == 0)
        #expect(TTSPlaybackController.indexOfWord(at: 1_000 * 0.4, in: words) == 1_000)
        #expect(TTSPlaybackController.indexOfWord(at: 4_999 * 0.4 + 0.1, in: words) == 4_999)
    }
}
