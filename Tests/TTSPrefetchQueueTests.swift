import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSPrefetchQueue", .serialized)
struct TTSPrefetchQueueTests {
    @Test("policy gate returns lowPowerMode when configured")
    func policyDefaults() {
        let policy = TTSPrefetchPolicy()
        #expect(policy.thermalCutoff == .serious)
        #expect(policy.pauseOnLowPowerMode)
        #expect(policy.maxQueuedItems == 256)
    }

    @Test("enqueue skips requests whose audio is already cached")
    func enqueueSkipsCached() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefetchTest-\(UUID().uuidString)", isDirectory: true)
        let cache = try TTSAudioCache(directoryURL: cacheDir)
        let synth = TTSSpeechSynthesizer()
        let queue = TTSPrefetchQueue(synthesizer: synth, cache: cache)

        let model = TTSMLX.supportedModels[0]
        let cachedRequest = TTSPrefetchRequest(text: "already cached", model: model)

        // Seed the cache with a fake-but-valid WAV under the request's key.
        let key = await cache.key(modelID: model.id, voice: nil, text: cachedRequest.text)
        let handle = await cache.reserveWrite(forKey: key)
        try writeFakeWAV(to: handle.temporaryURL)
        _ = try await cache.finalize(handle)
        #expect(await cache.contains(key: key))

        await queue.enqueue([cachedRequest])
        // The queue should have rejected the only enqueued item as already cached
        // before kicking off any work. Wait a beat for the async drain to settle.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await queue.queueDepth == 0)
    }

    @Test("replace() drops the pending queue and enqueues a new set")
    func replaceSwapsQueue() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefetchTest-\(UUID().uuidString)", isDirectory: true)
        let cache = try TTSAudioCache(directoryURL: cacheDir)
        let synth = TTSSpeechSynthesizer()
        // Keep the policy permissive so items aren't paused before we check.
        let queue = TTSPrefetchQueue(
            synthesizer: synth,
            cache: cache,
            policy: .init(thermalCutoff: .critical, pauseOnLowPowerMode: false, maxQueuedItems: 100)
        )

        let model = TTSMLX.supportedModels[0]
        let originalVoice: TTSVoice = "alice"
        let switchedVoice: TTSVoice = "bob"

        let original = (0..<5).map {
            TTSPrefetchRequest(text: "chunk-\($0)", model: model, voice: originalVoice)
        }
        let replacement = (0..<3).map {
            TTSPrefetchRequest(text: "chunk-\($0)", model: model, voice: switchedVoice)
        }

        await queue.enqueue(original)
        // Snapshot pre-replace depth: up to 5 pending + up to 1 in-flight.
        let preDepth = await queue.queueDepth
        #expect(preDepth >= 1)

        await queue.replace(replacement)
        // After replace, pending should only reflect the new (de-duped) set.
        // In-flight may still be a leftover from the original; bound depth.
        let postDepth = await queue.queueDepth
        #expect(postDepth <= replacement.count + 1)

        await queue.cancelAll()
    }

    @Test("maxQueuedItems caps the pending list")
    func capRespected() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrefetchTest-\(UUID().uuidString)", isDirectory: true)
        let cache = try TTSAudioCache(directoryURL: cacheDir)
        let synth = TTSSpeechSynthesizer()
        let queue = TTSPrefetchQueue(
            synthesizer: synth,
            cache: cache,
            policy: .init(thermalCutoff: .critical, pauseOnLowPowerMode: false, maxQueuedItems: 3)
        )

        let model = TTSMLX.supportedModels[0]
        let requests = (0..<10).map {
            TTSPrefetchRequest(text: "item-\($0)", model: model)
        }

        await queue.enqueue(requests)
        // The drain task will be picking items off the front, so we observe
        // the cap by checking that depth never exceeded 3 + 1 (in-flight).
        #expect(await queue.queueDepth <= 4)

        await queue.cancelAll()
    }
}

// MARK: - Helpers

private func writeFakeWAV(to url: URL, payloadSize: Int = 128) throws {
    let sampleRate: UInt32 = 22_050
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = UInt32(payloadSize)
    let chunkSize = 36 + dataSize

    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.append(le32(chunkSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.append(le32(16))
    data.append(le16(1))
    data.append(le16(channels))
    data.append(le32(sampleRate))
    data.append(le32(byteRate))
    data.append(le16(blockAlign))
    data.append(le16(bitsPerSample))
    data.append(contentsOf: Array("data".utf8))
    data.append(le32(dataSize))
    data.append(Data(repeating: 0, count: Int(dataSize)))

    try data.write(to: url)
}

private func le32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func le16(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}
