import Foundation
import Testing
@testable import TTSMLX

@Suite("Voice profiles")
struct TTSVoiceProfileTests {
    @Test("Structured voice design compiles into one readable description")
    func designDescription() {
        let design = TTSVoiceDesign(
            gender: .male, age: .mature, pitch: .deep, qualities: ["warm", "slightly raspy"],
            emotion: "calm and reassuring", pace: .slow, style: "narrator",
            custom: "natural pauses")
        #expect(design.description == "A mature male narrator, deep-pitched, warm, slightly raspy voice, calm and reassuring delivery, slow speaking pace, natural pauses")
        #expect(TTSVoiceDesign().isEmpty)
        #expect(TTSVoiceDesign(gender: .female).description == "A female speaker")
        #expect(TTSVoiceDesign(accent: "Scottish").description == "Scottish accent")
    }

    @Test("A designed profile fills options the caller left open and never overrides theirs")
    func designedProfileApplies() {
        let profile = TTSVoiceProfile(
            name: "Narrator", kind: .designed(description: "A calm narrator"),
            modelID: "mlx-community/VoxCPM2-4bit", language: .english, speed: .slow,
            diffusionSteps: 16, guidanceScale: 2.2, seed: 7)
        let options = profile.apply()
        #expect(options.voice == TTSVoice("A calm narrator"))
        #expect(options.language == .english)
        #expect(options.speed == .slow)
        #expect(options.diffusionSteps == 16 && options.guidanceScale == 2.2 && options.seed == 7)
        #expect(options.referenceAudio == nil)

        let kept = profile.apply(to: .init(language: .german, seed: 1))
        #expect(kept.language == .german && kept.seed == 1)
        #expect(!profile.usesRecording)
    }

    @Test("Cloned profiles carry the clip, the transcript, and need consent to be stored")
    func clonedProfiles() async throws {
        let clip = URL(fileURLWithPath: "/tmp/me.wav")
        let hifi = TTSVoiceProfile(
            name: "Me", kind: .highFidelity(referenceURL: clip, transcript: "Hello there."),
            modelID: "mlx-community/VoxCPM2-4bit")
        let options = hifi.apply()
        #expect(options.referenceAudio == clip && options.referenceText == "Hello there.")
        #expect(hifi.usesRecording && hifi.referenceURL == clip)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ttsmlx-profiles-\(UUID().uuidString)")
        let store = TTSVoiceProfileStore(directory: dir)
        await #expect(throws: TTSVoiceProfileStore.StoreError.consentRequired("Me")) {
            try await store.save(hifi)
        }
        var consented = hifi
        consented.consent = .init(speaker: "me", basis: "own voice", recordedAt: Date(timeIntervalSince1970: 1_762_700_000.25))
        consented.createdAt = Date(timeIntervalSince1970: 1_762_700_000.5)
        try await store.save(consented)
        let loaded = try await store.load(hifi.id)
        #expect(loaded == consented)
        #expect(try await store.all().count == 1)
        try await store.delete(hifi.id)
        #expect(try await store.all().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Variants keep the recipe and change only the seed")
    func variants() {
        let base = TTSVoiceProfile(name: "Host", kind: .designed(description: "A bright host"), modelID: "m")
        let variants = base.variants(seeds: [1, 2, 3])
        #expect(variants.map(\.seed) == [1, 2, 3])
        #expect(Set(variants.map(\.id)).count == 3)
        #expect(variants.allSatisfy { $0.kind == base.kind })
    }

    @Test("Profiles round-trip through JSON")
    func codable() throws {
        let profile = TTSVoiceProfile(
            name: "Me", kind: .cloned(referenceURL: URL(fileURLWithPath: "/tmp/me.wav")),
            modelID: "m", modelRevision: "abc", emotion: .happy,
            consent: .init(speaker: "me", basis: "own voice", recordedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(TTSVoiceProfile.self, from: encoder.encode(profile))
        #expect(copy.kind == profile.kind && copy.consent == profile.consent && copy.emotion == .happy)
    }
}
