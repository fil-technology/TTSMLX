import Foundation
import CryptoKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// On-disk, content-addressable cache for generated audio files.
///
/// The cache keys are SHA-256 hashes of a payload that identifies the
/// generation inputs (model id, voice, text). Writes are atomic: the caller
/// receives a temporary URL via ``reserveWrite(forKey:fileExtension:)``,
/// writes the audio file there, and then asks ``finalize(_:)`` to move it
/// into its final location. Half-written files are never visible to readers.
public actor TTSAudioCache {
    /// Pair of URLs returned by ``reserveWrite(forKey:fileExtension:)``.
    /// Write to ``temporaryURL`` and then call ``TTSAudioCache/finalize(_:)``
    /// (or ``TTSAudioCache/discard(_:)`` to throw the write away).
    public struct WriteHandle: Sendable, Hashable {
        public let key: String
        public let finalURL: URL
        public let temporaryURL: URL
    }

    public let directoryURL: URL
    private let fileManager: FileManager

    // Includes compressed containers so cachedURL/candidateURLs/remove find
    // AAC and Apple Lossless entries. Size accounting and pruning glob the
    // whole directory, so they are already codec-agnostic.
    private static let supportedExtensions = ["wav", "caf", "m4a", "aac"]

    public init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Keying

    /// Builds a stable cache key from the standard `(modelID | voice | text)` payload.
    public nonisolated func key(
        modelID: String,
        voice: TTSVoice?,
        text: String
    ) -> String {
        Self.makeKey(payload: Self.standardPayload(modelID: modelID, voice: voice, text: text))
    }

    /// Builds a cache key from an arbitrary payload. Use this when the standard
    /// `(modelID | voice | text)` is not enough — for example when language or
    /// generation profile also affect the audio.
    public nonisolated func key(payload: String) -> String {
        Self.makeKey(payload: payload)
    }

    // MARK: - Lookup

    /// Returns the URL of a usable cached file for the key, or `nil` if none exists.
    /// "Usable" means the file exists, is non-empty, and (where AVFoundation is
    /// available) can be opened with ``AVAudioFile``.
    public func cachedURL(forKey key: String) -> URL? {
        candidateURLs(forKey: key).first(where: { isUsable(at: $0) })
    }

    public func contains(key: String) -> Bool {
        cachedURL(forKey: key) != nil
    }

    // MARK: - Write workflow

    /// Reserve a writer pair for the given key. The caller writes audio bytes
    /// to ``WriteHandle/temporaryURL`` and then calls ``finalize(_:)`` to
    /// promote it. The temporary file is unique per call, so concurrent writes
    /// to the same key do not corrupt each other.
    public func reserveWrite(forKey key: String, fileExtension: String = "wav") -> WriteHandle {
        let ext = fileExtension.lowercased()
        let finalURL = directoryURL
            .appendingPathComponent(key)
            .appendingPathExtension(ext)
        let temporaryURL = directoryURL
            .appendingPathComponent("\(key).\(UUID().uuidString)")
            .appendingPathExtension("\(ext).part")
        return WriteHandle(key: key, finalURL: finalURL, temporaryURL: temporaryURL)
    }

    /// Atomically move the temporary file into its final location and return
    /// the final URL. Removes any prior cache entry for the same final URL.
    @discardableResult
    public func finalize(_ handle: WriteHandle) throws -> URL {
        if fileManager.fileExists(atPath: handle.finalURL.path) {
            try fileManager.removeItem(at: handle.finalURL)
        }
        try fileManager.moveItem(at: handle.temporaryURL, to: handle.finalURL)
        return handle.finalURL
    }

    /// Drop a reservation without promoting it. Removes the temporary file
    /// if it exists. Safe to call even if no bytes were written.
    public func discard(_ handle: WriteHandle) {
        try? fileManager.removeItem(at: handle.temporaryURL)
    }

    // MARK: - Maintenance

    /// Remove every entry associated with the key (all known extensions and
    /// any stale `.part` files matching the key prefix).
    public func remove(forKey key: String) {
        for url in candidateURLs(forKey: key) {
            try? fileManager.removeItem(at: url)
        }
        // Also clear stragglers like "<key>.<uuid>.wav.part"
        if let entries = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix("\(key).") {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Remove every file under the cache directory.
    public func removeAll() throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Total on-disk size of every regular file under the cache directory.
    public func totalSizeBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Evict the oldest files (by modification date) until the cache's total
    /// size is at or below `maxBytes`. Files inside the cache directory whose
    /// extension is `.part` are always removed first (they are corrupt or
    /// abandoned mid-write).
    @discardableResult
    public func prune(toMaxBytes maxBytes: Int64) -> Int64 {
        guard maxBytes >= 0 else { return 0 }
        let entries = enumerateEntries()
        var bytesRemoved: Int64 = 0

        // Always purge .part stragglers first.
        for entry in entries where entry.url.pathExtension == "part" {
            try? fileManager.removeItem(at: entry.url)
            bytesRemoved += entry.size
        }

        let live = entries
            .filter { $0.url.pathExtension != "part" }
            .sorted { $0.modificationDate < $1.modificationDate }

        var current = live.reduce(0) { $0 + $1.size }
        guard current > maxBytes else { return bytesRemoved }

        for entry in live {
            if current <= maxBytes { break }
            try? fileManager.removeItem(at: entry.url)
            current -= entry.size
            bytesRemoved += entry.size
        }
        return bytesRemoved
    }

    // MARK: - Internals

    func candidateURLs(forKey key: String) -> [URL] {
        Self.supportedExtensions.map { ext in
            directoryURL.appendingPathComponent(key).appendingPathExtension(ext)
        }
    }

    func isUsable(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize, size > 0
        else { return false }
        #if canImport(AVFoundation)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return false }
        return audioFile.length > 0
        #else
        return true
        #endif
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let modificationDate: Date
    }

    private func enumerateEntries() -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true
            else { return nil }
            return Entry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
    }

    nonisolated static func standardPayload(
        modelID: String,
        voice: TTSVoice?,
        text: String
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [modelID, voice?.identifier ?? "auto", normalized].joined(separator: "|")
    }

    nonisolated static func makeKey(payload: String) -> String {
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Managed narration bundles

    /// Filesystem URL of the cache-managed narration bundle for
    /// `(modelID, text)`. The hash intentionally omits voice/language —
    /// each voice gets its own sub-bundle under `voices/<slug>/` inside
    /// the returned directory, so swapping voices for the same chapter
    /// reuses the same parent bundle.
    ///
    /// Does not create the directory. Pair with
    /// ``TTSSpeechSynthesizer/streamAndCacheNarration(_:using:options:cache:chunker:progressHandler:)``
    /// which derives this URL automatically.
    public nonisolated func narrationBundle(
        modelID: String,
        text: String
    ) -> URL {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = "\(modelID)|\(normalized)"
        let hash = Self.makeKey(payload: payload)
        return directoryURL
            .appendingPathComponent("bundles", isDirectory: true)
            .appendingPathComponent("\(hash).\(TTSPreparedNarration.bundleExtension)", isDirectory: true)
    }

    /// Enumerates `(voice, language)` variants already baked for
    /// `(modelID, text)` inside the cache-managed bundle. Returns an
    /// empty array if no bundle exists yet.
    public func availableVariants(
        modelID: String,
        text: String
    ) -> [(voice: String?, language: String?, slug: String)] {
        let bundleURL = narrationBundle(modelID: modelID, text: text)
        guard fileManager.fileExists(atPath: bundleURL.path) else { return [] }
        return TTSPreparedNarration.availableVariants(at: bundleURL)
    }

    /// Absorbs legacy narration bundles produced before the cache owned
    /// the on-disk layout. Iterates `legacyRoot/*.ttsnarration/`,
    /// recomputes each bundle's cache-managed URL from its manifest's
    /// `modelID` + `sourceText`, and `moveItem`s it into place. Skips
    /// entries whose destination already exists. Returns the number of
    /// bundles moved.
    @discardableResult
    public func migrate(from legacyRoot: URL) async throws -> Int {
        let suffix = "." + TTSPreparedNarration.bundleExtension
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return 0 }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var moved = 0
        for entry in entries where entry.lastPathComponent.hasSuffix(suffix) {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let info = Self.legacyManifestInfo(at: entry) else { continue }
            let destination = narrationBundle(modelID: info.modelID, text: info.sourceText)
            if fileManager.fileExists(atPath: destination.path) { continue }
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.moveItem(at: entry, to: destination)
            moved += 1
        }
        return moved
    }

#if canImport(AVFoundation)
    /// Recompress every cache-managed narration bundle to `codec`, reclaiming
    /// space on an already-generated library. Walks `bundles/*.ttsnarration`,
    /// transcodes each in place via ``TTSPreparedNarration/recompress(bundleAt:to:fileManager:)``,
    /// and returns the summed before/after byte totals.
    ///
    /// Idempotent — bundles already in `codec` are skipped and contribute
    /// equal before/after bytes. `progress` fires as `(completed, total)`
    /// after each bundle, for a host progress bar.
    @discardableResult
    public func recompressAllBundles(
        to codec: TTSAudioCodec,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (before: Int64, after: Int64) {
        let bundlesRoot = directoryURL.appendingPathComponent("bundles", isDirectory: true)
        let suffix = "." + TTSPreparedNarration.bundleExtension
        guard fileManager.fileExists(atPath: bundlesRoot.path),
              let entries = try? fileManager.contentsOfDirectory(
                  at: bundlesRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return (0, 0)
        }
        let bundles = entries.filter { $0.lastPathComponent.hasSuffix(suffix) }
        var before: Int64 = 0
        var after: Int64 = 0
        for (offset, bundle) in bundles.enumerated() {
            // Use a fresh FileManager rather than the actor-isolated one: the
            // recompress work is nonisolated, and FileManager.default is safe
            // to use concurrently for these independent file operations.
            let result = try await TTSPreparedNarration.recompress(
                bundleAt: bundle, to: codec
            )
            before += result.before
            after += result.after
            progress?(offset + 1, bundles.count)
        }
        return (before, after)
    }
#endif

    /// Inspects a legacy bundle directory and returns `(modelID, sourceText)`
    /// from its first available manifest — either the root-level
    /// `manifest.json` (single-voice legacy) or the first per-voice
    /// sub-bundle under `voices/`.
    private static func legacyManifestInfo(at bundleURL: URL) -> (modelID: String, sourceText: String)? {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rootManifest = bundleURL.appendingPathComponent(TTSPreparedNarration.manifestFilename, isDirectory: false)
        if let data = try? Data(contentsOf: rootManifest),
           let manifest = try? decoder.decode(TTSPreparedNarrationManifest.self, from: data) {
            return (manifest.modelID, manifest.sourceText)
        }

        let voicesDir = bundleURL.appendingPathComponent("voices", isDirectory: true)
        guard let subs = try? fm.contentsOfDirectory(
            at: voicesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for sub in subs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let subManifest = sub.appendingPathComponent(TTSPreparedNarration.manifestFilename, isDirectory: false)
            guard let data = try? Data(contentsOf: subManifest),
                  let manifest = try? decoder.decode(TTSPreparedNarrationManifest.self, from: data)
            else { continue }
            return (manifest.modelID, manifest.sourceText)
        }
        return nil
    }
}
