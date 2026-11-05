import Foundation
import Testing
@testable import TTSMLX

/// The shared benchmark harness, driven from the test target so it runs under
/// `xcodebuild test` on macOS (plain `swift test` has no Metal library).
///
/// Off by default. Enable with `TTS_BENCH=1`; `TTS_BENCH_MODELS` is a
/// comma-separated list of catalog ids (default: the validated defaults),
/// `TTS_BENCH_TRIALS` (default 3), `TTS_BENCH_PROFILE=fast|balanced|highQuality`,
/// `TTS_BENCH_FIXTURES=sentence,paragraph,longForm`, `TTS_BENCH_MODES=narration,stream`,
/// `TTS_BENCH_OUT=<dir>` for JSON reports and WAV samples. `xcodebuild` forwards
/// variables prefixed `TEST_RUNNER_`:
///
///     TEST_RUNNER_TTS_BENCH=1 TEST_RUNNER_TTS_BENCH_MODELS=mlx-community/Kokoro-82M-bf16 \
///       TEST_RUNNER_TTS_BENCH_OUT=$PWD/Benchmarks/results \
///       xcodebuild test -scheme TTSMLX -destination 'platform=macOS' \
///       -only-testing:TTSMLXTests/TTSBenchmarkTests
///
/// `Tools/bench.sh` wraps this. On a device the demo app's `--benchmark`
/// argument runs the same harness.
@Suite("TTS benchmark harness", .serialized)
struct TTSBenchmarkTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var isEnabled: Bool { environment["TTS_BENCH"] == "1" }

    static func list(_ key: String) -> [String]? {
        environment[key]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test("run the harness for the requested models and write reports")
    func benchmark() async throws {
        guard Self.isEnabled else { return }
        let models = Self.list("TTS_BENCH_MODELS") ?? TTSMLX.defaultModels.map(\.id)
        let trials = Int(Self.environment["TTS_BENCH_TRIALS"] ?? "") ?? 3
        let profile = Self.environment["TTS_BENCH_PROFILE"].flatMap(TTSGenerationProfile.init(rawValue:))
        let fixtureIDs = Self.list("TTS_BENCH_FIXTURES")
        let fixtures = fixtureIDs.map { ids in TTSBenchmarkFixture.standard.filter { ids.contains($0.id) } }
            ?? TTSBenchmarkFixture.standard
        let modes = Self.list("TTS_BENCH_MODES")?.compactMap(TTSBenchmarkMode.init(rawValue:)) ?? TTSBenchmarkMode.allCases
        let output = Self.environment["TTS_BENCH_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let store = TTSModelStore()

        for modelID in models {
            var configuration = TTSBenchmarkConfiguration(
                modelID: modelID, fixtures: fixtures, trials: trials, modes: modes, profile: profile)
            configuration.audioOutputDirectory = output?
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent(TTSBenchmarkEnvironment.current().device, isDirectory: true)
            let report = try await TTSBenchmarkRunner.run(configuration, store: store)
            #expect(!report.trials.isEmpty, "\(modelID) produced no trials")
            for trial in report.trials {
                #expect(trial.audioSeconds > 0.5, "\(modelID) \(trial.fixtureID)/\(trial.mode.rawValue) #\(trial.index) produced no audio")
            }
            if let output {
                let url = try report.write(into: output)
                print("[bench] wrote \(url.path)")
            }
        }
    }

    @Test("fixtures are stable and summaries use the warm trials")
    func fixturesAndSummaries() {
        #expect(TTSBenchmarkFixture.sentence.wordCount == 12)
        #expect(TTSBenchmarkFixture.paragraph.wordCount == 51)
        #expect(TTSBenchmarkFixture.longForm.wordCount == 275)
        #expect(TTSBenchmarkFixture.standard.map(\.id) == ["sentence", "paragraph", "longForm"])

        func trial(_ index: Int, cold: Bool, firstAudio: Double, rtf: Double) -> TTSBenchmarkTrial {
            TTSBenchmarkTrial(
                fixtureID: "sentence", mode: .narration, index: index, includesLoad: cold, characters: 10,
                firstAudioSeconds: firstAudio, audioSeconds: rtf * 10, wallSeconds: 10, chunkCount: 1,
                stallCount: cold ? 1 : 0, stallSeconds: 0, stallFreePrerollSeconds: 0, overrunChunks: 0, longestTrailingSilenceSeconds: 0,
                peakDBFS: -3, rmsDBFS: -20, mlxPeakMB: 100, mlxActiveMB: 50, mlxCacheMB: 10, residentMB: 300,
                cpuUtilization: 1, thermalState: "nominal", batteryLevel: nil, availableMemoryMB: nil)
        }
        let report = TTSBenchmarkReport(
            modelID: "m", modelRevision: "abc", modelSizeMB: 1, modelLocation: "/tmp",
            environment: .current(), profile: nil, voice: nil, streamingInterval: 1, runtimeCacheLimitMB: 512,
            startedAt: Date(), finishedAt: Date(), load: nil,
            trials: [trial(0, cold: true, firstAudio: 9, rtf: 0.5), trial(1, cold: false, firstAudio: 1, rtf: 2), trial(2, cold: false, firstAudio: 3, rtf: 4)],
            notes: [])
        let summary = try! #require(report.summaries.first)
        #expect(summary.trials == 2)
        #expect(summary.medianFirstAudioSeconds == 2)
        #expect(summary.medianRealtimeFactor == 3)
        #expect(summary.stalls == 0)
        #expect(report.textLines().contains { $0.contains("(cold)") })
        #expect(TTSBenchmarkReport.median([3, 1, 2]) == 2)
        #expect(TTSBenchmarkReport.median([]) == 0)
    }

    @Test("a report with a silent trial still encodes")
    func silentTrialEncodes() throws {
        let silent = TTSBenchmarkTrial(
            fixtureID: "sentence", mode: .narration, index: 0, includesLoad: false, characters: 1,
            firstAudioSeconds: 0, audioSeconds: 0, wallSeconds: 1, chunkCount: 0, stallCount: 0, stallSeconds: 0,
            stallFreePrerollSeconds: 0, overrunChunks: 0, longestTrailingSilenceSeconds: 0,
            peakDBFS: -.infinity, rmsDBFS: -.infinity, mlxPeakMB: 0, mlxActiveMB: 0, mlxCacheMB: 0, residentMB: 0,
            cpuUtilization: 0, thermalState: "nominal", batteryLevel: nil, availableMemoryMB: nil)
        let report = TTSBenchmarkReport(
            modelID: "m", modelRevision: nil, modelSizeMB: 0, modelLocation: "", environment: .current(),
            profile: nil, voice: nil, streamingInterval: 1, runtimeCacheLimitMB: nil,
            startedAt: Date(), finishedAt: Date(), load: nil, trials: [silent], notes: [])
        let data = try report.jsonData()
        #expect(String(decoding: data, as: UTF8.self).contains("\"-inf\""))
    }
}
