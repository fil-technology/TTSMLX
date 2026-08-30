import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSPlaybackBackpressure")
struct TTSPlaybackBackpressureTests {
    /// Actor flag used to observe whether a suspended `reserve` has resumed
    /// without relying on wall-clock timing.
    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    @Test("capacity <= 0 disables backpressure: every reserve returns immediately")
    func disabledNeverBlocks() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 0)
        for _ in 0..<100 { await gate.reserve(5) }
        // queued stays 0 because the disabled gate never accounts reservations.
        #expect(gate.queued == 0)
    }

    @Test("reserves under capacity return immediately and accumulate")
    func underCapacityAdmits() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 10)
        await gate.reserve(3)
        await gate.reserve(3)
        #expect(gate.queued == 6)
    }

    @Test("a single buffer larger than the whole window is admitted when empty")
    func oversizedBufferNeverDeadlocks() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 5)
        await gate.reserve(60) // > capacity, but queue is empty → admit
        #expect(gate.queued == 60)
    }

    @Test("reserve blocks once over capacity and resumes after release")
    func blocksThenResumesOnRelease() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 10)
        await gate.reserve(8) // queued = 8
        let flag = Flag()
        let task = Task {
            await gate.reserve(8) // 8 + 8 > 10, and queue non-empty → blocks
            await flag.set()
        }
        // Give the task ample opportunity to (not) complete.
        for _ in 0..<20 { await Task.yield() }
        #expect(await flag.isSet == false)

        gate.release(8) // queued back to 0 → waiter fits and wakes
        await task.value
        #expect(await flag.isSet == true)
        #expect(gate.queued == 8)
    }

    @Test("finish() releases every suspended waiter")
    func finishReleasesWaiters() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 4)
        await gate.reserve(4)
        let flag = Flag()
        let task = Task {
            await gate.reserve(4) // blocks
            await flag.set()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await flag.isSet == false)

        gate.finish()
        await task.value
        #expect(await flag.isSet == true)
    }

    @Test("cancellation resumes a suspended reserve (no deadlock on background)")
    func cancellationResumesWaiter() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 4)
        await gate.reserve(4)
        let flag = Flag()
        let task = Task {
            await gate.reserve(4) // blocks
            await flag.set()
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await flag.isSet == false)

        task.cancel()
        await task.value
        #expect(await flag.isSet == true)
    }

    @Test("FIFO: a later small waiter does not jump a parked large one")
    func fifoOrdering() async {
        let gate = TTSPlaybackBackpressure(capacitySeconds: 10)
        await gate.reserve(10) // full
        let order = Order()
        let big = Task { await gate.reserve(10); await order.append("big") }
        for _ in 0..<10 { await Task.yield() }
        let small = Task { await gate.reserve(1); await order.append("small") }
        for _ in 0..<10 { await Task.yield() }

        // Free 1s: not enough for the parked 10s waiter, and FIFO forbids the
        // 1s waiter from jumping ahead, so neither resumes yet.
        gate.release(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(await order.values.isEmpty)

        // Free the rest: big now fits and is admitted (and holds its 10s).
        gate.release(9)
        await big.value
        #expect(await order.values == ["big"])

        // Releasing big's reservation finally makes room for small.
        gate.release(10)
        await small.value
        #expect(await order.values == ["big", "small"])
    }

    private actor Order {
        private(set) var values: [String] = []
        func append(_ v: String) { values.append(v) }
    }
}
