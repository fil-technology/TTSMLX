import Foundation
import Testing
@testable import TTSMLX

@Suite("TTSDeviceProfile + isSupported")
struct TTSDeviceProfileTests {
    @Test("TTSDeviceClass orders by memory rank")
    func deviceClassOrder() {
        #expect(TTSDeviceClass.iPhone < .iPad)
        #expect(TTSDeviceClass.iPad < .mac)
        #expect(TTSDeviceClass.mac >= .iPad)
    }

    @Test("isSupported gates on minimumDeviceClass")
    func minClassGate() {
        let model = TTSModelDescriptor(
            id: "x",
            capabilities: .init(
                isRuntimeSupported: true,
                peakMemoryMB: 200,
                minimumDeviceClass: .iPad
            )
        )
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 8_000)
        let pad = TTSDeviceProfile(deviceClass: .iPad, physicalMemoryMB: 8_000)
        #expect(!model.isSupported(on: phone))
        #expect(model.isSupported(on: pad))
    }

    @Test("isSupported gates on peakMemoryMB")
    func memoryGate() {
        let model = TTSModelDescriptor(
            id: "x",
            capabilities: .init(
                isRuntimeSupported: true,
                peakMemoryMB: 4_000,
                minimumDeviceClass: .iPhone
            )
        )
        let small = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 2_000)
        let big = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 8_000)
        #expect(!model.isSupported(on: small))
        #expect(model.isSupported(on: big))
    }

    @Test("isSupported allows unknown capability data (no false negatives)")
    func unknownDataAllows() {
        let model = TTSModelDescriptor(id: "x", capabilities: .init(isRuntimeSupported: true))
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 1_000)
        #expect(model.isSupported(on: phone))
    }

    @Test("Pocket TTS is blocked on iPhone in the validated catalog")
    func pocketBlockedOnPhone() {
        let pocket = TTSMLX.supportedModels.first { $0.id == "mlx-community/pocket-tts" }!
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_000)
        let pad = TTSDeviceProfile(deviceClass: .iPad, physicalMemoryMB: 6_000)
        #expect(!pocket.isSupported(on: phone))
        #expect(pocket.isSupported(on: pad))
    }

    @Test("recommendedModel prefers higher quality among models that fit")
    func recommendedModelRanking() {
        let iPhone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_000)
        let recommended = TTSMLX.recommendedModel(for: iPhone)
        #expect(recommended != nil)
        // Must not pick Pocket (iPad-only) or Orpheus (mac-only) on iPhone.
        #expect(recommended?.id != "mlx-community/pocket-tts")
        #expect(recommended?.id != "mlx-community/orpheus-3b-0.1-ft-bf16")
    }

    @Test("recommendedModel falls back when nothing fits the profile")
    func recommendedFallback() {
        let tiny = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 50)
        // Every catalog model has a peak > 50MB, so no candidate fits — should still
        // return something (best-effort) rather than nil.
        #expect(TTSMLX.recommendedModel(for: tiny) != nil)
    }
}
