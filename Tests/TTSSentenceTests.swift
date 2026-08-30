import Foundation
import Testing
@testable import TTSMLX

/// Sentence segmentation for read-along views.
///
/// The shape here follows ReadMeBook's listening view: a LazyVStack of
/// sentence rows where only the spoken row is expensive to render. Handing a
/// whole chapter to one Text and rebuilding it per word is O(text) per word,
/// which is what makes long-form read-along stutter.
@Suite("Sentence segmentation")
struct TTSSentenceTests {

    @Test("splits on sentence terminators")
    func splitsOnTerminators() {
        let text = "Markets rose. Analysts were cautious! Did rates hold?"
        let sentences = TTSSentenceSplitter.sentences(in: text)
        #expect(sentences.count == 3)
        #expect(sentences[0].text.trimmingCharacters(in: .whitespaces) == "Markets rose.")
        #expect(sentences[2].text.trimmingCharacters(in: .whitespaces) == "Did rates hold?")
    }

    @Test("ids are sequential and usable as scroll targets")
    func idsAreSequential() {
        let sentences = TTSSentenceSplitter.sentences(in: "One. Two. Three.")
        #expect(sentences.map(\.id) == [0, 1, 2])
    }

    /// Ranges must address the source text in UTF-16, because that is what
    /// NSRange, AttributedString and TextKit use.
    @Test("ranges are UTF-16 and slice back to the sentence")
    func rangesAreUTF16AndExact() {
        let text = "🇺🇸 Markets rose. Analysts were cautious."
        let ns = text as NSString
        for sentence in TTSSentenceSplitter.sentences(in: text) {
            let sliced = ns.substring(with: NSRange(location: sentence.location,
                                                    length: sentence.length))
            #expect(sliced == sentence.text, "range did not slice back to its text")
        }
    }

    @Test("sentences tile the text with no gaps or overlap")
    func sentencesTileTheText() {
        let text = "One sentence here. And a second one. Then a third."
        let sentences = TTSSentenceSplitter.sentences(in: text)
        #expect(sentences.first?.location == 0)
        for i in 1 ..< sentences.count {
            #expect(sentences[i].location == sentences[i - 1].range.upperBound,
                    "gap or overlap between sentences \(i - 1) and \(i)")
        }
        #expect(sentences.last?.range.upperBound == (text as NSString).length)
    }

    /// A long unterminated run must break at a word boundary, or the scroll
    /// target becomes one tall row and the spoken word drifts off screen.
    @Test("long prose breaks at a word boundary past the soft cap")
    func longProseBreaksSoftly() {
        let long = String(repeating: "word ", count: 60)   // 300 chars, no terminator
        let sentences = TTSSentenceSplitter.sentences(in: long, softMaxLength: 90)
        #expect(sentences.count > 1, "should have broken up")
        for sentence in sentences.dropLast() {
            #expect(sentence.length >= 90, "break came before the cap")
            #expect(sentence.text.hasSuffix(" "), "break must land on a word boundary")
        }
    }

    @Test("a large soft cap splits on terminators only")
    func largeCapDisablesSoftBreak() {
        let long = String(repeating: "word ", count: 60)
        #expect(TTSSentenceSplitter.sentences(in: long, softMaxLength: .max).count == 1)
    }

    @Test("empty and whitespace-only text yield nothing")
    func emptyIsSafe() {
        #expect(TTSSentenceSplitter.sentences(in: "").isEmpty)
        #expect(TTSSentenceSplitter.sentences(in: "   \n  ").isEmpty)
    }

    // MARK: - Index lookup

    @Test("finds the sentence containing the spoken position")
    func findsCurrentSentence() {
        let text = "One two. Three four. Five six."
        let sentences = TTSSentenceSplitter.sentences(in: text)
        func index(_ spoken: Int) -> Int? {
            TTSSentenceSplitter.index(forSpokenCharacter: spoken, in: sentences)
        }
        #expect(index(0) == 0)
        #expect(index(7) == 0)
        #expect(index(sentences[1].location) == 1)
        #expect(index(sentences[2].location + 1) == 2)
    }

    @Test("past the end stays on the last sentence")
    func clampsPastEnd() {
        let sentences = TTSSentenceSplitter.sentences(in: "One. Two.")
        #expect(TTSSentenceSplitter.index(forSpokenCharacter: 9_999, in: sentences)
                == sentences.count - 1)
    }

    @Test("empty list reports nil")
    func emptyListIsNil() {
        #expect(TTSSentenceSplitter.index(forSpokenCharacter: 5, in: []) == nil)
    }

    /// Binary search, because a chapter is hundreds of sentences and a
    /// read-along view asks this on every tick.
    @Test("lookup is correct across a chapter-sized text")
    func scalesToChapterLength() {
        let text = String(repeating: "This is a sentence of moderate length. ", count: 400)
        let sentences = TTSSentenceSplitter.sentences(in: text)
        #expect(sentences.count >= 400)

        for probe in [0, 100, 5_000, 12_000] where probe < (text as NSString).length {
            let index = try? #require(
                TTSSentenceSplitter.index(forSpokenCharacter: probe, in: sentences)
            )
            if let index {
                let sentence = sentences[index]
                #expect(sentence.range.upperBound > probe)
                if index > 0 {
                    #expect(sentences[index - 1].range.upperBound <= probe)
                }
            }
        }
    }
}
