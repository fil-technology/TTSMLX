import SwiftUI
import TTSMLX

#if os(iOS)
import UIKit

/// Exists solely to hand background-download events back to TTSMLX.
///
/// A background `URLSession` finishes its work while the app is suspended, or
/// after relaunching it in the background. iOS delivers that through the app
/// delegate, and the completion handler must be called once the app has
/// finished processing — SwiftUI has no equivalent hook, hence the adaptor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit hands back a non-Sendable closure; the downloader stores it
        // and invokes it on the main queue, which is where UIKit requires it,
        // so carrying it across is safe.
        nonisolated(unsafe) let handler = completionHandler
        TTSBackgroundModelDownloader.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: { handler() }
        )
    }
}
#endif

@main
struct TTSMLXDemoApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // `--moss-validation` turns the app into the on-device validation
        // runner (URGENT item 3): Xcode cannot host package tests on a device,
        // so the measurement runs inside the app and prints to the console.
        if ProcessInfo.processInfo.arguments.contains("--moss-validation") {
            Task.detached { await MossDeviceValidation.run() }
        }
    }

    var body: some Scene {
        WindowGroup {
            TabRootView()
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 680)
                #endif
        }
    }
}

import AVFoundation
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

/// Mirrors `Tests/MossDeviceValidationTests.swift` for a real device: download
/// (or reuse) MOSS-TTS-Nano, run the Reader path over several passages and
/// print one `[moss-device]` line per trial plus a summary, then exit. Launch:
///
///     xcrun devicectl device process launch --device <udid> --console \
///       --environment-variables '{"MOSS_TRIALS":"5"}' \
///       com.filtechnology.ttsmlx.demo.ios --moss-validation
///
/// The lines are also written to `Documents/moss-validation.txt` in the app
/// container in case the console session drops.
enum MossDeviceValidation {
    static let modelID = "mlx-community/MOSS-TTS-Nano-100M"
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

    static func run() async {
        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("moss-validation.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let trials = Int(ProcessInfo.processInfo.environment["MOSS_TRIALS"] ?? "") ?? 5
        let profile: TTSGenerationProfile? = switch ProcessInfo.processInfo.environment["MOSS_PROFILE"] {
            case "fast": .fast
            case "balanced": .balanced
            case "highQuality": .highQuality
            default: nil
        }
        do {
            guard let descriptor = TTSMLX.modelCatalog.first(where: { $0.id == modelID })?.descriptor else {
                log("[moss-device] no descriptor for \(modelID)"); exit(1)
            }
            let store = TTSModelStore()
            let synthesizer = TTSSpeechSynthesizer(modelStore: store)
            let prepareStart = Date()
            let installed = try await store.ensureDownloaded(descriptor) { update in
                if update.stage == .downloadingModel, let fraction = update.fractionCompleted, Int(fraction * 100) % 25 == 0 {
                    print("[moss-device] downloading \(Int(fraction * 100))%")
                }
            }
            let purgeable = installed.location.pathComponents.contains("Caches")
            log(String(format: "[moss-device] device=%@ os=%@ model=%@ sizeMB=%d durable=%@ prepare=%.1fs",
                       deviceModel(), ProcessInfo.processInfo.operatingSystemVersionString, installed.location.path,
                       Int(installed.sizeBytes / 1_000_000), purgeable ? "NO" : "yes", Date().timeIntervalSince(prepareStart)))

            struct Trial { var firstAudio: TimeInterval; var audio: Double; var wall: Double; var overruns: Int; var peakMB: Double; var residentMB: Double }
            var results: [Trial] = []
            for index in 0..<trials {
                let text = passages[index % passages.count]
                TTSRuntimeMemory.resetPeak()
                let started = Date()
                var firstAudio: TimeInterval?
                var frames = 0, chunks = 0, overruns = 0
                var longestTail = 0.0, sampleRate = 48_000.0
                let stream = try await synthesizer.synthesizeLong(text, using: descriptor, options: .init(generationProfile: profile))
                for try await chunk in stream {
                    if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
                    frames += Int(chunk.buffer.frameLength)
                    chunks += 1
                    sampleRate = chunk.buffer.format.sampleRate
                    let tail = trailingSilence(chunk.buffer)
                    longestTail = max(longestTail, tail)
                    if tail > 2 { overruns += 1 }
                }
                let wall = Date().timeIntervalSince(started)
                let audio = Double(frames) / sampleRate
                let trial = Trial(firstAudio: firstAudio ?? -1, audio: audio, wall: wall, overruns: overruns,
                                  peakMB: Double(TTSRuntimeMemory.current().peakBytes) / 1_048_576, residentMB: residentMB())
                results.append(trial)
                log(String(format: "[moss-device] trial=%d firstAudio=%.2fs audio=%.1fs wall=%.1fs rtf=%.2fx chunks=%d overruns=%d longestTail=%.1fs mlxPeak=%.0fMB active=%.0fMB cache=%.0fMB resident=%.0fMB available=%@",
                           index, trial.firstAudio, audio, wall, audio / wall, chunks, overruns, longestTail, trial.peakMB,
                           Double(TTSRuntimeMemory.current().activeBytes) / 1_048_576, Double(TTSRuntimeMemory.current().cacheBytes) / 1_048_576,
                           trial.residentMB, availableMemoryDescription()))
            }
            let rtfs = results.map { $0.audio / $0.wall }.sorted()
            log(String(format: "[moss-device] summary trials=%d medianRTF=%.2fx warmFirstAudio=%.2fs maxMLXPeak=%.0fMB maxResident=%.0fMB overruns=%d/%d",
                       results.count, rtfs.isEmpty ? 0 : rtfs[rtfs.count / 2],
                       results.dropFirst().map(\.firstAudio).min() ?? results.first?.firstAudio ?? -1,
                       results.map(\.peakMB).max() ?? 0, results.map(\.residentMB).max() ?? 0,
                       results.map(\.overruns).reduce(0, +), results.count))
            log("[moss-device] DONE")
            exit(0)
        } catch {
            log("[moss-device] FAILED: \(error)")
            exit(2)
        }
    }

    static func trailingSilence(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var index = count
        while index > 0, abs(channel[index - 1]) < 1e-3 { index -= 1 }
        return Double(count - index) / buffer.format.sampleRate
    }

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

    static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }
}
