#if canImport(AVFoundation)
import Foundation

/// Events emitted by a ``TTSRealtimeSession`` as it speaks conversational turns.
public enum TTSRealtimeEvent: Sendable {
    /// A turn started generating.
    case turnStarted(id: UUID, text: String)
    /// The first word of a turn reached the speaker. `latency` is wall-clock
    /// seconds from `say(_:)` to first audio — the number to watch for "feels
    /// instant" conversational TTS.
    case firstAudio(id: UUID, latency: TimeInterval)
    /// A turn finished speaking to completion.
    case turnFinished(id: UUID)
    /// A turn was cut off by a barge-in (`say(_:delivery:.interrupt)` or
    /// ``TTSRealtimeSession/interrupt()``).
    case interrupted(id: UUID)
    /// A turn failed; `message` is the underlying error description.
    case failed(id: UUID, message: String)
    /// The queue drained — nothing is speaking.
    case idle
}

/// How a new turn relates to whatever is currently speaking.
public enum TTSRealtimeDelivery: Sendable, Hashable {
    /// Barge-in: stop the current turn and clear the queue, speak this now.
    /// This is the default and the right mode for a conversational loop where
    /// each new user utterance should cut off the assistant immediately.
    case interrupt
    /// Speak after the current turn (and anything already queued) finishes.
    case enqueue
}

/// A low-latency conversational TTS controller for the "ask → speak → repeat"
/// loop. Feed it text turns (from your own speech-to-text, or any source) and
/// it speaks them with barge-in: a new `.interrupt` turn instantly stops both
/// in-flight generation and audio, then starts the new turn.
///
/// Speech-to-text is intentionally **out of scope** — supply text from whatever
/// recognizer you use. (The `mlx-audio-swift` backend ships streaming STT
/// (Voxtral) and turn detection (SmartTurn) if you later want a fully on-device
/// mic→text→speech loop; wire those in upstream and call `say(_:)` with the
/// transcript.)
///
/// ## Example
/// ```swift
/// let session = TTSRealtimeSession(
///     model: TTSMLX.recommendedModel(for: .current)!,
///     options: .init(streamingInterval: 0.8), // small chunks = fast first word
///     playback: playbackController,
///     onWord: { _, word in highlight(word) },
///     onEvent: { event in print(event) }
/// )
/// try await session.warmUp()           // once, so the first turn is instant
/// session.say("Hi, how can I help?")   // assistant speaks
/// // later, user starts talking again → your STT yields text →
/// session.say("Actually, never mind.") // barge-in: cuts off the previous turn
/// ```
@MainActor
public final class TTSRealtimeSession {
    public struct Turn: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let text: String
    }

    public let model: TTSModelDescriptor
    /// Synthesis options applied to every turn. A small `streamingInterval`
    /// (≈0.6–1.0 s) lowers time-to-first-word; tune per device.
    public var options: TTSSynthesisOptions

    private let synthesizer: TTSSpeechSynthesizer
    private let playback: TTSPlaybackController
    private let onWord: (@MainActor (UUID, TTSWordTiming) -> Void)?
    private let onEvent: (@MainActor (TTSRealtimeEvent) -> Void)?
    private let onProgress: (@MainActor @Sendable (TTSProgressUpdate) -> Void)?

    private var queue: [Turn] = []
    private var currentTurn: Turn?
    private var turnTask: Task<Void, Never>?
    /// Bumped on every barge-in. A turn task captures the value at launch and
    /// bails if it no longer matches — so a superseded turn never advances the
    /// queue or clears state belonging to its replacement.
    private var generation = 0

    public init(
        model: TTSModelDescriptor,
        options: TTSSynthesisOptions = .init(),
        synthesizer: TTSSpeechSynthesizer = TTSSpeechSynthesizer(),
        playback: TTSPlaybackController,
        onWord: (@MainActor (UUID, TTSWordTiming) -> Void)? = nil,
        onEvent: (@MainActor (TTSRealtimeEvent) -> Void)? = nil,
        onProgress: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) {
        self.model = model
        self.options = options
        self.synthesizer = synthesizer
        self.playback = playback
        self.onWord = onWord
        self.onEvent = onEvent
        self.onProgress = onProgress
    }

    /// `true` while a turn is generating or speaking.
    public var isSpeaking: Bool { currentTurn != nil }

    /// Preload the model so the first `say(_:)` doesn't pay the load cost.
    public func warmUp() async throws {
        _ = try await synthesizer.warmUp(model, hfToken: options.hfToken)
    }

    /// Speak `text`. With `.interrupt` (default) this cuts off whatever is
    /// currently speaking; with `.enqueue` it speaks after the current turn.
    /// Returns the created `Turn` (or `nil` if `text` was empty).
    @discardableResult
    public func say(_ text: String, delivery: TTSRealtimeDelivery = .interrupt) -> Turn? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let turn = Turn(id: UUID(), text: trimmed)
        switch delivery {
        case .interrupt:
            bargeIn()
            queue = [turn]
        case .enqueue:
            queue.append(turn)
        }
        pump()
        return turn
    }

    /// Cut off the current turn and clear the queue (e.g. the user started
    /// speaking again). Idempotent.
    public func interrupt() {
        guard currentTurn != nil || !queue.isEmpty else { return }
        bargeIn()
        queue.removeAll()
        emit(.idle)
    }

    /// Stop everything. Safe to call from a scene-teardown hook.
    public func finish() {
        bargeIn()
        queue.removeAll()
    }

    // MARK: - Internals

    /// Stop in-flight generation and audio immediately and invalidate the
    /// running turn. Generation is also re-cancelled at the start of the next
    /// turn task (ordered, so the replacement turn's own generation survives).
    private func bargeIn() {
        generation &+= 1
        turnTask?.cancel()
        turnTask = nil
        playback.stop()
        // Stop the detached MLX generation producer too (it isn't a child of
        // turnTask). Fire-and-forget; the next turn re-cancels in-order before
        // starting, so this can't race the replacement's generation.
        let synth = synthesizer
        Task { await synth.cancelAllInFlight() }
        if let turn = currentTurn { emit(.interrupted(id: turn.id)) }
        currentTurn = nil
    }

    private func pump() {
        guard currentTurn == nil, !queue.isEmpty else { return }
        let turn = queue.removeFirst()
        currentTurn = turn
        let myGeneration = generation
        let start = Date()
        emit(.turnStarted(id: turn.id, text: turn.text))

        turnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Guarantee any prior turn's generation is fully cancelled before
            // we touch MLX, so this turn starts clean and isn't cancelled by a
            // late-arriving cancellation from the turn we replaced.
            await self.synthesizer.cancelAllInFlight()
            guard myGeneration == self.generation else { return }

            await self.runTurn(turn, start: start)

            guard myGeneration == self.generation else { return }
            self.currentTurn = nil
            self.turnTask = nil
            if self.queue.isEmpty {
                self.emit(.idle)
            } else {
                self.pump()
            }
        }
    }

    private func runTurn(_ turn: Turn, start: Date) async {
        var firstAudioEmitted = false
        do {
            try Task.checkCancellation()
            let stream = try await synthesizer.synthesizeLong(
                turn.text, using: model, options: options,
                progressHandler: onProgress
            )
            try await playback.play(
                stream: stream,
                synthesizer: synthesizer,
                onWord: { [weak self] timing in
                    guard let self else { return }
                    if !firstAudioEmitted {
                        firstAudioEmitted = true
                        self.emit(.firstAudio(id: turn.id, latency: Date().timeIntervalSince(start)))
                    }
                    self.onWord?(turn.id, timing)
                }
            )
            // play(stream:) returns once the whole utterance is scheduled; wait
            // for the queued audio to actually finish before the turn is "done".
            try await waitUntilPlaybackFinished()
            emit(.turnFinished(id: turn.id))
        } catch is CancellationError {
            // Barge-in already emitted `.interrupted`; nothing to do.
        } catch {
            emit(.failed(id: turn.id, message: error.localizedDescription))
        }
    }

    private func waitUntilPlaybackFinished() async throws {
        // Safe to poll for completion only after play() returned (the stream is
        // fully scheduled), so no more buffers will be added and `.playing`
        // ends exactly when the tail finishes.
        while playback.state == .playing {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 60_000_000) // 60 ms
        }
    }

    private func emit(_ event: TTSRealtimeEvent) {
        onEvent?(event)
    }
}
#endif
