import Foundation
import Testing
@testable import TTSMLX

/// Word timings placed around a take's silences instead of spread evenly.
///
/// The bug these exist for: a 20 s take has silence at both ends and a pause
/// at every comma and full stop, and the even spread ignored all of it, so
/// the highlight trailed the voice by half a second and more.
@Suite("Pause-aware word timings")
struct TTSWordAlignmentTests {

    private func chunk(_ text: String, at start: Int = 0) -> TTSChunkInfo {
        TTSChunkInfo(text: text, characterRange: start ..< (start + text.count))
    }

    private func word(_ timings: [TTSWordTiming], _ word: String, in text: String) -> TTSWordTiming? {
        let characters = Array(text)
        return timings.first { String(characters[$0.characterRange]) == word }
    }

    /// `seconds` of a 200 Hz tone, or of silence.
    private func audio(_ seconds: TimeInterval, silent: Bool = false, rate: Double = 24_000) -> [Float] {
        (0 ..< Int(seconds * rate)).map { silent ? 0 : 0.5 * Float(sin(2 * Double.pi * 200 * Double($0) / rate)) }
    }

    @Test("the detector finds the silence at both ends and the pauses between")
    func detectorFindsSilences() throws {
        var detector = TTSSpeechPauseDetector()
        let samples = audio(0.3, silent: true) + audio(2) + audio(0.4, silent: true) + audio(1.5)
            + audio(0.05, silent: true) + audio(1) + audio(0.8, silent: true)
        detector.append(samples: samples, sampleRate: 24_000)
        let pauses = try #require(detector.pauses())

        #expect(abs(pauses.leading - 0.3) < 0.03)
        #expect(abs(pauses.trailing - 0.8) < 0.03)
        // The 50 ms gap is a consonant, not a pause.
        #expect(pauses.pauses.count == 1)
        let pause = try #require(pauses.pauses.first)
        #expect(abs(pause.lowerBound - 2.3) < 0.03)
        #expect(abs(pause.upperBound - 2.7) < 0.03)
    }

    @Test("a click after the voice has stopped counts as trailing silence")
    func blipAfterTheEndIsNotSpeech() throws {
        var detector = TTSSpeechPauseDetector()
        let samples = audio(2) + audio(0.4, silent: true) + audio(0.05) + audio(0.5, silent: true)
        detector.append(samples: samples, sampleRate: 24_000)
        let pauses = try #require(detector.pauses())
        #expect(pauses.pauses.isEmpty)
        #expect(abs(pauses.trailing - 0.95) < 0.03)
    }

    @Test("too little audio gives no pauses rather than a guess")
    func shortAudioGivesNothing() {
        var detector = TTSSpeechPauseDetector()
        detector.append(samples: audio(0.1), sampleRate: 24_000)
        #expect(detector.pauses() == nil)
        #expect(TTSSpeechPauseDetector().pauses() == nil)
    }

    @Test("the word after a pause starts when the voice resumes")
    func wordAfterPauseStartsAtPauseEnd() throws {
        let text = "She knocked twice, and nobody came to the door."
        let info = chunk(text)
        // 0.3 s lead, "She knocked twice," then a pause from 1.5 to 2.0 s,
        // the rest until 4.2 s, 0.8 s of silence at the end.
        let pauses = TTSSpeechPauses(leading: 0.3, trailing: 0.8, pauses: [1.5 ..< 2.0])
        let timings = info.wordTimings(forDuration: 5, pauses: pauses)

        let and = try #require(word(timings, "and", in: text))
        #expect(abs(and.offset - 2.0) < 1e-9)
        // The even spread would have put it near 1.9 s only by luck; the word
        // before it is what shows the difference.
        let twice = try #require(word(timings, "twice,", in: text))
        #expect(twice.offset < 1.5)
        #expect(abs(twice.offset + twice.duration - 2.0) < 1e-9, "a word lasts through the pause after it")
    }

    @Test("the last word ends where the voice does, not where the audio does")
    func trailingSilenceIsNotSpokenTime() throws {
        let text = "one two three four five six seven eight"
        let info = chunk(text)
        let even = info.wordTimings(forDuration: 4)
        let aware = info.wordTimings(forDuration: 4, pauses: TTSSpeechPauses(leading: 0, trailing: 1))

        let evenEight = try #require(word(even, "eight", in: text))
        let awareEight = try #require(word(aware, "eight", in: text))
        #expect(awareEight.offset < evenEight.offset - 0.4, "the even spread runs a second long")
        #expect(awareEight.offset < 3)
    }

    @Test("timings still tile the take and keep their ranges")
    func timingsTile() {
        let text = "First, a pause. Then another one; and a long run of words without any at all"
        let info = chunk(text, at: 40)
        let pauses = TTSSpeechPauses(leading: 0.28, trailing: 0.9, pauses: [0.7 ..< 0.9, 1.6 ..< 2.1, 3.0 ..< 3.2])
        let timings = info.wordTimings(forDuration: 7.5, pauses: pauses)
        let even = info.wordTimings(forDuration: 7.5)

        #expect(timings.map(\.characterRange) == even.map(\.characterRange))
        #expect(timings.first?.offset == 0)
        for (current, next) in zip(timings, timings.dropFirst()) {
            #expect(abs(current.offset + current.duration - next.offset) < 1e-9)
            #expect(next.offset >= current.offset)
        }
        let last = timings[timings.count - 1]
        #expect(abs(last.offset + last.duration - 7.5) < 1e-9)
    }

    @Test("a pause with no clause end nearby stops the clock where the pace says")
    func pauseWithoutPunctuation() throws {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel"
        let info = chunk(text)
        // Half the characters are spoken, then a breath.
        let timings = info.wordTimings(forDuration: 4.5, pauses: TTSSpeechPauses(pauses: [2.0 ..< 2.5]))
        let echo = try #require(word(timings, "echo", in: text))
        let even = try #require(word(info.wordTimings(forDuration: 4.5), "echo", in: text))
        #expect(echo.offset >= 2.0)
        #expect(echo.offset > even.offset)
    }

    @Test("pauses that cannot be this text fall back to the even spread")
    func implausiblePausesAreIgnored() {
        let info = chunk("a few words here")
        let even = info.wordTimings(forDuration: 3)
        // Nine tenths silence.
        let silence = info.wordTimings(forDuration: 3, pauses: TTSSpeechPauses(leading: 1.4, trailing: 1.4))
        #expect(silence == even)
        #expect(info.wordTimings(forDuration: 3, pauses: nil) == even)
    }
}
