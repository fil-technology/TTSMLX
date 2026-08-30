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

/// Simple `Bool` behind an `NSLock`. Used for state that the actor and
/// the synchronous notification observer both need to touch.
final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { self.value = initial }
    func withLock<T>(_ body: (inout Bool) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Synchronously-accessible shutdown coordinator shared between the
/// notification observer (which runs on the main thread when the OS
/// posts `willResignActive` / `didEnterBackground` / scene-deactivation
/// events) and the streaming drain Tasks (which run on the synthesizer
/// actor and on `@MainActor`). Both sides need to see the shutdown
/// signal *immediately*, without going through actor-hop scheduling —
/// that's why this is a class with an `NSLock` rather than actor state.
///
/// The Metal-in-background crash that motivates this design happens when
/// MLX submits a Metal command buffer between when the notification
/// observer fires and when our cooperative cancellation lands at the
/// next `await` checkpoint. By gating MLX-submitting code paths on
/// `isShuttingDown`, we close that window: streaming Tasks check the
/// flag synchronously before every upstream iteration and throw
/// `CancellationError` if it's set, so no further MLX work is
/// submitted past the notification.
final class TTSLifecycleCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var _isShuttingDown = false
    private var _tasks: [UUID: Task<Void, Never>] = [:]

    var isShuttingDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isShuttingDown
    }

    func setShuttingDown(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        _isShuttingDown = value
    }

    func track(id: UUID, _ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        _tasks[id] = task
    }

    func untrack(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        _tasks.removeValue(forKey: id)
    }

    /// Cancel every tracked Task synchronously and return how many were
    /// cancelled. Safe to call from any thread; the cancellations
    /// propagate to the Tasks' cooperative-cancellation checkpoints.
    @discardableResult
    func cancelAllTasks() -> Int {
        lock.lock()
        let snapshot = _tasks
        _tasks.removeAll()
        lock.unlock()
        for task in snapshot.values { task.cancel() }
        return snapshot.count
    }
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

    /// Set once a model has been materialised, which is the point MLX's Metal
    /// backend comes up. Guards ``releaseRuntimeBuffers()``.
    private var hasInitializedMLX = false
    private var warmedModelIDs: Set<String> = []
    /// Tracks the `(voice, language)` pair the cached `loadedModels[id]`
    /// instance was last used with. If a subsequent call requests a
    /// different pair, the cached instance is evicted and reloaded so the
    /// model doesn't start the new voice/language session with residual
    /// state from the prior one. We patched MimiAdapter to fully reset its
    /// caches between calls — this is belt-and-suspenders against any
    /// other latent state in upstream layers (FlowLM, ProjectedTransformer,
    /// rotary embeddings, etc.) that we don't know about. Reloading
    /// weights from the local cache takes ~300ms; switching voices and
    /// hearing voice-A still sound like voice-A is worth it.
    private var lastVariantByModel: [String: ModelVariant] = [:]

    private struct ModelVariant: Hashable {
        let voice: String?
        let language: String?
    }

    /// Shared shutdown coordinator. Owned by this synthesizer, observed by
    /// the notification block and read synchronously by every drain Task
    /// before submitting MLX work. See ``TTSLifecycleCoordinator``.
    nonisolated let lifecycle = TTSLifecycleCoordinator()

    /// When `false` (the default), in-flight generation is cancelled the
    /// moment the app enters the background. Set to `true` only if the
    /// caller owns its own `UIApplication.beginBackgroundTask` assertion
    /// and wants to keep generating past backgrounding — without that
    /// assertion, MLX Metal command-buffer submissions from the background
    /// crash the process with
    /// `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`.
    ///
    /// Nonisolated so the notification observer can read it on the main
    /// thread without an actor hop.
    public nonisolated var allowsBackgroundGeneration: Bool {
        get { _allowsBackgroundGeneration.withLock { $0 } }
        set { _allowsBackgroundGeneration.withLock { $0 = newValue } }
    }

    public init(
        modelStore: TTSModelStore = TTSModelStore(),
        diagnosticHandler: TTSDiagnosticHandler? = nil
    ) {
        self.modelStore = modelStore
        self.diagnosticHandler = diagnosticHandler
        // Three observers cover the three ways iOS signals "you're about to
        // lose GPU access": application-level `willResignActive` (still the
        // most reliable on UIApplication-based apps), the scene equivalent
        // `UIScene.willDeactivateNotification` (modern scene-based apps may
        // skip the application notification), and `didEnterBackground` as
        // last-resort backup. All three route through the same handler.
        //
        // The handler runs SYNCHRONOUSLY on the main thread because Metal
        // restrictions can clamp at any subsequent run-loop turn. Order
        // matters:
        //   1. Set `isShuttingDown = true`. Every drain Task checks this
        //      synchronously before each upstream iteration, so no new MLX
        //      work will be submitted past this point.
        //   2. Cancel all tracked Tasks synchronously. They'll exit at
        //      their next cooperative-cancellation checkpoint.
        //   3. `Stream.gpu.synchronize()` — block until all currently
        //      queued Metal command buffers complete. By the time the OS
        //      proceeds with the lifecycle transition, nothing is pending
        //      to be rejected.
        //   4. Dispatch the `cancelledByBackground` diagnostic
        //      asynchronously (observers don't need it sync).
        //
        // We accept that observers leak into NotificationCenter when the
        // synthesizer deallocates — the `[weak self]` capture means the
        // block becomes a no-op, and synthesizers typically live for the
        // app's lifetime.
        #if canImport(UIKit) && !os(watchOS)
        let coordinator = lifecycle
        let allowReader = _allowsBackgroundGeneration
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            // Honor opt-in: apps with their own beginBackgroundTask can
            // continue generating. They take responsibility for OS limits.
            guard !allowReader.withLock({ $0 }) else { return }
            coordinator.setShuttingDown(true)
            let count = coordinator.cancelAllTasks()
            Stream.gpu.synchronize()
            if count > 0, let self {
                Task { await self.emit(.cancelledByBackground(cancelledCount: count)) }
            }
        }
        let resumeHandler: @Sendable (Notification) -> Void = { _ in
            coordinator.setShuttingDown(false)
        }

        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main, using: handler
            )
        }
        for name in [
            UIApplication.didBecomeActiveNotification,
            UIScene.didActivateNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main, using: resumeHandler
            )
        }
        #endif
    }

    nonisolated private let _allowsBackgroundGeneration = LockedBool(false)

    /// Cancel every in-flight generation Task. Streams that were in progress
    /// finish with a `CancellationError`; future `synthesize*` calls are
    /// unaffected. Emits ``TTSDiagnostic/cancelledByBackground`` when called
    /// in response to a backgrounding notification, so observers can show
    /// "paused — app backgrounded" UX.
    public func cancelAllInFlight(reason: CancellationReason = .explicit) {
        let count = lifecycle.cancelAllTasks()
        guard count > 0 else { return }
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
        lifecycle.track(id: id, task)
    }

    fileprivate func untrackTask(id: UUID) {
        lifecycle.untrack(id: id)
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
        lastVariantByModel.removeValue(forKey: modelID)
        if droppedInstance || droppedMarker {
            // Dropping the model object frees its weights, but MLX keeps freed
            // buffers in its own cache — for a codec that allocates attention
            // buffers proportional to (frames * 32)^2 that is most of the
            // resident footprint, and it survives the unload otherwise.
            releaseRuntimeBuffers()
            emit(.modelUnloaded(modelID: modelID))
            log("unload: \(modelID) instance=\(droppedInstance) marker=\(droppedMarker)")
        }
    }

    /// Returns MLX's cached buffers to the OS.
    ///
    /// Live arrays are unaffected; this only releases what the allocator is
    /// holding for reuse. Worth calling after generation finishes or a model is
    /// dropped — on iOS that cache is the difference between settling near the
    /// weight footprint and staying pinned near the generation peak.
    ///
    /// No-op until a model has actually been loaded. Touching MLX's allocator
    /// initialises the Metal backend, which aborts the process where no
    /// metallib is present (plain `swift test`), so this must stay inert until
    /// something has already brought MLX up.
    public func releaseRuntimeBuffers() {
        guard hasInitializedMLX else { return }
        let before = MLX.GPU.cacheMemory
        MLX.GPU.clearCache()
        let after = MLX.GPU.cacheMemory
        log("releaseRuntimeBuffers: cache \(before / 1_048_576)MB -> \(after / 1_048_576)MB")
    }

    /// Drop every cached weight instance and clear the warmed set.
    public func unloadAll() {
        let ids = Array(warmedModelIDs.union(loadedModels.keys))
        loadedModels.removeAll()
        warmedModelIDs.removeAll()
        lastVariantByModel.removeAll()
        if !ids.isEmpty { releaseRuntimeBuffers() }
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
            // Wrap in `MLX.withError` so C++ MLX failures (e.g.
            // `broadcast_shapes` in attention with a stale KV-cache, OOM,
            // shape mismatches) surface as Swift `throws` instead of
            // terminating the process via `fatalError` inside
            // `MLX.ErrorHandler.dispatch`. The caught error wraps as
            // `TTSError.generationFailed` and propagates through the
            // existing handler chain.
            samples = try await MLX.withError {
                try await Self.generateSamples(
                    model: loadedModel,
                    text: prompt,
                    language: options.language?.identifier,
                    voice: options.voice?.identifier,
                    referenceAudio: referenceAudio,
                    referenceText: options.referenceText,
                    parameters: parameters
                )
            }
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
        try await synthesizeStream(
            text, using: model, options: options,
            emitsTerminalDiagnostic: true, progressHandler: progressHandler
        )
    }

    /// - Parameter emitsTerminalDiagnostic: whether to emit
    ///   ``TTSDiagnostic/streamingFinished(modelID:duration:bufferCount:)`` when
    ///   this stream drains. ``synthesizeLong(_:using:options:chunker:progressHandler:)``
    ///   passes `false`: it drives one of these per chunk, and consumers treat
    ///   that diagnostic as "the whole utterance is over". Emitting it per chunk
    ///   made the playback observer stop building its word timeline after the
    ///   first chunk — before that chunk's own timings had even been emitted —
    ///   so the karaoke cursor never advanced past the opening sentence.
    func synthesizeStream(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        emitsTerminalDiagnostic: Bool,
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
        let lifecycle = self.lifecycle
        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            var bufferCount = 0
            var emptyBufferCount = 0
            var firstBufferEmitted = false
            do {
                try Task.checkCancellation()
                if lifecycle.isShuttingDown { throw CancellationError() }
                let loadedModel = loadedBox.model
                let parameters = Self.makeParameters(for: loadedModel, options: capturedOptions)
                let referenceAudio = try capturedOptions.referenceAudio.map(Self.loadReferenceAudio)
                let sampleRate = loadedModel.sampleRate
                progressHandler?(.init(
                    stage: .generatingAudio,
                    message: "Streaming audio..."
                ))
                // NOTE: We can't wrap the streaming path in `MLX.withError`
                // because the AsyncThrowingStream returned by
                // `model.generatePCMBufferStream(...)` is non-Sendable and
                // can only be created and consumed on the same actor
                // (MainActor in this case), but MLX.withError requires a
                // closure that crosses isolation. The `synthesize`
                // (non-streaming) and `prepareModel` paths ARE wrapped —
                // see those call sites. The streaming path remains
                // vulnerable to MLX fatal errors (e.g. `broadcast_shapes`
                // from stale KV cache) until either upstream MLX adds a
                // MainActor-aware withError or the upstream
                // generatePCMBufferStream drops its @MainActor isolation.
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
                    // Gate every iteration on the shared shutdown flag so no
                    // further MLX work is submitted past a background signal.
                    if lifecycle.isShuttingDown { throw CancellationError() }
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
                if emitsTerminalDiagnostic {
                    await synthesizer.emit(.streamingFinished(
                        modelID: modelID,
                        duration: totalDuration,
                        bufferCount: bufferCount
                    ))
                }
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

        let lifecycle = self.lifecycle
        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            // Totals for the single terminal diagnostic this composite stream
            // owns; the per-chunk streams no longer emit one of their own.
            var totalAudioSeconds: TimeInterval = 0
            var totalBufferCount = 0
            do {
                for (index, info) in chunkInfos.enumerated() {
                    try Task.checkCancellation()
                    if lifecycle.isShuttingDown { throw CancellationError() }
                    synthesizer.info("synthesizeLong[\(modelID)]: chunk \(index + 1)/\(total) chars=\(info.text.count)")
                    let chunkStartedAt = Date()
                    var didEmitChunkStart = false
                    // Real audio length of this chunk, accumulated from the
                    // buffers actually rendered. Word timings and the playback
                    // cursor are both expressed in playback seconds, so
                    // deriving them from generation wall-clock desynchronises
                    // the highlight the moment generation is not exactly
                    // realtime — which it never is.
                    var chunkAudioSeconds: TimeInterval = 0

                    let chunkStream = try await synthesizer.synthesizeStream(
                        info.text,
                        using: model,
                        options: options,
                        emitsTerminalDiagnostic: false,
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
                        if lifecycle.isShuttingDown { throw CancellationError() }
                        if !didEmitChunkStart, pcmChunk.buffer.frameLength > 0 {
                            didEmitChunkStart = true
                            await synthesizer.emit(.chunkStarted(
                                modelID: modelID,
                                chunkIndex: index,
                                characterRange: info.characterRange
                            ))
                        }
                        if pcmChunk.sampleRate > 0 {
                            chunkAudioSeconds += Double(pcmChunk.buffer.frameLength)
                                / Double(pcmChunk.sampleRate)
                        }
                        totalBufferCount += 1
                        continuation.yield(pcmChunk)
                    }
                    let generationSeconds = Date().timeIntervalSince(chunkStartedAt)
                    synthesizer.info(
                        "synthesizeLong[\(modelID)]: chunk \(index + 1)/\(total) FINISHED "
                        + "audio=\(String(format: "%.2f", chunkAudioSeconds))s "
                        + "generated in \(String(format: "%.2f", generationSeconds))s "
                        + "(rtf=\(String(format: "%.2f", generationSeconds > 0 ? chunkAudioSeconds / generationSeconds : 0))x, "
                        + "didStart=\(didEmitChunkStart))"
                    )
                    // Both of these are consumed as playback seconds: the
                    // observer sums prior chunk durations to place each word on
                    // the timeline, then compares against the player's
                    // currentTime.
                    await synthesizer.emit(.chunkFinished(
                        modelID: modelID,
                        chunkIndex: index,
                        duration: chunkAudioSeconds
                    ))
                    totalAudioSeconds += chunkAudioSeconds
                    let timings = info.wordTimings(forDuration: chunkAudioSeconds)
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
                synthesizer.info(
                    "synthesizeLong[\(modelID)]: ALL \(total) chunks FINISHED "
                    + "audio=\(String(format: "%.2f", totalAudioSeconds))s"
                )
                // One terminal event for the whole utterance. Consumers treat
                // this as "stop building the timeline", so it must not fire
                // until every chunk's timings have been emitted.
                await synthesizer.emit(.streamingFinished(
                    modelID: modelID,
                    duration: totalAudioSeconds,
                    bufferCount: totalBufferCount
                ))
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
    ///
    /// Pass `startCharacterOffset` to resume mid-text. Chunks whose
    /// `characterRange.upperBound <= startCharacterOffset` are skipped
    /// before any I/O or event emission — they emit no `chunkStarted` /
    /// `chunkFinished` / `chunkTimings`. The first chunk that straddles
    /// or exceeds the offset is yielded normally, whether it's a REPLAY
    /// or GENERATION iteration. Cached chunks that fall before the
    /// offset stay on disk untouched and remain valid for a future call
    /// at offset 0. Audio still starts at the beginning of the first
    /// yielded chunk — TTSMLX has no sub-chunk seek today — so callers
    /// using a saved within-chunk position will hear a short replay of
    /// the chunk prefix before live sync catches up.
    /// Sibling of ``streamAndCacheNarration(_:using:options:cacheBundleAt:chunker:progressHandler:)``
    /// that lets the framework own the on-disk location. The URL is
    /// derived from ``TTSAudioCache/narrationBundle(modelID:text:)`` —
    /// callers no longer need to compute a stable path for each chapter.
    ///
    /// Use this when the bundle is purely a runtime cache. Use the
    /// `cacheBundleAt:` variant when the bundle is also a deliverable
    /// (export, distribution, debug inspection).
    public func streamAndCacheNarration(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        cache: TTSAudioCache,
        chunker: TTSTextChunker = .init(),
        startCharacterOffset: Int = 0,
        backpressure: TTSPlaybackBackpressure? = nil,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error> {
        let bundleURL = cache.narrationBundle(modelID: model.id, text: text)
        let parent = bundleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return try await streamAndCacheNarration(
            text,
            using: model,
            options: options,
            cacheBundleAt: bundleURL,
            chunker: chunker,
            startCharacterOffset: startCharacterOffset,
            backpressure: backpressure,
            progressHandler: progressHandler
        )
    }

#if canImport(AVFoundation)
    /// One-call helper that handles the entire foreground reading flow:
    /// streams `text` into the cache, plays the result through the supplied
    /// playback controller with playback-driven word highlighting, and
    /// returns when the stream finishes or the user backgrounds the app.
    ///
    /// This is the right call for most reader UIs. It collapses what would
    /// otherwise be four wired-up calls (`streamAndCacheNarration` →
    /// `play(stream:synthesizer:onWord:)` → manual event subscription
    /// removal → CancellationError handling) into one. Cached chunks
    /// inside the bundle are reused — switching voice mid-chapter and
    /// switching back is instant because each voice has its own
    /// sub-bundle (see ``TTSAudioCache/availableVariants(modelID:text:)``).
    ///
    /// Background continuity note: when the app backgrounds, iOS forbids
    /// MLX/Metal compute, so the framework cancels in-flight generation
    /// (`TTSDiagnostic.cancelledByBackground` is emitted). Already-scheduled
    /// audio buffers play out from the AVAudioEngine queue, then silence.
    /// For indefinite background playback, pre-bake the chapter with
    /// ``prepareNarration(_:using:options:into:chunker:progressHandler:)``
    /// and play the resulting `TTSPreparedNarration` via
    /// ``TTSPlaybackController/play(narration:onWord:onPlaybackEnd:)`` —
    /// that path is MLX-free at playback time and survives any number of
    /// foreground/background cycles.
    ///
    /// Throws `CancellationError` when the synthesizer's drain Task is
    /// cancelled by the OS background hand-off. Other errors come from
    /// the synthesis pipeline (model load, MLX runtime, disk I/O). The
    /// caller can simply call `speakStreaming(...)` again to resume —
    /// the cache will replay everything that finished generating before
    /// the cancellation and pick up generation at the first missing chunk.
    /// - Parameter lookAheadSeconds: how far audio generation may run ahead of
    ///   playback, in seconds of audio. Bounds memory + battery/thermal while
    ///   reading long-form text — generation suspends once this much audio is
    ///   queued ahead of the playback head and resumes as it drains. `nil`
    ///   (the default) uses ``TTSDeviceProfile/recommendedLookAheadSeconds``
    ///   for the current device; pass `0` to disable backpressure (unbounded,
    ///   the pre-0.7 behavior).
    public func speakStreaming(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        cache: TTSAudioCache,
        playback: TTSPlaybackController,
        chunker: TTSTextChunker = .init(),
        startCharacterOffset: Int = 0,
        lookAheadSeconds: Double? = nil,
        onWord: (@MainActor (TTSWordTiming) -> Void)? = nil,
        onPlaybackEnd: (@MainActor () -> Void)? = nil,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws {
        // Serial model use: cancel any prior in-flight generation before starting
        // a new utterance. The cached model instance is NOT safe for concurrent
        // generation, and with look-ahead the previous call may still be
        // generating chunks in the background when the user taps Play again —
        // overlapping generations corrupt the shared KV cache (manifested as a
        // "RoPE cache length exceeded" crash in CSM/Marvis).
        cancelAllInFlight(reason: .explicit)
        let window = lookAheadSeconds ?? TTSDeviceProfile.current.recommendedLookAheadSeconds
        // capacity <= 0 yields a disabled (pass-through) gate; only attach one
        // when bounding is actually requested.
        let backpressure = window > 0 ? TTSPlaybackBackpressure(capacitySeconds: window) : nil
        info("speakStreaming: ENTRY model=\(model.id) chars=\(text.count) lookAhead=\(window > 0 ? String(format: "%.0fs", window) : "unbounded")")
        let stream = try await streamAndCacheNarration(
            text,
            using: model,
            options: options,
            cache: cache,
            chunker: chunker,
            startCharacterOffset: startCharacterOffset,
            backpressure: backpressure,
            progressHandler: progressHandler
        )
        // Sentence-level highlighting needs the text to find sentence
        // boundaries; harmless for word level.
        await playback.setHighlightSourceText(text)
        try await playback.play(
            stream: stream,
            synthesizer: self,
            backpressure: backpressure,
            onWord: onWord,
            onPlaybackEnd: onPlaybackEnd
        )
    }
#endif

    public func streamAndCacheNarration(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        cacheBundleAt bundleURL: URL,
        chunker: TTSTextChunker = .init(),
        startCharacterOffset: Int = 0,
        backpressure: TTSPlaybackBackpressure? = nil,
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
        let codec = options.audioCodec

        let fileManager = FileManager.default
        // Each (voice, language) gets its own sub-bundle inside bundleURL, so
        // switching voice mid-chapter doesn't wipe the other voice's cache.
        try? TTSPreparedNarration.migrateLegacyIfMatches(
            bundleURL: bundleURL,
            voice: voiceID,
            language: languageID
        )
        let subBundleURL = TTSPreparedNarration.subBundleURL(
            in: bundleURL, voice: voiceID, language: languageID
        )
        let chunksDir = subBundleURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        // Load existing manifest, validate against this call's args. Mismatch
        // (different model/text) → wipe just this sub-bundle and start fresh.
        // Other voices' sub-bundles are untouched.
        var workingManifest: TTSPreparedNarrationManifest
        var workingEntries: [Int: TTSPreparedNarrationManifest.ChunkEntry] = [:]
        if let existing = try? TTSPreparedNarration(importing: subBundleURL).manifest,
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
            try? fileManager.removeItem(at: subBundleURL)
            try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
            workingManifest = TTSPreparedNarrationManifest(
                modelID: modelID,
                voice: voiceID,
                language: languageID,
                sourceText: text,
                sampleRate: 0,
                codec: codec.manifestTag,
                chunks: []
            )
        }

        let cachedCount = workingEntries.count
        let totalChunks = chunkInfos.count
        let offsetLog = startCharacterOffset > 0 ? " startCharacterOffset=\(startCharacterOffset)" : ""
        info("streamAndCacheNarration: ENTRY model=\(modelID) chunks=\(totalChunks) cached=\(cachedCount)/\(totalChunks) bundle=\(bundleURL.lastPathComponent)\(offsetLog)")

        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let synthesizer = self
        let taskID = UUID()
        let lifecycle = self.lifecycle
        let resumeOffset = max(0, startCharacterOffset)

        let drainTask = Task { @MainActor in
            defer {
                Task { [synthesizer] in await synthesizer.untrackTask(id: taskID) }
            }
            do {
                var skippedCount = 0
                for (index, info) in chunkInfos.enumerated() {
                    try Task.checkCancellation()
                    if lifecycle.isShuttingDown { throw CancellationError() }
                    // Skip chunks fully before the resume offset. Skipped
                    // chunks emit no chunkStarted / chunkFinished /
                    // chunkTimings — they're invisible to the consumer. The
                    // check sits *before* any I/O so cached files on disk
                    // stay untouched and remain valid for a future call at
                    // offset 0.
                    if info.characterRange.upperBound <= resumeOffset {
                        skippedCount += 1
                        continue
                    }
                    if skippedCount > 0, index == skippedCount {
                        synthesizer.info("streamAndCacheNarration[\(modelID)]: SKIPPED \(skippedCount) chunk(s) before offset \(resumeOffset); resuming at chunk \(index + 1)/\(totalChunks)")
                    }
                    // Fresh chunks are written in the caller's chosen codec.
                    // Cached chunks are located by their manifest-recorded path,
                    // which carries the real extension — so a bundle that mixes
                    // codecs (e.g. a WAV bundle resumed after switching to AAC)
                    // still replays its existing chunks.
                    let genFilename = String(format: "chunks/%03d.\(codec.fileExtension)", index)
                    let entry = workingEntries[index]
                    let replayFilename = entry?.audioFile ?? genFilename
                    let replayURL = subBundleURL.appendingPathComponent(replayFilename, isDirectory: false)
                    let fileExists = fileManager.fileExists(atPath: replayURL.path)

                    if let entry, fileExists, entry.text == info.text,
                       let chunkFile = try? AVAudioFile(forReading: replayURL),
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
                        // Gate on look-ahead before handing the (whole-chunk)
                        // buffer downstream so cached replay can't race ahead of
                        // playback and pile the whole book into memory either.
                        await backpressure?.reserve(entry.duration)
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
                            try? fileManager.removeItem(at: replayURL)
                            synthesizer.warning("streamAndCacheNarration[\(modelID)]: chunk \(index + 1) cached file invalid, regenerating")
                        }
                        let genURL = subBundleURL.appendingPathComponent(genFilename, isDirectory: false)
                        try await Self.generateAndPersist(
                            index: index,
                            info: info,
                            model: model,
                            options: options,
                            modelID: modelID,
                            codec: codec,
                            chunkURL: genURL,
                            chunkFilename: genFilename,
                            bundleURL: subBundleURL,
                            workingManifest: &workingManifest,
                            workingEntries: &workingEntries,
                            continuation: continuation,
                            backpressure: backpressure,
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
        codec: TTSAudioCodec,
        chunkURL: URL,
        chunkFilename: String,
        bundleURL: URL,
        workingManifest: inout TTSPreparedNarrationManifest,
        workingEntries: inout [Int: TTSPreparedNarrationManifest.ChunkEntry],
        continuation: AsyncThrowingStream<TTSAudioBufferChunk, Error>.Continuation,
        backpressure: TTSPlaybackBackpressure?,
        synthesizer: TTSSpeechSynthesizer
    ) async throws {
        synthesizer.info("streamAndCacheNarration[\(modelID)]: chunk \(index + 1) GENERATING")
        var didEmitChunkStart = false
        var audioFile: AVAudioFile?
        var frameCount: AVAudioFramePosition = 0
        var chunkSampleRate: Double = 0
        let lifecycle = synthesizer.lifecycle
        let chunkStream = try await synthesizer.synthesizeStream(
            info.text, using: model, options: options, progressHandler: nil
        )
        for try await pcm in chunkStream {
            try Task.checkCancellation()
            if lifecycle.isShuttingDown { throw CancellationError() }
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
                audioFile = try TTSAudioEncoder.makeFile(
                    at: chunkURL, codec: codec, sourceFormat: buffer.format
                )
            }
            if let audioFile { try TTSAudioEncoder.write(buffer, to: audioFile) }
            frameCount += AVAudioFramePosition(buffer.frameLength)
            // Persist always happens (to disk, bounded); only the downstream
            // yield is gated, so generation stays within the look-ahead window
            // of playback. The chunk file is fully written regardless, so a
            // background interruption still leaves a resumable cache.
            let bufferSeconds = buffer.format.sampleRate > 0
                ? Double(buffer.frameLength) / buffer.format.sampleRate
                : 0
            await backpressure?.reserve(bufferSeconds)
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
        if workingManifest.codec == nil {
            workingManifest.codec = codec.manifestTag
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
        let voiceID = options.voice?.identifier
        let languageID = options.language?.identifier
        let codec = options.audioCodec
        let subBundleURL = TTSPreparedNarration.subBundleURL(
            in: bundleURL, voice: voiceID, language: languageID
        )
        let chunksDirectory = subBundleURL.appendingPathComponent("chunks", isDirectory: true)
        // Wipe any stale contents in this sub-bundle so re-baking the same
        // (voice, language) pair overwrites rather than mingling old chunks.
        try? fileManager.removeItem(at: subBundleURL)
        try fileManager.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        var entries: [TTSPreparedNarrationManifest.ChunkEntry] = []
        entries.reserveCapacity(chunkInfos.count)
        var detectedSampleRate: Int = 0
        let lifecycle = self.lifecycle

        for (index, info) in chunkInfos.enumerated() {
            try Task.checkCancellation()
            if lifecycle.isShuttingDown { throw CancellationError() }
            let filename = String(format: "chunks/%03d.\(codec.fileExtension)", index)
            let chunkURL = subBundleURL.appendingPathComponent(filename, isDirectory: false)

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
                    if lifecycle.isShuttingDown { throw CancellationError() }
                    let buffer = chunk.buffer
                    guard buffer.frameLength > 0 else { continue }
                    if audioFile == nil {
                        let format = buffer.format
                        chunkSampleRate = format.sampleRate
                        audioFile = try TTSAudioEncoder.makeFile(
                            at: chunkURL, codec: codec, sourceFormat: format
                        )
                    }
                    if let audioFile { try TTSAudioEncoder.write(buffer, to: audioFile) }
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
            voice: voiceID,
            language: languageID,
            sourceText: text,
            sampleRate: detectedSampleRate,
            codec: codec.manifestTag,
            chunks: entries
        )
        let narration = TTSPreparedNarration(manifest: manifest, baseURL: subBundleURL)
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


    /// Applies model-specific knobs a generic `GenerateParameters` cannot carry.
    ///
    /// MOSS predicts its 16 residual codebooks sequentially, so the count is
    /// close to a linear dial on generation time — measured at 2.4x faster per
    /// word at 8 codebooks. The quantiser is coarse-to-fine, so the cost is
    /// high-frequency detail rather than intelligibility, which is the right
    /// trade for bulk work like baking a book and the wrong one for a short
    /// sample the user is auditioning.
    ///
    /// Routed through the existing generation profile rather than a new option,
    /// so callers keep one dial instead of two that can disagree.
    private func applyModelSpecificProfile(
        _ profile: TTSGenerationProfile?,
        to model: any SpeechGenerationModel
    ) {
        guard let moss = model as? MossTTSNanoModel else { return }
        switch profile {
        case .fast:        moss.codebookCount = 8
        case .balanced:    moss.codebookCount = 12
        case .highQuality: moss.codebookCount = nil   // all 16
        case nil:          moss.codebookCount = nil
        }
    }

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

        let requestedVariant = ModelVariant(
            voice: options.voice?.identifier,
            language: options.language?.identifier
        )

        // Cache hit: weights are resident from a prior call. Skip resolve,
        // download, and MLX load entirely — but only if the requested
        // voice/language matches the variant the cached instance was last
        // used with. If it changed, evict the cached instance and force a
        // fresh load so the new variant starts from a known-clean model
        // state (see note on `lastVariantByModel`).
        if let cached = loadedModels[model.id] {
            applyModelSpecificProfile(options.generationProfile, to: cached.model)
            if lastVariantByModel[model.id] == requestedVariant {
                info("prepareModel: CACHE HIT for \(model.id) sampleRate=\(cached.model.sampleRate) variant=\(requestedVariant.voice ?? "auto").\(requestedVariant.language ?? "auto")")
                emit(.modelLoadServedFromCache(modelID: model.id))
                return cached
            }
            let prior = lastVariantByModel[model.id]
            info("prepareModel: EVICTING cached \(model.id) — variant changed (\(prior?.voice ?? "auto").\(prior?.language ?? "auto") → \(requestedVariant.voice ?? "auto").\(requestedVariant.language ?? "auto"))")
            loadedModels.removeValue(forKey: model.id)
            warmedModelIDs.remove(model.id)
            emit(.modelUnloaded(modelID: model.id))
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
            // Same `MLX.withError` wrap as the generate path — model load
            // does MLX work (weight materialization, kernel JIT) that can
            // fail at the C++ layer; without this wrapper those failures
            // would terminate the process via `fatalError` inside MLX's
            // ErrorHandler.
            loaded = try await MLX.withError {
                try await MLXTTSModelLoader.load(descriptor: model, hfToken: options.hfToken)
            }
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
        applyModelSpecificProfile(options.generationProfile, to: loaded)
        hasInitializedMLX = true
        loadedModels[model.id] = box
        warmedModelIDs.insert(model.id)
        lastVariantByModel[model.id] = requestedVariant
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
