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

    public init(
        id: String,
        displayName: String,
        summary: String,
        supportStage: TTSModelSupportStage,
        supportedLanguages: [TTSLanguage] = [],
        runtimeNotes: String? = nil,
        modelURL: URL? = nil,
        projectURL: URL? = nil,
        descriptor: TTSModelDescriptor? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.supportStage = supportStage
        self.supportedLanguages = supportedLanguages
        self.runtimeNotes = runtimeNotes
        self.modelURL = modelURL
        self.projectURL = projectURL
        self.descriptor = descriptor
    }
}
