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

    public private(set) var state: State = .idle
    /// Playback rate. 1.0 = real time. Range 0.5–2.0 is the safe band that
    /// `AVAudioUnitTimePitch` handles without audible artifacts. Outside that
    /// band, audio quality degrades but it still plays.
    public var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.5, min(2.0, newValue)) }
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?
    private var scheduledBufferCount = 0
    private var completedBufferCount = 0
    private var onPlaybackEnd: (@MainActor () -> Void)?
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
        state = .stopped
        onPlaybackEnd = nil
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
