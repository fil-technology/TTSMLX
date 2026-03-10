import Foundation

public struct TTSModelDescriptor: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let summary: String?
    public let supportedLanguages: [TTSLanguage]
    public let suggestedVoices: [TTSVoice]
    public let metadata: TTSModelMetadata?

    public init(
        id: String,
        displayName: String? = nil,
        summary: String? = nil,
        supportedLanguages: [TTSLanguage] = [],
        suggestedVoices: [TTSVoice] = [],
        metadata: TTSModelMetadata? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.summary = summary
        self.supportedLanguages = supportedLanguages
        self.suggestedVoices = suggestedVoices
        self.metadata = metadata
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
