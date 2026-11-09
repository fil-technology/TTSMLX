import Foundation

/// A reusable voice configuration: what to tell the model so that separate
/// calls sound like the same speaker. It is a *recipe*, not a learned speaker
/// embedding: a designed profile stores the description the model reads, a
/// cloned profile points at the reference clip (and transcript) that is sent
/// along with every request. Nothing is extracted or cached from the clip
/// here; models that can prepare conditioning do so through
/// `TTSSpeechSynthesizer.prepareVoice`.
///
/// Profiles are `Codable` and meant for `TTSVoiceProfileStore`. The clip
/// itself is referenced by URL, not copied, so a profile never duplicates
/// someone's recording; move the clip and the profile stops working.
public struct TTSVoiceProfile: Sendable, Hashable, Codable, Identifiable {
    /// How the voice is produced.
    public enum Kind: Sendable, Hashable, Codable {
        /// Text-to-voice: a natural-language description, no recording.
        case designed(description: String)
        /// A reference clip lends its timbre; the style stays free.
        case cloned(referenceURL: URL)
        /// The model continues the clip as if the text followed its transcript.
        /// `transcript` must be what is actually said in the clip.
        case highFidelity(referenceURL: URL, transcript: String)
    }

    /// Where the right to use a cloned voice comes from. Required for the two
    /// cloned kinds; `TTSVoiceProfileStore.save` refuses a cloned profile
    /// without it.
    public struct Consent: Sendable, Hashable, Codable {
        /// Who the voice belongs to, as the user describes them ("me",
        /// "narrator hired for project X").
        public var speaker: String
        /// Free-form basis: "own voice", "written permission 2026-11-01", a
        /// licence name.
        public var basis: String
        public var recordedAt: Date

        public init(speaker: String, basis: String, recordedAt: Date = Date()) {
            self.speaker = speaker
            self.basis = basis
            self.recordedAt = recordedAt
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Catalog id of the model the profile was made for.
    public var modelID: String
    /// Checkpoint revision at creation (`.mlx-audio-snapshot.json`), when known,
    /// so a changed checkpoint can be noticed.
    public var modelRevision: String?
    public var language: TTSLanguage?
    /// Delivery steering that goes with the voice: free text, emotion, speed.
    public var instruction: String?
    public var emotion: TTSEmotion?
    public var speed: TTSSpeed?
    /// Generation defaults the profile was tuned with.
    public var generationProfile: TTSGenerationProfile?
    public var diffusionSteps: Int?
    public var guidanceScale: Float?
    /// Fixed seed: the same text reproduces the same take on the same
    /// checkpoint and runtime.
    public var seed: UInt64?
    public var consent: Consent?
    public var notes: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, kind: Kind, modelID: String, modelRevision: String? = nil,
        language: TTSLanguage? = nil, instruction: String? = nil, emotion: TTSEmotion? = nil,
        speed: TTSSpeed? = nil, generationProfile: TTSGenerationProfile? = nil,
        diffusionSteps: Int? = nil, guidanceScale: Float? = nil, seed: UInt64? = nil,
        consent: Consent? = nil, notes: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.language = language
        self.instruction = instruction
        self.emotion = emotion
        self.speed = speed
        self.generationProfile = generationProfile
        self.diffusionSteps = diffusionSteps
        self.guidanceScale = guidanceScale
        self.seed = seed
        self.consent = consent
        self.notes = notes
        self.createdAt = createdAt
    }

    public var usesRecording: Bool {
        switch kind {
        case .designed: return false
        case .cloned, .highFidelity: return true
        }
    }

    public var referenceURL: URL? {
        switch kind {
        case .designed: return nil
        case .cloned(let url), .highFidelity(let url, _): return url
        }
    }

    /// The profile applied to a request. Fields the caller already set win;
    /// the profile fills in the rest. For a designed voice the description
    /// goes into `voice`, which the model-specific controls layer turns into
    /// the model's own prompt (VoxCPM2: the parenthesised description).
    public func apply(to base: TTSSynthesisOptions = .init()) -> TTSSynthesisOptions {
        var options = base
        switch kind {
        case .designed(let description):
            if options.voice == nil { options.voice = TTSVoice(description) }
        case .cloned(let url):
            if options.referenceAudio == nil && options.preparedVoice == nil { options.referenceAudio = url }
        case .highFidelity(let url, let transcript):
            if options.referenceAudio == nil && options.preparedVoice == nil {
                options.referenceAudio = url
                options.referenceText = transcript
            }
        }
        if options.language == nil { options.language = language }
        if options.instruction == nil { options.instruction = instruction }
        if options.emotion == nil { options.emotion = emotion }
        if options.speed == nil { options.speed = speed }
        if options.generationProfile == nil { options.generationProfile = generationProfile }
        if options.diffusionSteps == nil { options.diffusionSteps = diffusionSteps }
        if options.guidanceScale == nil { options.guidanceScale = guidanceScale }
        if options.seed == nil { options.seed = seed }
        return options
    }

    /// Several variants of a designed voice: the same recipe under different
    /// seeds, so a user can audition and keep the one they like.
    public func variants(seeds: [UInt64]) -> [TTSVoiceProfile] {
        seeds.map { seed in
            var copy = self
            copy.id = UUID()
            copy.seed = seed
            copy.name = "\(name) · seed \(seed)"
            return copy
        }
    }
}

/// Builds a VoxCPM2-style voice description from structured choices. Every
/// field is optional and compiles into plain words; the model reads the
/// sentence, so none of these is a measured quantity (an "age" is a word in
/// the prompt, not a number the model enforces). The result is kept with the
/// profile so a voice can be reproduced.
public struct TTSVoiceDesign: Sendable, Hashable, Codable {
    public enum Gender: String, Sendable, Codable, CaseIterable { case male, female, neutral }
    public enum Age: String, Sendable, Codable, CaseIterable {
        case child, teenage, young = "young adult", middleAged = "middle-aged", mature, elderly
    }
    public enum Pitch: String, Sendable, Codable, CaseIterable { case deep, low, medium, high }
    public enum Pace: String, Sendable, Codable, CaseIterable { case slow, measured, natural, brisk, fast }

    public var gender: Gender?
    public var age: Age?
    public var pitch: Pitch?
    /// Timbre and texture words: "warm", "raspy", "breathy", "bright".
    public var qualities: [String]
    public var emotion: String?
    public var pace: Pace?
    public var accent: String?
    /// Role or register: "narrator", "news anchor", "storyteller".
    public var style: String?
    /// Anything the structured fields do not cover.
    public var custom: String?

    public init(
        gender: Gender? = nil, age: Age? = nil, pitch: Pitch? = nil, qualities: [String] = [],
        emotion: String? = nil, pace: Pace? = nil, accent: String? = nil, style: String? = nil,
        custom: String? = nil
    ) {
        self.gender = gender
        self.age = age
        self.pitch = pitch
        self.qualities = qualities
        self.emotion = emotion
        self.pace = pace
        self.accent = accent
        self.style = style
        self.custom = custom
    }

    /// The natural-language description the model receives.
    public var description: String {
        var subject: [String] = []
        if let age { subject.append(age.rawValue) }
        if let gender { subject.append(gender == .neutral ? "gender-neutral" : gender.rawValue) }
        if let style { subject.append(style) } else if !subject.isEmpty { subject.append("speaker") }
        var parts: [String] = []
        if !subject.isEmpty { parts.append("A " + subject.joined(separator: " ")) }
        var voice: [String] = []
        if let pitch { voice.append("\(pitch.rawValue)-pitched") }
        voice.append(contentsOf: qualities)
        if !voice.isEmpty { parts.append(voice.joined(separator: ", ") + " voice") }
        if let accent, !accent.isEmpty { parts.append("\(accent) accent") }
        if let emotion, !emotion.isEmpty { parts.append("\(emotion) delivery") }
        if let pace { parts.append("\(pace.rawValue) speaking pace") }
        if let custom, !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: ", ")
    }

    public var isEmpty: Bool { description.isEmpty }
}

/// Local, file-based storage for voice profiles: one JSON document per
/// profile under Application Support (or a directory of the caller's choice).
/// Cloned profiles are refused without consent information.
public actor TTSVoiceProfileStore {
    public enum StoreError: Error, LocalizedError, Equatable {
        case consentRequired(String)
        public var errorDescription: String? {
            switch self {
            case .consentRequired(let name):
                return "Voice profile \"\(name)\" reproduces a recording and needs consent information (speaker and basis) before it can be saved."
            }
        }
    }

    public let directory: URL
    private var fileManager: FileManager { .default }

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let fm = FileManager.default
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            self.directory = base.appendingPathComponent("TTSMLX/VoiceProfiles", isDirectory: true)
        }
    }

    public func save(_ profile: TTSVoiceProfile) throws {
        if profile.usesRecording, profile.consent == nil {
            throw StoreError.consentRequired(profile.name)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> TTSVoiceProfile? {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(TTSVoiceProfile.self, from: Data(contentsOf: url))
    }

    public func all() throws -> [TTSVoiceProfile] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TTSVoiceProfile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
