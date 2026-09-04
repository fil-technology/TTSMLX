import AVFoundation
import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSStreamGranularity")
struct TTSStreamGranularityTests {
    @Test("granularity decides which chunks are yielded whole")
    func yieldPolicy() {
        #expect(!TTSStreamGranularity.buffer.yieldsWholeChunk(at: 0))
        #expect(!TTSStreamGranularity.buffer.yieldsWholeChunk(at: 3))
        #expect(TTSStreamGranularity.chunk.yieldsWholeChunk(at: 0))
        #expect(!TTSStreamGranularity.chunkAfterFirst.yieldsWholeChunk(at: 0))
        #expect(TTSStreamGranularity.chunkAfterFirst.yieldsWholeChunk(at: 1))
    }

    @Test("concatenate joins float buffers sample-for-sample")
    func concatenateBuffers() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        func make(_ values: [Float]) -> TTSAudioBufferChunk {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
            buffer.frameLength = AVAudioFrameCount(values.count)
            for (i, v) in values.enumerated() { buffer.floatChannelData![0][i] = v }
            return TTSAudioBufferChunk(buffer: buffer, sampleRate: 24_000)
        }
        let joined = try #require(TTSSpeechSynthesizer.concatenate([make([1, 2, 3]), make([4]), make([5, 6])]))
        #expect(joined.count == 1)
        let out = joined[0].buffer
        #expect(out.frameLength == 6)
        let samples = (0..<6).map { out.floatChannelData![0][$0] }
        #expect(samples == [1, 2, 3, 4, 5, 6])
        #expect(joined[0].sampleRate == 24_000)
    }

    @Test("concatenate refuses mixed formats")
    func mixedFormats() throws {
        let a = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let b = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let ba = AVAudioPCMBuffer(pcmFormat: a, frameCapacity: 4)!; ba.frameLength = 4
        let bb = AVAudioPCMBuffer(pcmFormat: b, frameCapacity: 4)!; bb.frameLength = 4
        #expect(TTSSpeechSynthesizer.concatenate([
            TTSAudioBufferChunk(buffer: ba, sampleRate: 24_000),
            TTSAudioBufferChunk(buffer: bb, sampleRate: 16_000)
        ]) == nil)
    }
}
