import Foundation

/// A self-contained, playable narration bundle: pre-generated audio plus the
/// word-level timing metadata needed to highlight it, packaged together so it
/// can ship with the app and play **without** the MLX runtime or model
/// download.
///
/// Use this when you want:
/// - **Onboarding voiceovers** that play instantly on first launch, before
///   the user has downloaded any model.
/// - **Sample chapters** shown in a store listing or marketing flow.
/// - **Reproducible demos** that don't depend on a specific MLX build.
///
/// ## Bundle layout
///
/// A narration lives on disk as a directory with a `.ttsnarration` extension
/// (convention, not enforced). The layout is:
///
/// ```
/// MyOnboarding.ttsnarration/
///   manifest.json
///   chunks/
///     000.wav
///     001.wav
///     ...
/// ```
///
/// `manifest.json` is a versioned JSON document — see
/// ``TTSPreparedNarrationManifest`` for the schema. Each chunk's audio is a
/// standalone WAV; they are not concatenated so individual chunks remain
/// re-renderable in isolation (e.g. for editing a single paragraph).
///
/// ## Author-time flow
///
/// ```swift
/// let bundleURL = ... // a writable directory URL with .ttsnarration extension
/// let narration = try await synthesizer.prepareNarration(
///     text: welcomeScript,
///     using: model,
///     options: opts,
///     into: bundleURL
/// )
/// // narration is now on disk; ship `bundleURL` as a bundle resource.
/// ```
///
/// ## Runtime flow (no model required)
///
/// ```swift
/// let narration = try TTSPreparedNarration(importing: bundleURL)
/// let playback = TTSPlaybackController()
/// try playback.play(narration: narration) { word in
///     highlightStore.current = word.characterRange
/// }
/// ```
public struct TTSPreparedNarration: Sendable, Hashable {
    /// Parsed manifest. Stable across the import/export round-trip.
    public let manifest: TTSPreparedNarrationManifest
    /// Filesystem URL of the bundle directory. All `audioFile` paths in the
    /// manifest are resolved relative to this URL.
    public let baseURL: URL

    public init(manifest: TTSPreparedNarrationManifest, baseURL: URL) {
        self.manifest = manifest
        self.baseURL = baseURL
    }

    /// Loads a narration from a previously exported bundle directory.
    /// Validates the manifest schema version and that every referenced chunk
    /// audio file exists. Does **not** decode the audio.
    ///
    /// This is the **legacy** import path that reads `manifest.json` directly
    /// from `bundleURL`. For sub-bundle (per-voice/language) layouts, prefer
    /// ``init(importing:voice:language:)``.
    public init(importing bundleURL: URL) throws {
        try self.init(loadingManifestFrom: bundleURL)
    }

    /// Loads a narration for a specific `(voice, language)` sub-bundle inside
    /// `bundleURL`. Resolves to `bundleURL/voices/<slug>/manifest.json`.
    ///
    /// If no sub-bundle exists but a legacy root-level `manifest.json` is
    /// present whose `voice` / `language` fields match the requested values,
    /// the legacy layout is auto-migrated in place (manifest + chunks moved
    /// into the sub-bundle directory) before loading.
    public init(importing bundleURL: URL, voice: String?, language: String?) throws {
        let subURL = Self.subBundleURL(in: bundleURL, voice: voice, language: language)
        let fileManager = FileManager.default
        let subManifestURL = subURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        if !fileManager.fileExists(atPath: subManifestURL.path) {
            // Try a legacy migration: matching voice/language at the bundle root.
            try Self.migrateLegacyIfMatches(
                bundleURL: bundleURL,
                voice: voice,
                language: language
            )
        }
        try self.init(loadingManifestFrom: subURL)
    }

    private init(loadingManifestFrom dir: URL) throws {
        let manifestURL = dir.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw TTSPreparedNarrationError.manifestMissing(url: manifestURL, underlying: error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: TTSPreparedNarrationManifest
        do {
            manifest = try decoder.decode(TTSPreparedNarrationManifest.self, from: data)
        } catch {
            throw TTSPreparedNarrationError.manifestMalformed(underlying: error)
        }
        guard manifest.schemaVersion <= TTSPreparedNarrationManifest.currentSchemaVersion else {
            throw TTSPreparedNarrationError.schemaVersionTooNew(
                bundleVersion: manifest.schemaVersion,
                supportedVersion: TTSPreparedNarrationManifest.currentSchemaVersion
            )
        }
        // Surface missing chunk files at import time rather than mid-playback.
        for chunk in manifest.chunks {
            let url = dir.appendingPathComponent(chunk.audioFile, isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                throw TTSPreparedNarrationError.chunkAudioMissing(
                    chunkIndex: chunk.index,
                    audioURL: url
                )
            }
        }
        self.manifest = manifest
        self.baseURL = dir
    }

    /// Sanitizes a single component for the on-disk slug. Lowercased,
    /// alphanumerics + `-` preserved, everything else collapsed to `_`.
    /// `nil` → `"auto"`.
    private static func slugComponent(_ value: String?) -> String {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "auto"
        }
        var out = ""
        for ch in raw.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        return out.isEmpty ? "auto" : out
    }

    /// Slug for a `(voice, language)` pair, e.g. `"jean.en"` or `"auto.auto"`.
    public static func subBundleSlug(voice: String?, language: String?) -> String {
        "\(slugComponent(voice)).\(slugComponent(language))"
    }

    /// Filesystem URL of the sub-bundle directory inside `bundleURL` for the
    /// given `(voice, language)`. Returns `bundleURL/voices/<slug>/`.
    public static func subBundleURL(in bundleURL: URL, voice: String?, language: String?) -> URL {
        bundleURL
            .appendingPathComponent("voices", isDirectory: true)
            .appendingPathComponent(subBundleSlug(voice: voice, language: language), isDirectory: true)
    }

    /// Enumerates the `(voice, language)` variants stored inside `bundleURL`.
    /// Reads each sub-bundle's manifest to recover the authoritative voice /
    /// language fields. Returns an empty array if `bundleURL` has no
    /// `voices/` directory.
    public static func availableVariants(at bundleURL: URL) -> [(voice: String?, language: String?, slug: String)] {
        let voicesDir = bundleURL.appendingPathComponent("voices", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: voicesDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: voicesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [(voice: String?, language: String?, slug: String)] = []
        for entry in entries {
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir), entryIsDir.boolValue else {
                continue
            }
            let slug = entry.lastPathComponent
            let manifestURL = entry.appendingPathComponent(Self.manifestFilename, isDirectory: false)
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(TTSPreparedNarrationManifest.self, from: data) else {
                continue
            }
            out.append((voice: manifest.voice, language: manifest.language, slug: slug))
        }
        return out.sorted { $0.slug < $1.slug }
    }

    /// If `bundleURL` has a legacy root-level `manifest.json` whose voice /
    /// language fields match the requested pair, moves it (and `chunks/`)
    /// into the sub-bundle directory. No-op if the manifest is missing or
    /// the fields don't match.
    static func migrateLegacyIfMatches(
        bundleURL: URL,
        voice: String?,
        language: String?
    ) throws {
        let fm = FileManager.default
        let legacyManifestURL = bundleURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        guard fm.fileExists(atPath: legacyManifestURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyManifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacy = try? decoder.decode(TTSPreparedNarrationManifest.self, from: data) else {
            return
        }
        guard legacy.voice == voice, legacy.language == language else { return }

        let subURL = subBundleURL(in: bundleURL, voice: voice, language: language)
        try fm.createDirectory(at: subURL, withIntermediateDirectories: true)

        let destManifest = subURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        if fm.fileExists(atPath: destManifest.path) {
            try fm.removeItem(at: destManifest)
        }
        try fm.moveItem(at: legacyManifestURL, to: destManifest)

        let legacyChunks = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        if fm.fileExists(atPath: legacyChunks.path) {
            let destChunks = subURL.appendingPathComponent("chunks", isDirectory: true)
            if fm.fileExists(atPath: destChunks.path) {
                try fm.removeItem(at: destChunks)
            }
            try fm.moveItem(at: legacyChunks, to: destChunks)
        }
    }

    /// Writes the bundle to disk. Creates the directory tree if needed, then
    /// the manifest. Caller is responsible for placing chunk audio files at
    /// the paths declared in `manifest.chunks[*].audioFile` — for the typical
    /// case where the synthesizer writes them, use
    /// ``TTSSpeechSynthesizer/prepareNarration(_:using:options:into:chunker:progressHandler:)``
    /// which handles audio + manifest atomically.
    public func writeManifest() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let manifestURL = baseURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Resolves an absolute URL for a chunk's audio file inside the bundle.
    public func audioURL(forChunk chunkIndex: Int) -> URL? {
        guard let chunk = manifest.chunks.first(where: { $0.index == chunkIndex }) else { return nil }
        return baseURL.appendingPathComponent(chunk.audioFile, isDirectory: false)
    }

    /// The total playable duration, in source-audio seconds, summed across
    /// every chunk in declaration order.
    public var totalDuration: TimeInterval {
        manifest.chunks.reduce(0) { $0 + $1.duration }
    }

    /// A flat, sorted list of every word's timing in the **bundle-global**
    /// timeline. `offset` is measured from the start of playback (chunk 0
    /// offset 0); `characterRange` is re-anchored to the original-text
    /// coordinate space (manifest stores chunk-local ranges; this helper
    /// adds the chunk's start offset back in) so callers can drop a
    /// highlight directly on the source string.
    ///
    /// Used by `TTSPlaybackController.play(narration:onWord:...)` to fire
    /// per-word callbacks against the player's `currentTime`.
    public func flattenedWordTimeline() -> [TTSWordTiming] {
        var out: [TTSWordTiming] = []
        var cumulativeOffset: TimeInterval = 0
        for chunk in manifest.chunks {
            let chunkOriginStart = chunk.characterRange.start
            for word in chunk.wordTimings {
                let absoluteRange = (chunkOriginStart + word.characterRange.start)
                    ..< (chunkOriginStart + word.characterRange.end)
                out.append(TTSWordTiming(
                    characterRange: absoluteRange,
                    offset: cumulativeOffset + word.offset,
                    duration: word.duration
                ))
            }
            cumulativeOffset += chunk.duration
        }
        return out
    }

    static let manifestFilename = "manifest.json"
    public static let bundleExtension = "ttsnarration"
}

/// The on-disk manifest schema. Versioned via ``schemaVersion`` — bump
/// ``currentSchemaVersion`` when making a breaking change and add migration
/// in `TTSPreparedNarration.init(importing:)`.
public struct TTSPreparedNarrationManifest: Sendable, Hashable, Codable {
    /// Bump on every breaking change to this struct's shape. Readers reject
    /// bundles whose `schemaVersion` is newer than what they know.
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var modelID: String
    public var voice: String?
    public var language: String?
    public var sourceText: String
    public var sampleRate: Int
    public var chunks: [ChunkEntry]

    public init(
        schemaVersion: Int = TTSPreparedNarrationManifest.currentSchemaVersion,
        createdAt: Date = Date(),
        modelID: String,
        voice: String? = nil,
        language: String? = nil,
        sourceText: String,
        sampleRate: Int,
        chunks: [ChunkEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.modelID = modelID
        self.voice = voice
        self.language = language
        self.sourceText = sourceText
        self.sampleRate = sampleRate
        self.chunks = chunks
    }

    public struct ChunkEntry: Sendable, Hashable, Codable {
        public var index: Int
        /// Path relative to the bundle root, e.g. `"chunks/000.wav"`.
        public var audioFile: String
        /// Half-open character range in the original `sourceText`.
        public var characterRange: SerializableRange
        /// The chunk's text — denormalized for convenience so consumers
        /// don't have to re-slice `sourceText`.
        public var text: String
        /// Measured source-audio duration, seconds.
        public var duration: TimeInterval
        /// Word-level timings, offsets relative to the chunk's first sample.
        public var wordTimings: [SerializableWordTiming]

        public init(
            index: Int,
            audioFile: String,
            characterRange: SerializableRange,
            text: String,
            duration: TimeInterval,
            wordTimings: [SerializableWordTiming]
        ) {
            self.index = index
            self.audioFile = audioFile
            self.characterRange = characterRange
            self.text = text
            self.duration = duration
            self.wordTimings = wordTimings
        }
    }

    /// Codable surrogate for `Range<Int>` (Swift's `Range` isn't `Codable`).
    public struct SerializableRange: Sendable, Hashable, Codable {
        public var start: Int
        public var end: Int

        public init(_ range: Range<Int>) {
            self.start = range.lowerBound
            self.end = range.upperBound
        }

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }

        public var range: Range<Int> { start..<end }
    }

    /// Codable surrogate for `TTSWordTiming`.
    public struct SerializableWordTiming: Sendable, Hashable, Codable {
        public var characterRange: SerializableRange
        public var offset: TimeInterval
        public var duration: TimeInterval

        public init(_ timing: TTSWordTiming) {
            self.characterRange = SerializableRange(timing.characterRange)
            self.offset = timing.offset
            self.duration = timing.duration
        }

        public init(
            characterRange: SerializableRange,
            offset: TimeInterval,
            duration: TimeInterval
        ) {
            self.characterRange = characterRange
            self.offset = offset
            self.duration = duration
        }
    }
}

/// Errors thrown when importing a narration bundle.
public enum TTSPreparedNarrationError: LocalizedError, @unchecked Sendable {
    case manifestMissing(url: URL, underlying: Error)
    case manifestMalformed(underlying: Error)
    case schemaVersionTooNew(bundleVersion: Int, supportedVersion: Int)
    case chunkAudioMissing(chunkIndex: Int, audioURL: URL)

    public var errorDescription: String? {
        switch self {
        case let .manifestMissing(url, _):
            return "Narration manifest missing at \(url.path)"
        case let .manifestMalformed(underlying):
            return "Narration manifest is malformed: \(underlying.localizedDescription)"
        case let .schemaVersionTooNew(bundleVersion, supportedVersion):
            return "Narration bundle schema v\(bundleVersion) is newer than this TTSMLX (v\(supportedVersion)). Update the framework."
        case let .chunkAudioMissing(chunkIndex, audioURL):
            return "Narration chunk \(chunkIndex) audio missing at \(audioURL.path)"
        }
    }
}
