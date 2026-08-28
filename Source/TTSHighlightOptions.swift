import Foundation

/// How a consumer wants the "currently speaking" highlight to behave.
///
/// `Codable`, so an app can ship this as JSON and tune it without a rebuild:
///
/// ```json
/// { "granularity": "sentence", "leadTime": 0.08, "minimumDuration": 0.12 }
/// ```
///
/// This covers *behaviour* only. Colour, weight and animation stay in the app:
/// they have to answer to Dynamic Type, dark mode and Reduce Motion, which a
/// framework-level style config would fight rather than help.
public struct TTSHighlightOptions: Sendable, Hashable, Codable {

    /// What a single highlight covers.
    public enum Granularity: String, Sendable, Hashable, Codable {
        /// One word at a time. Precise, but unforgiving: on-device timings are
        /// estimated from character weight rather than forced alignment, so a
        /// word that runs long makes the cursor visibly lag.
        case word
        /// The whole sentence containing the current word. Much more tolerant
        /// of timing error — the highlight still looks right when a word is a
        /// couple of hundred milliseconds out — and it is what a long-form
        /// reader usually wants.
        case sentence
    }

    public var granularity: Granularity

    /// Fire each highlight this many seconds before its audio.
    ///
    /// A small lead (50–100 ms) reads as *tighter* rather than early, because
    /// the eye needs time to find the word before hearing it. Negative values
    /// delay instead.
    public var leadTime: TimeInterval

    /// Keep a highlight on screen at least this long before advancing.
    ///
    /// Short function words ("a", "of") can be tens of milliseconds and flicker
    /// past. This merges them forward into the next highlight rather than
    /// strobing.
    public var minimumDuration: TimeInterval

    public init(
        granularity: Granularity = .word,
        leadTime: TimeInterval = 0,
        minimumDuration: TimeInterval = 0
    ) {
        self.granularity = granularity
        self.leadTime = leadTime
        self.minimumDuration = minimumDuration
    }

    /// Word-level, no lead, no minimum — the callback fires exactly on the
    /// timing as generated.
    public static let `default` = TTSHighlightOptions()

    /// Sentence-level with a small lead. A reasonable starting point for a
    /// long-form reader driven by estimated (non-aligned) timings.
    public static let readingComfort = TTSHighlightOptions(
        granularity: .sentence, leadTime: 0.08, minimumDuration: 0.2
    )

    enum CodingKeys: String, CodingKey {
        case granularity, leadTime, minimumDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TTSHighlightOptions()
        granularity = try c.decodeIfPresent(Granularity.self, forKey: .granularity) ?? d.granularity
        leadTime = try c.decodeIfPresent(TimeInterval.self, forKey: .leadTime) ?? d.leadTime
        minimumDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .minimumDuration) ?? d.minimumDuration
    }
}

public extension TTSHighlightOptions {
    /// Rewrites a word timeline according to these options.
    ///
    /// - Parameters:
    ///   - timings: word-level timings, ascending by offset.
    ///   - text: the source text the ranges index into. Needed to find sentence
    ///     boundaries; pass the same string the timings were produced from.
    func apply(to timings: [TTSWordTiming], in text: String) -> [TTSWordTiming] {
        guard !timings.isEmpty else { return [] }
        var result = granularity == .sentence
            ? Self.groupedIntoSentences(timings, in: text)
            : timings

        if minimumDuration > 0 {
            result = Self.enforcingMinimumDuration(result, minimum: minimumDuration)
        }
        if leadTime != 0 {
            result = result.map {
                TTSWordTiming(
                    characterRange: $0.characterRange,
                    offset: max(0, $0.offset - leadTime),
                    duration: $0.duration
                )
            }
        }
        return result
    }

    /// Merges words into one entry per sentence, spanning from the first word's
    /// start to the last word's end.
    static func groupedIntoSentences(
        _ timings: [TTSWordTiming],
        in text: String
    ) -> [TTSWordTiming] {
        let characters = Array(text)
        // A sentence ends at terminal punctuation; anything trailing it
        // (quotes, brackets) belongs to the same sentence.
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

        var grouped: [TTSWordTiming] = []
        var start: TTSWordTiming?
        var last: TTSWordTiming?

        for timing in timings {
            if start == nil { start = timing }
            last = timing

            let end = min(timing.characterRange.upperBound, characters.count)
            // Look at the word plus whatever punctuation immediately follows,
            // since the word range itself usually stops before the period.
            var index = max(0, timing.characterRange.lowerBound)
            var endsSentence = false
            while index < end { 
                if terminators.contains(characters[index]) { endsSentence = true }
                index += 1
            }
            var trailing = end
            while trailing < characters.count, !characters[trailing].isWhitespace {
                if terminators.contains(characters[trailing]) { endsSentence = true }
                trailing += 1
            }

            if endsSentence, let first = start, let final = last {
                grouped.append(Self.span(from: first, to: final))
                start = nil
                last = nil
            }
        }
        if let first = start, let final = last {
            grouped.append(Self.span(from: first, to: final))
        }
        return grouped.isEmpty ? timings : grouped
    }

    private static func span(from first: TTSWordTiming, to last: TTSWordTiming) -> TTSWordTiming {
        TTSWordTiming(
            characterRange: first.characterRange.lowerBound ..< last.characterRange.upperBound,
            offset: first.offset,
            duration: max(0, (last.offset + last.duration) - first.offset)
        )
    }

    /// Drops entries shorter than `minimum` by folding them into the previous
    /// one, so a run of tiny words reads as a single steady highlight.
    static func enforcingMinimumDuration(
        _ timings: [TTSWordTiming],
        minimum: TimeInterval
    ) -> [TTSWordTiming] {
        var result: [TTSWordTiming] = []
        for timing in timings {
            if let previous = result.last, previous.duration < minimum {
                result[result.count - 1] = span(from: previous, to: timing)
            } else {
                result.append(timing)
            }
        }
        return result
    }
}
