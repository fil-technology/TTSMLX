import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSTextChunker")
struct TTSTextChunkerTests {
    @Test("empty or whitespace-only input yields no chunks")
    func emptyInput() {
        let chunker = TTSTextChunker()
        #expect(chunker.chunks(for: "").isEmpty)
        #expect(chunker.chunks(for: "   \n  \t").isEmpty)
    }

    @Test("first chunk respects the smaller character budget")
    func firstChunkSmallerBudget() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 20,
            followupChunkCharacterLimit: 80
        )
        let text = "Hello there, this is a longer sentence that does not fit the first budget."
        let chunks = chunker.chunks(for: text)
        #expect(!chunks.isEmpty)
        #expect(chunks[0].count <= 20)
        for chunk in chunks.dropFirst() {
            #expect(chunk.count <= 80)
        }
    }

    @Test("sentence-end punctuation creates breaks")
    func sentenceBreaks() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 200,
            followupChunkCharacterLimit: 200
        )
        let text = "First sentence. Second sentence! Third one?"
        let chunks = chunker.chunks(for: text)
        #expect(chunks == ["First sentence", "Second sentence", "Third one"])
    }

    @Test("clause punctuation creates breaks within long sentences")
    func clauseBreaks() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 200,
            followupChunkCharacterLimit: 200
        )
        let text = "Alpha, beta; gamma: delta."
        let chunks = chunker.chunks(for: text)
        #expect(chunks == ["Alpha", "beta", "gamma", "delta"])
    }

    @Test("word splitter handles segments without any punctuation")
    func wordSplitFallback() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 10,
            followupChunkCharacterLimit: 10
        )
        let text = "one two three four five six seven eight nine"
        let chunks = chunker.chunks(for: text)
        for chunk in chunks {
            #expect(chunk.count <= 10)
        }
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test("normalizes CRLF line endings before splitting")
    func crlfNormalization() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 200,
            followupChunkCharacterLimit: 200
        )
        let text = "Line one\r\nLine two\rLine three"
        let chunks = chunker.chunks(for: text)
        #expect(chunks == ["Line one", "Line two", "Line three"])
    }

    @Test("falls back to the whole input when no boundaries are present")
    func noBoundariesFallback() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 500,
            followupChunkCharacterLimit: 500
        )
        let text = "noboundariesatallinthisstring"
        #expect(chunker.chunks(for: text) == [text])
    }

    @Test("combinedFraction maps inner stream progress onto the outer one")
    func combinedFractionMath() {
        // start of chunk 0, no inner progress -> 0
        #expect(TTSSpeechSynthesizer.combinedFraction(chunkIndex: 0, chunkFraction: nil, chunkCount: 4) == 0.0)
        // start of chunk 2 (of 4) -> 0.5
        #expect(TTSSpeechSynthesizer.combinedFraction(chunkIndex: 2, chunkFraction: nil, chunkCount: 4) == 0.5)
        // halfway through chunk 2 (of 4) -> 0.5 + 0.5/4 = 0.625
        #expect(TTSSpeechSynthesizer.combinedFraction(chunkIndex: 2, chunkFraction: 0.5, chunkCount: 4) == 0.625)
        // bad input
        #expect(TTSSpeechSynthesizer.combinedFraction(chunkIndex: 0, chunkFraction: nil, chunkCount: 0) == nil)
    }
}
