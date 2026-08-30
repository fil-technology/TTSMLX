import Foundation
import Testing
@testable import TTSMLX

/// Highlight behaviour is configurable because on-device timings are estimated
/// rather than force-aligned: word-level highlighting exposes every timing
/// error, while sentence-level hides it. Apps need to pick.
@Suite("Highlight options")
struct TTSHighlightOptionsTests {

    private let text = "Markets rose. Analysts were cautious. Rates held."

    /// Word timings for `text`, tiled evenly — one entry per word.
    private var wordTimings: [TTSWordTiming] {
        TTSChunkInfo(text: text, characterRange: 0 ..< Array(text).count)
            .wordTimings(forDuration: 8)
    }

    @Test("word granularity passes timings through unchanged")
    func wordGranularityIsIdentity() {
        let options = TTSHighlightOptions(granularity: .word)
        let out = options.apply(to: wordTimings, in: text)
        #expect(out == wordTimings)
    }

    @Test("sentence granularity produces one span per sentence")
    func sentenceGranularityGroups() {
        let options = TTSHighlightOptions(granularity: .sentence)
        let out = options.apply(to: wordTimings, in: text)

        #expect(out.count == 3, "three sentences, got \(out.count)")

        let characters = Array(text)
        let first = String(characters[out[0].characterRange])
        #expect(first.hasPrefix("Markets"), "got \(first)")
        #expect(first.contains("rose"))

        // Spans must not overlap and must stay in order.
        for i in 1 ..< out.count {
            #expect(out[i].offset >= out[i - 1].offset)
            #expect(out[i].characterRange.lowerBound >= out[i - 1].characterRange.upperBound)
        }
    }

    @Test("a sentence span covers its words' full time range")
    func sentenceSpanCoversItsWords() {
        let words = wordTimings
        let sentences = TTSHighlightOptions(granularity: .sentence).apply(to: words, in: text)
        let firstSentence = sentences[0]

        let covered = words.filter {
            $0.characterRange.lowerBound >= firstSentence.characterRange.lowerBound
                && $0.characterRange.upperBound <= firstSentence.characterRange.upperBound
        }
        #expect(!covered.isEmpty)
        #expect(abs(firstSentence.offset - covered[0].offset) < 1e-9)
        let end = covered[covered.count - 1]
        #expect(abs((firstSentence.offset + firstSentence.duration)
                    - (end.offset + end.duration)) < 1e-9)
    }

    @Test("lead time shifts highlights earlier but never before zero")
    func leadTimeShiftsEarlier() {
        let options = TTSHighlightOptions(granularity: .word, leadTime: 0.1)
        let out = options.apply(to: wordTimings, in: text)
        #expect(out[0].offset == 0, "first highlight must not go negative")
        for (shifted, original) in zip(out.dropFirst(), wordTimings.dropFirst()) {
            #expect(abs(shifted.offset - (original.offset - 0.1)) < 1e-9)
        }
    }

    /// Short function words flicker past; folding them forward keeps the
    /// highlight steady instead of strobing.
    @Test("minimum duration folds very short entries together")
    func minimumDurationMergesShortWords() {
        let timings = [
            TTSWordTiming(characterRange: 0..<1, offset: 0.0, duration: 0.05),
            TTSWordTiming(characterRange: 2..<3, offset: 0.05, duration: 0.05),
            TTSWordTiming(characterRange: 4..<12, offset: 0.10, duration: 0.90),
        ]
        let out = TTSHighlightOptions(granularity: .word, minimumDuration: 0.2)
            .apply(to: timings, in: "a b sentence")

        #expect(out.count < timings.count, "short entries should merge")
        #expect(out[0].offset == 0)
        let last = out[out.count - 1]
        #expect(abs((last.offset + last.duration) - 1.0) < 1e-9,
                "merging must not lose time at the end")
    }

    @Test("decodes from JSON with defaults for omitted keys")
    func decodesFromJSON() throws {
        let json = Data(#"{"granularity":"sentence","leadTime":0.08}"#.utf8)
        let options = try JSONDecoder().decode(TTSHighlightOptions.self, from: json)
        #expect(options.granularity == .sentence)
        #expect(abs(options.leadTime - 0.08) < 1e-9)
        #expect(options.minimumDuration == 0, "omitted keys take defaults")

        let empty = try JSONDecoder().decode(TTSHighlightOptions.self, from: Data("{}".utf8))
        #expect(empty == .default)
    }

    @Test("round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let original = TTSHighlightOptions.readingComfort
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TTSHighlightOptions.self, from: data) == original)
    }

    @Test("empty input stays empty")
    func emptyIsSafe() {
        #expect(TTSHighlightOptions.readingComfort.apply(to: [], in: text).isEmpty)
    }
}
