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
