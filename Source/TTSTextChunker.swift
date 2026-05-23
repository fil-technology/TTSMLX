import Foundation

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
}
