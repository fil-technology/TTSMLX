import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

#if canImport(AVFoundation)
extension TTSPreparedNarration {
    /// Result of a recompression pass: the on-disk byte totals of the chunk
    /// audio *before* and *after* transcoding. `before - after` is the space
    /// reclaimed. When the bundle is already in the target codec both totals
    /// are equal (a no-op).
    public typealias RecompressionResult = (before: Int64, after: Int64)

    /// Transcode every chunk of the bundle at `url` to `codec` in place,
    /// rewriting the manifest to point at the new files and deleting the
    /// superseded originals.
    ///
    /// Handles both layouts:
    /// - Sub-bundle bundles (`voices/<slug>/…`, what the runtime cache and
    ///   `prepareNarration` produce) — every voice/language variant is
    ///   recompressed.
    /// - Legacy root-level bundles (`manifest.json` + `chunks/` at the bundle
    ///   root) — recompressed directly.
    ///
    /// Idempotent: a bundle already stored in `codec` is left untouched and
    /// reports equal before/after totals. Word timings and per-chunk durations
    /// are preserved exactly — they live in the manifest and are never
    /// re-derived from the audio — so highlighting stays aligned across the
    /// switch.
    ///
    /// This path is MLX-free: it decodes existing audio and re-encodes it, so a
    /// host can reclaim space on an already-generated library without loading a
    /// model.
    @discardableResult
    public static func recompress(
        bundleAt url: URL,
        to codec: TTSAudioCodec,
        fileManager: FileManager = .default
    ) async throws -> RecompressionResult {
        var before: Int64 = 0
        var after: Int64 = 0

        for directory in subBundleDirectories(in: url, fileManager: fileManager) {
            let result = try recompressSubBundle(at: directory, to: codec, fileManager: fileManager)
            before += result.before
            after += result.after
        }
        return (before, after)
    }

    /// Directories that hold a `manifest.json` under `bundleURL`: each
    /// `voices/<slug>/` sub-bundle plus, for legacy bundles, the root itself.
    private static func subBundleDirectories(in bundleURL: URL, fileManager: FileManager) -> [URL] {
        var directories: [URL] = []
        let voicesDir = bundleURL.appendingPathComponent("voices", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: voicesDir.path, isDirectory: &isDir), isDir.boolValue,
           let subs = try? fileManager.contentsOfDirectory(
               at: voicesDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for sub in subs {
                var subIsDir: ObjCBool = false
                let manifest = sub.appendingPathComponent(manifestFilename, isDirectory: false)
                if fileManager.fileExists(atPath: sub.path, isDirectory: &subIsDir), subIsDir.boolValue,
                   fileManager.fileExists(atPath: manifest.path) {
                    directories.append(sub)
                }
            }
        }
        // Legacy root manifest (pre sub-bundle layout).
        if fileManager.fileExists(atPath: bundleURL.appendingPathComponent(manifestFilename, isDirectory: false).path) {
            directories.append(bundleURL)
        }
        return directories
    }

    /// Recompress a single sub-bundle directory (one that directly contains a
    /// `manifest.json` + `chunks/`).
    static func recompressSubBundle(
        at directory: URL,
        to codec: TTSAudioCodec,
        fileManager: FileManager
    ) throws -> RecompressionResult {
        let manifestURL = directory.appendingPathComponent(manifestFilename, isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else { return (0, 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(TTSPreparedNarrationManifest.self, from: data)

        let targetTag = codec.manifestTag
        let targetExt = codec.fileExtension
        var before: Int64 = 0
        var after: Int64 = 0
        var changed = false

        for index in manifest.chunks.indices {
            let entry = manifest.chunks[index]
            let oldURL = directory.appendingPathComponent(entry.audioFile, isDirectory: false)
            let oldSize = fileSize(oldURL, fileManager: fileManager)
            let currentExt = (entry.audioFile as NSString).pathExtension.lowercased()

            // Already in the target codec? Extension alone is ambiguous (AAC and
            // ALAC share `.m4a`), so also require the manifest to declare the
            // target tag. Count the existing bytes on both sides so an
            // idempotent re-run reports before == after.
            if currentExt == targetExt, manifest.codec == targetTag {
                before += oldSize
                after += oldSize
                continue
            }

            // Missing source — nothing to transcode; skip without counting.
            guard fileManager.fileExists(atPath: oldURL.path) else { continue }

            let source = try AVAudioFile(forReading: oldURL)
            let format = source.processingFormat
            let length = AVAudioFrameCount(source.length)
            guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
                // Unreadable/empty — leave it in place rather than dropping audio.
                before += oldSize
                after += oldSize
                continue
            }
            try source.read(into: buffer)

            let newFilename = String(format: "chunks/%03d.%@", entry.index, targetExt)
            let newURL = directory.appendingPathComponent(newFilename, isDirectory: false)
            try fileManager.createDirectory(
                at: newURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: newURL.path) {
                try fileManager.removeItem(at: newURL)
            }
            // Scope the writer so it flushes/finalizes (m4a moov atom) before we
            // measure the encoded size.
            var writer: AVAudioFile? = try TTSAudioEncoder.makeFile(at: newURL, codec: codec, sourceFormat: format)
            try TTSAudioEncoder.write(buffer, to: writer!)
            writer = nil

            before += oldSize
            after += fileSize(newURL, fileManager: fileManager)
            if newURL.path != oldURL.path {
                try? fileManager.removeItem(at: oldURL)
            }
            manifest.chunks[index].audioFile = newFilename
            changed = true
        }

        if manifest.codec != targetTag {
            manifest.codec = targetTag
            changed = true
        }
        if changed {
            try TTSPreparedNarration(manifest: manifest, baseURL: directory).writeManifest()
        }
        return (before, after)
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }
}
#endif
