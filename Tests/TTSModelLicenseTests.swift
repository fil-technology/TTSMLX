import Foundation
import Testing
@testable import TTSMLX

@Suite("Model licences and usage tiers")
struct TTSModelLicenseTests {
    @Test("every catalog entry declares a licence and its descriptor carries it")
    func catalogIsAnnotated() throws {
        for entry in TTSMLX.modelCatalog {
            #expect(entry.license.tier != .unknown || entry.id == "mlx-community/VyvoTTS-EN-Beta-4bit", "\(entry.id) has no licence")
            if let d = entry.descriptor {
                #expect(d.license == entry.license, "\(entry.id) descriptor licence differs")
            }
        }
    }

    @Test("supportedModels never contains non-commercial or research weights")
    func supportedModelsAreShippable() {
        for d in TTSMLX.supportedModels {
            let tier = d.license?.tier ?? .unknown
            #expect(tier != .nonCommercial && tier != .researchOnly, "\(d.id) is \(tier)")
        }
    }

    @Test("tiers order from least to most restrictive and gate the model list")
    func tiersGateTheList() {
        #expect(TTSModelUsageTier.commercial < .attributionRequired)
        #expect(TTSModelUsageTier.attributionRequired < .nonCommercial)
        #expect(TTSModelUsageTier.nonCommercial < .researchOnly)
        #expect(TTSModelUsageTier.commercial.allowsCommercialUse && TTSModelUsageTier.attributionRequired.allowsCommercialUse)
        #expect(!TTSModelUsageTier.nonCommercial.allowsCommercialUse && !TTSModelUsageTier.unknown.allowsCommercialUse)
        let commercial = TTSMLX.models(maximumTier: .commercial).map(\.id)
        let withAttribution = TTSMLX.models(maximumTier: .attributionRequired).map(\.id)
        let personal = TTSMLX.models(maximumTier: .nonCommercial).map(\.id)
        #expect(!commercial.contains("mlx-community/pocket-tts"))
        #expect(withAttribution.contains("mlx-community/pocket-tts"))
        #expect(!withAttribution.contains("mlx-community/VyvoTTS-EN-Beta-4bit"))
        #expect(Set(commercial).isSubset(of: Set(withAttribution)) && Set(withAttribution).isSubset(of: Set(personal)))
        // Discovery-only entries have no descriptor, so a non-commercial model
        // only appears once it has been validated and given one.
        #expect(personal.allSatisfy { id in TTSMLX.modelCatalog.first { $0.id == id }?.descriptor != nil })
    }

    @Test("licences encode, decode and survive an entry without the key")
    func coding() throws {
        let entry = try #require(TTSMLX.modelCatalog.first { $0.id == "mlx-community/pocket-tts" })
        #expect(entry.license.tier == .attributionRequired && entry.license.note?.contains("Kyutai") == true)
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(TTSModelCatalogEntry.self, from: data)
        #expect(back.license == entry.license && back.descriptor?.license == entry.license)
        let legacy = #"{"id":"x/y","displayName":"Y","summary":"s","supportStage":"planned"}"#
        let old = try JSONDecoder().decode(TTSModelCatalogEntry.self, from: Data(legacy.utf8))
        #expect(old.license.tier == .unknown)
    }

    @Test("non-commercial entries are validated but gated behind the tier")
    func nonCommercialEntries() throws {
        let voxtral = try #require(TTSMLX.modelCatalog.first { $0.id == "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit" })
        let d = try #require(voxtral.descriptor)
        #expect(voxtral.license.tier == .nonCommercial && d.license?.tier == .nonCommercial)
        #expect(d.suggestedVoices.count == 20 && d.suggestedVoices.allSatisfy { $0.language != nil && $0.gender != nil })
        #expect(d.suggestedVoices.first { $0 == "fr_female" }?.language == .french)
        #expect(!d.capabilities.supportsReferenceAudio && !d.features.contains(.emotion))
        let omni = try #require(TTSMLX.modelCatalog.first { $0.id == "mlx-community/OmniVoice" }?.descriptor)
        #expect(omni.features.isSuperset(of: [.voiceDesign, .instruction, .voiceCloning, .referenceTranscript]))
        let shippable = Set(TTSMLX.supportedModels.map(\.id)), personal = Set(TTSMLX.models(maximumTier: .nonCommercial).map(\.id))
        #expect(!shippable.contains(d.id) && !shippable.contains(omni.id))
        #expect(personal.contains(d.id) && personal.contains(omni.id))
        #expect(!TTSMLX.models(maximumTier: .nonCommercial).contains { $0.id == "bosonai/higgs-tts-3-4b" })
    }
}
