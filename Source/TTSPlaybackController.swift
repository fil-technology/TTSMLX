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

    /// Wall-clock seconds of audio the player has actually rendered for the
    /// current session. Resets on ``stop()``. For file playback this respects
    /// ``seek(to:)`` (the returned value is "position in file", not "time
    /// since play started"). Rate-scaled: at 2× rate, two seconds of source
    /// audio render per real second.
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

    /// Total duration in seconds for file playback. `nil` for stream playback
    /// (the total length isn't known until the stream finishes).
    public var duration: TimeInterval? {
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
        self.onPlaybackEnd = onPlaybackEnd
        currentFile = nil
        seekFrameOffset = 0
        for try await chunk in stream {
            try schedule(chunk)
        }
    }

    /// Play an entire cached audio file. Stops any in-flight scheduled buffers
    /// first. Useful when you have a file from ``TTSAudioCache`` and don't
    /// need streaming.
    public func play(file url: URL, onPlaybackEnd: (@MainActor () -> Void)? = nil) throws {
        stop()
        self.onPlaybackEnd = onPlaybackEnd
        let audioFile = try AVAudioFile(forReading: url)
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
        state = .stopped
        onPlaybackEnd = nil
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
            // Format change mid-playback — reset the graph.
            playerNode.stop()
            engine.stop()
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
        }
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        if !engine.isRunning {
            try engine.start()
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
