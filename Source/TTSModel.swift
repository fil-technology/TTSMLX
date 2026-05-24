import Foundation

public struct TTSModelDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let summary: String?
    public let supportedLanguages: [TTSLanguage]
    public let suggestedVoices: [TTSVoice]
    public let capabilities: TTSModelCapabilities
    public let metadata: TTSModelMetadata?

    public init(
        id: String,
        displayName: String? = nil,
        summary: String? = nil,
        supportedLanguages: [TTSLanguage] = [],
        suggestedVoices: [TTSVoice] = [],
        capabilities: TTSModelCapabilities = .init(),
        metadata: TTSModelMetadata? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.summary = summary
        self.supportedLanguages = supportedLanguages
        self.suggestedVoices = suggestedVoices
        self.capabilities = capabilities
        self.metadata = metadata
    }
}

public struct TTSModelCapabilities: Sendable, Hashable, Codable {
    public let isRuntimeSupported: Bool
    public let supportsReferenceAudio: Bool
    public let supportsLanguageList: Bool
    public let supportedLanguages: [TTSLanguage]
    public let defaultGenerationProfile: TTSGenerationProfile
    public let supportsStreaming: Bool
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
        minimumDeviceClass: TTSDeviceClass? = nil
    ) {
        self.isRuntimeSupported = isRuntimeSupported
        self.supportsReferenceAudio = supportsReferenceAudio
        self.supportsLanguageList = supportsLanguageList
        self.supportedLanguages = supportedLanguages
        self.defaultGenerationProfile = defaultGenerationProfile
        self.supportsStreaming = supportsStreaming
        self.peakMemoryMB = peakMemoryMB
        self.minimumDeviceClass = minimumDeviceClass
    }

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
    }
}

public extension TTSModelDescriptor {
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

public struct TTSVoice: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public init(stringLiteral value: StringLiteralType) {
        self.identifier = value
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
