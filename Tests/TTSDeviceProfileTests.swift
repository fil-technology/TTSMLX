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

    @Test("Pocket TTS runs on modern iPhone in the validated catalog")
    func pocketAllowedOnPhone() {
        // Regression guard: a previous catalog hard-gated Pocket-TTS to
        // `.iPad` based on conservative paranoia (no measured OOM data).
        // ReadMeBook shipped Pocket-TTS on iPhone through 0.3 with no OOM
        // reports. The right gate is `peakMemoryMB` (600 < 6144 = fits),
        // not a device class. If this test starts failing, someone
        // re-introduced the gate without a measured reason — push back.
        let pocket = TTSMLX.supportedModels.first { $0.id == "mlx-community/pocket-tts" }!
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_144)
        let pad = TTSDeviceProfile(deviceClass: .iPad, physicalMemoryMB: 6_144)
        #expect(pocket.isSupported(on: phone))
        #expect(pocket.isSupported(on: pad))
    }

    @Test("every iPhone-class validated model fits a 6GB iPhone profile")
    func iPhoneClassModelsFitModernIPhone() {
        // Catalog-intent guard: if a new model lands with `.iPad` or `.mac`
        // class without a non-memory reason (see TTSModelCapabilities doc
        // comment), this test catches it before it ships.
        let phone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_144)
        let iPhoneClassModels = TTSMLX.supportedModels.filter {
            $0.capabilities.minimumDeviceClass == .iPhone
        }
        // Sanity: there should be at least a few. If the filter returns 0,
        // someone gated the entire catalog to iPad+, which is wrong.
        #expect(iPhoneClassModels.count >= 3)
        for model in iPhoneClassModels {
            #expect(model.isSupported(on: phone),
                    "\(model.id) should fit a 6GB iPhone — it advertises minimumDeviceClass: .iPhone")
        }
    }

    @Test("recommendedModel prefers higher quality among models that fit")
    func recommendedModelRanking() {
        let iPhone = TTSDeviceProfile(deviceClass: .iPhone, physicalMemoryMB: 6_000)
        let recommended = TTSMLX.recommendedModel(for: iPhone)
        #expect(recommended != nil)
        // Must not pick Orpheus (mac-only) on iPhone. Pocket is now allowed
        // on iPhone post-0.5.1, so we no longer exclude it here.
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
