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

public enum TTSError: LocalizedError, Sendable {
    case emptyText
    case invalidModelQuery
    case invalidResponse
    case httpError(statusCode: Int, body: Data)
    case modelNotFound(String)

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
