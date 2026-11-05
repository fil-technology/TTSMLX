import Foundation
import Testing
@testable import TTSMLX

/// A stream's generation task has to stop when nobody reads the stream.
///
/// The bug these exist for: the task generated to the end of its text after
/// the consumer had left, holding the generation gate for nobody.
@Suite("Stream consumer leaving")
struct TTSStreamConsumerTests {

    private actor Counter {
        private(set) var yielded = 0
        private(set) var wasCancelled = false
        func didYield() { yielded += 1 }
        func finished(cancelled: Bool) { wasCancelled = cancelled }
    }

    /// A stream wired the way the synthesizer wires its own: an unstructured
    /// task feeds it, up to `limit` values 5 ms apart.
    private func makeStream(limit: Int, counter: Counter) -> (AsyncThrowingStream<Int, Error>, Task<Void, Never>) {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let producer = Task {
            var value = 0
            while !Task.isCancelled, value < limit {
                continuation.yield(value)
                await counter.didYield()
                value += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            await counter.finished(cancelled: Task.isCancelled)
            continuation.finish()
        }
        continuation.cancelWhenConsumerLeaves(producer)
        return (stream, producer)
    }

    private func readThree(_ stream: AsyncThrowingStream<Int, Error>) async throws {
        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen == 3 { break }
        }
    }

    @Test("dropping the stream part-way stops the producer")
    func droppingTheStreamStopsTheProducer() async throws {
        let counter = Counter()
        let producer: Task<Void, Never>
        do {
            let (stream, task) = makeStream(limit: 400, counter: counter)
            producer = task
            try await readThree(stream)
        }
        await producer.value
        #expect(await counter.wasCancelled)
        #expect(await counter.yielded < 400)
    }

    @Test("cancelling the consuming task stops the producer")
    func cancellingTheConsumerStopsTheProducer() async {
        let counter = Counter()
        let (stream, producer) = makeStream(limit: 400, counter: counter)
        let consumer = Task {
            var seen = 0
            for try await _ in stream { seen += 1 }
            return seen
        }
        try? await Task.sleep(for: .milliseconds(30))
        consumer.cancel()
        // The loop ends without throwing; that is why the synthesizer checks
        // for cancellation after each of its own.
        let seen = (try? await consumer.value) ?? -1
        await producer.value
        #expect(seen >= 0 && seen < 400)
        #expect(await counter.wasCancelled)
    }

    @Test("a stream read to its end leaves the producer alone")
    func readingToTheEndDoesNotCancel() async throws {
        let counter = Counter()
        let (stream, producer) = makeStream(limit: 5, counter: counter)
        var seen = 0
        for try await _ in stream { seen += 1 }
        await producer.value
        #expect(seen == 5)
        #expect(await counter.wasCancelled == false)
    }
}
