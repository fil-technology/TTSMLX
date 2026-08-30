import Foundation
import Testing
@testable import TTSMLX

/// Word ranges are Character (grapheme) offsets, but UIKit, TextKit and
/// AttributedString all address text in UTF-16 code units. The two agree only
/// while the text stays inside the BMP with no combining sequences — so a news
/// headline carrying a flag emoji silently shifts every highlight after it.
@Suite("Word range UTF-16 conversion")
struct TTSWordRangeUTF16Tests {

    @Test("ASCII text: the two coordinate systems agree")
    func asciiRangesAreIdentical() {
        let text = "Markets closed higher"
        // "closed" is characters 8..<14
        let timing = TTSWordTiming(characterRange: 8..<14, offset: 0, duration: 1)
        #expect(String(Array(text)[8..<14]) == "closed")
        #expect(timing.utf16Range(in: text) == 8..<14)
    }

    /// The case that breaks a news reader: a flag emoji is one Character but
    /// four UTF-16 code units.
    @Test("emoji shifts UTF-16 offsets away from character offsets")
    func emojiShiftsOffsets() {
        let text = "🇺🇸 English News rose"
        let characters = Array(text)
        #expect(characters.count == 19)
        #expect(text.utf16.count == 22, "flag costs 4 code units, not 1")

        // "News" sits at characters 10..<14.
        #expect(String(characters[10..<14]) == "News")
        let timing = TTSWordTiming(characterRange: 10..<14, offset: 0, duration: 1)

        let utf16 = try? #require(timing.utf16Range(in: text))
        #expect(utf16 == 13..<17, "got \(String(describing: utf16))")

        // Proof it addresses the same word once converted — and that using the
        // character offsets directly would not.
        let ns = try? #require(timing.nsRange(in: text))
        let bridged = text as NSString
        #expect(bridged.substring(with: ns!) == "News")
        #expect(bridged.substring(with: NSRange(location: 10, length: 4)) != "News",
                "character offsets used as an NSRange land on the wrong word")
    }

    @Test("combining sequences also diverge")
    func combiningSequencesDiverge() {
        // "e" + combining acute is one Character, two UTF-16 units.
        let text = "cafe\u{0301} au lait"
        #expect(Array(text).count == 12)
        #expect(text.utf16.count == 13)

        // "au" is characters 5..<7.
        let timing = TTSWordTiming(characterRange: 5..<7, offset: 0, duration: 1)
        #expect(String(Array(text)[5..<7]) == "au")
        let ns = try? #require(timing.nsRange(in: text))
        #expect((text as NSString).substring(with: ns!) == "au")
    }

    @Test("out-of-bounds ranges report nil rather than crashing")
    func outOfBoundsIsNil() {
        let text = "short"
        #expect(TTSWordTiming(characterRange: 0..<99, offset: 0, duration: 1)
            .utf16Range(in: text) == nil)
        #expect(TTSWordTiming(characterRange: 0..<99, offset: 0, duration: 1)
            .nsRange(in: text) == nil)
    }

    /// Every word produced for a string containing emoji must convert to a
    /// range that extracts exactly that word — the end-to-end property a
    /// karaoke highlight depends on.
    @Test("every generated timing round-trips through NSRange")
    func allTimingsRoundTrip() {
        let text = "🇺🇸 Markets closed higher on Tuesday after the bank held rates"
        let info = TTSChunkInfo(text: text, characterRange: 0 ..< Array(text).count)
        let timings = info.wordTimings(forDuration: 5)
        #expect(!timings.isEmpty)

        let bridged = text as NSString
        let characters = Array(text)
        for timing in timings {
            let expected = String(characters[timing.characterRange])
            let ns = timing.nsRange(in: text)
            #expect(ns != nil, "no NSRange for \(expected)")
            if let ns {
                #expect(bridged.substring(with: ns) == expected,
                        "NSRange gave \(bridged.substring(with: ns)) for \(expected)")
            }
        }
    }
}
