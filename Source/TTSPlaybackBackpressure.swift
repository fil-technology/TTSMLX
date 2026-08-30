import Foundation

/// Bounds how far audio *generation* may run ahead of *playback*, capping the
/// memory used while streaming long-form text (whole books or articles) and
/// reducing battery / thermal load.
///
/// Without this gate the live path (``TTSSpeechSynthesizer/speakStreaming``)
/// generates chunk-by-chunk into an unbounded stream while the playback
/// controller schedules every produced buffer straight into
/// `AVAudioPlayerNode`. Because small models generate faster than real time,
/// a whole book's PCM would accumulate in memory (~170 MB per 30 min of audio,
/// multiplied across chapters) — enough to get the app jetsam-killed on iPhone.
///
/// The contract is a simple credit system measured in **seconds of audio**:
///
/// - The producer (synthesis) calls ``reserve(_:)`` *before* handing each
///   buffer downstream. When the queued-ahead audio reaches
///   `capacitySeconds`, `reserve` suspends.
/// - The consumer (playback) calls ``release(_:)`` as each buffer *finishes
///   playing*, which frees capacity and wakes the producer.
///
/// Net effect: at most `capacitySeconds` of audio is ever generated and
/// scheduled ahead of the playback head, so memory stays constant regardless
/// of how long the source text is.
///
/// The two sides run on different executors — the synthesizer's `@MainActor`
/// drain task and `AVAudioPlayerNode`'s render-thread completion handler — so
/// state is guarded by a lock rather than actor isolation. The lock is held
/// only for O(waiters) bookkeeping and never across a suspension point.
///
/// ### Deadlock safety on background
///
/// iOS suspends playback when the app backgrounds, so no buffers finish and no
/// `release` arrives. A producer suspended in `reserve` would then hang
/// forever, and because the consumer is waiting on the producer's next yield,
/// the whole stream would deadlock. Two mechanisms prevent that: task
/// cancellation resumes the suspended `reserve` (the producer then observes
/// `CancellationError` at its next checkpoint), and ``finish()`` releases every
/// waiter unconditionally when the stream ends or playback stops.
public final class TTSPlaybackBackpressure: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let amount: Double
        let resume: () -> Void
    }

    private let lock = NSLock()
    private let capacitySeconds: Double
    private var queuedSeconds: Double = 0
    private var isFinished = false
    private var waiters: [Waiter] = []
    /// IDs cancelled before their continuation registered, so the (slightly
    /// later) `reserve` body admits immediately instead of parking forever.
    private var cancelledBeforeRegister: Set<UUID> = []

    /// - Parameter capacitySeconds: maximum seconds of audio that may be
    ///   generated/scheduled ahead of the playback head. A value `<= 0`
    ///   disables backpressure entirely (every `reserve` returns immediately),
    ///   preserving the unbounded legacy behavior for callers that opt out.
    public init(capacitySeconds: Double) {
        self.capacitySeconds = capacitySeconds
    }

    /// The configured look-ahead window in seconds (`<= 0` means disabled).
    public var capacity: Double { capacitySeconds }

    /// Currently reserved (queued-ahead) seconds. Exposed for tests/metrics.
    public var queued: Double {
        lock.lock(); defer { lock.unlock() }
        return queuedSeconds
    }

    /// Suspend until there is room for `seconds` of audio, then reserve it.
    ///
    /// Returns immediately when backpressure is disabled (`capacity <= 0`),
    /// the gate is finished, the task is cancelled, or the queue is empty (so a
    /// single buffer longer than the whole window never deadlocks). Honors
    /// cooperative cancellation.
    public func reserve(_ seconds: Double) async {
        if capacitySeconds <= 0 { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isFinished
                    || cancelledBeforeRegister.remove(id) != nil
                    || queuedSeconds <= 0
                    || queuedSeconds + seconds <= capacitySeconds {
                    queuedSeconds += seconds
                    lock.unlock()
                    cont.resume()
                    return
                }
                waiters.append(Waiter(id: id, amount: seconds, resume: { cont.resume() }))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: idx)
                // The producer is unwinding; account for the reservation so the
                // counter doesn't go negative when (if) a matching release lands.
                queuedSeconds += waiter.amount
                lock.unlock()
                waiter.resume()
            } else {
                // Continuation hasn't registered yet — flag it so the body
                // admits immediately when it runs.
                cancelledBeforeRegister.insert(id)
                lock.unlock()
            }
        }
    }

    /// Mark `seconds` of audio as played, freeing capacity and waking any
    /// waiters that now fit (FIFO).
    public func release(_ seconds: Double) {
        lock.lock()
        queuedSeconds = max(0, queuedSeconds - seconds)
        let woken = drainWaitersLocked()
        lock.unlock()
        for resume in woken { resume() }
    }

    /// Release every waiter and admit all future `reserve` calls. Call when the
    /// stream ends, throws, is superseded, or playback stops — guarantees no
    /// producer stays suspended.
    public func finish() {
        lock.lock()
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    /// Wakes leading waiters that now fit. Must be called with `lock` held;
    /// returns their resume closures to invoke *after* unlocking.
    private func drainWaitersLocked() -> [() -> Void] {
        var woken: [() -> Void] = []
        while let waiter = waiters.first {
            if queuedSeconds <= 0 || queuedSeconds + waiter.amount <= capacitySeconds {
                queuedSeconds += waiter.amount
                woken.append(waiter.resume)
                waiters.removeFirst()
            } else {
                // Strict FIFO: a later small waiter must not jump a parked
                // large one, or it could starve.
                break
            }
        }
        return woken
    }
}
