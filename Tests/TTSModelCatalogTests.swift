import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSModelCatalog — multilingual expansion")
struct TTSModelCatalogTests {
    private func entry(_ id: String) -> TTSModelCatalogEntry? {
        TTSMLX.modelCatalog.first { $0.id == id }
    }

    @Test("Qwen3-TTS variants are present, implemented, multilingual, with descriptors")
    func qwen3VariantsPresent() throws {
        let ids = [
            "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit",
            "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit",
            "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
        ]
        for id in ids {
            let e = try #require(entry(id), "missing catalog entry: \(id)")
            #expect(e.supportStage == .implemented)
            let descriptor = try #require(e.descriptor, "\(id) must carry a descriptor to be selectable")
            #expect(descriptor.capabilities.isRuntimeSupported)
            // Multilingual: more than just English.
            #expect(descriptor.supportedLanguages.count > 1)
            #expect(descriptor.supportedLanguages.contains(.english))
            #expect(descriptor.supportedLanguages.contains(.japanese))
        }
    }

    @Test("CustomVoice variant advertises reference-audio support")
    func customVoiceSupportsReferenceAudio() throws {
        let e = try #require(entry("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"))
        let descriptor = try #require(e.descriptor)
        #expect(descriptor.capabilities.supportsReferenceAudio)
    }

    @Test("Soprano-80M-4bit is a tiny, fast English entry")
    func sopranoFastVariant() throws {
        let e = try #require(entry("mlx-community/Soprano-80M-4bit"))
        let descriptor = try #require(e.descriptor)
        #expect(e.supportStage == .implemented)
        #expect(descriptor.capabilities.defaultGenerationProfile == .fast)
        #expect((descriptor.capabilities.peakMemoryMB ?? .max) < 400)
    }

    @Test("implemented entries stay out of the validated default set")
    func implementedNotInDefaults() {
        let validatedIDs = Set(TTSMLX.supportedModels.map(\.id))
        // Newly added implemented models must not auto-appear as defaults
        // (and thus not be auto-picked by recommendedModel) until validated.
        #expect(!validatedIDs.contains("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit"))
        #expect(!validatedIDs.contains("mlx-community/Soprano-80M-4bit"))
        // The validated multilingual default is still present.
        #expect(validatedIDs.contains("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"))
    }

    @Test("recommendedModel only returns validated, device-fitting models")
    func recommendedModelIsValidated() {
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_000)
        let pick = TTSMLX.recommendedModel(for: phone)
        let validatedIDs = Set(TTSMLX.supportedModels.map(\.id))
        if let pick { #expect(validatedIDs.contains(pick.id)) }
    }
}

@Suite("TTSDeviceProfile — look-ahead window")
struct TTSDeviceProfileLookAheadTests {
    @Test("look-ahead scales with device memory and class")
    func lookAheadScales() {
        #expect(TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 3_000).recommendedLookAheadSeconds == 12)
        #expect(TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 4_000).recommendedLookAheadSeconds == 18)
        #expect(TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_000).recommendedLookAheadSeconds == 24)
        #expect(TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 8_000).recommendedLookAheadSeconds == 30)
        #expect(TTSDeviceProfile(deviceClass: .mac, physicalMemoryMB: 16_000).recommendedLookAheadSeconds == 45)
    }

    @Test("look-ahead is always a positive, finite window")
    func lookAheadPositive() {
        for klass in TTSDeviceClass.allCases {
            for mem in [2_000, 4_000, 6_000, 8_000, 16_000] {
                let window = TTSDeviceProfile(deviceClass: klass, physicalMemoryMB: mem).recommendedLookAheadSeconds
                #expect(window > 0)
                #expect(window <= 60)
            }
        }
    }
}
