import AVFoundation
import Foundation
import MLXAudioCore
import Testing
@testable import TTSMLX

@Suite("TTSChunkJoin")
struct TTSChunkJoinTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private func tone(frames: Int, value: Float = 1) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(repeating: value, count: frames)
        return buffer
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test("pause lengths follow the boundary kind")
    func pauses() {
        let join = TTSChunkJoin.natural
        #expect(join.pause(after: .paragraph) == 0.45)
        #expect(join.pause(after: .sentence) == 0.25)
        #expect(join.pause(after: .clause) == 0.12)
        #expect(join.pause(after: .open) == 0)
        for kind in TTSChunkBoundary.allCases {
            #expect(TTSChunkJoin.none.pause(after: kind) == 0)
        }
        #expect(TTSChunkJoin.none.edgeFade == 0)
        #expect(TTSSynthesisOptions().chunkJoin == .natural)
        // Negative values are clamped, never honoured.
        #expect(TTSChunkJoin(sentencePause: -1).sentencePause == 0)
    }

    @Test("shaper preserves every frame and fades only the edges")
    func shaperPreservesFramesAndFadesEdges() {
        var shaper = TTSChunkEdgeShaper(fadeFrames: 10)
        var out: [AVAudioPCMBuffer] = []
        for frames in [100, 7, 50] {
            if let b = shaper.push(tone(frames: frames)) { out.append(b) }
        }
        if let tail = shaper.finish() { out.append(tail) }

        let all = out.flatMap(samples)
        #expect(all.count == 157)
        // Fade-in: strictly rising from silence over the first 10 frames, then flat.
        #expect(all[0] == 0)
        #expect(all[5] > 0 && all[5] < 1)
        #expect(all[10] == 1)
        #expect(all[80] == 1)
        // Fade-out: last 10 frames fall to (near) silence.
        #expect(all[146] == 1)
        #expect(all[all.count - 1] < 0.03)
        #expect(all[all.count - 5] > 0 && all[all.count - 5] < 1)
        // Only the fade length is ever held back: the first push yields 90 of 100 frames.
        #expect(out.first!.frameLength == 90)
    }

    @Test("chunks shorter than one fade are ramped both ways")
    func tinyChunk() {
        var shaper = TTSChunkEdgeShaper(fadeFrames: 100)
        #expect(shaper.push(tone(frames: 30)) == nil)
        let tail = shaper.finish()!
        let s = samples(tail)
        #expect(s.count == 30)
        #expect(s[0] == 0)
        #expect(s[15] > 0.2 && s[15] < 0.5) // both ramps overlap mid-way
        #expect(s[29] < 0.1)
        #expect(shaper.finish() == nil)
    }

    @Test("a zero fade passes buffers through untouched")
    func zeroFadeIsPassThrough() {
        var shaper = TTSChunkEdgeShaper(fadeFrames: 0)
        let input = tone(frames: 40)
        let out = shaper.push(input)
        #expect(out === input)
        #expect(shaper.finish() == nil)
    }

    @Test("silence buffers are zero-filled at the requested length")
    func silence() {
        let buffer = TTSChunkEdgeShaper.silence(format: format, frames: 2400)!
        #expect(buffer.frameLength == 2400)
        #expect(samples(buffer).allSatisfy { $0 == 0 })
        #expect(TTSChunkEdgeShaper.silence(format: format, frames: 0) == nil)
        #expect(TTSAudioBufferChunk(buffer: buffer, sampleRate: 24_000, isPadding: true).isPadding)
        #expect(!TTSAudioBufferChunk(buffer: buffer, sampleRate: 24_000).isPadding)
    }

    @Test("profiles no longer override the model's sampling settings")
    func profilesRespectModelSampling() {
        var params = GenerateParameters(maxTokens: 1200, temperature: 0.6, topP: 0.8, repetitionPenalty: 1.3)
        TTSGenerationProfile.balanced.apply(to: &params)
        #expect(params.temperature == 0.6)
        #expect(params.topP == 0.8)
        #expect(params.maxTokens == 1200)
        TTSGenerationProfile.fast.apply(to: &params)
        #expect(params.maxTokens == 1200)
        TTSGenerationProfile.highQuality.apply(to: &params)
        #expect(params.temperature == 0.6)
        #expect(params.topP == 0.8)
        #expect(params.maxTokens == 2048)
        var big = GenerateParameters(maxTokens: 4096, temperature: 0.9)
        TTSGenerationProfile.highQuality.apply(to: &big)
        #expect(big.maxTokens == 4096)
    }
}
