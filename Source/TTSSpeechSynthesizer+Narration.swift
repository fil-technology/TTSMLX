import AVFoundation
import Foundation
import MLXAudioCore

/// One generated take, in memory.
struct TTSTake: Sendable {
    var samples: [Float]
    var sampleRate: Int
    var generationDuration: TimeInterval
}

/// Where a segment of a continuous take starts and how long it lasts. Exact:
/// each segment is generated on its own and the take is assembled from them.
public struct TTSSegment: Sendable, Hashable, Codable {
    public let index: Int
    public let text: String
    public let start: TimeInterval
    public let duration: TimeInterval
    public var end: TimeInterval { start + duration }
}

/// Generated audio with its levels and, for `synthesizeSegments`, the
/// boundaries of every segment. Write it with `write(to:)` or play
/// `pcmBuffer` directly.
public struct TTSSynthesizedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let analysis: TTSAudioAnalysis
    public let segments: [TTSSegment]
    public let modelID: String
    /// Wall-clock time spent inside the runtime, summed over the parts.
    public let generationDuration: TimeInterval

    public var duration: TimeInterval { analysis.duration }

    public var pcmBuffer: AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress { buffer.floatChannelData![0].update(from: base, count: samples.count) }
        }
        return buffer
    }

    @discardableResult
    public func write(to url: URL) throws -> TTSAudioFile {
        let finalURL = url.pathExtension.lowercased() == "wav" ? url : url.appendingPathExtension("wav")
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioUtils.writeWavFile(samples: samples, sampleRate: Double(sampleRate), fileURL: finalURL)
        return TTSAudioFile(url: finalURL, modelID: modelID, language: nil, voice: nil, sampleRate: sampleRate)
    }
}

/// One segment of `synthesizeSegmentsStream`, delivered as soon as it is generated.
public struct TTSSegmentAudio: Sendable {
    public let segment: TTSSegment
    public let audio: TTSSynthesizedAudio
}

extension TTSSpeechSynthesizer {
    /// The full narration path for one piece of text: `[pause]` markers become
    /// silence, each spoken part is one runtime take, then `rate` /
    /// `targetDuration` are applied by time-stretching when the model has no
    /// native rate. Every file-producing API goes through here.
    func synthesizeNarration(
        _ text: String,
        using model: TTSModelDescriptor,
        options: TTSSynthesisOptions,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)?
    ) async throws -> TTSTake {
        let parts = TTSPauseTag.split(text)
        var samples: [Float] = []
        var sampleRate = model.capabilities.sampleRate ?? 24_000
        var generation: TimeInterval = 0
        var spoke = false
        for (index, part) in parts.enumerated() {
            if !part.text.isEmpty {
                let take = try await synthesizeTake(part.text, using: model, options: options, progressHandler: index == 0 ? progressHandler : nil)
                sampleRate = take.sampleRate
                generation += take.generationDuration
                samples += take.samples
                spoke = true
            }
            if part.pauseAfter > 0 {
                samples += TTSAudioProcessing.silence(part.pauseAfter, sampleRate: sampleRate)
            }
        }
        guard spoke else { throw TTSError.emptyText }
        samples = try Self.applyTiming(samples, sampleRate: sampleRate, options: options, model: model)
        if releasesRuntimeBuffersAfterEachRequest { releaseRuntimeBuffers() }
        return TTSTake(samples: samples, sampleRate: sampleRate, generationDuration: generation)
    }

    /// Time-stretches for `rate` / `speed` on models without a native rate and
    /// for `targetDuration` everywhere (the native rate is applied first by
    /// the model, so the fit is measured on its output).
    static func applyTiming(_ samples: [Float], sampleRate: Int, options: TTSSynthesisOptions, model: TTSModelDescriptor) throws -> [Float] {
        var samples = samples
        if !model.features.contains(.speed), let rate = options.effectiveRate, abs(rate - 1) > 0.005 {
            samples = try TTSAudioProcessing.timeStretch(samples, sampleRate: sampleRate, rate: rate)
        }
        if let target = options.targetDuration, target > 0, !samples.isEmpty {
            let current = Double(samples.count) / Double(sampleRate)
            samples = try TTSAudioProcessing.timeStretch(samples, sampleRate: sampleRate, rate: Float(current / target))
        }
        return samples
    }

    /// `synthesize` without the file: the take, its levels, in memory.
    public func synthesizeAudio(
        _ text: String,
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSSynthesizedAudio {
        let take = try await synthesizeNarration(text, using: model, options: options, progressHandler: progressHandler)
        return TTSSynthesizedAudio(
            samples: take.samples, sampleRate: take.sampleRate,
            analysis: .analyze(samples: take.samples, sampleRate: take.sampleRate),
            segments: [TTSSegment(index: 0, text: text, start: 0, duration: Double(take.samples.count) / Double(take.sampleRate))],
            modelID: model.id, generationDuration: take.generationDuration)
    }

    /// Several lines as one continuous take, with the exact start and
    /// duration of each. Segments are generated one by one with the same
    /// options (so a reference clip or built-in voice keeps the speaker
    /// consistent) and joined with `pauseBetween` seconds of silence
    /// (default: the options' sentence pause). `[pause]` markers inside a
    /// segment work too.
    public func synthesizeSegments(
        _ segments: [String],
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        pauseBetween: TimeInterval? = nil,
        progressHandler: (@MainActor @Sendable (TTSProgressUpdate) -> Void)? = nil
    ) async throws -> TTSSynthesizedAudio {
        var samples: [Float] = []
        var boundaries: [TTSSegment] = []
        var sampleRate = model.capabilities.sampleRate ?? 24_000
        var generation: TimeInterval = 0
        let gap = pauseBetween ?? options.chunkJoin.sentencePause
        for (index, text) in segments.enumerated() {
            let take = try await synthesizeNarration(text, using: model, options: options, progressHandler: index == 0 ? progressHandler : nil)
            sampleRate = take.sampleRate
            generation += take.generationDuration
            let start = Double(samples.count) / Double(sampleRate)
            samples += take.samples
            boundaries.append(TTSSegment(index: index, text: text, start: start, duration: Double(take.samples.count) / Double(sampleRate)))
            if index < segments.count - 1, gap > 0 {
                samples += TTSAudioProcessing.silence(gap, sampleRate: sampleRate)
            }
        }
        return TTSSynthesizedAudio(
            samples: samples, sampleRate: sampleRate,
            analysis: .analyze(samples: samples, sampleRate: sampleRate),
            segments: boundaries, modelID: model.id, generationDuration: generation)
    }

    /// `synthesizeSegments`, delivered segment by segment as each finishes so
    /// a host can place the first lines while later ones generate. The
    /// `segment.start` values assume the same `pauseBetween` gap as the
    /// non-streaming variant.
    public nonisolated func synthesizeSegmentsStream(
        _ segments: [String],
        using model: TTSModelDescriptor = TTSMLX.defaultModels[0],
        options: TTSSynthesisOptions = .init(),
        pauseBetween: TimeInterval? = nil
    ) -> AsyncThrowingStream<TTSSegmentAudio, Error> {
        let gap = pauseBetween ?? options.chunkJoin.sentencePause
        return AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: TimeInterval = 0
                do {
                    for (index, text) in segments.enumerated() {
                        try Task.checkCancellation()
                        let audio = try await self.synthesizeAudio(text, using: model, options: options)
                        let segment = TTSSegment(index: index, text: text, start: cursor, duration: audio.duration)
                        cursor += audio.duration + gap
                        continuation.yield(TTSSegmentAudio(segment: segment, audio: audio))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
