import Foundation
import OSLog
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public actor TTSSpeechSynthesizer {
    private let modelStore: TTSModelStore
    private var diagnosticHandler: TTSDiagnosticHandler?
    nonisolated private let logger = Logger(subsystem: "technology.fil.ttsmlx", category: "Synthesizer")
    /// IDs of models that have been warmed (downloaded + initial-loaded at
    /// least once during this synthesizer's lifetime). Used by ``isLoaded(_:)``
    /// and lifecycle diagnostics. The model instance itself is owned by the
    /// upstream mlx-audio-swift runtime, not held here, because
    /// `SpeechGenerationModel` isn't `Sendable` and can't be safely cached on
    /// an actor while also being handed out to per-call generation code.
    private var warmedModelIDs: Set<String> = []

    public init(
        modelStore: TTSModelStore = TTSModelStore(),
        diagnosticHandler: TTSDiagnosticHandler? = nil
    ) {
        self.modelStore = modelStore
        self.diagnosticHandler = diagnosticHandler
    }

    public func modelStoreInstance() -> TTSModelStore {
        modelStore
    }

    /// Replace the diagnostic handler. Pass `nil` to stop receiving events.
    public func setDiagnosticHandler(_ handler: TTSDiagnosticHandler?) {
        diagnosticHandler = handler
    }

    nonisolated private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private func emit(_ event: TTSDiagnostic) {
        diagnosticHandler?(event)
    }

    // MARK: - Lifecycle

    /// Pre-warm a model: ensure it's downloaded and run the initial weight
    /// load so that the first `synthesize` / `synthesizeStream` call doesn't
    /// pay the cold-start cost. Subsequent calls still go through the upstream
    /// runtime, but on-disk files are hot and parsing time drops accordingly.
    ///
    /// Returns `true` if this call did the work, `false` if the model was
    /// already warmed during this synthesizer's lifetime.
    @discardableResult
    public func warmUp(
        _ model: TTSModelDescriptor,
        hfToken: String? = nil,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> Bool {
        if warmedModelIDs.contains(model.id) { return false }
        // Run the full prepareModel pipeline; discard the resulting instance.
        // Upstream caching makes the next load cheaper without us retaining a
        // reference here (see `warmedModelIDs` doc comment).
        _ = try await prepareModel(
            model,
            options: TTSSynthesisOptions(hfToken: hfToken),
            progressHandler: progressHandler
        )
        warmedModelIDs.insert(model.id)
        log("warmUp: marked \(model.id) ready")
        return true
    }

    /// `true` once ``warmUp(_:hfToken:progressHandler:)`` has run for the
    /// model during this synthesizer's lifetime.
    public func isLoaded(_ modelID: String) -> Bool {
        warmedModelIDs.contains(modelID)
    }

    /// Mark a model as no longer warmed. Emits ``TTSDiagnostic/modelUnloaded``.
    /// Does not currently free the upstream runtime's in-process weight cache
    /// (mlx-audio-swift owns that); the next synthesize call will re-load.
    public func unload(_ modelID: String) {
        if warmedModelIDs.remove(modelID) != nil {
            emit(.modelUnloaded(modelID: modelID))
            log("unload: \(modelID)")
        }
    }

    /// Clear every warmed-model marker.
    public func unloadAll() {
        let ids = Array(warmedModelIDs)
        warmedModelIDs.removeAll()
        for id in ids {
            emit(.modelUnloaded(modelID: id))
        }
        log("unloadAll: \(ids.count) model(s)")
    }

    /// One-call helper for iOS memory-warning notifications. Clears the warmed
    /// set and emits diagnostics; subsequent synthesize calls re-warm lazily.
    public func handleMemoryWarning() {
        log("memory warning received")
        unloadAll()
    }

    /// Internal seam used by tests to populate the warmed set without invoking
    /// MLX. Not part of the public API.
    func _markWarmedInternal(_ modelID: String) {
        warmedModelIDs.insert(modelID)
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
        emit(.requestStarted(modelID: model.id, textLength: prompt.count))
        log("synthesize start: model=\(model.id) chars=\(prompt.count)")

        let loadedModel = try await prepareModel(model, options: options, progressHandler: progressHandler)

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

        let generationStart = Date()
        let samples: [Float]
        do {
            samples = try await Self.generateSamples(
                model: loadedModel,
                text: prompt,
                language: options.language?.identifier,
                voice: options.voice?.identifier,
                referenceAudio: referenceAudio,
                referenceText: options.referenceText,
                parameters: parameters
            )
        } catch {
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .generatingAudio)
            emit(.errorOccurred(modelID: model.id, stage: .generatingAudio, error: wrapped))
            throw wrapped
        }
        emit(.synthesisFinished(
            modelID: model.id,
            duration: Date().timeIntervalSince(generationStart),
            sampleCount: samples.count
        ))

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
        await emitFromMain(.requestStarted(modelID: model.id, textLength: prompt.count))

        let loadedModel = try await prepareModel(model, options: options, progressHandler: progressHandler)
        let parameters = Self.makeParameters(for: loadedModel, options: options)
        let referenceAudio = try options.referenceAudio.map(Self.loadReferenceAudio)
        let sampleRate = loadedModel.sampleRate
        let voice = options.voice?.identifier
        let modelID = model.id

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
        let synthesizer = self
        let streamStart = Date()
        Task { @MainActor in
            var bufferCount = 0
            var firstBufferEmitted = false
            do {
                for try await buffer in upstream {
                    if !firstBufferEmitted, buffer.frameLength > 0 {
                        firstBufferEmitted = true
                        let latency = Date().timeIntervalSince(streamStart)
                        await synthesizer.emitFromMain(
                            .firstBufferYielded(modelID: modelID, latency: latency)
                        )
                    }
                    continuation.yield(.init(buffer: buffer, sampleRate: sampleRate))
                    bufferCount += 1
                }
                progressHandler?(.init(stage: .completed, fractionCompleted: 1, message: "Streaming finished."))
                await synthesizer.emitFromMain(.streamingFinished(
                    modelID: modelID,
                    duration: Date().timeIntervalSince(streamStart),
                    bufferCount: bufferCount
                ))
                continuation.finish()
            } catch {
                let wrapped = TTSError.wrap(error, modelID: modelID, stage: .generatingAudio)
                await synthesizer.emitFromMain(
                    .errorOccurred(modelID: modelID, stage: .generatingAudio, error: wrapped)
                )
                continuation.finish(throwing: wrapped)
            }
        }
        return stream
    }

    /// Helper to emit a diagnostic from a non-actor isolated context (e.g. the
    /// `@MainActor` Task that drains the streaming continuation).
    func emitFromMain(_ event: TTSDiagnostic) {
        emit(event)
    }

    /// Streams synthesis for long-form text by splitting it into smaller chunks
    /// before driving ``synthesizeStream(_:using:options:progressHandler:)``.
    ///
    /// The first chunk is sized for a fast time-to-first-buffer; subsequent
    /// chunks use a larger budget. Buffers from every chunk are flattened into
    /// the returned stream in order, so callers can treat the result the same
    /// way they treat a single-shot ``synthesizeStream`` call.
    @MainActor
    public func synthesizeLong(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TTSError.emptyText }

        // Use chunkInfos against the ORIGINAL text so emitted character ranges
        // map directly to what the caller passed in (matches their highlight
        // overlay coordinates).
        let chunkInfos = chunker.chunkInfos(for: text)
        guard !chunkInfos.isEmpty else { throw TTSError.emptyText }

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let total = chunkInfos.count
        let synthesizer = self
        let modelID = model.id

        Task { @MainActor in
            do {
                for (index, info) in chunkInfos.enumerated() {
                    try Task.checkCancellation()
                    let chunkStartedAt = Date()
                    var didEmitChunkStart = false

                    let chunkStream = try await synthesizer.synthesizeStream(
                        info.text,
                        using: model,
                        options: options,
                        progressHandler: { update in
                            guard update.stage != .completed else { return }
                            progressHandler?(.init(
                                stage: update.stage,
                                fractionCompleted: Self.combinedFraction(
                                    chunkIndex: index,
                                    chunkFraction: update.fractionCompleted,
                                    chunkCount: total
                                ),
                                message: update.message
                            ))
                        }
                    )

                    for try await pcmChunk in chunkStream {
                        try Task.checkCancellation()
                        if !didEmitChunkStart, pcmChunk.buffer.frameLength > 0 {
                            didEmitChunkStart = true
                            await synthesizer.emitFromMain(.chunkStarted(
                                modelID: modelID,
                                chunkIndex: index,
                                characterRange: info.characterRange
                            ))
                        }
                        continuation.yield(pcmChunk)
                    }
                    await synthesizer.emitFromMain(.chunkFinished(
                        modelID: modelID,
                        chunkIndex: index,
                        duration: Date().timeIntervalSince(chunkStartedAt)
                    ))
                }
                progressHandler?(.init(
                    stage: .completed,
                    fractionCompleted: 1,
                    message: "Long-form synthesis finished."
                ))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        return stream
    }

    static func combinedFraction(
        chunkIndex: Int,
        chunkFraction: Double?,
        chunkCount: Int
    ) -> Double? {
        guard chunkCount > 0 else { return nil }
        let base = Double(chunkIndex) / Double(chunkCount)
        guard let chunkFraction else { return base }
        return base + (chunkFraction / Double(chunkCount))
    }

    /// Pre-generate the entire text into a single combined audio file before
    /// playback. Unlike ``synthesizeLong``, this returns *after* every chunk
    /// has been written to disk — appropriate for "download for offline" UX
    /// where the caller wants one file, not a buffer stream.
    ///
    /// The output is a WAV. If `outputURL` already exists, it's overwritten.
    @MainActor
    public func synthesizeAll(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        into outputURL: URL,
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSAudioFile {
        let stream = try await synthesizeLong(
            text,
            using: model,
            options: options,
            chunker: chunker,
            progressHandler: progressHandler
        )

        let finalURL = outputURL.pathExtension.lowercased() == "wav"
            ? outputURL
            : outputURL.appendingPathExtension("wav")
        let parentDirectory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }

        var audioFile: AVAudioFile?
        var sampleRate: Int = 0
        for try await chunk in stream {
            let buffer = chunk.buffer
            guard buffer.frameLength > 0 else { continue }
            if audioFile == nil {
                let format = buffer.format
                sampleRate = chunk.sampleRate
                audioFile = try AVAudioFile(
                    forWriting: finalURL,
                    settings: format.settings,
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
        }
        audioFile = nil

        return TTSAudioFile(
            url: finalURL,
            modelID: model.id,
            language: options.language,
            voice: options.voice,
            sampleRate: sampleRate
        )
    }

    /// Get a synthesizer fully ready to play: warm up the model **and**
    /// pre-generate the first chunk so the first tap on Play hands the user
    /// audio immediately from cache instead of waiting for inference.
    ///
    /// `initialText` should be the first paragraph/sentence the user will
    /// hear. The full text isn't generated here — call `synthesizeLong` or
    /// `synthesizeAll` separately for the rest, or hand the remainder to
    /// ``TTSPrefetchQueue``.
    ///
    /// Returns the cached URL of the first chunk's audio, suitable for a
    /// pre-warmed AVAudioPlayer.
    @MainActor
    public func prepareForPlayback(
        using model: TTSModelDescriptor,
        initialText: String,
        options: TTSSynthesisOptions = .init(),
        cache: TTSAudioCache,
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> URL {
        _ = try await warmUp(model, hfToken: options.hfToken, progressHandler: progressHandler)

        let chunks = chunker.chunks(for: initialText)
        guard let firstChunk = chunks.first else { throw TTSError.emptyText }

        let key = await cache.key(modelID: model.id, voice: options.voice, text: firstChunk)
        if let cachedURL = await cache.cachedURL(forKey: key) {
            return cachedURL
        }

        let handle = await cache.reserveWrite(forKey: key)
        let stream = try await synthesizeStream(
            firstChunk,
            using: model,
            options: options,
            progressHandler: progressHandler
        )

        var audioFile: AVAudioFile?
        do {
            for try await chunk in stream {
                let buffer = chunk.buffer
                guard buffer.frameLength > 0 else { continue }
                if audioFile == nil {
                    let format = buffer.format
                    audioFile = try AVAudioFile(
                        forWriting: handle.temporaryURL,
                        settings: format.settings,
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                }
                try audioFile?.write(from: buffer)
            }
            audioFile = nil
        } catch {
            await cache.discard(handle)
            throw error
        }

        return try await cache.finalize(handle)
    }
#endif

    /// Centralizes the ensureDownloaded + load pipeline so that lifecycle
    /// diagnostics (resolve, download, load) are emitted from one place and
    /// caught errors are mapped to the right `TTSError` case. Consults the
    /// in-memory model cache before re-loading from disk.
    func prepareModel(
        _ model: TTSModelDescriptor,
        options: TTSSynthesisOptions,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)?
    ) async throws -> sending any SpeechGenerationModel {
        let resolveStart = Date()
        let wasInstalled = await modelStore.isInstalled(model.id)
        emit(.modelResolveFinished(
            modelID: model.id,
            wasInstalled: wasInstalled,
            duration: Date().timeIntervalSince(resolveStart)
        ))

        if !wasInstalled {
            emit(.modelDownloadStarted(modelID: model.id))
        }
        let downloadStart = Date()
        do {
            _ = try await modelStore.ensureDownloaded(
                model,
                hfToken: options.hfToken,
                progressHandler: progressHandler
            )
        } catch {
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .downloadingModel)
            emit(.errorOccurred(modelID: model.id, stage: .downloadingModel, error: wrapped))
            throw wrapped
        }
        if !wasInstalled {
            emit(.modelDownloadFinished(
                modelID: model.id,
                duration: Date().timeIntervalSince(downloadStart)
            ))
        }

        if let progressHandler {
            await progressHandler(.init(
                stage: .loadingModel,
                message: "Preparing synthesis pipeline..."
            ))
        }
        emit(.modelLoadStarted(modelID: model.id))
        let loadStart = Date()
        let loaded: any SpeechGenerationModel
        do {
            loaded = try await MLXTTSModelLoader.load(descriptor: model, hfToken: options.hfToken)
        } catch {
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .loadingModel)
            emit(.errorOccurred(modelID: model.id, stage: .loadingModel, error: wrapped))
            throw wrapped
        }
        emit(.modelLoadFinished(
            modelID: model.id,
            duration: Date().timeIntervalSince(loadStart)
        ))
        warmedModelIDs.insert(model.id)
        return loaded
    }
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
