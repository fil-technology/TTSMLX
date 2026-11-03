import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

/// What kind of break follows a chunk in the source text. Drives the pause
/// the synthesizer inserts after the chunk's audio so sentences and
/// paragraphs are audibly separated instead of running together.
public enum TTSChunkBoundary: String, Sendable, Hashable, Codable, CaseIterable {
    /// A blank line or newline follows the chunk.
    case paragraph
    /// The chunk ends in `.`, `!`, `?` or `…` (closing quotes/brackets allowed).
    case sentence
    /// The chunk ends in `,`, `;` or `:`.
    case clause
    /// The chunk was cut mid-phrase (a long clause split on whitespace).
    case open

    static let sentenceMarks: Set<Character> = [".", "!", "?", "…"]
    static let clauseMarks: Set<Character> = [",", ";", ":"]
    /// Characters that may trail a punctuation mark and still belong to the
    /// same boundary: closing quotes and brackets.
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

    /// Classifies free text by its last meaningful character. Trailing
    /// whitespace and closing quotes/brackets are ignored.
    public static func infer(from text: String) -> TTSChunkBoundary {
        var characters = Substring(text)
        while let last = characters.last, last.isWhitespace || closers.contains(last) {
            characters = characters.dropLast()
        }
        guard let last = characters.last else { return .open }
        if sentenceMarks.contains(last) { return .sentence }
        if clauseMarks.contains(last) { return .clause }
        return .open
    }
}

/// How consecutive chunks are stitched into one continuous narration.
///
/// Each chunk is generated independently, so without help the audio runs
/// straight from one chunk into the next with no breath and a hard edge at
/// the seam. ``natural`` (the default) inserts a short pause scaled to the
/// kind of boundary the chunk ended on and applies a few milliseconds of
/// fade at both edges so the seams are click-free. ``none`` restores the
/// pre-0.9 behavior: raw buffers, no pause.
///
/// Inserted silence is yielded as its own ``TTSAudioBufferChunk`` with
/// ``TTSAudioBufferChunk/isPadding`` set, so word timings stay anchored to
/// speech while playback timelines and cached chunk files include the pause.
public struct TTSChunkJoin: Sendable, Hashable {
    /// Silence appended after a chunk that ends a paragraph.
    public var paragraphPause: TimeInterval
    /// Silence appended after a chunk that ends a sentence.
    public var sentencePause: TimeInterval
    /// Silence appended after a chunk that ends on clause punctuation.
    public var clausePause: TimeInterval
    /// Raised-cosine fade applied to the first and last `edgeFade` seconds of
    /// every chunk. Removes clicks at seams; inaudible as a fade.
    public var edgeFade: TimeInterval

    public init(
        paragraphPause: TimeInterval = 0.45,
        sentencePause: TimeInterval = 0.25,
        clausePause: TimeInterval = 0.12,
        edgeFade: TimeInterval = 0.008
    ) {
        self.paragraphPause = max(0, paragraphPause)
        self.sentencePause = max(0, sentencePause)
        self.clausePause = max(0, clausePause)
        self.edgeFade = max(0, edgeFade)
    }

    /// Breath-like pauses between sentences and paragraphs, click-free seams.
    public static let natural = TTSChunkJoin()
    /// No inserted silence and no edge fades (behavior before 0.9.0).
    public static let none = TTSChunkJoin(paragraphPause: 0, sentencePause: 0, clausePause: 0, edgeFade: 0)

    /// Seconds of silence to append after a chunk ending on `boundary`.
    public func pause(after boundary: TTSChunkBoundary) -> TimeInterval {
        switch boundary {
        case .paragraph: paragraphPause
        case .sentence: sentencePause
        case .clause: clausePause
        case .open: 0
        }
    }
}

#if canImport(AVFoundation)
/// Applies ``TTSChunkJoin/edgeFade`` to a stream of PCM buffers without
/// delaying them by more than the fade length.
///
/// The fade-in is applied to the first frames yielded. The fade-out needs the
/// *last* frames, which are not known until the stream ends, so the shaper
/// holds back only the final `fadeFrames` of whatever it has seen so far and
/// prepends that tail to the next buffer. Time-to-first-audio therefore grows
/// by the fade length (8 ms by default), not by a whole streaming interval.
///
/// Only float32 PCM is shaped; any other format passes through untouched.
struct TTSChunkEdgeShaper {
    let fadeFrames: Int
    private var carry: AVAudioPCMBuffer?
    private var fadedIn = false

    init(fadeFrames: Int) {
        self.fadeFrames = max(0, fadeFrames)
    }

    /// Feeds one upstream buffer. Returns the buffer to yield now, or `nil`
    /// while the shaper is still accumulating a tail.
    mutating func push(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard fadeFrames > 0, Self.isShapeable(buffer) else {
            // Pass-through. Flush any tail first so order is preserved.
            if let pending = carry {
                carry = nil
                return Self.join(pending, buffer) ?? buffer
            }
            return buffer
        }

        let combined: AVAudioPCMBuffer
        if let pending = carry {
            guard let joined = Self.join(pending, buffer) else { carry = nil; return buffer }
            combined = joined
        } else {
            combined = buffer
        }
        carry = nil

        let total = Int(combined.frameLength)
        guard total > fadeFrames else {
            carry = combined
            return nil
        }

        let head = Self.copy(combined, frames: 0..<(total - fadeFrames))
        carry = Self.copy(combined, frames: (total - fadeFrames)..<total)
        guard let head else { return combined }
        if !fadedIn {
            Self.applyFade(to: head, rampIn: true, frames: fadeFrames)
            fadedIn = true
        }
        return head
    }

    /// Flushes the held tail with the fade-out applied. Call once after the
    /// upstream stream finishes.
    mutating func finish() -> AVAudioPCMBuffer? {
        guard let tail = carry else { return nil }
        carry = nil
        guard fadeFrames > 0, Self.isShapeable(tail) else { return tail }
        if !fadedIn {
            // The whole chunk was shorter than one fade: ramp both ways.
            Self.applyFade(to: tail, rampIn: true, frames: fadeFrames)
            fadedIn = true
        }
        Self.applyFade(to: tail, rampIn: false, frames: fadeFrames)
        return tail
    }

    // MARK: - Buffer helpers

    static func isShapeable(_ buffer: AVAudioPCMBuffer) -> Bool {
        buffer.format.commonFormat == .pcmFormatFloat32 && buffer.floatChannelData != nil
    }

    static func silence(format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData {
            let channels = Int(format.channelCount)
            if format.isInterleaved {
                data[0].update(repeating: 0, count: frames * channels)
            } else {
                for channel in 0..<channels { data[channel].update(repeating: 0, count: frames) }
            }
        } else if let data = buffer.int16ChannelData {
            let channels = Int(format.channelCount)
            if format.isInterleaved {
                data[0].update(repeating: 0, count: frames * channels)
            } else {
                for channel in 0..<channels { data[channel].update(repeating: 0, count: frames) }
            }
        }
        return buffer
    }

    /// Copies `frames` of `source` into a fresh buffer of the same format.
    static func copy(_ source: AVAudioPCMBuffer, frames range: Range<Int>) -> AVAudioPCMBuffer? {
        let count = range.count
        guard count > 0,
              range.upperBound <= Int(source.frameLength),
              let data = source.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
              let dest = out.floatChannelData
        else { return nil }
        let channels = Int(source.format.channelCount)
        if source.format.isInterleaved {
            dest[0].update(from: data[0].advanced(by: range.lowerBound * channels), count: count * channels)
        } else {
            for channel in 0..<channels {
                dest[channel].update(from: data[channel].advanced(by: range.lowerBound), count: count)
            }
        }
        out.frameLength = AVAudioFrameCount(count)
        return out
    }

    static func join(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard a.format == b.format,
              let da = a.floatChannelData, let db = b.floatChannelData else { return nil }
        let fa = Int(a.frameLength), fb = Int(b.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: AVAudioFrameCount(fa + fb)),
              let dest = out.floatChannelData else { return nil }
        let channels = Int(a.format.channelCount)
        if a.format.isInterleaved {
            dest[0].update(from: da[0], count: fa * channels)
            dest[0].advanced(by: fa * channels).update(from: db[0], count: fb * channels)
        } else {
            for channel in 0..<channels {
                dest[channel].update(from: da[channel], count: fa)
                dest[channel].advanced(by: fa).update(from: db[channel], count: fb)
            }
        }
        out.frameLength = AVAudioFrameCount(fa + fb)
        return out
    }

    /// Raised-cosine ramp over the first (`rampIn`) or last `frames` of the
    /// buffer, bounded by the buffer length.
    static func applyFade(to buffer: AVAudioPCMBuffer, rampIn: Bool, frames: Int) {
        guard let data = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        let n = min(frames, length)
        guard n > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        for k in 0..<n {
            // 0 → 1 over n frames (half-Hann); mirrored for the ramp-out.
            let phase = Double(k) / Double(n)
            let gainIn = Float(0.5 - 0.5 * cos(Double.pi * phase))
            let gain = rampIn ? gainIn : 1 - gainIn
            let frame = rampIn ? k : length - n + k
            if interleaved {
                for channel in 0..<channels { data[0][frame * channels + channel] *= gain }
            } else {
                for channel in 0..<channels { data[channel][frame] *= gain }
            }
        }
    }
}
#endif
