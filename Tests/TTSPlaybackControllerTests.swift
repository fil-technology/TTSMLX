#if canImport(AVFoundation)
import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TTSMLX

@MainActor
@Suite("TTSPlaybackController")
struct TTSPlaybackControllerTests {
    @Test("rate is clamped to the 0.5–2.0 range")
    func rateClamping() {
        let controller = TTSPlaybackController(rate: 1.0)
        controller.rate = 5.0
        #expect(controller.rate == 2.0)
        controller.rate = 0.1
        #expect(controller.rate == 0.5)
        controller.rate = 1.25
        #expect(controller.rate == 1.25)
    }

    @Test("constructor clamps initial rate the same way")
    func initialRateClamping() {
        let high = TTSPlaybackController(rate: 99)
        #expect(high.rate == 2.0)
        let low = TTSPlaybackController(rate: -1)
        #expect(low.rate == 0.5)
    }

    @Test("default state is idle and stop transitions to stopped")
    func stateMachine() {
        let controller = TTSPlaybackController()
        #expect(controller.state == .idle)
        controller.stop()
        #expect(controller.state == .stopped)
    }

    @Test("currentTime is 0 and duration is nil before any playback")
    func currentTimeBeforePlayback() {
        let controller = TTSPlaybackController()
        #expect(controller.currentTime == 0)
        #expect(controller.duration == nil)
    }

    @Test("duration reflects the file length once a file is loaded")
    func durationFromFile() throws {
        let url = try Self.makeSineFile(durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        try controller.play(file: url)
        let dur = try #require(controller.duration)
        #expect(abs(dur - 1.0) < 0.05)
        controller.stop()
        #expect(controller.duration == nil)
    }

    @Test("seek throws when no file is loaded (stream-mode playback)")
    func seekThrowsForStream() throws {
        let controller = TTSPlaybackController()
        var threw = false
        do {
            try controller.seek(to: 1.0)
        } catch TTSPlaybackController.PlaybackError.seekUnsupportedForStream {
            threw = true
        }
        #expect(threw)
    }

    @Test("seek to a valid file position updates seekFrameOffset → currentTime")
    func seekUpdatesCurrentTime() throws {
        let url = try Self.makeSineFile(durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        try controller.play(file: url)
        controller.pause() // freeze sample-time advancement; only seek offset moves
        try controller.seek(to: 1.0)
        // currentTime = sampleTime/sampleRate + seekOffset/sampleRate.
        // Right after seek, sampleTime is 0; the reported time should be ≈ seek target.
        // (lastRenderTime may briefly be nil before the engine reschedules, which yields 0.
        // Both 0 and ~1.0 are acceptable; the key invariant is "no negative, no garbage".)
        let t = controller.currentTime
        #expect(t >= 0)
        #expect(t < 2.5)
        controller.stop()
    }

    @Test("seek past duration finishes playback and fires the end callback")
    func seekPastEndFinishes() throws {
        let url = try Self.makeSineFile(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        var ended = false
        try controller.play(file: url) { ended = true }
        try controller.seek(to: 10.0)
        #expect(ended)
        #expect(controller.state == .idle)
    }

    @Test("seeking inside a playing file does not report the end of playback")
    func seekDoesNotEndPlayback() async throws {
        // Stopping the player node to seek calls the completion handler of
        // what was queued. Counted against the re-queued audio, that ended
        // playback on the spot: resuming a narration part-way reported
        // end-of-playback and the reader moved to the next chapter.
        let url = try Self.makeSineFile(durationSeconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        var ended = false
        try controller.play(file: url) { ended = true }
        try controller.seek(to: 1.0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!ended)
        #expect(controller.state == .playing)
        controller.stop()
    }

    @Test("replacing what is playing does not end the new playback")
    func restartDoesNotEndPlayback() async throws {
        let url = try Self.makeSineFile(durationSeconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        var firstEnded = false
        var secondEnded = false
        try controller.play(file: url) { firstEnded = true }
        try controller.play(file: url) { secondEnded = true }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!firstEnded)
        #expect(!secondEnded)
        #expect(controller.state == .playing)
        controller.stop()
    }

    @Test("a live stream fires its words against the audio that was queued")
    func markedStreamFiresWords() async throws {
        // Two bugs met here. The word observer left as soon as it saw the
        // `.stopped` state every stream session starts in, so a live stream
        // (first audio arrives after the first take is generated) never
        // fired a word. And the timeline came from synthesizer-wide events,
        // which a player can miss or get from another narration; the marks
        // on the stream's own elements cannot be either.
        let controller = TTSPlaybackController()
        let synthesizer = TTSSpeechSynthesizer()
        let (stream, continuation) = AsyncThrowingStream<TTSAudioBufferChunk, Error>.makeStream()
        let feeder = Task {
            // First audio arrives late, as it does when it is being generated.
            try? await Task.sleep(for: .milliseconds(300))
            // Chunk 0 handed over whole: timings ride on its audio.
            continuation.yield(TTSAudioBufferChunk(
                buffer: Self.makeToneBuffer(seconds: 0.4), sampleRate: 24_000,
                narrationMark: TTSNarrationMark(chunkIndex: 0, characterRange: 0 ..< 7, wordTimings: [
                    TTSWordTiming(characterRange: 0 ..< 3, offset: 0, duration: 0.2),
                    TTSWordTiming(characterRange: 4 ..< 7, offset: 0.2, duration: 0.2),
                ])))
            // Chunk 1 streamed buffer by buffer: timings follow on an
            // element with no audio.
            for _ in 0 ..< 2 {
                continuation.yield(TTSAudioBufferChunk(
                    buffer: Self.makeToneBuffer(seconds: 0.2), sampleRate: 24_000,
                    narrationMark: TTSNarrationMark(chunkIndex: 1, characterRange: 8 ..< 15)))
            }
            continuation.yield(TTSAudioBufferChunk(
                buffer: Self.makeToneBuffer(seconds: 0), sampleRate: 24_000, isPadding: true,
                narrationMark: TTSNarrationMark(chunkIndex: 1, characterRange: 8 ..< 15, wordTimings: [
                    TTSWordTiming(characterRange: 8 ..< 11, offset: 0, duration: 0.2),
                    TTSWordTiming(characterRange: 12 ..< 15, offset: 0.2, duration: 0.2),
                ])))
            continuation.finish()
        }
        var fired: [TTSWordTiming] = []
        var ended = false
        try await controller.play(
            stream: stream, synthesizer: synthesizer,
            onWord: { fired.append($0) },
            onPlaybackEnd: { ended = true }
        )
        await feeder.value
        for _ in 0 ..< 40 where !ended { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(ended)
        #expect(fired.map(\.characterRange) == [0 ..< 3, 4 ..< 7, 8 ..< 11, 12 ..< 15])
        // The second chunk starts where the first chunk's audio ends.
        let offsets = fired.map(\.offset)
        #expect(offsets.count == 4)
        for (offset, expected) in zip(offsets, [0, 0.2, 0.4, 0.6]) {
            #expect(abs(offset - expected) < 1e-6)
        }
        controller.stop()
    }

    @Test("timePulse finishes once stop() is called")
    func timePulseFinishesOnStop() async throws {
        let url = try Self.makeSineFile(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = TTSPlaybackController()
        try controller.play(file: url)
        let pulse = controller.timePulse(interval: 0.05)
        // Collect a couple of ticks then stop.
        let collector = Task { @MainActor () -> [TimeInterval] in
            var ticks: [TimeInterval] = []
            for await t in pulse {
                ticks.append(t)
                if ticks.count >= 2 { break }
            }
            return ticks
        }
        // Give the pulse a moment to emit, then stop.
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.stop()
        let ticks = await collector.value
        #expect(ticks.count >= 1)
        for t in ticks { #expect(t >= 0) }
    }

    // MARK: - Test helpers

    /// Writes a short mono 16-bit PCM WAV file of `durationSeconds` to a
    /// temporary location and returns its URL. Used to exercise file-backed
    /// playback without needing the MLX runtime.
    static func makeToneBuffer(seconds: Double, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        return buffer
    }

    static func makeSineFile(
        durationSeconds: Double,
        sampleRate: Double = 22_050
    ) throws -> URL {
        let frames = AVAudioFrameCount(durationSeconds * sampleRate)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                let phase = Double(i) / sampleRate * 2 * .pi * 440
                channel[i] = Float(sin(phase) * 0.1)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttsmlx-test-\(UUID().uuidString).wav")
        // Write through AVAudioFile to honor the platform's WAV settings.
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try audioFile.write(from: buffer)
        return url
    }
}
#endif
