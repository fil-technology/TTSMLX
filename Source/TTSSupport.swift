import Foundation
import HuggingFace
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

    /// Adjusts the model's own `defaultGenerationParameters`.
    ///
    /// Since 0.9.0 a profile no longer overrides temperature or top-p: every
    /// model ships sampling settings its authors tuned (Orpheus and VyvoTTS
    /// at 0.6 / 0.8 with a repetition penalty, Soprano at 0.7 / 0.95, ...),
    /// and the old profile values (up to 1.0 / 0.98 for "High Quality")
    /// made speech-token sampling noticeably less stable — pitch wobble,
    /// slurred words, the occasional garbage syllable. Explicit
    /// ``TTSSynthesisOptions/temperature`` / ``TTSSynthesisOptions/topP``
    /// still override. What a profile does control:
    ///
    /// - ``highQuality`` raises the token budget to at least 2048 so long
    ///   chunks are never truncated.
    /// - For MOSS-TTS-Nano, the residual codebook count (8 / 12 / 16), the
    ///   model's real speed-versus-detail dial. See
    ///   `TTSSpeechSynthesizer.applyModelSpecificProfile`.
    func apply(to parameters: inout GenerateParameters) {
        switch self {
        case .fast, .balanced:
            break
        case .highQuality:
            if let current = parameters.maxTokens {
                parameters.maxTokens = max(current, 2048)
            }
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
    /// Codec used when the framework writes generated audio to disk — narration
    /// bundle chunks (``TTSSpeechSynthesizer/streamAndCacheNarration(_:using:options:cache:chunker:startCharacterOffset:backpressure:progressHandler:)``
    /// and ``TTSSpeechSynthesizer/prepareNarration(_:using:options:into:chunker:progressHandler:)``).
    /// Defaults to ``TTSAudioCodec/wav`` so existing behavior is unchanged; a
    /// host opts into compression by passing e.g. `.aacLC(bitrate: 32_000)`.
    /// Playback is unaffected — `AVAudioFile` decodes every codec transparently
    /// — and word timings are codec-independent.
    public var audioCodec: TTSAudioCodec
    /// How chunk audio is stitched together: pauses after sentences and
    /// paragraphs plus click-free edge fades. Defaults to
    /// ``TTSChunkJoin/natural``; pass ``TTSChunkJoin/none`` for raw buffers.
    public var chunkJoin: TTSChunkJoin

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
        streamingInterval: Double = 2.0,
        audioCodec: TTSAudioCodec = .wav,
        chunkJoin: TTSChunkJoin = .natural
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
        self.audioCodec = audioCodec
        self.chunkJoin = chunkJoin
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
    /// `true` for silence the synthesizer inserted between chunks (see
    /// ``TTSChunkJoin``). Play and persist it like any other buffer; skip it
    /// when measuring how long the *speech* in a chunk is.
    public let isPadding: Bool

    public init(buffer: AVAudioPCMBuffer, sampleRate: Int, isPadding: Bool = false) {
        self.buffer = buffer
        self.sampleRate = sampleRate
        self.isPadding = isPadding
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
    /// Direct downloading of a specific model file from a static host failed.
    case modelDownloadFailed(file: String, status: Int)

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
            return "Loading \(modelID) failed: \(Self.describe(underlying))"
        case let .generationFailed(modelID, underlying):
            return "Generating audio with \(modelID) failed: \(Self.describe(underlying))"
        case let .networkUnavailable(underlying):
            if let underlying {
                return "Network unavailable: \(Self.describe(underlying))"
            }
            return "Network unavailable."
        case let .modelDownloadFailed(file, status):
            return "Downloading file '\(file)' failed with HTTP status \(status)."
        }
    }
}

extension TTSError {
    /// Text for an underlying error that is never blank. Some runtime failures
    /// (MLX C++ errors, bare `NSError`s) carry an empty `localizedDescription`,
    /// which left apps showing an alert with no message at all; fall back to
    /// the error's structural description and, failing that, its type.
    static func describe(_ error: Error) -> String {
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty { return localized }
        let structural = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !structural.isEmpty { return structural }
        return String(describing: type(of: error))
    }

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
    /// `cache` is where the runtime resolves (and, if needed, downloads) the
    /// model files. Pass the store's cache so loading looks in the same place
    /// the store downloaded to; the default is the runtime's own default cache.
    static func load(
        descriptor: TTSModelDescriptor,
        hfToken: String?,
        cache: HubCache = .default
    ) async throws -> any SpeechGenerationModel {
        try await TTS.loadModel(
            modelRepo: descriptor.id,
            hfToken: hfToken,
            cache: cache
        )
    }
}
