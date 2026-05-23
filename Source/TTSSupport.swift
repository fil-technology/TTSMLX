import Foundation
import MLXAudioTTS
@preconcurrency import MLXLMCommon
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public enum TTSGenerationProfile: String, Sendable, Hashable, Codable, CaseIterable {
    case fast
    case balanced
    case highQuality

    public var title: String {
        switch self {
        case .fast:
            "Fast"
        case .balanced:
            "Balanced"
        case .highQuality:
            "High Quality"
        }
    }

    func apply(to parameters: inout GenerateParameters) {
        switch self {
        case .fast:
            parameters.maxTokens = 640
            parameters.temperature = 0.75
            parameters.topP = 0.85
        case .balanced:
            parameters.maxTokens = 1280
            parameters.temperature = 0.9
            parameters.topP = 0.95
        case .highQuality:
            parameters.maxTokens = 2048
            parameters.temperature = 1.0
            parameters.topP = 0.98
        }
    }
}

public struct TTSSynthesisOptions: Sendable, Hashable {
    public var language: TTSLanguage?
    public var voice: TTSVoice?
    public var referenceAudio: URL?
    public var referenceText: String?
    // Used by synthesize(_:using:options:...). The streaming API currently yields buffers only
    // and does not surface a persisted output artifact through the wrapper.
    public var outputURL: URL?
    public var generationProfile: TTSGenerationProfile?
    public var maxTokens: Int?
    public var temperature: Float?
    public var topP: Float?
    public var hfToken: String?
    public var streamingInterval: Double

    public init(
        language: TTSLanguage? = nil,
        voice: TTSVoice? = nil,
        referenceAudio: URL? = nil,
        referenceText: String? = nil,
        outputURL: URL? = nil,
        generationProfile: TTSGenerationProfile? = nil,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        hfToken: String? = nil,
        streamingInterval: Double = 2.0
    ) {
        self.language = language
        self.voice = voice
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.outputURL = outputURL
        self.generationProfile = generationProfile
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.hfToken = hfToken
        self.streamingInterval = streamingInterval
    }
}

public struct TTSAudioFile: Sendable, Hashable {
    public let url: URL
    public let modelID: String
    public let language: TTSLanguage?
    public let voice: TTSVoice?
    public let sampleRate: Int

    public init(
        url: URL,
        modelID: String,
        language: TTSLanguage?,
        voice: TTSVoice?,
        sampleRate: Int
    ) {
        self.url = url
        self.modelID = modelID
        self.language = language
        self.voice = voice
        self.sampleRate = sampleRate
    }
}

#if canImport(AVFoundation)
public struct TTSAudioBufferChunk: Sendable {
    public let buffer: AVAudioPCMBuffer
    public let sampleRate: Int

    public init(buffer: AVAudioPCMBuffer, sampleRate: Int) {
        self.buffer = buffer
        self.sampleRate = sampleRate
    }
}
#endif

public enum TTSError: LocalizedError, @unchecked Sendable {
    case emptyText
    case invalidModelQuery
    case invalidResponse
    case httpError(statusCode: Int, body: Data)
    case modelNotFound(String)
    case unsupportedModel(String)
    /// The current device does not meet a model's minimum requirements.
    /// Callers should use this signal to pick a smaller model.
    case deviceUnsupported(modelID: String, reason: String)
    /// The synthesizer detected (or strongly suspects) the host is out of memory.
    /// Drop loaded weights via ``TTSSpeechSynthesizer/unloadAll()`` before retrying.
    case outOfMemory(modelID: String)
    /// MLX failed to materialize a downloaded model into memory.
    case modelLoadFailed(modelID: String, underlying: Error)
    /// The model loaded but the actual audio generation failed.
    case generationFailed(modelID: String, underlying: Error)
    /// The Hugging Face API was unreachable. Distinct from ``httpError`` (4xx/5xx)
    /// because callers usually want to retry on connectivity, not on 401/404.
    case networkUnavailable(underlying: Error?)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Text cannot be empty."
        case .invalidModelQuery:
            return "The Hugging Face model query could not be built."
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .httpError(statusCode, _):
            return "The request failed with HTTP status \(statusCode)."
        case let .modelNotFound(modelID):
            return "The model \(modelID) is not installed."
        case let .unsupportedModel(modelID):
            return "This app can list \(modelID), but the current MLX runtime cannot synthesize with it yet."
        case let .deviceUnsupported(modelID, reason):
            return "\(modelID) cannot run on this device: \(reason)"
        case let .outOfMemory(modelID):
            return "Not enough memory to run \(modelID). Unload other models or pick a smaller one."
        case let .modelLoadFailed(modelID, underlying):
            return "Loading \(modelID) failed: \(underlying.localizedDescription)"
        case let .generationFailed(modelID, underlying):
            return "Generating audio with \(modelID) failed: \(underlying.localizedDescription)"
        case let .networkUnavailable(underlying):
            if let underlying {
                return "Network unavailable: \(underlying.localizedDescription)"
            }
            return "Network unavailable."
        }
    }
}

extension TTSError {
    /// Wraps an arbitrary error thrown during a known stage so callers can
    /// pattern-match. Network failures become ``networkUnavailable``, load
    /// failures become ``modelLoadFailed`` etc. Pass-throughs preserve existing
    /// `TTSError` values unchanged.
    static func wrap(_ error: Error, modelID: String, stage: TTSProgressUpdate.Stage) -> TTSError {
        if let typed = error as? TTSError { return typed }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable(underlying: error)
        }

        switch stage {
        case .resolvingModel, .downloadingModel:
            return .networkUnavailable(underlying: error)
        case .loadingModel:
            return .modelLoadFailed(modelID: modelID, underlying: error)
        case .generatingAudio, .writingFile, .completed:
            return .generationFailed(modelID: modelID, underlying: error)
        }
    }
}

enum MLXTTSModelLoader {
    static func load(descriptor: TTSModelDescriptor, hfToken: String?) async throws -> any SpeechGenerationModel {
        try await TTS.loadModel(
            modelRepo: descriptor.id,
            hfToken: hfToken
        )
    }
}
