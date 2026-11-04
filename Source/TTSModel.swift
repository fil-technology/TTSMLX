import Foundation

public struct TTSModelDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let summary: String?
    public let supportedLanguages: [TTSLanguage]
    public let suggestedVoices: [TTSVoice]
    public let capabilities: TTSModelCapabilities
    public let metadata: TTSModelMetadata?
    public let modelURL: URL?
    public let files: [String]?
    /// Licence of the weights. Catalog descriptors always carry one; a
    /// descriptor discovered from the hub may not.
    public let license: TTSModelLicense?

    public init(
        id: String,
        displayName: String? = nil,
        summary: String? = nil,
        supportedLanguages: [TTSLanguage] = [],
        suggestedVoices: [TTSVoice] = [],
        capabilities: TTSModelCapabilities = .init(),
        metadata: TTSModelMetadata? = nil,
        modelURL: URL? = nil,
        files: [String]? = nil,
        license: TTSModelLicense? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.summary = summary
        self.supportedLanguages = supportedLanguages
        self.suggestedVoices = suggestedVoices
        self.capabilities = capabilities
        self.metadata = metadata
        self.modelURL = modelURL
        self.files = files
        self.license = license
    }

    /// The same descriptor with `license` set.
    public func withLicense(_ license: TTSModelLicense) -> TTSModelDescriptor {
        TTSModelDescriptor(
            id: id, displayName: displayName, summary: summary, supportedLanguages: supportedLanguages,
            suggestedVoices: suggestedVoices, capabilities: capabilities, metadata: metadata,
            modelURL: modelURL, files: files, license: license)
    }

    /// False for non-commercial, research-only and unlicensed weights.
    public var allowsCommercialUse: Bool { license?.allowsCommercialUse ?? false }
}

public struct TTSModelCapabilities: Sendable, Hashable, Codable {
    public let isRuntimeSupported: Bool
    public let supportsReferenceAudio: Bool
    public let supportsLanguageList: Bool
    public let supportedLanguages: [TTSLanguage]
    public let defaultGenerationProfile: TTSGenerationProfile
    public let supportsStreaming: Bool
    /// Everything the model can do, in the uniform vocabulary. Always includes
    /// the members implied by the boolean fields and the voice list.
    public let features: Set<TTSModelFeature>
    /// The model's spelling of each supported `TTSEventTag`; empty when the
    /// model has none. The synthesizer rewrites canonical markers with it.
    public let eventTags: [TTSEventTag: String]
    /// Output sample rate in Hz, when known.
    public let sampleRate: Int?
    /// Empirical peak resident memory in MB while generating. `nil` means unknown.
    ///
    /// Prefer this over ``minimumDeviceClass`` for any **memory-pressure**
    /// reason — it's gateable per-device without hand-curating per-class
    /// lists, and it doesn't punish a 6GB iPhone for being an iPhone when
    /// the model fits comfortably (see Pocket-TTS regression in 0.5.0).
    public let peakMemoryMB: Int?
    /// Smallest device class needed for a **non-memory** reason — e.g. the
    /// model needs ANE-only kernels, GPU features absent on older A-series
    /// chips, or a jetsam headroom that's tighter than `peakMemoryMB` alone
    /// can express. `nil` means no class-level constraint.
    ///
    /// **Do not** use this as a shortcut for "feels like it might OOM on
    /// iPhone." Use `peakMemoryMB` for that — it's the empirically correct
    /// gate. Every entry that sets this above the smallest class
    /// `peakMemoryMB` would allow on a modern 8GB iPhone needs a code
    /// comment explaining the non-memory reason; otherwise it's redundant
    /// and should be removed.
    public let minimumDeviceClass: TTSDeviceClass?

    public init(
        isRuntimeSupported: Bool = false,
        supportsReferenceAudio: Bool = false,
        supportsLanguageList: Bool = false,
        supportedLanguages: [TTSLanguage] = [],
        defaultGenerationProfile: TTSGenerationProfile = .balanced,
        supportsStreaming: Bool = true,
        peakMemoryMB: Int? = nil,
        minimumDeviceClass: TTSDeviceClass? = nil,
        features: Set<TTSModelFeature> = [],
        eventTags: [TTSEventTag: String] = [:],
        sampleRate: Int? = nil,
        hasBuiltInVoices: Bool = false
    ) {
        self.isRuntimeSupported = isRuntimeSupported
        self.supportsReferenceAudio = supportsReferenceAudio
        self.supportsLanguageList = supportsLanguageList
        self.supportedLanguages = supportedLanguages
        self.defaultGenerationProfile = defaultGenerationProfile
        self.supportsStreaming = supportsStreaming
        self.peakMemoryMB = peakMemoryMB
        self.minimumDeviceClass = minimumDeviceClass
        self.eventTags = eventTags
        self.sampleRate = sampleRate
        self.features = Self.impliedFeatures(
            explicit: features, supportsStreaming: supportsStreaming,
            supportsReferenceAudio: supportsReferenceAudio, languageCount: supportedLanguages.count,
            eventTags: !eventTags.isEmpty, hasBuiltInVoices: hasBuiltInVoices)
    }

    static func impliedFeatures(
        explicit: Set<TTSModelFeature>, supportsStreaming: Bool, supportsReferenceAudio: Bool,
        languageCount: Int, eventTags: Bool, hasBuiltInVoices: Bool
    ) -> Set<TTSModelFeature> {
        var features = explicit
        if supportsStreaming { features.insert(.streaming) }
        if supportsReferenceAudio { features.insert(.voiceCloning) }
        if languageCount > 1 { features.insert(.multilingual) }
        if eventTags { features.insert(.eventTags) }
        if hasBuiltInVoices { features.insert(.builtInVoices) }
        return features
    }

    /// `features` in display order.
    public var sortedFeatures: [TTSModelFeature] { features.sorted() }

    /// Decode tolerates older encoded values without the device fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isRuntimeSupported = try c.decode(Bool.self, forKey: .isRuntimeSupported)
        self.supportsReferenceAudio = try c.decode(Bool.self, forKey: .supportsReferenceAudio)
        self.supportsLanguageList = try c.decode(Bool.self, forKey: .supportsLanguageList)
        self.supportedLanguages = try c.decode([TTSLanguage].self, forKey: .supportedLanguages)
        self.defaultGenerationProfile = try c.decode(TTSGenerationProfile.self, forKey: .defaultGenerationProfile)
        self.supportsStreaming = try c.decodeIfPresent(Bool.self, forKey: .supportsStreaming) ?? true
        self.peakMemoryMB = try c.decodeIfPresent(Int.self, forKey: .peakMemoryMB)
        self.minimumDeviceClass = try c.decodeIfPresent(TTSDeviceClass.self, forKey: .minimumDeviceClass)
        self.eventTags = try c.decodeIfPresent([TTSEventTag: String].self, forKey: .eventTags) ?? [:]
        self.sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate)
        let explicit = try c.decodeIfPresent(Set<TTSModelFeature>.self, forKey: .features) ?? []
        self.features = Self.impliedFeatures(
            explicit: explicit, supportsStreaming: supportsStreaming,
            supportsReferenceAudio: supportsReferenceAudio, languageCount: supportedLanguages.count,
            eventTags: !eventTags.isEmpty, hasBuiltInVoices: explicit.contains(.builtInVoices))
    }
}

public extension TTSModelDescriptor {
    /// `capabilities.features` plus `.builtInVoices` when the descriptor lists voices.
    var features: Set<TTSModelFeature> {
        suggestedVoices.isEmpty ? capabilities.features : capabilities.features.union([.builtInVoices])
    }

    /// `features` in display order.
    var sortedFeatures: [TTSModelFeature] { features.sorted() }

    /// Event tags the model renders, in canonical order.
    var supportedEventTags: [TTSEventTag] {
        TTSEventTag.allCases.filter { capabilities.eventTags[$0] != nil }
    }

    /// Returns `true` when this model's known requirements fit the profile.
    /// Models with no recorded capability data (peakMemoryMB / minimumDeviceClass)
    /// are treated as "unknown → allow", since we can't prove they will fail.
    func isSupported(on profile: TTSDeviceProfile) -> Bool {
        if let minClass = capabilities.minimumDeviceClass, profile.deviceClass < minClass {
            return false
        }
        if let peak = capabilities.peakMemoryMB, profile.physicalMemoryMB < peak {
            return false
        }
        return true
    }
}

extension TTSDeviceClass: Comparable {
    public static func < (lhs: TTSDeviceClass, rhs: TTSDeviceClass) -> Bool {
        lhs.memoryRank < rhs.memoryRank
    }
}

public struct TTSInstalledModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let descriptor: TTSModelDescriptor
    public let location: URL
    public let sizeBytes: Int64

    public init(descriptor: TTSModelDescriptor, location: URL, sizeBytes: Int64) {
        self.id = descriptor.id
        self.descriptor = descriptor
        self.location = location
        self.sizeBytes = sizeBytes
    }
}

public struct TTSLanguage: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public init(stringLiteral value: StringLiteralType) {
        self.identifier = value
    }

    public static let english: Self = "English"
    public static let spanish: Self = "Spanish"
    public static let french: Self = "French"
    public static let german: Self = "German"
    public static let italian: Self = "Italian"
    public static let portuguese: Self = "Portuguese"
    public static let dutch: Self = "Dutch"
    public static let polish: Self = "Polish"
    public static let turkish: Self = "Turkish"
    public static let russian: Self = "Russian"
    public static let japanese: Self = "Japanese"
    public static let korean: Self = "Korean"
    public static let chinese: Self = "Chinese"
    public static let arabic: Self = "Arabic"
    public static let hindi: Self = "Hindi"
    public static let hungarian: Self = "Hungarian"
    public static let persian: Self = "Persian"
    public static let czech: Self = "Czech"
    public static let danish: Self = "Danish"
    public static let swedish: Self = "Swedish"
    public static let greek: Self = "Greek"
}

/// A voice the runtime selects by `identifier`. Catalog voices also carry the
/// metadata the model's documentation gives (display name, language, gender,
/// a one-line description) so an app can build a picker without a lookup
/// table per model. Equality and hashing use the identifier only: a literal
/// `"alba"` matches the catalog's annotated `alba`, and cache keys stay stable.
public struct TTSVoice: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let identifier: String
    public let displayName: String?
    public let language: TTSLanguage?
    public let gender: TTSVoiceGender?
    public let summary: String?

    public init(
        _ identifier: String,
        displayName: String? = nil,
        language: TTSLanguage? = nil,
        gender: TTSVoiceGender? = nil,
        summary: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.language = language
        self.gender = gender
        self.summary = summary
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    /// `displayName`, or the identifier.
    public var name: String { displayName ?? identifier }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }
    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let identifier = try? single.decode(String.self) {
            self.init(identifier)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try c.decode(String.self, forKey: .identifier),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            language: try c.decodeIfPresent(TTSLanguage.self, forKey: .language),
            gender: try c.decodeIfPresent(TTSVoiceGender.self, forKey: .gender),
            summary: try c.decodeIfPresent(String.self, forKey: .summary)
        )
    }

    public static let alba: Self = "alba"
    public static let marius: Self = "marius"
    public static let javert: Self = "javert"
    public static let jean: Self = "jean"
    public static let leah: Self = "leah"
    public static let jess: Self = "jess"
    public static let tara: Self = "tara"
    public static let leo: Self = "leo"
    public static let dan: Self = "dan"
    public static let mia: Self = "mia"
    public static let zac: Self = "zac"
    public static let zoe: Self = "zoe"
    public static let enUS1: Self = "en-us-1"
}

public struct TTSModelMetadata: Sendable, Hashable, Codable {
    public let pipelineTag: String?
    public let tags: [String]
    public let downloads: Int?
    public let likes: Int?
    public let storageSizeBytes: Int64?
    public let languageIdentifiers: [String]
    public let license: String?
    public let modelType: String?
    public let architectures: [String]
    public let sampleRate: Int?
    public let extra: [String: String]

    public init(
        pipelineTag: String? = nil,
        tags: [String] = [],
        downloads: Int? = nil,
        likes: Int? = nil,
        storageSizeBytes: Int64? = nil,
        languageIdentifiers: [String] = [],
        license: String? = nil,
        modelType: String? = nil,
        architectures: [String] = [],
        sampleRate: Int? = nil,
        extra: [String: String] = [:]
    ) {
        self.pipelineTag = pipelineTag
        self.tags = tags
        self.downloads = downloads
        self.likes = likes
        self.storageSizeBytes = storageSizeBytes
        self.languageIdentifiers = languageIdentifiers
        self.license = license
        self.modelType = modelType
        self.architectures = architectures
        self.sampleRate = sampleRate
        self.extra = extra
    }
}
