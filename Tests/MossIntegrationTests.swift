import Foundation
import Testing
@testable import TTSMLX

/// Reproduces the demo app's Reader path for MOSS-TTS-Nano on the host, so
/// failures surface here instead of only as a truncated string on device.
@Suite("MOSS-TTS-Nano integration", .serialized)
struct MossIntegrationTests {
    static let modelID = "mlx-community/MOSS-TTS-Nano-100M"

    static var descriptor: TTSModelDescriptor {
        get throws {
            let entry = try #require(TTSMLX.modelCatalog.first(where: { $0.id == modelID }))
            return try #require(entry.descriptor)
        }
    }

    @Test("catalog descriptor is runtime-supported so the store will download it")
    func descriptorIsRuntimeSupported() throws {
        let descriptor = try Self.descriptor
        // TTSModelStore.ensureDownloaded throws .unsupportedModel unless this is set.
        #expect(descriptor.capabilities.isRuntimeSupported)
    }

    /// Opt-in: this one downloads ~375 MB and needs Metal, so it stays out of
    /// the default suite, which is otherwise offline and runs in about a
    /// second. Run with `MOSS_INTEGRATION=1` (and via xcodebuild, so the
    /// metallib is available).
    @Test("full prepare path: download then MLX load")
    func prepareModelPathSucceeds() async throws {
        guard ProcessInfo.processInfo.environment["MOSS_INTEGRATION"] == "1" else { return }
        let descriptor = try Self.descriptor
        let store = TTSModelStore()

        do {
            _ = try await store.ensureDownloaded(descriptor)
        } catch {
            Issue.record("ensureDownloaded failed: \(error) — \(error.localizedDescription)")
            return
        }

        do {
            let model = try await MLXTTSModelLoader.load(descriptor: descriptor, hfToken: nil)
            #expect(model.sampleRate == 48000)
        } catch {
            Issue.record("MLX load failed: \(error) — \(error.localizedDescription)")
        }
    }
}
