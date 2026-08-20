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

    /// Total duration in seconds for file or narration playback, and for
    /// stream playback the audio produced so far.
    ///
    /// For a stream this grows as chunks arrive and settles on the true total
    /// once the stream finishes, so a scrubber can show a running total rather
    /// than nothing at all. ``isDurationFinal`` says which it is.
    public var duration: TimeInterval? {
        if let narrationTotalDuration { return narrationTotalDuration }
        if let streamAccumulatedDuration { return streamAccumulatedDuration }
        guard let file = currentFile else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// Sum of the audio produced by the stream so far. Fed by `.chunkFinished`
    /// durations, which are audio seconds.
    private var streamAccumulatedDuration: TimeInterval?
    /// Whether ``duration`` is the final total rather than a running one.
    public private(set) var isDurationFinal: Bool = true

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    /// True while a streamed source is still producing buffers. Prevents
    /// `finishIfNeeded` from declaring playback finished when the queue merely
    /// drains between chunks (which would prematurely fire `onPlaybackEnd`,
    /// flipping a reader UI back to "stopped" mid-read).
    private var streamProducing = false
    private var onPlaybackEnd: (@MainActor () -> Void)?
    private var currentFile: AVAudioFile?

    /// Chunk files of the narration being played, with the absolute time each
    /// one begins at. Held so ``seek(to:)`` can land inside any chunk and
    /// re-queue the remainder — without this, seeking could only address the
    /// first chunk and silently dropped everything after it.
    private var narrationChunks: [(file: AVAudioFile, startTime: TimeInterval)] = []

    /// Bumped on every seek. The word observer watches this and re-places its
    /// cursor, because the cursor only moves forward: without this a backward
    /// seek freezes the highlight until playback returns to where it was, and a
    /// forward seek flashes it through every word it skipped.
    private var seekGeneration = 0

    /// Word timeline for whatever is playing, so the current word can be looked
    /// up at any moment rather than only observed as it passes.
    private var activeWordTimeline: [TTSWordTiming] = []

    /// The word being spoken right now, or `nil` when nothing is playing.
    ///
    /// Updated as playback advances and re-placed after a seek. Read this when
    /// rendering — a view that redraws for an unrelated reason, or appears
    /// mid-playback, needs the current word rather than the last callback it
    /// happened to catch.
    public private(set) var currentWord: TTSWordTiming?
    private var seekFrameOffset: AVAudioFramePosition = 0
    /// Set when playing a TTSPreparedNarration. Overrides `duration` to be
    /// the bundle's total length and drives the word-callback observer task.
    private var narrationTotalDuration: TimeInterval?
    private var narrationWordObserver: Task<Void, Never>?
    /// Bumped every time a `play(...)` method starts a new session. Used
    /// so a long-running `for try await chunk in stream` loop from a
    /// prior call can detect that a newer session has taken over (e.g.
    /// the user switched voice or speed and a new stream is being
    /// scheduled) and bail out cleanly instead of continuing to schedule
    /// stale buffers onto the audio engine.
    private var sessionToken: Int = 0
    /// Optional look-ahead gate. When set (by ``play(stream:backpressure:...)``,
    /// wired up automatically by ``TTSSpeechSynthesizer/speakStreaming``), the
    /// producer reserves capacity before generating each buffer and we release
    /// it here as each buffer finishes playing — bounding how far generation
    /// runs ahead of playback. `nil` preserves the unbounded legacy behavior.
    private var backpressure: TTSPlaybackBackpressure?
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
        // Duration of this buffer in source-audio seconds, used to release the
        // backpressure reservation the producer made for it. Capture the gate
        // active *now* so a buffer always releases the gate it reserved against,
        // even if a later session installed a different one.
        let bufferSeconds = chunk.sampleRate > 0
            ? Double(chunk.buffer.frameLength) / Double(chunk.sampleRate)
            : 0
        let gate = backpressure
        playerNode.scheduleBuffer(chunk.buffer) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completedBufferCount += 1
                gate?.release(bufferSeconds)
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
        backpressure: TTSPlaybackBackpressure? = nil,
        onPlaybackEnd: (@MainActor () -> Void)? = nil
    ) async throws {
        // Stop any prior session so this call doesn't stack onto a still-
        // running playback (the classic voice-change-mid-stream glitch),
        // then claim a fresh session before consuming the stream.
        stop()
        self.backpressure = backpressure
        let myToken = beginSession()
        try await drainStream(stream, token: myToken, gate: backpressure, onPlaybackEnd: onPlaybackEnd)
    }

    /// Bump and return the new session token. Stays a single source of
    /// truth so every public play(...) entry point invalidates older
    /// sessions consistently.
    private func beginSession() -> Int {
        sessionToken += 1
        return sessionToken
    }

    /// Pure stream-drain loop, no stop() or session bump — those must be
    /// handled by the caller exactly once per public play(...) entry. The
    /// loop bails early if a newer session has taken over so stale buffers
    /// from a superseded call don't reach the audio engine.
    private func drainStream(
        _ stream: AsyncThrowingStream<TTSAudioBufferChunk, Error>,
        token myToken: Int,
        gate: TTSPlaybackBackpressure?,
        onPlaybackEnd: (@MainActor () -> Void)?
    ) async throws {
        logger.info("play(stream:): ENTRY state=\(String(describing: self.state), privacy: .public) token=\(myToken, privacy: .public)")
        self.onPlaybackEnd = onPlaybackEnd
        currentFile = nil
        narrationChunks = []
        activeWordTimeline = []
        currentWord = nil
        seekFrameOffset = 0
        var consumed = 0
        // While draining, don't let a transient queue-drain between chunks be
        // mistaken for end-of-playback.
        streamProducing = true
        // Whatever ends this drain (completion, supersession, throw,
        // cancellation), release any producer parked on the gate so it can't
        // deadlock waiting for a `release` that will never come.
        defer { gate?.finish() }
        do {
            for try await chunk in stream {
                if sessionToken != myToken {
                    logger.info("play(stream:): superseded by token=\(self.sessionToken, privacy: .public); exiting")
                    return // a newer session's stop() owns resetting streamProducing
                }
                try schedule(chunk)
                consumed += 1
            }
        } catch {
            streamProducing = false
            logger.error("play(stream:): stream THREW after \(consumed, privacy: .public) buffers: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        // Stream fully produced: now end-of-queue genuinely means finished.
        streamProducing = false
        finishIfNeeded()
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
        backpressure: TTSPlaybackBackpressure? = nil,
        onWord: (@MainActor (TTSWordTiming) -> Void)? = nil,
        onPlaybackEnd: (@MainActor () -> Void)? = nil
    ) async throws {
        // Same stop+session ordering as the simple play(stream:) overload —
        // but stop() must happen *before* startStreamWordObserver, otherwise
        // stop() would cancel the observer we just registered.
        stop()
        self.backpressure = backpressure
        let myToken = beginSession()
        // A stream's total length is unknown until it ends; `duration` reports
        // the audio produced so far and `isDurationFinal` stays false until
        // `.streamingFinished`.
        isDurationFinal = false
        streamAccumulatedDuration = 0
        if let onWord {
            let events = await synthesizer.events()
            startStreamWordObserver(events: events, onWord: onWord)
        }
        try await drainStream(stream, token: myToken, gate: backpressure, onPlaybackEnd: onPlaybackEnd)
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
                        self?.streamAccumulatedDuration = chunkDurations.values.reduce(0, +)
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
                        // The cursor below only moves forward, so an
                        // out-of-order arrival would strand every word behind
                        // it. Chunks normally arrive in order and this is a
                        // no-op; it costs little and removes the failure mode.
                        if timeline.count > 1 {
                            let tail = timeline[(timeline.count - timings.count)...]
                            if let first = tail.first,
                               let previous = timeline.dropLast(timings.count).last,
                               first.offset < previous.offset {
                                timeline.sort { $0.offset < $1.offset }
                            }
                        }
                    case .streamingFinished:
                        streamingFinished = true
                        self?.isDurationFinal = true
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
                    self.currentWord = timeline.last
                    return
                }
                let t = self.currentTime
                // Keep the queryable timeline in step with what has arrived, so
                // `wordTiming(at:)` and `currentWord` work mid-stream too.
                self.activeWordTimeline = timeline
                while (firedThrough + 1) < timeline.count,
                      timeline[firedThrough + 1].offset <= t {
                    firedThrough += 1
                    self.currentWord = timeline[firedThrough]
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
        streamProducing = false
        scheduledBufferCount = 0
        completedBufferCount = 0
        connectedFormat = nil
        currentFile = nil
        narrationChunks = []
        activeWordTimeline = []
        currentWord = nil
        seekFrameOffset = 0
        narrationTotalDuration = nil
        streamAccumulatedDuration = nil
        isDurationFinal = true
        narrationWordObserver?.cancel()
        narrationWordObserver = nil
        // Release any producer parked on the look-ahead gate so it observes the
        // stop (the next play(...) installs a fresh gate).
        backpressure?.finish()
        backpressure = nil
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
        currentFile = firstFile
        narrationTotalDuration = narration.totalDuration
        seekFrameOffset = 0
        narrationChunks = []

        var startTime: TimeInterval = 0
        for chunkEntry in chunks {
            let chunkURL = narration.baseURL.appendingPathComponent(chunkEntry.audioFile, isDirectory: false)
            // Re-open per chunk so each schedule() call holds its own file handle.
            let chunkFile = (chunkEntry.index == firstChunkEntry.index)
                ? firstFile
                : try AVAudioFile(forReading: chunkURL)
            narrationChunks.append((file: chunkFile, startTime: startTime))
            let rate = chunkFile.processingFormat.sampleRate
            if rate > 0 { startTime += Double(chunkFile.length) / rate }
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
        activeWordTimeline = timeline
        let observer = Task { @MainActor [weak self] in
            var firedThrough = -1
            var seenGeneration = self?.seekGeneration ?? 0
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
                    self.currentWord = timeline.last
                    return
                }
                let t = self.currentTime

                // A seek moves the playhead arbitrarily, so re-place the cursor
                // instead of walking to it: walking backwards is impossible and
                // walking forwards would fire every word in between.
                if self.seekGeneration != seenGeneration {
                    seenGeneration = self.seekGeneration
                    let landing = Self.indexOfWord(at: t, in: timeline)
                    firedThrough = landing
                    if landing >= 0 {
                        self.currentWord = timeline[landing]
                        onWord(timeline[landing])
                    } else {
                        self.currentWord = nil
                    }
                }

                // Walk forward as long as the next word's start has passed.
                while (firedThrough + 1) < timeline.count,
                      timeline[firedThrough + 1].offset <= t {
                    firedThrough += 1
                    self.currentWord = timeline[firedThrough]
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
    /// Index of the word being spoken at `time`, or -1 before the first word.
    ///
    /// Binary search: the timeline for a long article runs to thousands of
    /// words and this is consulted on every seek.
    nonisolated static func indexOfWord(at time: TimeInterval, in timeline: [TTSWordTiming]) -> Int {
        guard let first = timeline.first, time >= first.offset else { return -1 }
        var low = 0
        var high = timeline.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if timeline[mid].offset <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// The word spoken at `time`, for anything playing with a word timeline
    /// (a narration, or a stream once its timings have arrived).
    ///
    /// Useful for rendering a scrubber preview, or restoring a highlight after
    /// the view reappears, without waiting for the next callback.
    public func wordTiming(at time: TimeInterval) -> TTSWordTiming? {
        let index = Self.indexOfWord(at: time, in: activeWordTimeline)
        guard index >= 0 else { return nil }
        return activeWordTimeline[index]
    }

    /// Seeks across a multi-chunk narration: plays the containing chunk from
    /// an offset, then queues every later chunk in full.
    ///
    /// `seekFrameOffset` is set to the absolute target so ``currentTime`` keeps
    /// reporting position within the whole narration rather than within the
    /// chunk — the word timeline is absolute, so the two must share an origin.
    private func seekWithinNarration(to time: TimeInterval) throws {
        let target = max(0, time)
        if let total = narrationTotalDuration, target >= total {
            let callback = onPlaybackEnd
            stop()
            state = .idle
            callback?()
            return
        }

        guard let landing = narrationChunks.last(where: { $0.startTime <= target })
                ?? narrationChunks.first else {
            throw PlaybackError.seekUnsupportedForStream
        }
        let sampleRate = landing.file.processingFormat.sampleRate
        guard sampleRate > 0 else { return }

        let wasPlaying = (state == .playing)
        playerNode.stop()
        scheduledBufferCount = 0
        completedBufferCount = 0
        seekFrameOffset = AVAudioFramePosition(target * sampleRate)
        seekGeneration += 1

        let intoChunk = target - landing.startTime
        let startFrame = min(
            max(0, AVAudioFramePosition(intoChunk * sampleRate)),
            max(0, landing.file.length - 1)
        )
        let remaining = AVAudioFrameCount(max(0, landing.file.length - startFrame))
        if remaining > 0 {
            scheduledBufferCount += 1
            playerNode.scheduleSegment(
                landing.file, startingFrame: startFrame, frameCount: remaining, at: nil
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.completedBufferCount += 1
                    self.finishIfNeeded()
                }
            }
        }

        for chunk in narrationChunks where chunk.startTime > landing.startTime {
            scheduledBufferCount += 1
            playerNode.scheduleFile(chunk.file, at: nil) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.completedBufferCount += 1
                    self.finishIfNeeded()
                }
            }
        }

        if wasPlaying {
            playerNode.play()
            state = .playing
        }
    }

    public func seek(to time: TimeInterval) throws {
        // A narration is many files; seek has to find the one containing the
        // target and re-queue everything after it. Rescheduling only the file
        // the target lands in would silently truncate playback there.
        if narrationChunks.count > 1 {
            try seekWithinNarration(to: time)
            return
        }
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
        seekGeneration += 1
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
        // Don't finish while a stream is still producing — the queue draining
        // between chunks is transient, not end-of-playback.
        guard !streamProducing,
              scheduledBufferCount > 0,
              completedBufferCount >= scheduledBufferCount else { return }
        state = .idle
        let callback = onPlaybackEnd
        onPlaybackEnd = nil
        callback?()
    }
}
#endif
