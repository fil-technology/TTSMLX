import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

/// How generated narration audio is stored on disk.
///
/// Narration was historically written as uncompressed WAV, which dominates
/// on-disk usage for a library of pre-generated books. Encoding to AAC-LC
/// shrinks each chunk by roughly 8–16× with no change to the playback path —
/// `AVAudioFile(forReading:)` decodes AAC (and Apple Lossless) transparently,
/// so nothing downstream has to know the chunk was compressed.
///
/// The choice is per-synthesis (see ``TTSSynthesisOptions/audioCodec``) so a
/// host can keep WAV as the default and opt individual generations into
/// compression, or offer the user a quality setting. Timing/highlight data is
/// codec-independent — word offsets are measured from the PCM frame count
/// *before* encoding and stored in the manifest, so switching codec never
/// moves a highlight.
public enum TTSAudioCodec: Sendable, Hashable, Codable {
    /// Uncompressed linear PCM in a WAV container. The historical default;
    /// largest on disk, zero decode cost.
    case wav
    /// AAC-LC in an `.m4a` container at `bitrate` bits/second. 24–48 kbps mono
    /// is ample for speech; the default is 32 kbps. Lossy but transparent for
    /// narration, ~8–16× smaller than 24 kHz/16-bit WAV.
    case aacLC(bitrate: Int)
    /// Apple Lossless in an `.m4a` container. Bit-exact, ~2× smaller than WAV;
    /// use when fidelity must be preserved exactly.
    case appleLossless

    /// A sensible AAC bitrate for speech (32 kbps mono).
    public static let defaultAACBitrate = 32_000

    /// Convenience for the recommended speech default.
    public static let aacLCDefault = TTSAudioCodec.aacLC(bitrate: defaultAACBitrate)

    /// File extension for chunks written with this codec (no leading dot).
    public var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aacLC: return "m4a"
        case .appleLossless: return "m4a"
        }
    }

    /// Stable, human-readable tag recorded in the manifest's `codec` field.
    /// Distinguishes AAC from ALAC (both use the `.m4a` extension) and records
    /// the bitrate for diagnostics. `nil` in a manifest means legacy WAV.
    public var manifestTag: String {
        switch self {
        case .wav: return "wav"
        case let .aacLC(bitrate): return "aac-lc@\(bitrate)"
        case .appleLossless: return "alac"
        }
    }
}

#if canImport(AVFoundation)
/// Internal helper that turns a stream of PCM buffers into an on-disk audio
/// file in a chosen ``TTSAudioCodec``. Centralizes the `AVAudioFile` creation
/// (WAV vs AAC vs ALAC settings) and the buffer-format bridging so every write
/// site — live generation, author-time baking, and migration — encodes the
/// same way.
enum TTSAudioEncoder {
    enum EncodeError: Error {
        case converterUnavailable(from: AVAudioFormat, to: AVAudioFormat)
        case bufferAllocationFailed
    }

    /// Create an `AVAudioFile` for writing `codec`, deriving the file settings
    /// from a PCM `sourceFormat` (the format the MLX model produces). The
    /// returned file's `processingFormat` is what ``write(_:to:)`` expects; for
    /// compressed codecs AVFoundation deduces a standard float PCM processing
    /// format that matches the model's mono float32 output, so no conversion is
    /// usually needed.
    ///
    /// The URL's path extension must already match `codec.fileExtension` — for
    /// compressed codecs AVFoundation infers the container from the extension,
    /// so an `.m4a` path is required for AAC/ALAC.
    static func makeFile(at url: URL, codec: TTSAudioCodec, sourceFormat: AVAudioFormat) throws -> AVAudioFile {
        switch codec {
        case .wav:
            // Preserve the exact PCM layout the model produced.
            return try AVAudioFile(
                forWriting: url,
                settings: sourceFormat.settings,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
        case let .aacLC(bitrate):
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
                AVEncoderBitRateKey: bitrate
            ]
            return try AVAudioFile(forWriting: url, settings: settings)
        case .appleLossless:
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: Int(sourceFormat.channelCount)
            ]
            return try AVAudioFile(forWriting: url, settings: settings)
        }
    }

    /// Write one PCM buffer to `file`, converting to the file's processing
    /// format only when the buffer format differs (e.g. interleave flag).
    static func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        if buffer.format == file.processingFormat {
            try file.write(from: buffer)
        } else {
            try file.write(from: convert(buffer, to: file.processingFormat))
        }
    }

    /// Convert a PCM buffer to `format`. Used as a safety net when a source
    /// buffer's format doesn't exactly equal an `AVAudioFile`'s processing
    /// format; a no-op fast path returns the buffer unchanged when formats
    /// already match.
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw EncodeError.converterUnavailable(from: buffer.format, to: format)
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw EncodeError.bufferAllocationFailed
        }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }
}
#endif
