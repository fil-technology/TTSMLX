import Foundation

/// One highlightable line of a read-along view.
///
/// Exists so a consumer can render a long text as a `LazyVStack` of rows and
/// re-render only the row being spoken. Handing a whole chapter to a single
/// `Text(AttributedString)` and rebuilding it on every word is O(text) per
/// word — fine for a paragraph, ruinous for a book.
///
/// Ranges are **UTF-16 code-unit** offsets, matching `NSRange`,
/// `AttributedString` and TextKit. That is deliberately not the unit
/// ``TTSWordTiming/characterRange`` uses; see ``TTSWordTiming/utf16Range(in:)``.
public struct TTSSentence: Identifiable, Sendable, Hashable {
    /// Position in the sentence list. Stable for a given text, and usable
    /// directly as a `ForEach` id and a `ScrollViewReader` target.
    public let id: Int
    /// Span within the source text, in UTF-16 code units.
    public let range: Range<Int>
    /// The sentence itself, so a row can render without slicing the source.
    public let text: String

    public var location: Int { range.lowerBound }
    public var length: Int { range.upperBound - range.lowerBound }

    public init(id: Int, range: Range<Int>, text: String) {
        self.id = id
        self.range = range
        self.text = text
    }
}

public enum TTSSentenceSplitter {

    /// Longest run of characters emitted without a sentence terminator.
    ///
    /// A 200-character sentence renders as several visual lines; with the
    /// scroller anchoring the row's top, the word being spoken at the bottom
    /// runs off screen until the next terminator arrives. Breaking long prose
    /// at a word boundary past this cap keeps the scroll target fine-grained.
    /// About 90 is two to three lines at a large serif face.
    public static let defaultSoftMaxLength = 90

    /// Splits `text` into highlightable lines.
    ///
    /// Cheap enough to run once per text, and it must be: recomputing it on
    /// every playback tick is what makes read-along views stutter on long
    /// chapters. Cache the result and recompute only when the text changes.
    ///
    /// - Parameters:
    ///   - text: source text.
    ///   - softMaxLength: see ``defaultSoftMaxLength``. Pass a large value to
    ///     split on sentence terminators alone.
    public static func sentences(
        in text: String,
        softMaxLength: Int = defaultSoftMaxLength
    ) -> [TTSSentence] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        let terminators: Set<UnicodeScalar> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]

        var result: [TTSSentence] = []
        var start = 0
        var cursor = 0
        var index = 0

        func append(end: Int) {
            guard end > start else { return }
            let value = ns.substring(with: NSRange(location: start, length: end - start))
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(TTSSentence(id: index, range: start ..< end, text: value))
                index += 1
            }
            start = end
        }

        while cursor < ns.length {
            let unit = ns.character(at: cursor)
            cursor += 1
            guard let scalar = UnicodeScalar(unit) else { continue }
            if terminators.contains(scalar) {
                append(end: cursor)
            } else if cursor - start >= softMaxLength,
                      CharacterSet.whitespacesAndNewlines.contains(scalar) {
                // Soft break: long un-terminated prose just reached a word
                // boundary past the cap.
                append(end: cursor)
            }
        }
        append(end: ns.length)
        return result
    }

    /// Index of the sentence containing `spokenCharacterCount` UTF-16 units of
    /// progress, or `nil` for an empty list.
    ///
    /// Binary search rather than a scan: a chapter is hundreds of sentences and
    /// a read-along view asks this on every tick.
    public static func index(
        forSpokenCharacter spokenCharacterCount: Int,
        in sentences: [TTSSentence]
    ) -> Int? {
        guard !sentences.isEmpty else { return nil }
        let spoken = max(0, spokenCharacterCount)

        var low = 0
        var high = sentences.count - 1
        var result = sentences.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sentences[mid].range.upperBound > spoken {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }
}
