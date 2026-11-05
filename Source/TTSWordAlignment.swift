import AVFoundation
import Foundation

/// Where a take is silent: before its first word, after its last, and at the
/// pauses in between. Times are seconds from the start of the take's speech
/// audio (the padding ``TTSChunkJoin`` adds after a take is not part of it).
public struct TTSSpeechPauses: Sendable, Hashable {
    public let leading: TimeInterval
    public let trailing: TimeInterval
    /// Silences between words, in order.
    public let pauses: [Range<TimeInterval>]

    public init(leading: TimeInterval = 0, trailing: TimeInterval = 0, pauses: [Range<TimeInterval>] = []) {
        self.leading = leading
        self.trailing = trailing
        self.pauses = pauses
    }
}

/// Finds the pauses of a take from its audio while it is generated, without
/// keeping the samples: it reduces them to one level per 10 ms.
///
/// Silence is judged against the take's own loudest window, so it finds the
/// digital-quiet gaps of models such as Kokoro and reports nothing for a
/// model whose pauses carry codec noise. Reporting nothing is safe: the word
/// timings then fall back to the even spread.
public struct TTSSpeechPauseDetector: Sendable {
    static let windowSeconds: TimeInterval = 0.01
    /// Shorter gaps are stop consonants, not pauses.
    static let minimumPause: TimeInterval = 0.15
    static let silenceRatio: Float = 0.03

    private var levels: [Float] = []
    private var windowFrames = 0
    private var sumSquares: Double = 0
    private var filled = 0
    private var isUsable = true

    public init() {}

    /// Feed the take's speech buffers in order (not its padding).
    public mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard isUsable, buffer.frameLength > 0 else { return }
        guard let channel = buffer.floatChannelData?[0] else {
            isUsable = false
            return
        }
        append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)), sampleRate: buffer.format.sampleRate)
    }

    public mutating func append(samples: [Float], sampleRate: Double) {
        samples.withUnsafeBufferPointer { append($0, sampleRate: sampleRate) }
    }

    private mutating func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        if windowFrames == 0 { windowFrames = max(1, Int(sampleRate * Self.windowSeconds)) }
        for sample in samples {
            sumSquares += Double(sample) * Double(sample)
            filled += 1
            if filled == windowFrames {
                levels.append(Float((sumSquares / Double(windowFrames)).squareRoot()))
                sumSquares = 0
                filled = 0
            }
        }
    }

    /// `nil` when there is too little audio, or none that could be read.
    public func pauses() -> TTSSpeechPauses? {
        guard isUsable, levels.count >= 20, let peak = levels.max(), peak > 0 else { return nil }
        let threshold = peak * Self.silenceRatio
        var runs: [Range<Int>] = []
        var runStart: Int?
        for (index, level) in levels.enumerated() {
            if level < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append(start..<index)
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start..<levels.count) }

        let window = Self.windowSeconds
        var leading: TimeInterval = 0
        var trailing: TimeInterval = 0
        if let first = runs.first, first.lowerBound == 0 {
            leading = Double(first.count) * window
            runs.removeFirst()
        }
        if let last = runs.last, last.upperBound == levels.count {
            trailing = Double(last.count) * window
            runs.removeLast()
        }
        let minimumWindows = Int((Self.minimumPause / window).rounded())
        var pauses = runs.filter { $0.count >= minimumWindows }
        // A click or breath after the voice has stopped (or before it has
        // started) is not a word: count it with the silence around it.
        let blipWindows = minimumWindows
        if let last = pauses.last,
           levels.count - Int((trailing / window).rounded()) - last.upperBound < blipWindows {
            trailing = Double(levels.count - last.lowerBound) * window
            pauses.removeLast()
        }
        if let first = pauses.first,
           first.lowerBound - Int((leading / window).rounded()) < blipWindows {
            leading = Double(first.upperBound) * window
            pauses.removeFirst()
        }
        return TTSSpeechPauses(
            leading: leading,
            trailing: trailing,
            pauses: pauses.map { Double($0.lowerBound) * window ..< Double($0.upperBound) * window }
        )
    }
}

extension TTSChunkInfo {
    /// How much longer per character the last word before a pause is spoken.
    static let phraseFinalStretch = 1.8

    /// Word timings placed around the take's real silences.
    ///
    /// ``wordTimings(forDuration:)`` spreads the characters evenly over the
    /// whole take. A take is not evenly spoken: it starts and ends with
    /// silence and stops at commas and full stops, so over a 20 s take the
    /// even spread drifts by half a second and more, and the highlight
    /// trails the voice.
    ///
    /// Here the characters are spread over the time the voice is actually
    /// sounding. Each pause stops the clock at the point in the text the
    /// speaking pace says was reached; when a word ending a clause or
    /// sentence is close to that point the pause is pinned to it, which
    /// also corrects whatever the pace had drifted by.
    ///
    /// The result still tiles `[0, duration]`: the first word starts at 0 and
    /// each word lasts until the next begins, pause included. With `pauses`
    /// `nil`, or when they do not look like this text being spoken, this is
    /// the even spread.
    public func wordTimings(forDuration duration: TimeInterval, pauses: TTSSpeechPauses?) -> [TTSWordTiming] {
        let even = wordTimings(forDuration: duration)
        guard let pauses, even.count > 1 else { return even }

        let speechStart = min(max(0, pauses.leading), duration)
        let speechEnd = max(speechStart, duration - max(0, pauses.trailing))
        let inner = pauses.pauses.filter { $0.lowerBound > speechStart && $0.upperBound < speechEnd }
        let spoken = speechEnd - speechStart - inner.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        // Mostly silence: whatever was measured, it was not this text.
        guard spoken > duration * 0.3 else { return even }

        // Characters spoken before each word starts; `starts[count]` is all.
        var starts: [Double] = [0]
        starts.reserveCapacity(even.count + 1)
        for timing in even {
            starts.append(starts[starts.count - 1] + Double(timing.characterRange.count))
        }
        let total = starts[even.count]
        guard total > 0 else { return even }
        let pace = total / spoken
        let endsClause = wordsEndingClause(even)

        // The text as a path through time: (characters spoken, seconds).
        // Between two knots the voice runs at a steady pace; a pause is two
        // knots at the same character count. `lastWordStart` is set on a
        // knot that closes a phrase: the character count where the phrase's
        // last word begins.
        typealias Knot = (characters: Double, seconds: TimeInterval, lastWordStart: Double?)
        var knots: [Knot] = [(0, speechStart, nil)]
        var firstWord = 0
        for pause in inner {
            let anchor = knots[knots.count - 1]
            let expected = anchor.characters + pace * (pause.lowerBound - anchor.seconds)
            let slack = max(8, 0.3 * (expected - anchor.characters))
            // A pause falls after a word, so look at where words end.
            var pinned: Int?
            for word in firstWord..<max(firstWord, even.count - 1) where endsClause[word] {
                let miss = abs(starts[word + 1] - expected)
                if miss <= slack, pinned.map({ miss < abs(starts[$0 + 1] - expected) }) ?? true {
                    pinned = word
                }
            }
            let reached: Double
            var lastWordStart: Double?
            if let pinned {
                reached = starts[pinned + 1]
                lastWordStart = starts[pinned]
                firstWord = pinned + 1
            } else {
                // No clause ends nearby (a breath mid-phrase, or a dash
                // inside a word): trust the pace.
                reached = min(max(expected, anchor.characters), total)
                while firstWord < even.count - 1, starts[firstWord + 1] <= reached { firstWord += 1 }
            }
            knots.append((reached, pause.lowerBound, lastWordStart))
            knots.append((reached, pause.upperBound, nil))
        }
        knots.append((total, max(knots[knots.count - 1].seconds, speechEnd), starts[even.count - 1]))

        // A stretch spoken several times faster or slower than the take
        // means a pause was pinned to the wrong word. Keep what is certain,
        // the silence at both ends, and spread evenly inside it.
        let fits = zip(knots, knots.dropFirst()).allSatisfy { from, to in
            let characters = to.characters - from.characters
            let seconds = to.seconds - from.seconds
            if characters <= 0 { return true }
            guard seconds > 0 else { return false }
            return characters / seconds < pace * 2.5 && characters / seconds > pace / 2.5
        }
        if !fits { knots = [(0, speechStart, nil), (total, speechEnd, starts[even.count - 1])] }

        // A voice slows into a pause: the last word of a phrase takes
        // longer per character than the ones before it. Counting it as
        // longer keeps the words before it from being placed late.
        func length(_ characters: Double, in phrase: Knot, from: Knot) -> Double {
            guard let lastWordStart = phrase.lastWordStart, lastWordStart > from.characters,
                  characters > lastWordStart else { return characters - from.characters }
            return lastWordStart - from.characters + Self.phraseFinalStretch * (characters - lastWordStart)
        }

        // When the path reaches a character count. At a pause that is the
        // end of the pause: the word after it starts when the voice resumes.
        func seconds(at characters: Double) -> TimeInterval {
            var result = knots[0].seconds
            for (from, to) in zip(knots, knots.dropFirst()) where from.characters <= characters {
                if to.characters > from.characters, characters < to.characters {
                    let fraction = length(characters, in: to, from: from) / length(to.characters, in: to, from: from)
                    return from.seconds + fraction * (to.seconds - from.seconds)
                }
                result = to.seconds
            }
            return result
        }
        var offsets = even.indices.map { seconds(at: starts[$0]) }
        // Light the first word from the start of the take rather than
        // leaving nothing highlighted through the leading silence.
        offsets[0] = 0
        return even.indices.map { index in
            let end = index + 1 < even.count ? max(offsets[index + 1], offsets[index]) : duration
            return TTSWordTiming(
                characterRange: even[index].characterRange,
                offset: offsets[index],
                duration: max(0, end - offsets[index])
            )
        }
    }

    /// For each word, whether it ends a clause or sentence (closing quotes
    /// and brackets ignored): the places a voice pauses.
    private func wordsEndingClause(_ timings: [TTSWordTiming]) -> [Bool] {
        let characters = Array(text)
        let chunkStart = characterRange.lowerBound
        return timings.map { timing in
            var end = timing.characterRange.upperBound - chunkStart
            let start = timing.characterRange.lowerBound - chunkStart
            while end > start, end <= characters.count, TTSChunkBoundary.closers.contains(characters[end - 1]) {
                end -= 1
            }
            guard end > start, end <= characters.count else { return false }
            let last = characters[end - 1]
            return TTSChunkBoundary.sentenceMarks.contains(last)
                || TTSChunkBoundary.clauseMarks.contains(last)
                || last == "—" || last == "–"
        }
    }
}
