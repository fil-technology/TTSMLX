import Foundation

/// What a model's licence lets an app do, least restrictive first.
///
/// `TTSMLX.supportedModels` only ever contains tiers that allow commercial
/// use; the non-commercial and research tiers are reachable through
/// `TTSMLX.models(maximumTier:)` so an app has to opt in explicitly.
public enum TTSModelUsageTier: String, Sendable, Codable, Hashable, CaseIterable, Comparable {
    /// MIT, Apache-2.0 and similar: use anywhere, no conditions worth noting.
    case commercial
    /// CC-BY and similar: commercial use is fine, credit the model.
    case attributionRequired
    /// CC-BY-NC, CC-BY-NC-SA: personal and non-monetised use only. A video
    /// that is monetised, sponsored or promotes a product is commercial.
    case nonCommercial
    /// Research licences: no deployment and no published outputs.
    case researchOnly
    /// No licence published; treat as non-commercial until one is.
    case unknown

    public var allowsCommercialUse: Bool {
        self == .commercial || self == .attributionRequired
    }

    public var displayName: String {
        switch self {
        case .commercial: "commercial"
        case .attributionRequired: "attribution required"
        case .nonCommercial: "non-commercial"
        case .researchOnly: "research only"
        case .unknown: "licence unknown"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The licence of a model's weights (the runtime code is MIT regardless).
public struct TTSModelLicense: Sendable, Hashable, Codable {
    /// SPDX-style name: "MIT", "Apache-2.0", "CC-BY-NC-4.0".
    public let name: String
    public let tier: TTSModelUsageTier
    public let url: URL?
    /// Anything a caller should know before shipping: who to credit, which
    /// clause bites, why the tier is what it is.
    public let note: String?

    public init(name: String, tier: TTSModelUsageTier, url: URL? = nil, note: String? = nil) {
        self.name = name
        self.tier = tier
        self.url = url
        self.note = note
    }

    public var allowsCommercialUse: Bool { tier.allowsCommercialUse }

    public static let mit = TTSModelLicense(name: "MIT", tier: .commercial, url: URL(string: "https://opensource.org/license/mit"))
    public static let apache2 = TTSModelLicense(name: "Apache-2.0", tier: .commercial, url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"))
    public static func ccBy4(credit: String) -> TTSModelLicense {
        TTSModelLicense(name: "CC-BY-4.0", tier: .attributionRequired,
                        url: URL(string: "https://creativecommons.org/licenses/by/4.0/"), note: "Credit \(credit).")
    }
    public static let ccByNc4 = TTSModelLicense(name: "CC-BY-NC-4.0", tier: .nonCommercial,
                                                 url: URL(string: "https://creativecommons.org/licenses/by-nc/4.0/"))
    public static let ccByNcSa4 = TTSModelLicense(name: "CC-BY-NC-SA-4.0", tier: .nonCommercial,
                                                   url: URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/"))
    public static let unknown = TTSModelLicense(name: "unknown", tier: .unknown, note: "No licence is published for these weights.")
    public static func researchOnly(name: String, url: URL?, note: String) -> TTSModelLicense {
        TTSModelLicense(name: name, tier: .researchOnly, url: url, note: note)
    }
}
