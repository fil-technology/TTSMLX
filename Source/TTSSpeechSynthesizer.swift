import Foundation
import OSLog
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
@preconcurrency import MLXLMCommon
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Holds a loaded `SpeechGenerationModel` so the actor can keep weights
/// resident across calls. The upstream type isn't `Sendable`, but the
/// box is — that's how we hand the cached instance across the actor /
/// MainActor boundary without re-loading. Concurrent generation against
/// the *same* boxed model from two callers is undefined: the synthesizer
/// is designed for serial use (UI playback, prefetch queue) and that's
/// the contract. Run parallel pipelines with separate `TTSSpeechSynthesizer`
/// instances.
final class LoadedModelBox: @unchecked Sendable {
    let model: any SpeechGenerationModel
    init(_ model: any SpeechGenerationModel) { self.model = model }
}

public actor TTSSpeechSynthesizer {
    private let modelStore: TTSModelStore
    private var diagnosticHandler: TTSDiagnosticHandler?
    private var eventContinuations: [UUID: AsyncStream<TTSDiagnostic>.Continuation] = [:]
    nonisolated private let logger = Logger(subsystem: "technology.fil.ttsmlx", category: "Synthesizer")
    /// Loaded model instances keyed by `descriptor.id`. Populated by
    /// ``prepareModel(_:options:progressHandler:)`` on first use and reused
    /// on every subsequent call until ``unload(_:)`` /  ``unloadAll()``
    /// (or ``handleMemoryWarning()``) drop the entry. `warmedModelIDs`
    /// stays in sync with `loadedModels.keys` and is kept as a small
    /// `Set<String>` to keep `isLoaded(_:)` O(1) without exposing the box.
    private var loadedModels: [String: LoadedModelBox] = [:]
    private var warmedModelIDs: Set<String> = []

    /// In-flight generation Tasks spawned by streaming methods. Tracked so
    /// they can be cancelled on app backgrounding (or explicit
    /// ``cancelAllInFlight()``). Cancellation is cooperative — each Task
    /// checks `Task.isCancelled` at MLX-stream iteration boundaries, then
    /// finishes its `AsyncThrowingStream` continuation with a
    /// `CancellationError` so the consumer sees a clean error rather than a
    /// crash.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    /// When `false` (the default), in-flight generation is cancelled the
    /// moment the app enters the background. Set to `true` only if the
    /// caller owns its own `UIApplication.beginBackgroundTask` assertion
    /// and wants to keep generating past backgrounding — without that
    /// assertion, MLX Metal command-buffer submissions from the background
    /// crash the process with
    /// `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`.
    public var allowsBackgroundGeneration: Bool = false

    public init(
        modelStore: TTSModelStore = TTSModelStore(),
        diagnosticHandler: TTSDiagnosticHandler? = nil
    ) {
        self.modelStore = modelStore
        self.diagnosticHandler = diagnosticHandler
        // Block-style notification observer because we need a SYNCHRONOUS
        // entry point on the main thread to call `Stream.gpu.synchronize()`
        // before iOS clamps Metal access. The async-iterator variant we used
        // previously deferred the work through Task scheduling, which routinely
        // arrived too late — Metal command buffers submitted by the
        // in-flight `generate()` were already in flight and fired in
        // background, crashing the process.
        //
        // We listen to `willResignActive` (the earliest signal — fires before
        // `didEnterBackground` and while Metal access is still permitted).
        // The block:
        //   1. Calls `Stream.gpu.synchronize()` SYNCHRONOUSLY on the main
        //      thread. This blocks until every queued GPU command finishes,
        //      so by the time the OS proceeds with backgrounding nothing is
        //      in flight to be rejected.
        //   2. Dispatches an async task to cancel the tracked drain Tasks.
        //      Cooperative cancellation lands at their next `await`.
        //
        // We accept that the observer leaks into NotificationCenter when the
        // synthesizer deallocates (NotificationCenter holds the block
        // strongly until removal, but the block's `[weak self]` capture lets
        // self deallocate normally). In practice synthesizers live for the
        // app lifetime, so this never matters.
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Drain pending GPU work while Metal is still allowed.
            Stream.gpu.synchronize()
            guard let self else { return }
            Task {
                if await !self.allowsBackgroundGeneration {
                    await self.cancelAllInFlight(reason: .background)
                }
            }
        }
        #endif
    }

    /// Cancel every in-flight generation Task. Streams that were in progress
    /// finish with a `CancellationError`; future `synthesize*` calls are
    /// unaffected. Emits ``TTSDiagnostic/cancelledByBackground`` when called
    /// in response to a backgrounding notification, so observers can show
    /// "paused — app backgrounded" UX.
    public func cancelAllInFlight(reason: CancellationReason = .explicit) {
        guard !inFlightTasks.isEmpty else { return }
        let count = inFlightTasks.count
        for task in inFlightTasks.values { task.cancel() }
        inFlightTasks.removeAll()
        log("cancelAllInFlight: cancelled \(count) task(s) reason=\(reason)")
        if reason == .background {
            emit(.cancelledByBackground(cancelledCount: count))
        }
    }

    public enum CancellationReason: Sendable, Hashable {
        case background
        case explicit
    }

    fileprivate func trackTask(id: UUID, _ task: Task<Void, Never>) {
        inFlightTasks[id] = task
    }

    fileprivate func untrackTask(id: UUID) {
        inFlightTasks.removeValue(forKey: id)
    }

    public func modelStoreInstance() -> TTSModelStore {
        modelStore
    }

    /// Replace the diagnostic handler. Pass `nil` to stop receiving events.
    public func setDiagnosticHandler(_ handler: TTSDiagnosticHandler?) {
        diagnosticHandler = handler
    }

    /// A typed event stream of every ``TTSDiagnostic`` this synthesizer emits.
    /// Prefer this over ``setDiagnosticHandler(_:)`` for SwiftUI consumers —
    /// you can `for await event in await synthesizer.events()` without
    /// bridging through `NotificationCenter` or a `@Sendable` closure.
    ///
    /// Each call returns an independent stream; the closure handler is still
    /// invoked in parallel for callers that want both. Streams finish when
    /// the consumer cancels iteration or when the synthesizer is deallocated.
    public func events() -> AsyncStream<TTSDiagnostic> {
        let (stream, continuation) = AsyncStream<TTSDiagnostic>.makeStream()
        let id = UUID()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.removeEventContinuation(id: id)
            }
        }
        return stream
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    nonisolated private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    nonisolated private func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    nonisolated private func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    /// Standardized error logger so every catch site emits the same shape:
    /// `ERROR <site>: modelID=<id> stage=<stage> underlying=<description>`.
    /// Read in Console.app by filtering subsystem `technology.fil.ttsmlx`
    /// category `Synthesizer` (or `Playback`, `Prefetch`).
    nonisolated private func logError(
        _ site: String,
        modelID: String?,
        stage: String?,
        error: Error
    ) {
        let id = modelID ?? "?"
        let s = stage ?? "?"
        let description = error.localizedDescription
        logger.error("ERROR \(site, privacy: .public): modelID=\(id, privacy: .public) stage=\(s, privacy: .public) underlying=\(description, privacy: .public)")
    }

    private func emit(_ event: TTSDiagnostic) {
        diagnosticHandler?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Read-only state dump for ad-hoc diagnosis. Safe to call from anywhere.
    /// Mirrored into `os.Logger.info` so it shows up alongside synthesis
    /// logs when you're trying to correlate "why didn't generation start."
    public struct Snapshot: Sendable, Hashable {
        public let warmedModelIDs: [String]
        public let eventStreamSubscriberCount: Int
        public let hasClosureHandler: Bool
    }

    public func snapshot() -> Snapshot {
        let snap = Snapshot(
            warmedModelIDs: Array(warmedModelIDs).sorted(),
            eventStreamSubscriberCount: eventContinuations.count,
            hasClosureHandler: diagnosticHandler != nil
        )
        info("snapshot: warmed=\(snap.warmedModelIDs) subscribers=\(snap.eventStreamSubscriberCount) closureHandler=\(snap.hasClosureHandler)")
        return snap
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

    /// Drop the cached weight instance and clear the warmed marker so the
    /// next synthesize call goes through the full load pipeline again.
    /// Emits ``TTSDiagnostic/modelUnloaded``. Memory is released as soon
    /// as the underlying MLX runtime has no other strong references.
    public func unload(_ modelID: String) {
        let droppedInstance = loadedModels.removeValue(forKey: modelID) != nil
        let droppedMarker = warmedModelIDs.remove(modelID) != nil
        if droppedInstance || droppedMarker {
            emit(.modelUnloaded(modelID: modelID))
            log("unload: \(modelID) instance=\(droppedInstance) marker=\(droppedMarker)")
        }
    }

    /// Drop every cached weight instance and clear the warmed set.
    public func unloadAll() {
        let ids = Array(warmedModelIDs.union(loadedModels.keys))
        loadedModels.removeAll()
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
            info("synthesize: REJECTED empty text")
            throw TTSError.emptyText
        }
        info("synthesize: ENTRY model=\(model.id) chars=\(prompt.count) voice=\(options.voice?.identifier ?? "nil")")
        emit(.requestStarted(modelID: model.id, textLength: prompt.count))

        let loadedBox = try await prepareModel(model, options: options, progressHandler: progressHandler)
        let loadedModel = loadedBox.model

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

        info("synthesize: calling MLX.generate for \(model.id)")
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
            logError("synthesize.generate", modelID: model.id, stage: "generatingAudio", error: error)
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .generatingAudio)
            emit(.errorOccurred(modelID: model.id, stage: .generatingAudio, error: wrapped))
            throw wrapped
        }
        let generationDuration = Date().timeIntervalSince(generationStart)
        if samples.isEmpty {
            logger.warning("synthesize: MLX.generate returned ZERO samples for \(model.id, privacy: .public). Model loaded but produced no audio — likely a runtime issue.")
        } else {
            info("synthesize: MLX.generate produced \(samples.count) samples in \(String(format: "%.2f", generationDuration))s")
        }
        emit(.synthesisFinished(
            modelID: model.id,
            duration: generationDuration,
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
    public func synthesizeStream(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            info("synthesizeStream: REJECTED empty text")
            throw TTSError.emptyText
        }
        info("synthesizeStream: ENTRY model=\(model.id) chars=\(prompt.count) voice=\(options.voice?.identifier ?? "nil") interval=\(options.streamingInterval)s")
        emit(.requestStarted(modelID: model.id, textLength: prompt.count))

        let loadedBox = try await prepareModel(model, options: options, progressHandler: progressHandler)
        let modelID = model.id
        let capturedPrompt = prompt
        let capturedOptions = options

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let synthesizer = self
        let streamStart = Date()
        let taskID = UUID()
        // Drainer stays on MainActor so the user-facing `progressHandler`
        // (which is `@MainActor`) can be called synchronously and so the
        // upstream MLX `generatePCMBufferStream` (also MainActor-isolated)
        // is invoked from the actor it expects. The returned MLX stream is
        // non-Sendable, so it must be created AND consumed on the same
        // actor — that's why MLX setup and the drain loop both live inside
        // this Task rather than crossing the boundary from the synthesizer
        // actor.
        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            var bufferCount = 0
            var emptyBufferCount = 0
            var firstBufferEmitted = false
            do {
                try Task.checkCancellation()
                let loadedModel = loadedBox.model
                let parameters = Self.makeParameters(for: loadedModel, options: capturedOptions)
                let referenceAudio = try capturedOptions.referenceAudio.map(Self.loadReferenceAudio)
                let sampleRate = loadedModel.sampleRate
                progressHandler?(.init(
                    stage: .generatingAudio,
                    message: "Streaming audio..."
                ))
                let upstream = try await Self.makePCMBufferStream(
                    model: loadedModel,
                    text: capturedPrompt,
                    voice: capturedOptions.voice?.identifier,
                    referenceAudio: referenceAudio,
                    referenceText: capturedOptions.referenceText,
                    language: capturedOptions.language?.identifier,
                    parameters: parameters,
                    streamingInterval: capturedOptions.streamingInterval
                )
                for try await buffer in upstream {
                    if buffer.frameLength == 0 {
                        emptyBufferCount += 1
                        continue
                    }
                    if !firstBufferEmitted {
                        firstBufferEmitted = true
                        let latency = Date().timeIntervalSince(streamStart)
                        synthesizer.info("synthesizeStream[\(modelID)]: FIRST BUFFER at \(String(format: "%.2f", latency))s, frameLength=\(buffer.frameLength)")
                        await synthesizer.emit(
                            .firstBufferYielded(modelID: modelID, latency: latency)
                        )
                    }
                    continuation.yield(.init(buffer: buffer, sampleRate: sampleRate))
                    bufferCount += 1
                    // Periodic progress log for long streams (every 25 buffers).
                    if bufferCount.isMultiple(of: 25) {
                        synthesizer.info("synthesizeStream[\(modelID)]: \(bufferCount) buffers yielded so far")
                    }
                }
                let totalDuration = Date().timeIntervalSince(streamStart)
                progressHandler?(.init(stage: .completed, fractionCompleted: 1, message: "Streaming finished."))
                if bufferCount == 0 {
                    synthesizer.warning("synthesizeStream[\(modelID)]: FINISHED WITH ZERO BUFFERS after \(String(format: "%.2f", totalDuration))s (empty=\(emptyBufferCount)). MLX path ran but emitted no audio. Most common causes: (1) text contained only punctuation, (2) MLX runtime issue on this device, (3) model loaded but generate path is mis-wired upstream. Check that another model produces audio on the same device.")
                } else {
                    synthesizer.info("synthesizeStream[\(modelID)]: FINISHED total=\(bufferCount) buffers (empty=\(emptyBufferCount) skipped) in \(String(format: "%.2f", totalDuration))s")
                }
                await synthesizer.emit(.streamingFinished(
                    modelID: modelID,
                    duration: totalDuration,
                    bufferCount: bufferCount
                ))
                continuation.finish()
            } catch is CancellationError {
                synthesizer.info("synthesizeStream[\(modelID)]: CANCELLED")
                continuation.finish(throwing: CancellationError())
            } catch {
                synthesizer.logError("synthesizeStream.upstream", modelID: modelID, stage: "generatingAudio", error: error)
                let wrapped = TTSError.wrap(error, modelID: modelID, stage: .generatingAudio)
                await synthesizer.emit(
                    .errorOccurred(modelID: modelID, stage: .generatingAudio, error: wrapped)
                )
                continuation.finish(throwing: wrapped)
            }
        }
        trackTask(id: taskID, drainTask)
        return stream
    }

    /// Streams synthesis for long-form text by splitting it into smaller chunks
    /// before driving ``synthesizeStream(_:using:options:progressHandler:)``.
    ///
    /// The first chunk is sized for a fast time-to-first-buffer; subsequent
    /// chunks use a larger budget. Buffers from every chunk are flattened into
    /// the returned stream in order, so callers can treat the result the same
    /// way they treat a single-shot ``synthesizeStream`` call.
    public func synthesizeLong(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            info("synthesizeLong: REJECTED empty text")
            throw TTSError.emptyText
        }

        // Use chunkInfos against the ORIGINAL text so emitted character ranges
        // map directly to what the caller passed in (matches their highlight
        // overlay coordinates).
        let chunkInfos = chunker.chunkInfos(for: text)
        guard !chunkInfos.isEmpty else {
            info("synthesizeLong: REJECTED text produced zero chunks (likely whitespace/punctuation only)")
            throw TTSError.emptyText
        }

        info("synthesizeLong: ENTRY model=\(model.id) chars=\(text.count) chunks=\(chunkInfos.count)")

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let total = chunkInfos.count
        let synthesizer = self
        let modelID = model.id
        let taskID = UUID()

        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            do {
                for (index, info) in chunkInfos.enumerated() {
                    try Task.checkCancellation()
                    synthesizer.info("synthesizeLong[\(modelID)]: chunk \(index + 1)/\(total) chars=\(info.text.count)")
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
                            await synthesizer.emit(.chunkStarted(
                                modelID: modelID,
                                chunkIndex: index,
                                characterRange: info.characterRange
                            ))
                        }
                        continuation.yield(pcmChunk)
                    }
                    let chunkDuration = Date().timeIntervalSince(chunkStartedAt)
                    synthesizer.info("synthesizeLong[\(modelID)]: chunk \(index + 1)/\(total) FINISHED in \(String(format: "%.2f", chunkDuration))s (didStart=\(didEmitChunkStart))")
                    await synthesizer.emit(.chunkFinished(
                        modelID: modelID,
                        chunkIndex: index,
                        duration: chunkDuration
                    ))
                    let timings = info.wordTimings(forDuration: chunkDuration)
                    if !timings.isEmpty {
                        await synthesizer.emit(.chunkTimings(
                            modelID: modelID,
                            chunkIndex: index,
                            timings: timings
                        ))
                    }
                }
                progressHandler?(.init(
                    stage: .completed,
                    fractionCompleted: 1,
                    message: "Long-form synthesis finished."
                ))
                synthesizer.info("synthesizeLong[\(modelID)]: ALL \(total) chunks FINISHED")
                continuation.finish()
            } catch is CancellationError {
                synthesizer.info("synthesizeLong[\(modelID)]: CANCELLED")
                continuation.finish(throwing: CancellationError())
            } catch {
                synthesizer.logError("synthesizeLong.chunkLoop", modelID: modelID, stage: "generatingAudio", error: error)
                continuation.finish(throwing: error)
            }
        }
        trackTask(id: taskID, drainTask)

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

    /// Stream synthesis like ``synthesizeLong``, but cache progress to a
    /// ``TTSPreparedNarration`` bundle **per-chunk** as you go. The same
    /// bundle format we ship for onboarding voiceovers, used here as the
    /// runtime cache.
    ///
    /// First call with a fresh `cacheBundleAt` URL: generates every chunk,
    /// writes each chunk's WAV to `bundleURL/chunks/NNN.wav` and the
    /// manifest **as soon as the chunk completes** (not after the whole
    /// stream). If the stream is cancelled — backgrounding, watchdog,
    /// user-tap — the chunks completed so far remain valid on disk.
    ///
    /// Next call with the same `bundleURL`: the framework reads the
    /// manifest, verifies it matches the call's `model` / `voice` /
    /// `text`, and replays each cached chunk **without invoking MLX**.
    /// Missing chunks fall through to generation. This is the right
    /// primitive for "generate once, replay forever, fast" chapter-level
    /// flows — and it's resilient to mid-stream cancellation by
    /// construction.
    ///
    /// If the existing manifest's `modelID` / `voice` / `sourceText`
    /// don't match the call's arguments, the stale bundle is wiped and a
    /// fresh one is started — so callers can pick `cacheBundleAt` from
    /// any stable identifier (chapter id, hash of inputs, etc.) without
    /// having to invalidate it themselves on voice/model switches.
    ///
    /// Diagnostics (`chunkStarted`, `chunkFinished`, `chunkTimings`) are
    /// emitted whether the chunk replays from disk or generates fresh —
    /// the consumer's highlight UI doesn't need to distinguish.
    public func streamAndCacheNarration(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        cacheBundleAt bundleURL: URL,
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            info("streamAndCacheNarration: REJECTED empty text")
            throw TTSError.emptyText
        }
        let chunkInfos = chunker.chunkInfos(for: text)
        guard !chunkInfos.isEmpty else {
            info("streamAndCacheNarration: REJECTED text produced zero chunks")
            throw TTSError.emptyText
        }

        let modelID = model.id
        let voiceID = options.voice?.identifier
        let languageID = options.language?.identifier

        let fileManager = FileManager.default
        let chunksDir = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        // Load existing manifest, validate against this call's args. Mismatch
        // (different model/voice/text) → wipe and start fresh, so a stable
        // bundleURL can be used across voice/model switches without manual
        // invalidation on the caller's side.
        var workingManifest: TTSPreparedNarrationManifest
        var workingEntries: [Int: TTSPreparedNarrationManifest.ChunkEntry] = [:]
        if let existing = try? TTSPreparedNarration(importing: bundleURL).manifest,
           existing.modelID == modelID,
           existing.voice == voiceID,
           existing.sourceText == text,
           existing.chunks.count <= chunkInfos.count,
           existing.chunks.allSatisfy({ entry in
               entry.index < chunkInfos.count
                   && entry.text == chunkInfos[entry.index].text
           }) {
            workingManifest = existing
            for entry in existing.chunks { workingEntries[entry.index] = entry }
        } else {
            try? fileManager.removeItem(at: bundleURL)
            try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
            workingManifest = TTSPreparedNarrationManifest(
                modelID: modelID,
                voice: voiceID,
                language: languageID,
                sourceText: text,
                sampleRate: 0,
                chunks: []
            )
        }

        let cachedCount = workingEntries.count
        let totalChunks = chunkInfos.count
        info("streamAndCacheNarration: ENTRY model=\(modelID) chunks=\(totalChunks) cached=\(cachedCount)/\(totalChunks) bundle=\(bundleURL.lastPathComponent)")

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let synthesizer = self
        let taskID = UUID()

        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            do {
                for (index, info) in chunkInfos.enumerated() {
                    try Task.checkCancellation()
                    let chunkFilename = String(format: "chunks/%03d.wav", index)
                    let chunkURL = bundleURL.appendingPathComponent(chunkFilename, isDirectory: false)
                    let entry = workingEntries[index]
                    let fileExists = fileManager.fileExists(atPath: chunkURL.path)

                    if let entry, fileExists, entry.text == info.text,
                       let chunkFile = try? AVAudioFile(forReading: chunkURL),
                       chunkFile.length > 0,
                       let buffer = AVAudioPCMBuffer(
                           pcmFormat: chunkFile.processingFormat,
                           frameCapacity: AVAudioFrameCount(chunkFile.length)
                       ) {
                        // ────── REPLAY PATH ──────
                        synthesizer.info("streamAndCacheNarration[\(modelID)]: chunk \(index + 1)/\(totalChunks) REPLAY from cache")
                        try chunkFile.read(into: buffer)
                        let sampleRate = Int(chunkFile.processingFormat.sampleRate.rounded())
                        await synthesizer.emit(.chunkStarted(
                            modelID: modelID, chunkIndex: index,
                            characterRange: info.characterRange
                        ))
                        continuation.yield(.init(buffer: buffer, sampleRate: sampleRate))
                        await synthesizer.emit(.chunkFinished(
                            modelID: modelID, chunkIndex: index,
                            duration: entry.duration
                        ))
                        let liveTimings = entry.wordTimings.map { ser -> TTSWordTiming in
                            let base = info.characterRange.lowerBound
                            return TTSWordTiming(
                                characterRange: (base + ser.characterRange.start)..<(base + ser.characterRange.end),
                                offset: ser.offset,
                                duration: ser.duration
                            )
                        }
                        if !liveTimings.isEmpty {
                            await synthesizer.emit(.chunkTimings(
                                modelID: modelID, chunkIndex: index, timings: liveTimings
                            ))
                        }
                    } else {
                        // ────── GENERATION PATH ──────
                        // Either the entry doesn't exist, the file doesn't
                        // exist, the cached chunk text changed, or the cached
                        // file is corrupt/empty. Drop any stale entry first.
                        if entry != nil {
                            workingEntries.removeValue(forKey: index)
                            try? fileManager.removeItem(at: chunkURL)
                            synthesizer.warning("streamAndCacheNarration[\(modelID)]: chunk \(index + 1) cached file invalid, regenerating")
                        }
                        try await Self.generateAndPersist(
                            index: index,
                            info: info,
                            model: model,
                            options: options,
                            modelID: modelID,
                            chunkURL: chunkURL,
                            chunkFilename: chunkFilename,
                            bundleURL: bundleURL,
                            workingManifest: &workingManifest,
                            workingEntries: &workingEntries,
                            continuation: continuation,
                            synthesizer: synthesizer
                        )
                    }
                }
                synthesizer.info("streamAndCacheNarration[\(modelID)]: ALL \(totalChunks) chunks DONE (replayed=\(cachedCount) generated=\(totalChunks - cachedCount))")
                progressHandler?(.init(stage: .completed, fractionCompleted: 1, message: "Synthesis + cache finished."))
                continuation.finish()
            } catch is CancellationError {
                synthesizer.info("streamAndCacheNarration[\(modelID)]: CANCELLED. \(workingEntries.count)/\(totalChunks) chunks cached on disk for next call.")
                continuation.finish(throwing: CancellationError())
            } catch {
                synthesizer.logError("streamAndCacheNarration", modelID: modelID, stage: "generatingAudio", error: error)
                continuation.finish(throwing: error)
            }
        }
        trackTask(id: taskID, drainTask)
        return stream
    }

    /// Generation helper, factored out so both the fresh-chunk path and the
    /// corrupt-cached-chunk-recovery path share one implementation.
    private static func generateAndPersist(
        index: Int,
        info: TTSChunkInfo,
        model: TTSModelDescriptor,
        options: TTSSynthesisOptions,
        modelID: String,
        chunkURL: URL,
        chunkFilename: String,
        bundleURL: URL,
        workingManifest: inout TTSPreparedNarrationManifest,
        workingEntries: inout [Int: TTSPreparedNarrationManifest.ChunkEntry],
        continuation: AsyncThrowingStream<TTSAudioBufferChunk, Error>.Continuation,
        synthesizer: TTSSpeechSynthesizer
    ) async throws {
        synthesizer.info("streamAndCacheNarration[\(modelID)]: chunk \(index + 1) GENERATING")
        var didEmitChunkStart = false
        var audioFile: AVAudioFile?
        var frameCount: AVAudioFramePosition = 0
        var chunkSampleRate: Double = 0
        let chunkStream = try await synthesizer.synthesizeStream(
            info.text, using: model, options: options, progressHandler: nil
        )
        for try await pcm in chunkStream {
            try Task.checkCancellation()
            let buffer = pcm.buffer
            guard buffer.frameLength > 0 else { continue }
            if !didEmitChunkStart {
                didEmitChunkStart = true
                await synthesizer.emit(.chunkStarted(
                    modelID: modelID, chunkIndex: index,
                    characterRange: info.characterRange
                ))
            }
            if audioFile == nil {
                chunkSampleRate = buffer.format.sampleRate
                audioFile = try AVAudioFile(
                    forWriting: chunkURL,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
            continuation.yield(pcm)
        }
        audioFile = nil
        guard chunkSampleRate > 0, frameCount > 0 else {
            throw TTSError.generationFailed(modelID: modelID, underlying: NSError(
                domain: "streamAndCacheNarration", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Chunk \(index) produced no audio."
                ]
            ))
        }
        let duration = TimeInterval(frameCount) / chunkSampleRate
        await synthesizer.emit(.chunkFinished(
            modelID: modelID, chunkIndex: index, duration: duration
        ))
        let liveTimings = info.wordTimings(forDuration: duration)
        if !liveTimings.isEmpty {
            await synthesizer.emit(.chunkTimings(
                modelID: modelID, chunkIndex: index, timings: liveTimings
            ))
        }
        if workingManifest.sampleRate == 0 {
            workingManifest.sampleRate = Int(chunkSampleRate.rounded())
        }
        let shifted = liveTimings.map { timing -> TTSPreparedNarrationManifest.SerializableWordTiming in
            TTSPreparedNarrationManifest.SerializableWordTiming(
                characterRange: TTSPreparedNarrationManifest.SerializableRange(
                    start: timing.characterRange.lowerBound - info.characterRange.lowerBound,
                    end: timing.characterRange.upperBound - info.characterRange.lowerBound
                ),
                offset: timing.offset,
                duration: timing.duration
            )
        }
        let newEntry = TTSPreparedNarrationManifest.ChunkEntry(
            index: index,
            audioFile: chunkFilename,
            characterRange: TTSPreparedNarrationManifest.SerializableRange(info.characterRange),
            text: info.text,
            duration: duration,
            wordTimings: shifted
        )
        workingEntries[index] = newEntry
        workingManifest.chunks = workingEntries.keys.sorted().compactMap { workingEntries[$0] }
        let narration = TTSPreparedNarration(manifest: workingManifest, baseURL: bundleURL)
        try narration.writeManifest()
        synthesizer.info("streamAndCacheNarration[\(modelID)]: chunk \(index + 1) PERSISTED (duration=\(String(format: "%.2f", duration))s)")
    }

    /// Bake the entire `text` into a self-contained, redistributable
    /// ``TTSPreparedNarration`` bundle: per-chunk WAV files plus a manifest
    /// with word-level timings. Intended for **author-time** use (build
    /// scripts, demo apps) — the resulting bundle plays at runtime with
    /// ``TTSPlaybackController/play(narration:onWord:onPlaybackEnd:)`` and
    /// does **not** require MLX or the model to be loaded.
    ///
    /// The bundle is written atomically: each chunk is generated, measured,
    /// and converted into a manifest entry before the manifest is flushed to
    /// disk. If generation fails mid-way the partial directory is left in
    /// place for inspection (no auto-cleanup, since author-time runs are
    /// usually run by hand).
    ///
    /// - Parameter into: Directory URL for the bundle (e.g. ending in
    ///   `.ttsnarration`). Created if missing.
    public func prepareNarration(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        into bundleURL: URL,
        chunker: TTSTextChunker = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSPreparedNarration {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TTSError.emptyText }
        let chunkInfos = chunker.chunkInfos(for: text)
        guard !chunkInfos.isEmpty else { throw TTSError.emptyText }

        let fileManager = FileManager.default
        let chunksDirectory = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        var entries: [TTSPreparedNarrationManifest.ChunkEntry] = []
        entries.reserveCapacity(chunkInfos.count)
        var detectedSampleRate: Int = 0

        for (index, info) in chunkInfos.enumerated() {
            try Task.checkCancellation()
            let filename = String(format: "chunks/%03d.wav", index)
            let chunkURL = bundleURL.appendingPathComponent(filename, isDirectory: false)

            let stream = try await synthesizeStream(
                info.text,
                using: model,
                options: options,
                progressHandler: progressHandler
            )

            var audioFile: AVAudioFile?
            var frameCount: AVAudioFramePosition = 0
            var chunkSampleRate: Double = 0
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    let buffer = chunk.buffer
                    guard buffer.frameLength > 0 else { continue }
                    if audioFile == nil {
                        let format = buffer.format
                        chunkSampleRate = format.sampleRate
                        audioFile = try AVAudioFile(
                            forWriting: chunkURL,
                            settings: format.settings,
                            commonFormat: format.commonFormat,
                            interleaved: format.isInterleaved
                        )
                    }
                    try audioFile?.write(from: buffer)
                    frameCount += AVAudioFramePosition(buffer.frameLength)
                }
                audioFile = nil
            } catch {
                audioFile = nil
                throw error
            }

            guard chunkSampleRate > 0, frameCount > 0 else {
                throw TTSError.generationFailed(
                    modelID: model.id,
                    underlying: NSError(domain: "TTSPreparedNarration", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Chunk \(index) produced no audio."
                    ])
                )
            }

            let duration = TimeInterval(frameCount) / chunkSampleRate
            let liveTimings = info.wordTimings(forDuration: duration)
            let serialized = liveTimings.map { TTSPreparedNarrationManifest.SerializableWordTiming($0) }
                .map { timing -> TTSPreparedNarrationManifest.SerializableWordTiming in
                    // Re-anchor character ranges so they're relative to the
                    // chunk's own text rather than the original input. The
                    // runtime path can resolve back to the original via
                    // `chunk.characterRange.start + word.characterRange.start`.
                    let shifted = TTSPreparedNarrationManifest.SerializableRange(
                        start: timing.characterRange.start - info.characterRange.lowerBound,
                        end: timing.characterRange.end - info.characterRange.lowerBound
                    )
                    return TTSPreparedNarrationManifest.SerializableWordTiming(
                        characterRange: shifted,
                        offset: timing.offset,
                        duration: timing.duration
                    )
                }

            if detectedSampleRate == 0 {
                detectedSampleRate = Int(chunkSampleRate.rounded())
            }

            entries.append(TTSPreparedNarrationManifest.ChunkEntry(
                index: index,
                audioFile: filename,
                characterRange: TTSPreparedNarrationManifest.SerializableRange(info.characterRange),
                text: info.text,
                duration: duration,
                wordTimings: serialized
            ))
        }

        let manifest = TTSPreparedNarrationManifest(
            modelID: model.id,
            voice: options.voice?.identifier,
            language: options.language?.identifier,
            sourceText: text,
            sampleRate: detectedSampleRate,
            chunks: entries
        )
        let narration = TTSPreparedNarration(manifest: manifest, baseURL: bundleURL)
        try narration.writeManifest()
        return narration
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

        let key = cache.key(modelID: model.id, voice: options.voice, text: firstChunk)
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
    ) async throws -> LoadedModelBox {
        info("prepareModel: ENTRY \(model.id) wasWarmed=\(warmedModelIDs.contains(model.id))")

        // Cache hit: weights are resident from a prior call. Skip resolve,
        // download, and MLX load entirely — emit a single served-from-cache
        // event so consumers can tell this generation reused warm weights.
        if let cached = loadedModels[model.id] {
            info("prepareModel: CACHE HIT for \(model.id) sampleRate=\(cached.model.sampleRate)")
            emit(.modelLoadServedFromCache(modelID: model.id))
            return cached
        }

        let resolveStart = Date()
        let wasInstalled = await modelStore.isInstalled(model.id)
        info("prepareModel: resolved \(model.id) installed=\(wasInstalled) in \(String(format: "%.2f", Date().timeIntervalSince(resolveStart)))s")
        emit(.modelResolveFinished(
            modelID: model.id,
            wasInstalled: wasInstalled,
            duration: Date().timeIntervalSince(resolveStart)
        ))

        if !wasInstalled {
            info("prepareModel: download STARTED for \(model.id)")
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
            logError("prepareModel.ensureDownloaded", modelID: model.id, stage: "downloadingModel", error: error)
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .downloadingModel)
            emit(.errorOccurred(modelID: model.id, stage: .downloadingModel, error: wrapped))
            throw wrapped
        }
        if !wasInstalled {
            info("prepareModel: download FINISHED for \(model.id) in \(String(format: "%.2f", Date().timeIntervalSince(downloadStart)))s")
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
        info("prepareModel: MLX load STARTED for \(model.id)")
        emit(.modelLoadStarted(modelID: model.id))
        let loadStart = Date()
        let loaded: any SpeechGenerationModel
        do {
            loaded = try await MLXTTSModelLoader.load(descriptor: model, hfToken: options.hfToken)
        } catch {
            logError("prepareModel.MLXLoad", modelID: model.id, stage: "loadingModel", error: error)
            let wrapped = TTSError.wrap(error, modelID: model.id, stage: .loadingModel)
            emit(.errorOccurred(modelID: model.id, stage: .loadingModel, error: wrapped))
            throw wrapped
        }
        let loadDuration = Date().timeIntervalSince(loadStart)
        info("prepareModel: MLX load FINISHED for \(model.id) in \(String(format: "%.2f", loadDuration))s sampleRate=\(loaded.sampleRate)")
        emit(.modelLoadFinished(
            modelID: model.id,
            duration: loadDuration
        ))
        let box = LoadedModelBox(loaded)
        loadedModels[model.id] = box
        warmedModelIDs.insert(model.id)
        return box
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
    // Stays @MainActor because the upstream MLX `generatePCMBufferStream` is
    // MainActor-isolated. The hop is brief — it returns a stream synchronously;
    // generation work runs on MLX's own executor.
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
