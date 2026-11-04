import AVFoundation
import Foundation
import Testing
@preconcurrency import MLX
@testable import TTSMLX
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

/// Validation run for MOSS-TTS-Nano (URGENT item 3): the Reader path end to
/// end, several times, with the numbers a device decision needs — first-audio
/// latency, realtime factor, MLX peak/active/cache, process footprint, and
/// whether any chunk ran to the frame budget with silence (end-of-audio miss).
///
/// Off by default. Enable with `MOSS_DEVICE=1` in the environment; optional
/// `MOSS_TRIALS=N` (default 3) and `MOSS_PROFILE=fast|balanced|highQuality`.
/// `xcodebuild` forwards variables prefixed `TEST_RUNNER_` to the test host,
/// which is how it reaches a device:
///
///     TEST_RUNNER_MOSS_DEVICE=1 TEST_RUNNER_MOSS_TRIALS=5 xcodebuild test \
///       -project DemoApp/TTSMLXDemo.xcodeproj -scheme TTSMLX \
///       -destination 'id=<device udid>' -only-testing:TTSMLXTests/MossDeviceValidationTests
///
/// The model (~375 MB) is downloaded when missing. A marker file at
/// `Tests/.moss-device` also enables it on the host (plain `swift test` has no
/// Metal library, so run it through `xcodebuild` there too).
@Suite("MOSS-TTS-Nano device validation", .serialized)
struct MossDeviceValidationTests {
    static let modelID = "mlx-community/MOSS-TTS-Nano-100M"

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["MOSS_DEVICE"] == "1" { return true }
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".moss-device")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    static var trials: Int { Int(ProcessInfo.processInfo.environment["MOSS_TRIALS"] ?? "") ?? 3 }

    static var profile: TTSGenerationProfile? {
        switch ProcessInfo.processInfo.environment["MOSS_PROFILE"] {
        case "fast": .fast
        case "balanced": .balanced
        case "highQuality": .highQuality
        default: nil
        }
    }

    /// A news paragraph of the size the Reader feeds per article section.
    static let passages = [
        """
        Global markets closed higher on Tuesday after the central bank signalled it would hold \
        interest rates steady through the end of the year. Analysts said the decision eased fears \
        of a prolonged slowdown, though several cautioned that inflation remains above target. \
        The index gained one point two percent on the session.
        """,
        """
        The city council approved the new transit plan late on Monday, ending months of debate. \
        Construction on the first two lines is expected to begin next spring, with service \
        starting in twenty twenty-nine. Critics argued the budget leaves little room for the \
        bus network, which carries most of the city's riders today.
        """,
        """
        Researchers reported that the coral colonies recovered faster than expected after the \
        summer heat wave. Water temperatures fell back to normal in September, and by November \
        most of the surveyed reefs showed new growth. The team will return in March to check \
        whether the recovery holds through the next warm season.
        """,
    ]

    @Test("download, load and synthesize several passages; report latency, throughput, memory and end-of-audio")
    func validate() async throws {
        guard Self.isEnabled else { return }
        let entry = try #require(TTSMLX.modelCatalog.first { $0.id == Self.modelID })
        let descriptor = try #require(entry.descriptor)
        let store = TTSModelStore()
        let synthesizer = TTSSpeechSynthesizer(modelStore: store)

        let downloadStart = Date()
        let installed = try await store.ensureDownloaded(descriptor)
        let durable = !TTSModelStore.isPurgeable(installed.location)
        print(String(
            format: "[moss-device] model=%@ sizeMB=%d durable=%@ prepare=%.1fs",
            installed.location.path, Int(installed.sizeBytes / 1_000_000), durable ? "yes" : "no",
            Date().timeIntervalSince(downloadStart)))
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        #expect(durable, "model landed in a purgeable directory: \(installed.location.path)")
        #endif

        struct Trial { var firstAudio: TimeInterval; var audio: Double; var wall: Double; var overruns: Int; var peakMB: Double; var residentMB: Double }
        var results: [Trial] = []

        for index in 0..<Self.trials {
            let text = Self.passages[index % Self.passages.count]
            MLX.GPU.resetPeakMemory()
            let started = Date()
            var firstAudio: TimeInterval?
            var frames = 0, chunks = 0, overruns = 0
            var longestTail = 0.0
            var sampleRate = 48_000.0

            let stream = try await synthesizer.synthesizeLong(
                text, using: descriptor, options: .init(generationProfile: Self.profile))
            for try await chunk in stream {
                if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
                frames += Int(chunk.buffer.frameLength)
                chunks += 1
                sampleRate = chunk.buffer.format.sampleRate
                let tail = Self.trailingSilence(chunk.buffer)
                longestTail = max(longestTail, tail)
                // A missed end-of-audio fills the rest of the 375-frame budget
                // (about 30 s) with silence; real pauses are well under 2 s.
                if tail > 2 { overruns += 1 }
            }

            let wall = Date().timeIntervalSince(started)
            let audio = Double(frames) / sampleRate
            let trial = Trial(
                firstAudio: firstAudio ?? -1, audio: audio, wall: wall, overruns: overruns,
                peakMB: Double(MLX.GPU.peakMemory) / 1_048_576, residentMB: Self.residentMB())
            results.append(trial)
            print(String(
                format: "[moss-device] trial=%d firstAudio=%.2fs audio=%.1fs wall=%.1fs rtf=%.2fx chunks=%d "
                    + "overruns=%d longestTail=%.1fs mlxPeak=%.0fMB active=%.0fMB cache=%.0fMB resident=%.0fMB available=%@",
                index, trial.firstAudio, audio, wall, audio / wall, chunks, overruns, longestTail,
                trial.peakMB, Double(MLX.Memory.activeMemory) / 1_048_576,
                Double(MLX.Memory.cacheMemory) / 1_048_576, trial.residentMB, Self.availableMemoryDescription()))
            #expect(chunks > 0 && audio > 1, "trial \(index) produced no audio")
        }

        let rtfs = results.map { $0.audio / $0.wall }.sorted()
        print(String(
            format: "[moss-device] summary trials=%d medianRTF=%.2fx warmFirstAudio=%.2fs maxMLXPeak=%.0fMB maxResident=%.0fMB overruns=%d/%d",
            results.count, rtfs[rtfs.count / 2], results.dropFirst().map(\.firstAudio).min() ?? results[0].firstAudio,
            results.map(\.peakMB).max() ?? 0, results.map(\.residentMB).max() ?? 0,
            results.map(\.overruns).reduce(0, +), results.count))
    }

    /// Seconds of near-silence at the end of a buffer.
    static func trailingSilence(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var index = count
        while index > 0, abs(channel[index - 1]) < 1e-3 { index -= 1 }
        return Double(count - index) / buffer.format.sampleRate
    }

    /// Physical footprint of this process in MB (what iOS jetsam judges by).
    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func availableMemoryDescription() -> String {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return String(format: "%.0fMB", Double(os_proc_available_memory()) / 1_048_576)
        #else
        return "n/a"
        #endif
    }
}
