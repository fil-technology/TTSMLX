import Foundation

/// One chunk emitted by ``TTSTextChunker/chunkInfos(for:)`` carrying both the
/// chunk text and its position in the original input. Use the range to map
/// from "currently playing chunk" back to the source text for highlighting.
///
/// `characterRange` is half-open. Indexing back into the original string:
/// ```swift
/// let lower = text.index(text.startIndex, offsetBy: info.characterRange.lowerBound)
/// let upper = text.index(text.startIndex, offsetBy: info.characterRange.upperBound)
/// let slice = text[lower..<upper]
/// ```
public struct TTSChunkInfo: Sendable, Hashable {
    public let text: String
    /// Half-open `Character` offset range in the original input passed to
    /// ``TTSTextChunker/chunkInfos(for:)``. Counts grapheme clusters, not
    /// UTF-16 code units, so it matches `String.count` arithmetic.
    public let characterRange: Range<Int>
    /// The kind of break that follows this chunk in the source text. The
    /// synthesizer uses it to size the pause after the chunk's audio (see
    /// ``TTSChunkJoin``). Defaults to ``TTSChunkBoundary/infer(from:)`` on
    /// `text` when not supplied.
    public let boundary: TTSChunkBoundary

    public init(text: String, characterRange: Range<Int>, boundary: TTSChunkBoundary? = nil) {
        self.text = text
        self.characterRange = characterRange
        self.boundary = boundary ?? TTSChunkBoundary.infer(from: text)
    }

    /// Split this chunk's text into word-level timings, proportional to each
    /// word's non-whitespace character count.
    ///
    /// MLX TTS models don't expose per-token timing consistently, so the
    /// library falls back to a character-proportional estimate against the
    /// chunk's measured `duration`. Quality is good enough for word-level
    /// highlight overlays — at typical speech rates, character count tracks
    /// word duration to within roughly ±15%.
    ///
    /// Returned ranges are in the **original input** coordinate space — same
    /// as ``characterRange`` — so callers can map them straight onto the
    /// source string without offset arithmetic. Pure whitespace chunks return
    /// an empty array.
    public func wordTimings(forDuration duration: TimeInterval) -> [TTSWordTiming] {
        guard duration > 0, !text.isEmpty else { return [] }
        let characters = Array(text)
        let chunkStart = characterRange.lowerBound

        // Identify word spans (half-open character offsets within the chunk).
        var words: [Range<Int>] = []
        var wordStart: Int? = nil
        for (i, ch) in characters.enumerated() {
            if ch.isWhitespace {
                if let s = wordStart { words.append(s..<i); wordStart = nil }
            } else if wordStart == nil {
                wordStart = i
            }
        }
        if let s = wordStart { words.append(s..<characters.count) }
        guard !words.isEmpty else { return [] }

        let totalWeight = words.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard totalWeight > 0 else { return [] }
        let weightedSecond = duration / Double(totalWeight)

        // Walk words once, accumulating offset so timings tile [0, duration]
        // without rounding drift.
        var timings: [TTSWordTiming] = []
        timings.reserveCapacity(words.count)
        var cursor: TimeInterval = 0
        for (index, span) in words.enumerated() {
            let weight = Double(span.upperBound - span.lowerBound)
            let raw = weight * weightedSecond
            // For the last word, soak up any rounding remainder so the chunk
            // tiles exactly. Avoids "missing 3ms at the end" highlight bugs.
            let wordDuration = (index == words.count - 1)
                ? max(0, duration - cursor)
                : raw
            timings.append(TTSWordTiming(
                characterRange: (chunkStart + span.lowerBound)..<(chunkStart + span.upperBound),
                offset: cursor,
                duration: wordDuration
            ))
            cursor += wordDuration
        }
        return timings
    }
}

/// One word's timing within a chunk. Emitted by
/// ``TTSChunkInfo/wordTimings(forDuration:)`` and the synthesizer's
/// ``TTSDiagnostic/chunkTimings(modelID:chunkIndex:timings:)`` event.
///
/// `characterRange` is in the **original input** coordinate space (same as
/// ``TTSChunkInfo/characterRange``), so apps can drop a highlight straight on
/// the source text. `offset` is relative to the chunk's first audible buffer.
public struct TTSWordTiming: Sendable, Hashable {
    public let characterRange: Range<Int>
    public let offset: TimeInterval
    public let duration: TimeInterval

    /// This word's span as UTF-16 code-unit offsets into `text`.
    ///
    /// `text` must be the same string the timings were produced from. Returns
    /// `nil` if the range falls outside it.
    public func utf16Range(in text: String) -> Range<Int>? {
        let characters = Array(text)
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound <= characters.count,
              characterRange.lowerBound <= characterRange.upperBound
        else { return nil }

        // Count code units up to each boundary. Walking the prefix keeps this
        // correct for any grapheme cluster, however many scalars it spans.
        let lower = characters[0 ..< characterRange.lowerBound]
            .reduce(0) { $0 + String($1).utf16.count }
        let span = characters[characterRange.lowerBound ..< characterRange.upperBound]
            .reduce(0) { $0 + String($1).utf16.count }
        return lower ..< (lower + span)
    }

    /// This word's span as an `NSRange`, for TextKit and `NSAttributedString`.
    public func nsRange(in text: String) -> NSRange? {
        guard let range = utf16Range(in: text) else { return nil }
        return NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound)
    }

    public init(characterRange: Range<Int>, offset: TimeInterval, duration: TimeInterval) {
        self.characterRange = characterRange
        self.offset = offset
        self.duration = duration
    }
}

/// Splits long text into TTS-friendly chunks.
///
/// The first chunk uses a smaller character budget so the model can produce
/// the first audible buffer quickly; later chunks use a larger budget so the
/// overall generation cost stays low. Boundaries are tried in order:
///
/// 1. Sentence-ending punctuation (`.`, `!`, `?`, `…`, newline).
/// 2. Clause punctuation (`,`, `;`, `:`).
/// 3. Whitespace, when a single clause still exceeds the budget.
///
/// Punctuation is **kept** at the end of every chunk (since 0.9.0): the
/// models rely on it for intonation and pauses, so a chunk reads "How are
/// you?" rather than "How are you". A mark only counts as a boundary when
/// whitespace or the end of the text follows it, so "3.14", "10:30" and
/// "1,000" stay intact. Short sentences are packed together up to the
/// active budget rather than becoming one chunk each.
public struct TTSTextChunker: Sendable, Hashable {
    public var firstChunkCharacterLimit: Int
    public var followupChunkCharacterLimit: Int

    public init(
        firstChunkCharacterLimit: Int = 80,
        followupChunkCharacterLimit: Int = 220
    ) {
        precondition(firstChunkCharacterLimit > 0, "firstChunkCharacterLimit must be positive")
        precondition(followupChunkCharacterLimit > 0, "followupChunkCharacterLimit must be positive")
        self.firstChunkCharacterLimit = firstChunkCharacterLimit
        self.followupChunkCharacterLimit = followupChunkCharacterLimit
    }

    /// Chunk texts only. Line endings are normalized to `\n` first; use
    /// ``chunkInfos(for:)`` when positions in the original string matter.
    /// Produces exactly the texts ``chunkInfos(for:)`` would for the
    /// normalized input, so cache keys agree across both APIs.
    public func chunks(for text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let chunks = chunkInfos(for: normalized).map(\.text)
        return chunks.isEmpty ? [normalized] : chunks
    }

    /// Position-aware variant of ``chunks(for:)``. Returns chunks alongside
    /// their `Character`-offset range in the original input — no normalization
    /// is applied so the ranges map 1:1 to the caller's string. Intended for
    /// highlighting the currently playing chunk in the source text.
    public func chunkInfos(for text: String) -> [TTSChunkInfo] {
        guard !text.isEmpty else { return [] }

        // Walk the string once, accumulating chunks per boundary fall-through.
        // We track Character offsets (not String.Index) so the result is
        // Sendable and trivially serializable.
        let scalars = Array(text)

        // First pass: sentence segments. A boundary is a run of sentence
        // marks plus any closing quotes/brackets after it, kept *inside* the
        // segment. Newlines always break; other marks only when whitespace
        // (or the end) follows, so decimals and abbreviations survive.
        var sentenceSegments: [Segment] = []
        var segmentStart = 0
        var i = 0
        while i < scalars.count {
            if let end = Self.boundaryEnd(in: scalars, at: i, marks: Self.sentenceMarks, allowsAnyFollower: scalars[i] == "\n") {
                appendIfMeaningful(scalars: scalars, start: segmentStart, end: end, into: &sentenceSegments)
                segmentStart = end
                i = end
            } else {
                i += 1
            }
        }
        appendIfMeaningful(scalars: scalars, start: segmentStart, end: scalars.count, into: &sentenceSegments)

        // Second pass: subdivide each sentence by clause punctuation.
        var clauseSegments: [Segment] = []
        for sentence in sentenceSegments {
            var clauseStart = sentence.range.lowerBound
            var j = sentence.range.lowerBound
            while j < sentence.range.upperBound {
                if let end = Self.boundaryEnd(in: scalars, at: j, marks: TTSChunkBoundary.clauseMarks, allowsAnyFollower: false),
                   end <= sentence.range.upperBound {
                    appendIfMeaningful(scalars: scalars, start: clauseStart, end: end, into: &clauseSegments)
                    clauseStart = end
                    j = end
                } else {
                    j += 1
                }
            }
            appendIfMeaningful(scalars: scalars, start: clauseStart, end: sentence.range.upperBound, into: &clauseSegments)
        }

        var chunks: [TTSChunkInfo] = []
        var isFirstChunk = true

        // PACK consecutive clause segments into a chunk up to the active limit.
        // Without this, prose with many short sentences produces dozens of tiny
        // chunks — each paying full per-chunk generation overhead and draining
        // the audio queue between them, which makes streamed reading choppy
        // ("a lot of reads with a lot of stops"). The first chunk stays small
        // (firstChunkCharacterLimit) for a fast time-to-first-audio.
        var packStart: Int? = nil
        var packEnd = 0

        func flushPack() {
            if let start = packStart, packEnd > start {
                appendIfMeaningful(scalars: scalars, start: start, end: packEnd, into: &chunks)
                isFirstChunk = false
            }
            packStart = nil
        }

        for segment in clauseSegments {
            let limit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit
            let segStart = segment.range.lowerBound
            let segEnd = segment.range.upperBound

            if segEnd - segStart > limit {
                // A single segment exceeds the limit: flush the pack, then
                // greedily word-split this segment up to the limit.
                flushPack()
                var wpStart = segStart
                var lastWordEnd = segStart
                var wordStart: Int? = nil
                for k in segment.range {
                    if scalars[k].isWhitespace {
                        if wordStart != nil {
                            let curLimit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit
                            if k - wpStart > curLimit, lastWordEnd > wpStart {
                                appendIfMeaningful(scalars: scalars, start: wpStart, end: lastWordEnd, into: &chunks)
                                isFirstChunk = false
                                wpStart = wordStart!
                            }
                            lastWordEnd = k
                            wordStart = nil
                        }
                    } else if wordStart == nil {
                        wordStart = k
                    }
                }
                let curLimit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit
                if segEnd - wpStart > curLimit, lastWordEnd > wpStart {
                    appendIfMeaningful(scalars: scalars, start: wpStart, end: lastWordEnd, into: &chunks)
                    isFirstChunk = false
                    appendIfMeaningful(scalars: scalars, start: lastWordEnd, end: segEnd, into: &chunks)
                    isFirstChunk = false
                } else {
                    appendIfMeaningful(scalars: scalars, start: wpStart, end: segEnd, into: &chunks)
                    isFirstChunk = false
                }
                continue
            }

            if packStart == nil {
                packStart = segStart
                packEnd = segEnd
            } else if segEnd - packStart! <= limit {
                // Extend the pack to absorb this segment (and the punctuation
                // between it and the previous one).
                packEnd = segEnd
            } else {
                // Adding this segment would exceed the limit → flush and restart.
                flushPack()
                packStart = segStart
                packEnd = segEnd
            }
            // Never pack across a paragraph break: the pause after a paragraph
            // is inserted at chunk ends only, and a newline inside a prompt
            // reads as plain whitespace to the model.
            if Self.newlineFollows(scalars, from: segEnd) {
                flushPack()
            }
        }
        flushPack()

        return chunks
    }

    // MARK: - Internals

    private static let sentenceMarks: Set<Character> = TTSChunkBoundary.sentenceMarks.union(["\n"])

    private struct Segment {
        let text: String
        let range: Range<Int>
    }

    /// If `index` starts a boundary run (one or more `marks`, then any closing
    /// quotes/brackets), returns the index just past the run; otherwise `nil`.
    /// Unless `allowsAnyFollower`, the run must be followed by whitespace or
    /// the end of text, so "3.14" / "10:30" / "e.g." are not boundaries.
    private static func boundaryEnd(
        in scalars: [Character], at index: Int, marks: Set<Character>, allowsAnyFollower: Bool
    ) -> Int? {
        guard marks.contains(scalars[index]) else { return nil }
        var end = index + 1
        while end < scalars.count, marks.contains(scalars[end]) || TTSChunkBoundary.closers.contains(scalars[end]) {
            end += 1
        }
        if !allowsAnyFollower, end < scalars.count, !scalars[end].isWhitespace {
            return nil
        }
        return end
    }

    /// True when the whitespace run starting at `index` contains a newline.
    private static func newlineFollows(_ scalars: [Character], from index: Int) -> Bool {
        var k = index
        while k < scalars.count, scalars[k].isWhitespace {
            if scalars[k].isNewline { return true }
            k += 1
        }
        return false
    }

    private static func isMeaningful(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private func appendIfMeaningful(scalars: [Character], start: Int, end: Int, into out: inout [Segment]) {
        let (trimmedStart, trimmedEnd) = Self.trimWhitespaceBounds(scalars, start: start, end: end)
        guard trimmedEnd > trimmedStart else { return }
        let text = String(scalars[trimmedStart..<trimmedEnd])
        guard Self.isMeaningful(text) else { return }
        out.append(Segment(text: text, range: trimmedStart..<trimmedEnd))
    }

    private func appendIfMeaningful(scalars: [Character], start: Int, end: Int, into out: inout [TTSChunkInfo]) {
        let (trimmedStart, trimmedEnd) = Self.trimWhitespaceBounds(scalars, start: start, end: end)
        guard trimmedEnd > trimmedStart else { return }
        let text = String(scalars[trimmedStart..<trimmedEnd])
        guard Self.isMeaningful(text) else { return }
        let boundary: TTSChunkBoundary = Self.newlineFollows(scalars, from: trimmedEnd)
            ? .paragraph
            : TTSChunkBoundary.infer(from: text)
        out.append(TTSChunkInfo(text: text, characterRange: trimmedStart..<trimmedEnd, boundary: boundary))
    }

    private static func trimWhitespaceBounds(_ scalars: [Character], start: Int, end: Int) -> (Int, Int) {
        var lo = start
        var hi = end
        while lo < hi, scalars[lo].isWhitespace { lo += 1 }
        while hi > lo, scalars[hi - 1].isWhitespace { hi -= 1 }
        return (lo, hi)
    }
}

extension TTSTextChunker {
    /// The same chunker with both limits capped at `limit`, a model's
    /// `maxCharactersPerTake`. The narration paths apply it so a model that
    /// degrades on long takes (MOSS-TTS-Nano runs away past about 140
    /// characters) never receives more than it handles, whatever chunker the
    /// caller passed. `nil` or a non-positive limit leaves the chunker as is.
    public func limited(to limit: Int?) -> TTSTextChunker {
        guard let limit, limit > 0 else { return self }
        return TTSTextChunker(
            firstChunkCharacterLimit: min(firstChunkCharacterLimit, limit),
            followupChunkCharacterLimit: min(followupChunkCharacterLimit, limit))
    }
}
