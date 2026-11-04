import AVFoundation
import Foundation

/// Levels and silences of a generated take, so a host can normalise, trim or
/// place it without decoding the file again.
public struct TTSAudioAnalysis: Sendable, Hashable, Codable {
    public let duration: TimeInterval
    /// Absolute sample peak, 0...1.
    public let peak: Float
    public let peakDBFS: Float
    /// Un-weighted RMS level of the whole take in dBFS. Close to integrated
    /// loudness for speech but not a K-weighted LUFS measurement.
    public let rmsDBFS: Float
    /// Seconds below `silenceThresholdDBFS` at the start and at the end.
    public let leadingSilence: TimeInterval
    public let trailingSilence: TimeInterval

    public static let silenceThresholdDBFS: Float = -50

    public static func analyze(samples: [Float], sampleRate: Int) -> TTSAudioAnalysis {
        let rate = Double(max(sampleRate, 1))
        guard !samples.isEmpty else {
            return TTSAudioAnalysis(duration: 0, peak: 0, peakDBFS: -.infinity, rmsDBFS: -.infinity, leadingSilence: 0, trailingSilence: 0)
        }
        let threshold = powf(10, silenceThresholdDBFS / 20)
        var peak: Float = 0, sumSquares: Double = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = Float((sumSquares / Double(samples.count)).squareRoot())
        var lead = 0
        while lead < samples.count, abs(samples[lead]) < threshold { lead += 1 }
        var trail = 0
        while trail < samples.count - lead, abs(samples[samples.count - 1 - trail]) < threshold { trail += 1 }
        func dbfs(_ value: Float) -> Float { value > 0 ? 20 * log10(value) : -.infinity }
        return TTSAudioAnalysis(
            duration: Double(samples.count) / rate, peak: peak, peakDBFS: dbfs(peak), rmsDBFS: dbfs(rms),
            leadingSilence: Double(lead) / rate, trailingSilence: Double(trail) / rate)
    }
}

/// `[pause 0.8s]` / `[pause 800ms]` markers: a silence of that length inserted
/// at that point of the take. Handled by TTSMLX for every model, in
/// `synthesize`, `synthesizeAudio` and `synthesizeSegments`; the streaming
/// APIs leave the text untouched.
public enum TTSPauseTag {
    public struct Part: Sendable, Hashable {
        public let text: String
        public let pauseAfter: TimeInterval
    }

    public static func marker(_ seconds: TimeInterval) -> String {
        String(format: "[pause %.2fs]", seconds)
    }

    static let pattern = try! NSRegularExpression(pattern: #"\[pause\s+([0-9]*\.?[0-9]+)\s*(ms|s)?\s*\]"#, options: .caseInsensitive)

    public static func contains(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Splits `text` at its markers. Each part's `pauseAfter` is the marker
    /// that followed it (0 for the last part); consecutive markers add up.
    public static func split(_ text: String) -> [Part] {
        let ns = text as NSString
        var parts: [Part] = []
        var cursor = 0
        var pendingText = ""
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pendingText += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let number = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let unit = match.range(at: 2).location == NSNotFound ? "s" : ns.substring(with: match.range(at: 2)).lowercased()
            let seconds = unit == "ms" ? number / 1000 : number
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, var last = parts.popLast() {
                last = Part(text: last.text, pauseAfter: last.pauseAfter + seconds)
                parts.append(last)
            } else {
                parts.append(Part(text: trimmed, pauseAfter: seconds))
            }
            pendingText = ""
            cursor = match.range.location + match.range.length
        }
        pendingText += ns.substring(from: cursor)
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || parts.isEmpty { parts.append(Part(text: trimmed, pauseAfter: 0)) }
        return parts
    }
}

enum TTSAudioProcessing {
    static func silence(_ seconds: TimeInterval, sampleRate: Int) -> [Float] {
        [Float](repeating: 0, count: max(0, Int(seconds * Double(sampleRate))))
    }

    /// Changes speaking rate without changing pitch (offline AVAudioUnitTimePitch).
    /// `rate` 1.2 makes the take 1.2x faster. Clamped to 0.5...2.0.
    static func timeStretch(_ samples: [Float], sampleRate: Int, rate: Float) throws -> [Float] {
        let rate = min(2, max(0.5, rate))
        guard abs(rate - 1) > 0.005, samples.count > 0 else { return samples }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else { return samples }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = rate
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        let frames = AVAudioFrameCount(samples.count)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return samples }
        input.frameLength = frames
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        let expected = Int((Double(samples.count) / Double(rate)).rounded())
        var out: [Float] = []
        out.reserveCapacity(expected + 4096)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return samples }
        var idle = 0
        while out.count < expected, idle < 64 {
            let status = try engine.renderOffline(buffer.frameCapacity, to: buffer)
            switch status {
            case .success, .insufficientDataFromInputNode:
                let count = Int(buffer.frameLength)
                if count == 0 { idle += 1; continue }
                out.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
                if status == .insufficientDataFromInputNode { idle += 1 }
            case .cannotDoInCurrentContext:
                idle += 1
            case .error:
                throw TTSError.generationFailed(modelID: "time-stretch", underlying: NSError(domain: "TTSMLX.TimeStretch", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline rendering failed"]))
            @unknown default:
                idle += 1
            }
        }
        engine.stop()
        return Array(out.prefix(expected))
    }
}
