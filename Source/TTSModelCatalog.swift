import Foundation

public enum TTSModelSupportStage: String, Sendable, Hashable, Codable, CaseIterable {
    case planned
    case implemented
    case validated

    public var title: String {
        switch self {
        case .planned:
            "Planned"
        case .implemented:
            "Implemented"
        case .validated:
            "Validated"
        }
    }
}

public struct TTSModelCatalogEntry: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let supportStage: TTSModelSupportStage
    public let supportedLanguages: [TTSLanguage]
    public let runtimeNotes: String?
    public let modelURL: URL?
    public let projectURL: URL?
    public let descriptor: TTSModelDescriptor?
    /// Licence of the weights; the descriptor carries the same value.
    public let license: TTSModelLicense

    public init(
        id: String,
        displayName: String,
        summary: String,
        supportStage: TTSModelSupportStage,
        supportedLanguages: [TTSLanguage] = [],
        runtimeNotes: String? = nil,
        modelURL: URL? = nil,
        projectURL: URL? = nil,
        descriptor: TTSModelDescriptor? = nil,
        license: TTSModelLicense = .unknown
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.supportStage = supportStage
        self.supportedLanguages = supportedLanguages
        self.runtimeNotes = runtimeNotes
        self.modelURL = modelURL
        self.projectURL = projectURL
        self.license = license
        self.descriptor = descriptor.map { $0.license == nil ? $0.withLicense(license) : $0 }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            displayName: try c.decode(String.self, forKey: .displayName),
            summary: try c.decode(String.self, forKey: .summary),
            supportStage: try c.decode(TTSModelSupportStage.self, forKey: .supportStage),
            supportedLanguages: try c.decodeIfPresent([TTSLanguage].self, forKey: .supportedLanguages) ?? [],
            runtimeNotes: try c.decodeIfPresent(String.self, forKey: .runtimeNotes),
            modelURL: try c.decodeIfPresent(URL.self, forKey: .modelURL),
            projectURL: try c.decodeIfPresent(URL.self, forKey: .projectURL),
            descriptor: try c.decodeIfPresent(TTSModelDescriptor.self, forKey: .descriptor),
            license: try c.decodeIfPresent(TTSModelLicense.self, forKey: .license) ?? .unknown)
    }
}
