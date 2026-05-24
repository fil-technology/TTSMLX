import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSError.wrap")
struct TTSErrorWrapTests {
    @Test("passes existing TTSError through unchanged")
    func passesTTSErrorThrough() {
        let original = TTSError.modelNotFound("foo")
        let wrapped = TTSError.wrap(original, modelID: "x", stage: .loadingModel)
        if case .modelNotFound(let id) = wrapped {
            #expect(id == "foo")
        } else {
            Issue.record("expected modelNotFound, got \(wrapped)")
        }
    }

    @Test("maps NSURL errors to networkUnavailable regardless of stage")
    func mapsURLErrors() {
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let wrapped = TTSError.wrap(urlError, modelID: "x", stage: .generatingAudio)
        if case .networkUnavailable(let underlying) = wrapped {
            #expect(underlying != nil)
        } else {
            Issue.record("expected networkUnavailable, got \(wrapped)")
        }
    }

    @Test("maps loadingModel-stage errors to modelLoadFailed")
    func mapsLoadStageErrors() {
        let raw = NSError(domain: "MLX", code: 7, userInfo: nil)
        let wrapped = TTSError.wrap(raw, modelID: "model-id", stage: .loadingModel)
        if case .modelLoadFailed(let id, _) = wrapped {
            #expect(id == "model-id")
        } else {
            Issue.record("expected modelLoadFailed, got \(wrapped)")
        }
    }

    @Test("maps generatingAudio-stage errors to generationFailed")
    func mapsGenerationStageErrors() {
        let raw = NSError(domain: "MLX", code: 99, userInfo: nil)
        let wrapped = TTSError.wrap(raw, modelID: "m", stage: .generatingAudio)
        if case .generationFailed(let id, _) = wrapped {
            #expect(id == "m")
        } else {
            Issue.record("expected generationFailed, got \(wrapped)")
        }
    }

    @Test("maps download-stage errors to networkUnavailable")
    func mapsDownloadStageErrors() {
        let raw = NSError(domain: "Foo", code: 1, userInfo: nil)
        let wrapped = TTSError.wrap(raw, modelID: "m", stage: .downloadingModel)
        if case .networkUnavailable = wrapped {
            // ok
        } else {
            Issue.record("expected networkUnavailable, got \(wrapped)")
        }
    }
}

@Suite("TTSWordTiming")
struct TTSWordTimingTests {
    @Test("returns one timing per whitespace-separated word")
    func wordCount() {
        let info = TTSChunkInfo(text: "Hello world from TTSMLX", characterRange: 0..<23)
        let timings = info.wordTimings(forDuration: 1.0)
        #expect(timings.count == 4)
    }

    @Test("timings tile exactly to the chunk duration (no rounding drift)")
    func tilesExactly() {
        let info = TTSChunkInfo(text: "alpha beta gamma delta", characterRange: 0..<22)
        let duration: TimeInterval = 1.234
        let timings = info.wordTimings(forDuration: duration)
        let last = timings.last!
        #expect(abs((last.offset + last.duration) - duration) < 1e-9)
    }

    @Test("ranges are in the ORIGINAL input coordinate space")
    func rangesInOriginal() {
        // Simulate a chunk that starts at offset 100 in the original text.
        let info = TTSChunkInfo(text: "one two", characterRange: 100..<107)
        let timings = info.wordTimings(forDuration: 1.0)
        #expect(timings[0].characterRange == 100..<103)
        #expect(timings[1].characterRange == 104..<107)
    }

    @Test("zero or negative duration yields an empty array")
    func emptyForZeroDuration() {
        let info = TTSChunkInfo(text: "hello", characterRange: 0..<5)
        #expect(info.wordTimings(forDuration: 0).isEmpty)
        #expect(info.wordTimings(forDuration: -1).isEmpty)
    }

    @Test("whitespace-only chunk returns an empty array")
    func emptyForWhitespace() {
        let info = TTSChunkInfo(text: "   \n\t  ", characterRange: 0..<7)
        #expect(info.wordTimings(forDuration: 1.0).isEmpty)
    }

    @Test("offsets are monotonically non-decreasing and non-negative")
    func monotonic() {
        let info = TTSChunkInfo(text: "a bb ccc dddd eeeee", characterRange: 0..<19)
        let timings = info.wordTimings(forDuration: 2.0)
        var prev: TimeInterval = -1
        for t in timings {
            #expect(t.offset >= prev)
            #expect(t.duration >= 0)
            prev = t.offset
        }
    }
}

@Suite("TTSError.errorDescription")
struct TTSErrorDescriptionTests {
    @Test("descriptions include the model id and reason where appropriate")
    func descriptions() {
        #expect(TTSError.deviceUnsupported(modelID: "m", reason: "too big").errorDescription?.contains("m") == true)
        #expect(TTSError.deviceUnsupported(modelID: "m", reason: "too big").errorDescription?.contains("too big") == true)
        #expect(TTSError.outOfMemory(modelID: "m").errorDescription?.contains("m") == true)
        #expect(TTSError.networkUnavailable(underlying: nil).errorDescription == "Network unavailable.")
    }
}
