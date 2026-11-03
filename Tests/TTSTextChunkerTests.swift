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
        // Short sentences pack into one chunk (see packing test); the
        // punctuation is kept because the models need it for intonation.
        #expect(chunker.chunks(for: text) == ["First sentence. Second sentence! Third one?"])

        let tight = TTSTextChunker(firstChunkCharacterLimit: 16, followupChunkCharacterLimit: 16)
        #expect(tight.chunks(for: text) == ["First sentence.", "Second sentence!", "Third one?"])
    }

    @Test("clause punctuation creates breaks within long sentences")
    func clauseBreaks() {
        let chunker = TTSTextChunker(
            firstChunkCharacterLimit: 200,
            followupChunkCharacterLimit: 200
        )
        let text = "Alpha, beta; gamma: delta."
        #expect(chunker.chunks(for: text) == ["Alpha, beta; gamma: delta."])

        let tight = TTSTextChunker(firstChunkCharacterLimit: 6, followupChunkCharacterLimit: 6)
        #expect(tight.chunks(for: text) == ["Alpha,", "beta;", "gamma:", "delta."])
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
        let tight = TTSTextChunker(firstChunkCharacterLimit: 10, followupChunkCharacterLimit: 10)
        #expect(tight.chunks(for: text) == ["Line one", "Line two", "Line three"])
        // Newlines separate segments but are never part of a chunk's text.
        for chunk in chunker.chunks(for: text) { #expect(!chunk.contains("\n")) }
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

    @Test("chunkInfos returns ranges that slice back to the chunk text")
    func chunkInfoRangesRoundTrip() {
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 200, followupChunkCharacterLimit: 200)
        let text = "First sentence. Second sentence! Third one?"
        let infos = chunker.chunkInfos(for: text)
        // All three short sentences fit under the 200-char limit, so they pack
        // into a single chunk (see packing test below). Ranges must still slice
        // back to the exact chunk text.
        #expect(infos.count == 1)
        for info in infos {
            let start = text.index(text.startIndex, offsetBy: info.characterRange.lowerBound)
            let end = text.index(text.startIndex, offsetBy: info.characterRange.upperBound)
            #expect(String(text[start..<end]) == info.text)
        }
    }

    @Test("short sentences are packed up to the limit, not one chunk each")
    func packsShortSentences() {
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 80, followupChunkCharacterLimit: 220)
        // 12 short sentences (~24 chars each ≈ 290 chars). Per-sentence chunking
        // would yield 12 chunks; packing should yield only a few (≤ ceil(290/220)+1).
        let text = Array(repeating: "The cat sat on the mat.", count: 12).joined(separator: " ")
        let infos = chunker.chunkInfos(for: text)
        #expect(infos.count <= 4)
        // First chunk stays small for fast time-to-first-audio.
        #expect(infos.first!.text.count <= 80)
        // Every chunk respects its budget.
        for (i, info) in infos.enumerated() {
            #expect(info.text.count <= (i == 0 ? 80 : 220))
        }
        // Round-trips against the original text.
        for info in infos {
            let start = text.index(text.startIndex, offsetBy: info.characterRange.lowerBound)
            let end = text.index(text.startIndex, offsetBy: info.characterRange.upperBound)
            #expect(String(text[start..<end]) == info.text)
        }
    }

    @Test("chunkInfos preserves CRLF positions (no normalization)")
    func chunkInfoNoNormalization() {
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 200, followupChunkCharacterLimit: 200)
        let text = "Hello\r\nWorld"
        let infos = chunker.chunkInfos(for: text)
        // Ranges must be valid in the ORIGINAL (CRLF) string, not a normalized copy.
        for info in infos {
            #expect(info.characterRange.upperBound <= text.count)
            let start = text.index(text.startIndex, offsetBy: info.characterRange.lowerBound)
            let end = text.index(text.startIndex, offsetBy: info.characterRange.upperBound)
            #expect(String(text[start..<end]) == info.text)
        }
    }

    @Test("chunkInfos returns empty for empty input")
    func chunkInfoEmpty() {
        #expect(TTSTextChunker().chunkInfos(for: "").isEmpty)
    }

    @Test("chunkInfos respects character budgets like chunks(for:)")
    func chunkInfoBudgets() {
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 12, followupChunkCharacterLimit: 24)
        let text = "Alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        let infos = chunker.chunkInfos(for: text)
        #expect(!infos.isEmpty)
        #expect(infos[0].text.count <= 12)
        for info in infos.dropFirst() {
            #expect(info.text.count <= 24)
        }
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

    // MARK: - Punctuation handling (0.9.0)

    @Test("terminal punctuation stays on every chunk, including runs and closing quotes")
    func keepsTerminalPunctuation() {
        let tight = TTSTextChunker(firstChunkCharacterLimit: 24, followupChunkCharacterLimit: 24)
        let text = "Really?! \"Yes.\" Wait… (Fine!) Done."
        let infos = tight.chunkInfos(for: text)
        let texts = infos.map(\.text)
        #expect(texts == ["Really?! \"Yes.\" Wait…", "(Fine!) Done."])
        for info in infos {
            #expect(info.boundary == .sentence)
            let start = text.index(text.startIndex, offsetBy: info.characterRange.lowerBound)
            let end = text.index(text.startIndex, offsetBy: info.characterRange.upperBound)
            #expect(String(text[start..<end]) == info.text)
        }
    }

    @Test("marks inside numbers and abbreviations are not boundaries")
    func numbersAndAbbreviationsSurvive() {
        let tight = TTSTextChunker(firstChunkCharacterLimit: 12, followupChunkCharacterLimit: 12)
        #expect(tight.chunks(for: "Pi is 3.14159 today") == ["Pi is", "3.14159", "today"])
        #expect(tight.chunks(for: "Meet at 10:30, bring 1,000 forms.") == ["Meet at", "10:30,", "bring 1,000", "forms."])
        #expect(tight.chunks(for: "See www.x.com now") == ["See", "www.x.com", "now"])
    }

    @Test("punctuation-only segments are dropped, never sent to the model")
    func punctuationOnlySegmentsDropped() {
        let chunker = TTSTextChunker(firstChunkCharacterLimit: 10, followupChunkCharacterLimit: 10)
        #expect(chunker.chunks(for: "... Hello. ---") == ["Hello."])
        #expect(chunker.chunkInfos(for: "?!").isEmpty)
        #expect(chunker.chunks(for: "?!") == ["?!"]) // legacy whole-input fallback
    }

    @Test("boundary kinds: paragraph, sentence, clause, open")
    func boundaryKinds() {
        let tight = TTSTextChunker(firstChunkCharacterLimit: 14, followupChunkCharacterLimit: 14)
        let text = "One done.\n\nTwo here, three\nthe quick brown fox jumped"
        let infos = tight.chunkInfos(for: text)
        let kinds = infos.map { ($0.text, $0.boundary) }
        #expect(kinds.map(\.0) == ["One done.", "Two here,", "three", "the quick", "brown fox", "jumped"])
        #expect(kinds.map(\.1) == [.paragraph, .clause, .paragraph, .open, .open, .open])
    }

    @Test("TTSChunkBoundary.infer classifies by last meaningful character")
    func inferBoundary() {
        #expect(TTSChunkBoundary.infer(from: "Hello.") == .sentence)
        #expect(TTSChunkBoundary.infer(from: "Hello?\"  ") == .sentence)
        #expect(TTSChunkBoundary.infer(from: "Hello…") == .sentence)
        #expect(TTSChunkBoundary.infer(from: "Hello,") == .clause)
        #expect(TTSChunkBoundary.infer(from: "Hello;)") == .clause)
        #expect(TTSChunkBoundary.infer(from: "Hello") == .open)
        #expect(TTSChunkBoundary.infer(from: "") == .open)
        #expect(TTSChunkInfo(text: "Hi!", characterRange: 0..<3).boundary == .sentence)
    }

    @Test("chunks(for:) and chunkInfos(for:) agree on texts")
    func legacyAndInfoAgree() {
        let chunker = TTSTextChunker()
        let text = Array(repeating: "The cat sat on the mat, and then it slept.", count: 20).joined(separator: " ")
        #expect(chunker.chunks(for: text) == chunker.chunkInfos(for: text).map(\.text))
    }
}
