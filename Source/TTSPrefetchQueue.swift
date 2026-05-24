import Foundation
import OSLog
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

/// One unit of work the prefetch queue can take on.
public struct TTSPrefetchRequest: Sendable, Hashable {
    public let text: String
    public let model: TTSModelDescriptor
    public let voice: TTSVoice?
    public let options: TTSSynthesisOptions

    public init(
        text: String,
        model: TTSModelDescriptor,
        voice: TTSVoice? = nil,
        options: TTSSynthesisOptions = .init()
    ) {
        self.text = text
        self.model = model
        self.voice = voice
        self.options = options
    }
}

/// Configurable thermal/power gates applied between prefetch items.
public struct TTSPrefetchPolicy: Sendable, Hashable {
    /// Skip new generations when the device is in or above this thermal state.
    /// Default `.serious` — leaves headroom before fans/throttling kick in.
    public var thermalCutoff: ProcessInfo.ThermalState
    /// Skip new generations entirely when Low Power Mode is on.
    public var pauseOnLowPowerMode: Bool
    /// Cap on how many items we keep in `inFlight`. Prevents runaway memory
    /// pressure if the caller enqueues thousands of items.
    public var maxQueuedItems: Int

    public init(
        thermalCutoff: ProcessInfo.ThermalState = .serious,
        pauseOnLowPowerMode: Bool = true,
        maxQueuedItems: Int = 256
    ) {
        self.thermalCutoff = thermalCutoff
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.maxQueuedItems = maxQueuedItems
    }
}

/// Background queue that fills a `TTSAudioCache` with generated audio while
/// the user is doing something else (e.g. playing the current chapter).
///
/// Honors thermal state and Low Power Mode so it doesn't roast the device.
/// One item is processed at a time — concurrent MLX generation isn't safe and
/// would just contend with foreground playback anyway.
public actor TTSPrefetchQueue {
    public enum Status: Sendable, Hashable {
        case idle
        case running
        case paused(reason: PauseReason)
    }

    public enum PauseReason: Sendable, Hashable {
        case thermal
        case lowPowerMode
        case cancelled
    }

    private let synthesizer: TTSSpeechSynthesizer
    private let cache: TTSAudioCache
    private var policy: TTSPrefetchPolicy
    private var pending: [TTSPrefetchRequest] = []
    private var inFlightID: String?
    private var workTask: Task<Void, Never>?
    private var statusValue: Status = .idle
    nonisolated private let logger = Logger(subsystem: "technology.fil.ttsmlx", category: "Prefetch")

    public init(
        synthesizer: TTSSpeechSynthesizer,
        cache: TTSAudioCache,
        policy: TTSPrefetchPolicy = .init()
    ) {
        self.synthesizer = synthesizer
        self.cache = cache
        self.policy = policy
    }

    public func updatePolicy(_ policy: TTSPrefetchPolicy) {
        self.policy = policy
    }

    public var status: Status { statusValue }
    public var queueDepth: Int { pending.count + (inFlightID == nil ? 0 : 1) }

    /// Adds requests to the back of the queue. Requests that already have a
    /// usable cached entry are skipped immediately. Starts the worker if it's
    /// idle. Capped by `policy.maxQueuedItems`.
    public func enqueue(_ requests: [TTSPrefetchRequest]) async {
        for request in requests {
            if pending.count >= policy.maxQueuedItems { break }
            let key = cache.key(modelID: request.model.id, voice: request.voice, text: request.text)
            if await cache.contains(key: key) { continue }
            pending.append(request)
        }
        startIfNeeded()
    }

    /// Drop every pending request matching the predicate. The currently-running
    /// item is left to finish (cancelling MLX mid-generation is messy).
    public func cancel(where predicate: @Sendable (TTSPrefetchRequest) -> Bool) {
        pending.removeAll(where: predicate)
    }

    /// Cancel everything. Currently-running item is allowed to finish.
    public func cancelAll() {
        pending.removeAll()
        statusValue = .paused(reason: .cancelled)
        workTask?.cancel()
    }

    /// Atomically swap the pending queue. Drops every queued item, leaves the
    /// in-flight item alone (it'll finish, then the new queue takes over).
    /// Use this for voice or model switches mid-session — the new requests'
    /// cache keys differ (voice is part of the key) so previously-prefetched
    /// audio for the old voice stays cached and doesn't get regenerated.
    ///
    /// Returns the number of newly enqueued items after de-dup against the
    /// cache. The currently-running generation, if any, finishes on the old
    /// voice; the next chunk plays in the new voice.
    @discardableResult
    public func replace(_ requests: [TTSPrefetchRequest]) async -> Int {
        pending.removeAll()
        await enqueue(requests)
        return pending.count
    }

    // MARK: - Internals

    private func startIfNeeded() {
        guard workTask == nil else { return }
        guard !pending.isEmpty else {
            statusValue = .idle
            return
        }
        let policy = self.policy
        statusValue = .running

        workTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drain(with: policy)
        }
    }

    private func drain(with policy: TTSPrefetchPolicy) async {
        while !Task.isCancelled, let next = takeNext() {
            if let pauseReason = gatePolicy(policy) {
                pending.insert(next, at: 0)
                statusValue = .paused(reason: pauseReason)
                let deferredCount = pending.count
                logger.log("paused (\(String(describing: pauseReason), privacy: .public)); deferring \(deferredCount) item(s)")
                break
            }

            let key = cache.key(modelID: next.model.id, voice: next.voice, text: next.text)
            inFlightID = key
            statusValue = .running

            if await cache.contains(key: key) {
                inFlightID = nil
                continue
            }

            do {
                try await generate(request: next, cacheKey: key)
            } catch {
                logger.error("prefetch failed for \(next.model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            inFlightID = nil
        }

        workTask = nil
        if pending.isEmpty && !Task.isCancelled {
            statusValue = .idle
        }
    }

    private func takeNext() -> TTSPrefetchRequest? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func gatePolicy(_ policy: TTSPrefetchPolicy) -> PauseReason? {
        let info = ProcessInfo.processInfo
        if policy.pauseOnLowPowerMode, info.isLowPowerModeEnabled {
            return .lowPowerMode
        }
        if info.thermalState.rawValue >= policy.thermalCutoff.rawValue {
            return .thermal
        }
        return nil
    }

#if canImport(AVFoundation)
    private func generate(request: TTSPrefetchRequest, cacheKey: String) async throws {
        let handle = await cache.reserveWrite(forKey: cacheKey)
        var options = request.options
        if options.voice == nil { options.voice = request.voice }

        let stream = try await synthesizer.synthesizeStream(
            request.text,
            using: request.model,
            options: options,
            progressHandler: nil
        )

        var audioFile: AVAudioFile?
        do {
            for try await chunk in stream {
                if Task.isCancelled { throw CancellationError() }
                let buffer = chunk.buffer
                guard buffer.frameLength > 0 else { continue }
                if audioFile == nil {
                    let parent = handle.temporaryURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
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
            _ = try await cache.finalize(handle)
            logger.log("prefetched \(cacheKey, privacy: .public)")
        } catch {
            await cache.discard(handle)
            throw error
        }
    }
#else
    private func generate(request: TTSPrefetchRequest, cacheKey: String) async throws {
        // Streaming prefetch requires AVFoundation. On platforms without it,
        // the queue is effectively a no-op for now.
        throw TTSError.generationFailed(
            modelID: request.model.id,
            underlying: NSError(domain: "TTSPrefetchQueue", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Prefetch requires AVFoundation."
            ])
        )
    }
#endif
}
