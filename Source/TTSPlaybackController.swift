#if canImport(AVFoundation)
import Foundation
import OSLog
@preconcurrency import AVFoundation

/// A small audio-engine wrapper that plays `TTSAudioBufferChunk` streams (or
/// cached files) with pitch-preserving speed control.
///
/// The graph is `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`, so
/// changing ``rate`` between calls preserves voice pitch while making it
/// faster or slower. Useful for audiobook apps that want a 0.8× / 1.0× /
/// 1.2× / 1.5× picker.
///
/// All methods are MainActor-isolated because they touch AVAudioEngine
/// state, which the framework expects on a single thread.
@MainActor
public final class TTSPlaybackController {
    public enum State: Sendable, Hashable {
        case idle
        case playing
        case paused
        case stopped
    }

    /// Thrown when a request can't be honored by the current playback mode.
    public enum PlaybackError: Error, Sendable, Equatable {
        /// Seeking requires a file-backed playback session. Stream playback
        /// has no addressable timeline.
        case seekUnsupportedForStream
    }

    public private(set) var state: State = .idle
    /// Playback rate. 1.0 = real time. Range 0.5–2.0 is the safe band that
    /// `AVAudioUnitTimePitch` handles without audible artifacts. Outside that
    /// band, audio quality degrades but it still plays.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.5, min(2.0, newValue)) }
    }

    /// Position in the currently playing audio, measured in **source-audio
    /// seconds** — i.e. seconds of the original recording, not wall-clock
    /// seconds of playback. Resets on ``stop()``. For file playback this
    /// respects ``seek(to:)`` (returned value is "position in file", not
    /// "time since play started").
    ///
    /// **Rate-independent.** `rate = 1.5` makes audio play faster in real
    /// time, but `currentTime` still reports source-audio seconds, so word
    /// timings (which are also in source-audio seconds) stay correctly
    /// aligned at any rate without re-derivation on the caller's side.
    ///
    /// (Implementation note: the value advances 2× faster per real second
    /// at 2× rate. That's *how* it stays rate-independent — both the
    /// player's sample-time and the source timeline are in the same units,
    /// so the ratio is rate-invariant. Use this property directly to look
    /// up word timings against ``TTSChunkInfo/wordTimings(forDuration:)``.)
    public var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        let sampleRate = playerTime.sampleRate
        guard sampleRate > 0 else { return 0 }
        let elapsed = Double(playerTime.sampleTime) / sampleRate
        let offset = Double(seekFrameOffset) / sampleRate
        return max(0, elapsed + offset)
    }

    /// Total duration in seconds for file or narration playback. `nil` for
    /// stream playback (the total length isn't known until the stream ends).
    public var duration: TimeInterval? {
        if let narrationTotalDuration { return narrationTotalDuration }
        guard let file = currentFile else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    private var onPlaybackEnd: (@MainActor () -> Void)?
    private var currentFile: AVAudioFile?
    private var seekFrameOffset: AVAudioFramePosition = 0
    /// Set when playing a TTSPreparedNarration. Overrides `duration` to be
    /// the bundle's total length and drives the word-callback observer task.
    private var narrationTotalDuration: TimeInterval?
    private var narrationWordObserver: Task<Void, Never>?
    nonisolated private let logger = Logger(subsystem: "technology.fil.ttsmlx", category: "Playback")

    public init(rate: Float = 1.0) {
        engine.attach(playerNode)
        engine.attach(timePitch)
        timePitch.rate = max(0.5, min(2.0, rate))
        // Connect player → pitch lazily once we know the buffer format.
    }

    /// Schedule a single PCM buffer for playback. Starts the engine on the
    /// first buffer; subsequent buffers are appended to the queue.
    public func schedule(_ chunk: TTSAudioBufferChunk) throws {
        try connectIfNeeded(format: chunk.buffer.format)
        scheduledBufferCount += 1
        // Log every Nth schedule call to avoid log spam on long streams.
        if scheduledBufferCount == 1 || scheduledBufferCount.isMultiple(of: 25) {
            logger.info("schedule: buffer #\(self.scheduledBufferCount, privacy: .public) frameLength=\(chunk.buffer.frameLength, privacy: .public) sampleRate=\(chunk.sampleRate, privacy: .public)")
        }
        playerNode.scheduleBuffer(chunk.buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedBufferCount += 1
                self.finishIfNeeded()
            }
        }
        if !playerNode.isPlaying, state != .paused {
            playerNode.play()
            state = .playing
            logger.info("schedule: playerNode.play() invoked; state=playing")
        }
    }

    /// Convenience: drain every chunk from a TTSMLX stream and schedule them
    /// in order. Returns when the stream ends; playback may still be ongoing.
    /// Hand a closure via `onPlaybackEnd` to be notified when the last
    /// buffer finishes playing.
    public func play(
        stream: AsyncThrowingStream<TTSAudioBufferChunk, Error>,
        onPlaybackEnd: (@MainActor () -> Void)? = nil
    ) async throws {
        logger.info("play(stream:): ENTRY state=\(String(describing: self.state), privacy: .public)")
        self.onPlaybackEnd = onPlaybackEnd
        currentFile = nil
        seekFrameOffset = 0
        var consumed = 0
        do {
            for try await chunk in stream {
                try schedule(chunk)
                consumed += 1
            }
        } catch {
            logger.error("play(stream:): stream THREW after \(consumed, privacy: .public) buffers: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if consumed == 0 {
            logger.warning("play(stream:): stream FINISHED WITH ZERO BUFFERS. Upstream synthesis produced no audio. Check synthesizeStream logs for the matching modelID.")
        } else {
            logger.info("play(stream:): stream drained, \(consumed, privacy: .public) buffers scheduled")
        }
    }

    /// Play a streaming synthesis result with **playback-driven** word
    /// highlighting. The framework's `chunkStarted` / `chunkFinished` /
    /// `chunkTimings` events fire when the synthesizer *generates* a chunk,
    /// not when its audio reaches the speaker — so using them directly for
    /// highlighting makes the cursor lead the audio by however long the
    /// playback queue has buffered ahead. For streams in particular, the
    /// gap accumulates and the highlight ends up pointing at words the
    /// listener hasn't reached yet (often: completely different text).
    ///
    /// This overload solves that by subscribing to the synthesizer's
    /// `events()` stream internally, building an absolute-time timeline as
    /// `chunkFinished` + `chunkTimings` events arrive, and firing `onWord`
    /// based on the player's actual `currentTime`. Behaviorally it's the
    /// same model the prebaked-narration path already uses.
    ///
    /// Call this *immediately* after `streamAndCacheNarration(...)` /
    /// `synthesizeLong(...)` returns: the events stream is established
    /// here, so events emitted between those two calls are missed.
    /// Worst-case effect is missed highlights for the first chunk if
    /// generation completed before subscription — for live MLX generation
    /// that gap is microseconds; for fully-cached replay the existing
    /// `play(narration:onWord:)` path is the right tool and doesn't have
    /// this race.
    public func play(
        stream: AsyncThrowingStream<TTSAudioBufferChunk, Error>,
        synthesizer: TTSSpeechSynthesizer,
        onWord: (@MainActor (TTSWordTiming) -> Void)? = nil,
        onPlaybackEnd: (@MainActor () -> Void)? = nil
    ) async throws {
        if let onWord {
            let events = await synthesizer.events()
            startStreamWordObserver(events: events, onWord: onWord)
        }
        try await play(stream: stream, onPlaybackEnd: onPlaybackEnd)
    }

    private func startStreamWordObserver(
        events: AsyncStream<TTSDiagnostic>,
        onWord: @escaping @MainActor (TTSWordTiming) -> Void
    ) {
        // Two concurrent loops sharing a tiny piece of state: the timeline
        // builder (consumes events, appends word entries with absolute
        // offsets) and the poller (samples `currentTime`, fires onWord
        // callbacks for crossed words). Both live on the @MainActor.
        //
        // We track chunk durations as they finish; when `chunkTimings`
        // arrives we sum every prior chunk's duration to derive the
        // absolute offset of each word. Out-of-order events are tolerated.
        let observer = Task { @MainActor [weak self] in
            var chunkDurations: [Int: TimeInterval] = [:]
            var timeline: [TTSWordTiming] = []
            var firedThrough = -1
            var streamingFinished = false

            let collector = Task { @MainActor in
                for await event in events {
                    if Task.isCancelled { return }
                    switch event {
                    case let .chunkFinished(_, chunkIndex, duration):
                        chunkDurations[chunkIndex] = duration
                    case let .chunkTimings(_, chunkIndex, timings):
                        let priorTotal = chunkDurations
                            .filter { $0.key < chunkIndex }
                            .values.reduce(0, +)
                        for timing in timings {
                            timeline.append(TTSWordTiming(
                                characterRange: timing.characterRange,
                                offset: priorTotal + timing.offset,
                                duration: timing.duration
                            ))
                        }
                    case .streamingFinished:
                        streamingFinished = true
                        return
                    default:
                        break
                    }
                }
            }

            defer { collector.cancel() }

            while !Task.isCancelled {
                guard let self else { return }
                let s = self.state
                if s == .stopped { return }
                // Only flush+return on idle when the upstream stream has
                // actually finished. Mid-stream `.idle` is transient — the
                // AVAudioPlayerNode briefly drains its queue between chunk
                // arrivals while we wait for MLX to deliver the next
                // chunk's buffers. Flushing the known timeline there fires
                // `onWord` for every word we've received metadata for
                // (which includes words far past the live playback edge),
                // killing the highlight cursor for the rest of the
                // session.
                if s == .idle, streamingFinished {
                    for i in (firedThrough + 1)..<timeline.count {
                        onWord(timeline[i])
                    }
                    return
                }
                let t = self.currentTime
                while (firedThrough + 1) < timeline.count,
                      timeline[firedThrough + 1].offset <= t {
                    firedThrough += 1
                    onWord(timeline[firedThrough])
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        narrationWordObserver = observer
    }

    /// Play an entire cached audio file. Stops any in-flight scheduled buffers
    /// first. Useful when you have a file from ``TTSAudioCache`` and don't
    /// need streaming.
    public func play(file url: URL, onPlaybackEnd: (@MainActor () -> Void)? = nil) throws {
        logger.info("play(file:): ENTRY url=\(url.lastPathComponent, privacy: .public)")
        stop()
        self.onPlaybackEnd = onPlaybackEnd
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            logger.error("play(file:): AVAudioFile(forReading:) failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        logger.info("play(file:): opened file length=\(audioFile.length, privacy: .public) frames sampleRate=\(audioFile.processingFormat.sampleRate, privacy: .public)")
        try connectIfNeeded(format: audioFile.processingFormat)
        currentFile = audioFile
        seekFrameOffset = 0
        scheduledBufferCount += 1
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedBufferCount += 1
                self.finishIfNeeded()
            }
        }
        if !playerNode.isPlaying, state != .paused {
            playerNode.play()
            state = .playing
            logger.info("play(file:): playerNode.play() invoked; state=playing")
        }
    }

    public func pause() {
        guard playerNode.isPlaying else { return }
        playerNode.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        playerNode.play()
        state = .playing
    }

    public func stop() {
        playerNode.stop()
        engine.stop()
        scheduledBufferCount = 0
        completedBufferCount = 0
        connectedFormat = nil
        currentFile = nil
        seekFrameOffset = 0
        narrationTotalDuration = nil
        narrationWordObserver?.cancel()
        narrationWordObserver = nil
        state = .stopped
        onPlaybackEnd = nil
    }

    /// Play a pre-baked ``TTSPreparedNarration`` end-to-end. Schedules each
    /// chunk's WAV in declaration order so the player's `currentTime` reports
    /// cumulative source-audio seconds across the entire bundle. `duration`
    /// reports the bundle total. `rate` and `seek(to:)` work the same way
    /// they do for single-file playback.
    ///
    /// `onWord` fires on the main actor whenever playback crosses a new word
    /// boundary. Timings are character-proportional, so highlight quality
    /// matches what live `synthesizeLong` would produce — but no model is
    /// loaded and no inference runs.
    ///
    /// Stops any in-flight playback before starting.
    public func play(
        narration: TTSPreparedNarration,
        onWord: (@MainActor (TTSWordTiming) -> Void)? = nil,
        onPlaybackEnd: (@MainActor () -> Void)? = nil
    ) throws {
        stop()
        self.onPlaybackEnd = onPlaybackEnd

        // Open the first chunk so we can hand its processingFormat to the
        // engine before scheduling. All chunks in a single narration are
        // assumed to share format — they were generated by the same model in
        // the same run.
        let chunks = narration.manifest.chunks.sorted { $0.index < $1.index }
        guard let firstChunkEntry = chunks.first else {
            throw TTSPreparedNarrationError.chunkAudioMissing(chunkIndex: -1, audioURL: narration.baseURL)
        }
        let firstChunkURL = narration.baseURL.appendingPathComponent(firstChunkEntry.audioFile, isDirectory: false)
        let firstFile = try AVAudioFile(forReading: firstChunkURL)
        try connectIfNeeded(format: firstFile.processingFormat)

        // Mark this as a narration session so duration / cleanup behave right.
        // currentFile points at the first chunk so seek(to:) inside the first
        // chunk's range still works. Multi-chunk seek isn't supported in this
        // pass — seek() will clamp to the first chunk's frame range.
        currentFile = firstFile
        narrationTotalDuration = narration.totalDuration
        seekFrameOffset = 0

        for chunkEntry in chunks {
            let chunkURL = narration.baseURL.appendingPathComponent(chunkEntry.audioFile, isDirectory: false)
            // Re-open per chunk so each schedule() call holds its own file handle.
            let chunkFile = (chunkEntry.index == firstChunkEntry.index)
                ? firstFile
                : try AVAudioFile(forReading: chunkURL)
            scheduledBufferCount += 1
            playerNode.scheduleFile(chunkFile, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.completedBufferCount += 1
                    self.finishIfNeeded()
                }
            }
        }
        if !playerNode.isPlaying, state != .paused {
            playerNode.play()
            state = .playing
        }

        if let onWord {
            startNarrationWordObserver(timeline: narration.flattenedWordTimeline(), onWord: onWord)
        }
    }

    private func startNarrationWordObserver(
        timeline: [TTSWordTiming],
        onWord: @escaping @MainActor (TTSWordTiming) -> Void
    ) {
        let observer = Task { @MainActor [weak self] in
            var firedThrough = -1
            while !Task.isCancelled {
                guard let self else { return }
                let s = self.state
                if s == .stopped { return }
                if s == .idle {
                    // Final flush: fire any remaining words to keep the
                    // highlight cursor from sticking at the second-to-last
                    // word for narrations that end mid-sentence.
                    for i in (firedThrough + 1)..<timeline.count {
                        onWord(timeline[i])
                    }
                    return
                }
                let t = self.currentTime
                // Walk forward as long as the next word's start has passed.
                while (firedThrough + 1) < timeline.count,
                      timeline[firedThrough + 1].offset <= t {
                    firedThrough += 1
                    onWord(timeline[firedThrough])
                }
                try? await Task.sleep(nanoseconds: 30_000_000) // ~30Hz
            }
        }
        narrationWordObserver = observer
    }

    /// Seek to a position in the currently playing file. Throws
    /// ``PlaybackError/seekUnsupportedForStream`` when no file is loaded
    /// (i.e. stream playback is active). Clamps to `[0, duration]`; seeking at
    /// or past `duration` finishes playback as if it had played to the end.
    /// Preserves the prior `playing` / `paused` state.
    public func seek(to time: TimeInterval) throws {
        guard let file = currentFile else {
            throw PlaybackError.seekUnsupportedForStream
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return }
        let totalFrames = file.length
        let targetFrame = AVAudioFramePosition(max(0, time) * sampleRate)
        if targetFrame >= totalFrames {
            // Treat as natural end-of-file: invoke the end callback and idle.
            let callback = onPlaybackEnd
            stop()
            state = .idle
            callback?()
            return
        }

        let wasPlaying = (state == .playing)
        // Resetting the player resets sampleTime to 0; we add seekFrameOffset
        // back via currentTime so observers see "position in file".
        playerNode.stop()
        scheduledBufferCount = 1
        completedBufferCount = 0
        seekFrameOffset = targetFrame
        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)
        playerNode.scheduleSegment(
            file,
            startingFrame: targetFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedBufferCount += 1
                self.finishIfNeeded()
            }
        }
        if wasPlaying {
            playerNode.play()
            state = .playing
        } else {
            state = .paused
        }
    }

    /// A stream of playback positions, sampled every `interval` seconds while
    /// the controller is active. Finishes when ``state`` becomes `.stopped` or
    /// `.idle` (natural end), or when the consumer cancels the iteration.
    ///
    /// Useful for driving a scrubber UI without polling on a `Timer` on the
    /// caller's side. Multiple subscribers are supported — each call returns
    /// an independent stream.
    public func timePulse(interval: TimeInterval = 0.1) -> AsyncStream<TimeInterval> {
        let safeInterval = max(0.01, interval)
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    let currentState = self.state
                    if currentState == .stopped || currentState == .idle {
                        // Emit one final position so consumers see end state.
                        continuation.yield(self.currentTime)
                        continuation.finish()
                        return
                    }
                    continuation.yield(self.currentTime)
                    try? await Task.sleep(nanoseconds: UInt64(safeInterval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func connectIfNeeded(format: AVAudioFormat) throws {
        if let existing = connectedFormat, existing == format { return }
        if connectedFormat != nil {
            logger.info("connectIfNeeded: format CHANGED, resetting graph (was sr=\(self.connectedFormat?.sampleRate ?? 0, privacy: .public) ch=\(self.connectedFormat?.channelCount ?? 0, privacy: .public) → new sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public))")
            playerNode.stop()
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
        } else {
            logger.info("connectIfNeeded: initial connect sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
        }
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            do {
                try engine.start()
                logger.info("connectIfNeeded: engine.start() OK")
            } catch {
                logger.error("connectIfNeeded: engine.start() FAILED: \(error.localizedDescription, privacy: .public). Most common causes: AVAudioSession not configured for .playback, or another app holding the audio hardware. Check the app's AVAudioSession setup.")
                throw error
            }
        }
        connectedFormat = format
    }

    private func finishIfNeeded() {
        guard scheduledBufferCount > 0,
              completedBufferCount >= scheduledBufferCount else { return }
        state = .idle
        let callback = onPlaybackEnd
        onPlaybackEnd = nil
        callback?()
    }
}
#endif
