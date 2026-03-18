import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public actor TTSSpeechSynthesizer {
    private let modelStore: TTSModelStore

    public init(modelStore: TTSModelStore = TTSModelStore()) {
        self.modelStore = modelStore
    }

    public func modelStoreInstance() -> TTSModelStore {
        modelStore
    }

    public func synthesize(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSAudioFile {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TTSError.emptyText
        }

        _ = try await modelStore.ensureDownloaded(
            model,
            hfToken: options.hfToken,
            progressHandler: progressHandler
        )
        if let progressHandler {
            await progressHandler(.init(
                stage: .loadingModel,
                message: "Preparing synthesis pipeline..."
            ))
        }
        let loadedModel = try await MLXTTSModelLoader.load(descriptor: model, hfToken: options.hfToken)

        var parameters = loadedModel.defaultGenerationParameters
        options.generationProfile?.apply(to: &parameters)
        if let maxTokens = options.maxTokens {
            parameters.maxTokens = maxTokens
        }
        if let temperature = options.temperature {
            parameters.temperature = temperature
        }
        if let topP = options.topP {
            parameters.topP = topP
        }

        let referenceAudio = try options.referenceAudio.map(Self.loadReferenceAudio)

        if let progressHandler {
            await progressHandler(.init(
                stage: .generatingAudio,
                message: "Generating audio..."
            ))
        }
        let samples = try await Self.generateSamples(
            model: loadedModel,
            text: prompt,
            language: options.language?.identifier,
            voice: options.voice?.identifier,
            referenceAudio: referenceAudio,
            referenceText: options.referenceText,
            parameters: parameters
        )

        if let progressHandler {
            await progressHandler(.init(
                stage: .writingFile,
                message: "Writing WAV file..."
            ))
        }
        let outputURL = try options.outputURL ?? Self.makeDefaultOutputURL(fileManager: .default)
        let finalURL = outputURL.pathExtension.lowercased() == "wav"
            ? outputURL
            : outputURL.appendingPathExtension("wav")

        let parentDirectory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try AudioUtils.writeWavFile(
            samples: samples,
            sampleRate: Double(loadedModel.sampleRate),
            fileURL: finalURL
        )

        let audioFile = TTSAudioFile(
            url: finalURL,
            modelID: model.id,
            language: options.language,
            voice: options.voice,
            sampleRate: Int(loadedModel.sampleRate)
        )

        if let progressHandler {
            await progressHandler(.init(
                stage: .completed,
                fractionCompleted: 1,
                message: "Finished."
            ))
        }

        return audioFile
    }

#if canImport(AVFoundation)
    @MainActor
    public func synthesizeStream(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw TTSError.emptyText
        }

        _ = try await modelStore.ensureDownloaded(
            model,
            hfToken: options.hfToken,
            progressHandler: progressHandler
        )

        if let progressHandler {
            progressHandler(.init(
                stage: .loadingModel,
                message: "Preparing streaming pipeline..."
            ))
        }

        let loadedModel = try await MLXTTSModelLoader.load(descriptor: model, hfToken: options.hfToken)
        let parameters = Self.makeParameters(for: loadedModel, options: options)
        let referenceAudio = try options.referenceAudio.map(Self.loadReferenceAudio)
        let sampleRate = loadedModel.sampleRate
        let voice = options.voice?.identifier

        if let progressHandler {
            progressHandler(.init(
                stage: .generatingAudio,
                message: "Streaming audio..."
            ))
        }

        let upstream = try await Self.makePCMBufferStream(
            model: loadedModel,
            text: prompt,
            voice: voice,
            referenceAudio: referenceAudio,
            referenceText: options.referenceText,
            language: options.language?.identifier,
            parameters: parameters,
            streamingInterval: options.streamingInterval
        )

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        Task { @MainActor in
            do {
                for try await buffer in upstream {
                    continuation.yield(.init(buffer: buffer, sampleRate: sampleRate))
                }
                progressHandler?(.init(stage: .completed, fractionCompleted: 1, message: "Streaming finished."))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }
#endif
}

private extension TTSSpeechSynthesizer {
    static func loadReferenceAudio(from url: URL) throws -> MLXArray {
        let (_, audio) = try loadAudioArray(from: url)
        return audio
    }

    static func generateSamples(
        model: any SpeechGenerationModel,
        text: String,
        language: String?,
        voice: String?,
        referenceAudio: MLXArray?,
        referenceText: String?,
        parameters: GenerateParameters
    ) async throws -> [Float] {
        do {
            return try await model.generate(
                text: text,
                voice: voice,
                refAudio: referenceAudio,
                refText: referenceText,
                language: language,
                generationParameters: parameters
            ).asArray(Float.self)
        } catch {
            guard voice != nil else { throw error }
            return try await model.generate(
                text: text,
                voice: nil,
                refAudio: referenceAudio,
                refText: referenceText,
                language: language,
                generationParameters: parameters
            ).asArray(Float.self)
        }
    }

    static func makeParameters(
        for model: any SpeechGenerationModel,
        options: TTSSynthesisOptions
    ) -> GenerateParameters {
        var parameters = model.defaultGenerationParameters
        options.generationProfile?.apply(to: &parameters)
        if let maxTokens = options.maxTokens {
            parameters.maxTokens = maxTokens
        }
        if let temperature = options.temperature {
            parameters.temperature = temperature
        }
        if let topP = options.topP {
            parameters.topP = topP
        }
        return parameters
    }

#if canImport(AVFoundation)
    @MainActor
    static func makePCMBufferStream(
        model: any SpeechGenerationModel,
        text: String,
        voice: String?,
        referenceAudio: MLXArray?,
        referenceText: String?,
        language: String?,
        parameters: GenerateParameters,
        streamingInterval: Double
    ) async throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        if let voice {
            return model.generatePCMBufferStream(
                text: text,
                voice: voice,
                refAudio: referenceAudio,
                refText: referenceText,
                language: language,
                generationParameters: parameters,
                streamingInterval: streamingInterval
            )
        }

        return model.generatePCMBufferStream(
            text: text,
            voice: nil,
            refAudio: referenceAudio,
            refText: referenceText,
            language: language,
            generationParameters: parameters,
            streamingInterval: streamingInterval
        )
    }
#endif

    static func makeDefaultOutputURL(fileManager: FileManager) throws -> URL {
        #if os(iOS)
        let baseURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        #else
        let baseURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        #endif

        let outputDirectory = baseURL.appendingPathComponent("TTSMLX", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let filename = "speech-\(UUID().uuidString).wav"
        return outputDirectory.appendingPathComponent(filename)
    }
}
