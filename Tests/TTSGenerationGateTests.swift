import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSGenerationGate")
struct TTSGenerationGateTests {
    @Test("second acquirer waits until the holder releases")
    func serializesAcquirers() async throws {
        let gate = TTSGenerationGate()
        try await gate.acquire()
        #expect(gate.isLocked)

        let order = OrderRecorder()
        let waiter = Task {
            try await gate.acquire()
            await order.append("second")
            gate.release()
        }
        // Give the waiter time to queue up behind the holder.
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.waitingCount == 1)
        await order.append("first")
        gate.release()
        try await waiter.value
        #expect(await order.values == ["first", "second"])
        #expect(!gate.isLocked)
    }

    @Test("a cancelled waiter throws and leaves the queue")
    func cancelledWaiterLeavesQueue() async throws {
        let gate = TTSGenerationGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.waitingCount == 1)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(gate.waitingCount == 0)
        gate.release()
        #expect(!gate.isLocked)
        // The gate is still usable afterwards.
        try await gate.acquire()
        gate.release()
    }

    @Test("acquire on an already-cancelled task throws without holding")
    func acquireOnCancelledTaskThrows() async throws {
        let gate = TTSGenerationGate()
        let task = Task {
            try await Task.sleep(for: .seconds(10))
            try await gate.acquire()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!gate.isLocked)
    }
}

private actor OrderRecorder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
