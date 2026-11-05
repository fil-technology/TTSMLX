import Combine
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
            RunStatus.shared.begin(title: "MOSS-TTS-Nano validation")
            Task.detached { await MossDeviceValidation.run() }
        }
        // `--benchmark` runs the shared harness (`TTSBenchmarkRunner`) on this
        // device for the models in `--models a,b` and exits. See Tools/bench.sh.
        if ProcessInfo.processInfo.arguments.contains("--benchmark") {
            RunStatus.shared.begin(title: "Benchmark")
            Task.detached { await DeviceBenchmark.run() }
        }
    }

    var body: some Scene {
        WindowGroup {
            if RunStatus.shared.isActive {
                RunStatusView()
            } else {
                TabRootView()
                    #if os(macOS)
                    .frame(minWidth: 860, minHeight: 680)
                    #endif
            }
        }
    }
}

/// What an unattended run (benchmark or validation) is doing right now, for
/// the screen of the device it runs on. Also keeps the device awake: a locked
/// phone backgrounds the app, iOS then refuses Metal compute and the run dies.
@MainActor @Observable
final class RunStatus {
    static let shared = RunStatus()

    private(set) var isActive = false
    private(set) var title = ""
    /// The last "doing now" line: preparing, loading, running fixture #n.
    private(set) var stage = "Starting…"
    private(set) var currentModel = ""
    private(set) var completedModels: [String] = []
    private(set) var lines: [String] = []
    private(set) var startedAt = Date()
    private(set) var finished = false
    private(set) var failures = 0

    func begin(title: String) {
        self.title = title
        isActive = true
        startedAt = Date()
        // Too early for the idle timer (no window yet); RunStatusView asserts it.
    }

    func record(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        let body = line.replacingOccurrences(of: "[bench] ", with: "").replacingOccurrences(of: "[moss-device] ", with: "")
        if body.hasPrefix("preparing ") || body.hasPrefix("loading ") || body.hasPrefix("reloading ")
            || body.hasPrefix("running ") || body.hasPrefix("downloading ") || body.hasPrefix("trial=") {
            stage = body
        }
        if body.hasPrefix("preparing "), let model = body.split(separator: " ").dropFirst().first {
            currentModel = String(model)
        }
        if body.hasPrefix("finished "), let model = body.split(separator: " ").dropFirst().first {
            completedModels.append(String(model))
        }
        if body.hasPrefix("FAILED") { failures += 1 }
        if body.hasPrefix("DONE") {
            finished = true
            stage = failures == 0 ? "Done" : "Done with \(failures) failure(s)"
            KeepAwake.set(false)
        }
    }
}

enum KeepAwake {
    /// Disables the idle timer while something that must not be interrupted
    /// runs (an unattended benchmark, or synthesis in the demo tabs).
    @MainActor static func set(_ awake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}

struct RunStatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    private let status = RunStatus.shared
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(status.title).font(.title2.bold())
                Spacer()
                Text(elapsed).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if status.finished {
                    Image(systemName: status.failures == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(status.failures == 0 ? .green : .red)
                } else {
                    ProgressView()
                }
                Text(status.stage).font(.headline)
            }
            if !status.currentModel.isEmpty {
                Text("Model: \(status.currentModel)").font(.subheadline).foregroundStyle(.secondary)
            }
            if !status.completedModels.isEmpty {
                Text("Finished: \(status.completedModels.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Keep this app in front and the phone unlocked: leaving it cancels generation and iOS may kill the run. The screen stays on by itself. Reports: Documents/benchmarks.")
                .font(.footnote).foregroundStyle(.tertiary)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(status.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.replacingOccurrences(of: "[bench] ", with: ""))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                .onChange(of: status.lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding()
        .onAppear { KeepAwake.set(true) }
        .onReceive(clock) {
            now = $0
            // Set at launch the flag does not stick (no window yet) and iOS
            // can reset it; re-assert it every tick while the run is active.
            KeepAwake.set(!status.finished)
        }
        .onChange(of: scenePhase) { _, phase in
            // Evidence for a cancelled trial: the app left the foreground.
            RunStatus.shared.record("[bench] app scene phase: \(phase)")
        }
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(status.startedAt))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
/// On-device driver for the shared benchmark harness. Launch arguments
/// (devicectl rejects environment variables, so everything is an argument):
///
///     --benchmark --models mlx-community/Kokoro-82M-bf16,mlx-community/pocket-tts
///     [--trials 3] [--profile fast|balanced|highQuality]
///     [--fixtures sentence,paragraph,longForm] [--modes narration,stream]
///
/// Reports are written to `Documents/benchmarks/` (JSON plus WAV samples under
/// `audio/`) and every line is printed with a `[bench]` prefix so
/// `devicectl device process launch --console` shows it.
enum DeviceBenchmark {
    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func list(_ name: String) -> [String]? {
        argument(name)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("benchmarks", isDirectory: true)
        let logURL = output.appendingPathComponent("benchmark.log")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logURL)
        let log: @Sendable (String) -> Void = { line in
            print(line)
            Task { @MainActor in RunStatus.shared.record(line) }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            } else {
                try? (line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
        let models = list("--models") ?? TTSMLX.defaultModels.map(\.id)
        let trials = Int(argument("--trials") ?? "") ?? 3
        let profile = argument("--profile").flatMap(TTSGenerationProfile.init(rawValue:))
        let fixtures = list("--fixtures").map { ids in TTSBenchmarkFixture.standard.filter { ids.contains($0.id) } }
            ?? TTSBenchmarkFixture.standard
        let modes = list("--modes")?.compactMap(TTSBenchmarkMode.init(rawValue:)) ?? TTSBenchmarkMode.allCases
        let store = TTSModelStore()
        var failures = 0
        for modelID in models {
            do {
                var configuration = TTSBenchmarkConfiguration(
                    modelID: modelID, fixtures: fixtures, trials: trials, modes: modes, profile: profile)
                configuration.audioOutputDirectory = output
                    .appendingPathComponent("audio", isDirectory: true)
                    .appendingPathComponent(TTSBenchmarkEnvironment.current().device, isDirectory: true)
                let report = try await TTSBenchmarkRunner.run(configuration, store: store, log: log)
                let url = try report.write(into: output)
                log("[bench] wrote \(url.lastPathComponent)")
            } catch {
                failures += 1
                log("[bench] FAILED \(modelID): \(error)")
            }
        }
        log("[bench] DONE failures=\(failures)")
        // Leave the summary on screen for a moment before the process exits.
        try? await Task.sleep(for: .seconds(5))
        exit(failures == 0 ? 0 : 2)
    }
}

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
            Task { @MainActor in RunStatus.shared.record(line) }
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
