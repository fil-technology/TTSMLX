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

    private static let supportedExtensions = ["wav", "caf"]

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
}
