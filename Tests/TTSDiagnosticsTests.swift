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
