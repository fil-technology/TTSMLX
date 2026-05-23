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

    public init(text: String, characterRange: Range<Int>) {
        self.text = text
        self.characterRange = characterRange
    }
}

/// Splits long text into TTS-friendly chunks.
///
/// The first chunk uses a smaller character budget so the model can produce
/// the first audible buffer quickly; later chunks use a larger budget so the
/// overall generation cost stays low. Boundaries are tried in order:
///
/// 1. Sentence-ending punctuation (`.`, `!`, `?`, newline).
/// 2. Clause punctuation (`,`, `;`, `:`).
/// 3. Whitespace, when a single clause still exceeds the budget.
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

    public func chunks(for text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let coarseSegments = normalized
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",;:")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var isFirstChunk = true

        for segment in coarseSegments {
            let limit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit

            if segment.count <= limit {
                chunks.append(segment)
                isFirstChunk = false
                continue
            }

            var current = ""
            for word in segment.split(whereSeparator: { $0.isWhitespace }) {
                let activeLimit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit
                let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
                if candidate.count <= activeLimit {
                    current = candidate
                } else {
                    if !current.isEmpty {
                        chunks.append(current)
                        isFirstChunk = false
                    }
                    current = String(word)
                }
            }

            if !current.isEmpty {
                chunks.append(current)
                isFirstChunk = false
            }
        }

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
        let sentenceBoundaries: Set<Character> = [".", "!", "?", "\n"]
        let clauseBoundaries: Set<Character> = [",", ";", ":"]

        // First pass: produce sentence segments with original-range positions.
        var sentenceSegments: [Segment] = []
        var segmentStart = 0
        for (i, ch) in scalars.enumerated() {
            if sentenceBoundaries.contains(ch) {
                appendIfMeaningful(scalars: scalars, start: segmentStart, end: i, into: &sentenceSegments)
                segmentStart = i + 1
            }
        }
        appendIfMeaningful(scalars: scalars, start: segmentStart, end: scalars.count, into: &sentenceSegments)

        // Second pass: subdivide each sentence by clause punctuation.
        var clauseSegments: [Segment] = []
        for sentence in sentenceSegments {
            var clauseStart = sentence.range.lowerBound
            for i in sentence.range {
                if clauseBoundaries.contains(scalars[i]) {
                    appendIfMeaningful(scalars: scalars, start: clauseStart, end: i, into: &clauseSegments)
                    clauseStart = i + 1
                }
            }
            appendIfMeaningful(scalars: scalars, start: clauseStart, end: sentence.range.upperBound, into: &clauseSegments)
        }

        var chunks: [TTSChunkInfo] = []
        var isFirstChunk = true

        for segment in clauseSegments {
            let limit = isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit

            if segment.text.count <= limit {
                chunks.append(.init(text: segment.text, characterRange: segment.range))
                isFirstChunk = false
                continue
            }

            // Word-split: walk indices and pack greedily up to the active limit.
            var packStart = segment.range.lowerBound
            var packEnd = packStart
            var wordStart: Int? = nil

            for i in segment.range {
                let ch = scalars[i]
                if ch.isWhitespace {
                    if wordStart != nil {
                        let tentativeEnd = i
                        if tentativeEnd - packStart > (isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit) {
                            // Flush whatever we accumulated up through packEnd.
                            if packEnd > packStart {
                                appendIfMeaningful(scalars: scalars, start: packStart, end: packEnd, into: &chunks)
                                isFirstChunk = false
                            }
                            packStart = wordStart!
                            packEnd = tentativeEnd
                        } else {
                            packEnd = tentativeEnd
                        }
                        wordStart = nil
                    }
                } else if wordStart == nil {
                    wordStart = i
                }
            }
            // Tail
            let finalEnd = segment.range.upperBound
            if finalEnd - packStart > (isFirstChunk ? firstChunkCharacterLimit : followupChunkCharacterLimit) && packEnd > packStart {
                appendIfMeaningful(scalars: scalars, start: packStart, end: packEnd, into: &chunks)
                isFirstChunk = false
                if let ws = wordStart {
                    appendIfMeaningful(scalars: scalars, start: ws, end: finalEnd, into: &chunks)
                    isFirstChunk = false
                }
            } else {
                appendIfMeaningful(scalars: scalars, start: packStart, end: finalEnd, into: &chunks)
                isFirstChunk = false
            }
        }

        return chunks
    }

    // MARK: - Internals

    private struct Segment {
        let text: String
        let range: Range<Int>
    }

    private func appendIfMeaningful(scalars: [Character], start: Int, end: Int, into out: inout [Segment]) {
        let (trimmedStart, trimmedEnd) = Self.trimWhitespaceBounds(scalars, start: start, end: end)
        guard trimmedEnd > trimmedStart else { return }
        let text = String(scalars[trimmedStart..<trimmedEnd])
        out.append(Segment(text: text, range: trimmedStart..<trimmedEnd))
    }

    private func appendIfMeaningful(scalars: [Character], start: Int, end: Int, into out: inout [TTSChunkInfo]) {
        let (trimmedStart, trimmedEnd) = Self.trimWhitespaceBounds(scalars, start: start, end: end)
        guard trimmedEnd > trimmedStart else { return }
        let text = String(scalars[trimmedStart..<trimmedEnd])
        out.append(TTSChunkInfo(text: text, characterRange: trimmedStart..<trimmedEnd))
    }

    private static func trimWhitespaceBounds(_ scalars: [Character], start: Int, end: Int) -> (Int, Int) {
        var lo = start
        var hi = end
        while lo < hi, scalars[lo].isWhitespace { lo += 1 }
        while hi > lo, scalars[hi - 1].isWhitespace { hi -= 1 }
        return (lo, hi)
    }
}
