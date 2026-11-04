import Foundation
import Testing
@testable import TTSMLX

@Suite("Uniform model controls")
struct TTSModelControlsTests {
    private func entry(_ id: String) -> TTSModelCatalogEntry? {
        TTSMLX.modelCatalog.first { $0.id == id }
    }

    @Test("Canonical event markers are rewritten into the model's spelling or dropped")
    func eventTagRewrite() {
        let text = "Oh no \(TTSEventTag.laugh), really? \(TTSEventTag.yawn) Fine."
        #expect(TTSEventTag.rewrite(text, using: [.laugh: "<laugh>"]) == "Oh no <laugh>, really? Fine.")
        #expect(TTSEventTag.rewrite(text, using: [:]) == "Oh no, really? Fine.")
        #expect(TTSEventTag.rewrite("no tags here", using: [:]) == "no tags here")
        #expect(TTSEventTag.markers(in: text) == [.laugh, .yawn])
        #expect(TTSEventTag.clearThroat.marker == "[clearThroat]")
    }

    @Test("Implied features come from the boolean fields, tags and voices")
    func impliedFeatures() {
        let c = TTSModelCapabilities(
            isRuntimeSupported: true, supportsReferenceAudio: true, supportsLanguageList: true,
            supportedLanguages: [.english, .french], supportsStreaming: true,
            features: [.emotion], eventTags: [.laugh: "[laugh]"])
        #expect(c.features == [.emotion, .streaming, .voiceCloning, .multilingual, .eventTags])
        #expect(c.sortedFeatures == [.streaming, .voiceCloning, .multilingual, .eventTags, .emotion])
        let d = TTSModelDescriptor(
            id: "x/y", displayName: "Y", summary: nil, supportedLanguages: [.english],
            suggestedVoices: ["a"], capabilities: c)
        #expect(d.features.contains(.builtInVoices))
        #expect(d.supportedEventTags == [.laugh])
    }

    @Test("Voices compare by identifier and round-trip their metadata")
    func voiceMetadata() throws {
        let voice = TTSVoice("af_heart", displayName: "Heart", language: .english, gender: .female, summary: "American")
        #expect(voice == "af_heart")
        #expect(voice.name == "Heart")
        #expect(TTSVoice("plain").name == "plain")
        let data = try JSONEncoder().encode(voice)
        let decoded = try JSONDecoder().decode(TTSVoice.self, from: data)
        #expect(decoded.gender == .female && decoded.language == .english && decoded.summary == "American")
        // Older encodings carried the identifier only.
        let legacy = try JSONDecoder().decode(TTSVoice.self, from: Data(#"{"identifier":"alba"}"#.utf8))
        #expect(legacy == .alba && legacy.displayName == nil)
    }

    @Test("Capabilities decode without the new keys and encode the tag table as an object")
    func capabilitiesCoding() throws {
        let legacy = #"{"isRuntimeSupported":true,"supportsReferenceAudio":false,"supportsLanguageList":true,"supportedLanguages":[{"identifier":"English"}],"defaultGenerationProfile":"balanced"}"#
        let c = try JSONDecoder().decode(TTSModelCapabilities.self, from: Data(legacy.utf8))
        #expect(c.features == [.streaming])
        #expect(c.eventTags.isEmpty && c.sampleRate == nil)
        let ming = try #require(entry("mlx-community/Ming-3.0-tts-0.5B-bf16")?.descriptor)
        let json = try JSONEncoder().encode(ming.capabilities)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let tags = try #require(object["eventTags"] as? [String: String])
        #expect(tags["laugh"] == "[Laughter]")
        let back = try JSONDecoder().decode(TTSModelCapabilities.self, from: json)
        #expect(back == ming.capabilities)
    }

    @Test("Catalog entries advertise their controls")
    func catalogFeatures() throws {
        let ming = try #require(entry("mlx-community/Ming-3.0-tts-0.5B-bf16")?.descriptor)
        #expect(ming.features.isSuperset(of: [.builtInVoices, .voiceCloning, .multilingual, .eventTags, .instruction, .emotion, .speed, .voiceDesign]))
        #expect(ming.capabilities.sampleRate == 44_100)
        #expect(ming.suggestedVoices.first?.gender == .male)
        let kokoro = try #require(entry("mlx-community/Kokoro-82M-bf16")?.descriptor)
        #expect(kokoro.features.contains(.speed) && !kokoro.features.contains(.emotion))
        let heart = try #require(kokoro.suggestedVoices.first { $0 == "af_heart" })
        #expect(heart.gender == .female && heart.language == .english && heart.displayName == "Heart")
        let siwis = try #require(kokoro.suggestedVoices.first { $0 == "ff_siwis" })
        #expect(siwis.language == .french)
        let turbo = try #require(entry("mlx-community/chatterbox-turbo-4bit")?.descriptor)
        #expect(turbo.supportedEventTags.contains(.laugh) && !turbo.features.contains(.emotion))
        let regular = try #require(entry("mlx-community/chatterbox-4bit")?.descriptor)
        #expect(regular.features.contains(.emotion))
        let custom = try #require(entry("mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit")?.descriptor)
        #expect(custom.features.contains(.instruction) && custom.suggestedVoices.allSatisfy { $0.language != nil })
        let orpheus = try #require(entry("mlx-community/orpheus-3b-0.1-ft-bf16")?.descriptor)
        #expect(orpheus.capabilities.eventTags[.laugh] == "<laugh>")
        for d in TTSMLX.modelCatalog.compactMap(\.descriptor) {
            #expect(d.capabilities.sampleRate != nil, "\(d.id) has no sample rate")
            #expect(d.features.contains(.streaming) == d.capabilities.supportsStreaming)
        }
    }

    @Test("Options report controls and only change the cache key when set")
    func optionsControls() {
        #expect(!TTSSynthesisOptions().hasControls)
        #expect(TTSSynthesisOptions().controlsCacheSuffix.isEmpty)
        let o = TTSSynthesisOptions(emotion: .happy, speed: .fast)
        #expect(o.hasControls)
        #expect(o.controlsCacheSuffix == "|instruction=|emotion=happy|speed=fast")
        #expect(TTSSpeed.slow.rate < 1 && TTSSpeed.fast.rate > 1)
        #expect(TTSSpeechSynthesizer.mingEmotion(.happy) == "高兴")
        #expect(TTSSpeechSynthesizer.chatterboxExaggeration(.angry) > TTSSpeechSynthesizer.chatterboxExaggeration(.neutral))
    }
}
