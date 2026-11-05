import AVFoundation
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

// MARK: - Fixtures

/// A passage the benchmark synthesizes. The three standard fixtures are fixed
/// text so numbers stay comparable across models, devices and releases.
public struct TTSBenchmarkFixture: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let language: TTSLanguage?

    public init(id: String, text: String, language: TTSLanguage? = nil) {
        self.id = id
        self.text = text
        self.language = language
    }

    public var characterCount: Int { text.count }
    public var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }

    /// One conversational sentence (12 words): the agent-turn case.
    public static let sentence = TTSBenchmarkFixture(
        id: "sentence",
        text: "Sure, I can do that. The meeting moves to Thursday at ten.")

    /// A news paragraph (51 words): one Reader section.
    public static let paragraph = TTSBenchmarkFixture(
        id: "paragraph",
        text: """
        Global markets closed higher on Tuesday after the central bank signalled it would hold \
        interest rates steady through the end of the year. Analysts said the decision eased fears \
        of a prolonged slowdown, though several cautioned that inflation remains above target. \
        The index gained one point two percent on the session.
        """)

    /// Long-form narration (275 words, six paragraphs): the stability case.
    public static let longForm = TTSBenchmarkFixture(
        id: "longForm",
        text: """
        The lighthouse keeper had kept the same routine for thirty-one years. Each evening, an hour \
        before dusk, he climbed the one hundred and twelve steps to the lamp room, polished the lens, \
        checked the clockwork, and wrote the weather in a ledger that had belonged to his father.

        The village below had changed around him. The fishing fleet had shrunk from forty boats to \
        six, the school had closed, and the ferry now came twice a week instead of every morning. \
        Yet the light still turned, and the ships still passed, and nobody had told him to stop.

        That winter a letter arrived from the harbour authority. The lamp would be automated in the \
        spring, it said, and the keeper's position would end on the last day of March. There was a \
        paragraph about pension arrangements and a paragraph thanking him for his service.

        He read the letter twice, folded it, and put it in the ledger between the pages for February. \
        Then he climbed the stairs as usual, because the weather was closing in from the west and a \
        trawler was due back before midnight.

        In the morning the storm had passed. The trawler was tied up at the quay, the crew were \
        asleep, and the light was still turning in the pale sunshine. The keeper switched it off, \
        wrote "clear, light wind, sea moderate" in the ledger, and went down to make his breakfast.

        Nobody in the village noticed anything different that day, which was, he decided, exactly \
        as it should be. The automation engineers would arrive in three weeks. Until then the light \
        was his, and he intended to keep it properly.
        """)

    /// The standard set every report should include.
    public static let standard: [TTSBenchmarkFixture] = [.sentence, .paragraph, .longForm]
}

// MARK: - Configuration

/// Which synthesizer path a trial measures.
///
/// - `narration`: ``TTSSpeechSynthesizer/synthesizeLong(_:using:options:chunker:progressHandler:)``,
///   the chunked path apps use for articles. First audio is the first chunk of
///   the first take.
/// - `stream`: ``TTSSpeechSynthesizer/synthesizeStream(_:using:options:progressHandler:)``,
///   one take through the model's own streaming path with a short
///   ``TTSSynthesisOptions/streamingInterval``. First audio is the first buffer
///   the runtime yields; for models that generate a take whole this equals the
///   full generation time, which is the honest number for them.
public enum TTSBenchmarkMode: String, Sendable, Codable, CaseIterable {
    case narration
    case stream
}

public struct TTSBenchmarkConfiguration: Sendable {
    public var modelID: String
    public var fixtures: [TTSBenchmarkFixture]
    /// Trials per fixture and mode. The first narration trial of the first
    /// fixture is the cold one when `measuresLoad` is set.
    public var trials: Int
    public var modes: [TTSBenchmarkMode]
    public var profile: TTSGenerationProfile?
    public var voice: TTSVoice?
    public var language: TTSLanguage?
    /// Interval for `stream` trials. Narration keeps the synthesizer default.
    public var streamingInterval: Double
    /// Time a cold load (first load in the process) and a warm reload.
    public var measuresLoad: Bool
    /// Fixtures longer than this many words skip `stream` mode: a single take
    /// through the model is only meaningful at sentence or paragraph length.
    public var streamWordLimit: Int
    /// When set, the first trial of each fixture and mode writes its audio here
    /// as `<model>-<fixture>-<mode>.wav` for listening comparisons.
    public var audioOutputDirectory: URL?
    public var hfToken: String?
    /// Cap on MLX's buffer cache for the run, the same knob an app sets through
    /// ``TTSSpeechSynthesizer/init(modelStore:runtimeCacheLimitMB:releasesRuntimeBuffersAfterEachRequest:)``.
    /// Uncapped, the cache grows with every request (tens of GB over a
    /// long-form run on macOS) and the numbers stop describing any real app.
    public var runtimeCacheLimitMB: Int?
    /// Called after every trial with the report so far, so a run the OS kills
    /// (a jetsam on a phone) still leaves the trials it completed on disk.
    public var partialReportHandler: (@Sendable (TTSBenchmarkReport) -> Void)?

    public init(
        modelID: String,
        fixtures: [TTSBenchmarkFixture] = TTSBenchmarkFixture.standard,
        trials: Int = 3,
        modes: [TTSBenchmarkMode] = TTSBenchmarkMode.allCases,
        profile: TTSGenerationProfile? = nil,
        voice: TTSVoice? = nil,
        language: TTSLanguage? = nil,
        streamingInterval: Double = 1.0,
        measuresLoad: Bool = true,
        streamWordLimit: Int = 80,
        audioOutputDirectory: URL? = nil,
        hfToken: String? = nil,
        runtimeCacheLimitMB: Int? = 512
    ) {
        self.runtimeCacheLimitMB = runtimeCacheLimitMB
        self.modelID = modelID
        self.fixtures = fixtures
        self.trials = max(1, trials)
        self.modes = modes
        self.profile = profile
        self.voice = voice
        self.language = language
        self.streamingInterval = streamingInterval
        self.measuresLoad = measuresLoad
        self.streamWordLimit = streamWordLimit
        self.audioOutputDirectory = audioOutputDirectory
        self.hfToken = hfToken
    }
}

// MARK: - Results

/// Hardware, OS and build the numbers were taken on. Every report carries one
/// so results from different machines are never compared unlabelled.
public struct TTSBenchmarkEnvironment: Sendable, Codable, Hashable {
    public let device: String
    public let chip: String?
    public let osVersion: String
    public let physicalMemoryMB: Int
    public let buildConfiguration: String
    public let processName: String

    public static func current() -> TTSBenchmarkEnvironment {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        #if os(macOS)
        let device = TTSBenchmarkProbe.sysctlString("hw.model") ?? "mac"
        #else
        let device = TTSBenchmarkProbe.sysctlString("hw.machine") ?? "unknown"
        #endif
        return TTSBenchmarkEnvironment(
            device: device,
            chip: TTSBenchmarkProbe.sysctlString("machdep.cpu.brand_string"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            buildConfiguration: build,
            processName: ProcessInfo.processInfo.processName)
    }
}

/// One synthesis run of one fixture.
public struct TTSBenchmarkTrial: Sendable, Codable, Hashable {
    public let fixtureID: String
    public let mode: TTSBenchmarkMode
    public let index: Int
    /// `true` when this trial also paid the model load (process-cold).
    public let includesLoad: Bool
    public let characters: Int
    /// Seconds from the call to the first non-padding audio buffer.
    public let firstAudioSeconds: Double
    /// Seconds of audio produced (padding included, as a player would hear it).
    public let audioSeconds: Double
    public let wallSeconds: Double
    /// `audioSeconds / wallSeconds`: above 1 means faster than playback.
    public var realtimeFactor: Double { wallSeconds > 0 ? audioSeconds / wallSeconds : 0 }
    public let chunkCount: Int
    /// Times a player that started at first audio would have run dry, and for
    /// how long in total.
    public let stallCount: Int
    public let stallSeconds: Double
    /// Seconds of audio a player would have to buffer before starting for the
    /// trial to play without a single stall (0 when generation stays ahead).
    public let stallFreePrerollSeconds: Double
    /// Chunks ending in more than two seconds of silence (a missed end-of-audio
    /// fills the frame budget with silence).
    public let overrunChunks: Int
    public let longestTrailingSilenceSeconds: Double
    public let peakDBFS: Float
    public let rmsDBFS: Float
    public let mlxPeakMB: Double
    public let mlxActiveMB: Double
    public let mlxCacheMB: Double
    /// Physical footprint of the process at the end of the trial.
    public let residentMB: Double
    /// Process CPU seconds divided by wall seconds (can exceed 1 on several cores).
    public let cpuUtilization: Double
    public let thermalState: String
    /// iOS only; `nil` on macOS or when unavailable.
    public let batteryLevel: Double?
    /// iOS only: what `os_proc_available_memory` says the process may still
    /// allocate before jetsam, at the end of the trial. Falling values across
    /// trials mean the system, not the model, is closing in.
    public let availableMemoryMB: Double?
}

public struct TTSBenchmarkLoad: Sendable, Codable, Hashable {
    /// First load in this process. Weights are mapped lazily, so this is
    /// mostly object construction; the real cold cost shows up in
    /// `coldFirstAudioSeconds`.
    public let coldLoadSeconds: Double?
    /// Load plus the first audio of the sentence fixture in a fresh process:
    /// weights materialised and Metal kernels compiled. What a user waits for
    /// on the first utterance after launch.
    public let coldFirstAudioSeconds: Double?
    /// Reload after ``TTSSpeechSynthesizer/unload(_:)`` with the OS file cache warm.
    public let warmLoadSeconds: Double?
    public let mlxActiveAfterLoadMB: Double
    public let residentAfterLoadMB: Double
}

public struct TTSBenchmarkReport: Sendable, Codable {
    public let modelID: String
    public let modelRevision: String?
    public let modelSizeMB: Int
    public let modelLocation: String
    public let environment: TTSBenchmarkEnvironment
    public let profile: TTSGenerationProfile?
    public let voice: String?
    public let streamingInterval: Double
    public let runtimeCacheLimitMB: Int?
    public let startedAt: Date
    public let finishedAt: Date
    public let load: TTSBenchmarkLoad?
    public let trials: [TTSBenchmarkTrial]
    public let notes: [String]

    /// Medians per fixture and mode over the warm trials.
    public struct Summary: Sendable, Codable, Hashable {
        public let fixtureID: String
        public let mode: TTSBenchmarkMode
        public let trials: Int
        public let medianFirstAudioSeconds: Double
        public let medianRealtimeFactor: Double
        public let maxMLXPeakMB: Double
        public let maxResidentMB: Double
        public let stalls: Int
        public let overruns: Int
        public let medianStallFreePrerollSeconds: Double
    }

    public var summaries: [Summary] {
        var groups: [String: [TTSBenchmarkTrial]] = [:]
        var order: [String] = []
        for trial in trials {
            let key = "\(trial.fixtureID)/\(trial.mode.rawValue)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(trial)
        }
        return order.compactMap { key in
            guard var group = groups[key] else { return nil }
            // The cold trial only counts when it is the only one.
            if group.count > 1 { group.removeAll(where: \.includesLoad) }
            guard let first = group.first else { return nil }
            return Summary(
                fixtureID: first.fixtureID, mode: first.mode, trials: group.count,
                medianFirstAudioSeconds: Self.median(group.map(\.firstAudioSeconds)),
                medianRealtimeFactor: Self.median(group.map(\.realtimeFactor)),
                maxMLXPeakMB: group.map(\.mlxPeakMB).max() ?? 0,
                maxResidentMB: group.map(\.residentMB).max() ?? 0,
                stalls: group.map(\.stallCount).reduce(0, +),
                overruns: group.map(\.overrunChunks).reduce(0, +),
                medianStallFreePrerollSeconds: Self.median(group.map(\.stallFreePrerollSeconds)))
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }

    /// Human-readable lines, one per trial plus load and summary lines.
    public func textLines() -> [String] {
        var lines: [String] = []
        lines.append(String(
            format: "[bench] model=%@ rev=%@ sizeMB=%d device=%@ os=%@ build=%@ memMB=%d cacheLimitMB=%@",
            modelID, modelRevision ?? "?", modelSizeMB, environment.device, environment.osVersion,
            environment.buildConfiguration, environment.physicalMemoryMB,
            runtimeCacheLimitMB.map(String.init) ?? "none"))
        if let load {
            lines.append(String(
                format: "[bench] load cold=%@ coldFirstAudio=%@ warm=%@ mlxActiveAfterLoad=%.0fMB residentAfterLoad=%.0fMB",
                load.coldLoadSeconds.map { String(format: "%.2fs", $0) } ?? "n/a",
                load.coldFirstAudioSeconds.map { String(format: "%.2fs", $0) } ?? "n/a",
                load.warmLoadSeconds.map { String(format: "%.2fs", $0) } ?? "n/a",
                load.mlxActiveAfterLoadMB, load.residentAfterLoadMB))
        }
        for trial in trials {
            lines.append(String(
                format: "[bench] %@/%@ #%d%@ firstAudio=%.2fs audio=%.1fs wall=%.1fs rtf=%.2fx chunks=%d stalls=%d (%.1fs) preroll=%.1fs overruns=%d tail=%.1fs peak=%.1fdBFS rms=%.1fdBFS mlxPeak=%.0fMB active=%.0fMB cache=%.0fMB resident=%.0fMB cpu=%.2f thermal=%@%@",
                trial.fixtureID, trial.mode.rawValue, trial.index, trial.includesLoad ? " (cold)" : "",
                trial.firstAudioSeconds, trial.audioSeconds, trial.wallSeconds, trial.realtimeFactor,
                trial.chunkCount, trial.stallCount, trial.stallSeconds, trial.stallFreePrerollSeconds, trial.overrunChunks,
                trial.longestTrailingSilenceSeconds, trial.peakDBFS, trial.rmsDBFS, trial.mlxPeakMB,
                trial.mlxActiveMB, trial.mlxCacheMB, trial.residentMB, trial.cpuUtilization, trial.thermalState,
                (trial.batteryLevel.map { String(format: " battery=%.0f%%", $0 * 100) } ?? "")
                    + (trial.availableMemoryMB.map { String(format: " available=%.0fMB", $0) } ?? "")))
        }
        for summary in summaries {
            lines.append(String(
                format: "[bench] summary %@/%@ trials=%d medianFirstAudio=%.2fs medianRTF=%.2fx maxMLXPeak=%.0fMB maxResident=%.0fMB stalls=%d preroll=%.1fs overruns=%d",
                summary.fixtureID, summary.mode.rawValue, summary.trials, summary.medianFirstAudioSeconds,
                summary.medianRealtimeFactor, summary.maxMLXPeakMB, summary.maxResidentMB, summary.stalls,
                summary.medianStallFreePrerollSeconds, summary.overruns))
        }
        for note in notes { lines.append("[bench] note: \(note)") }
        return lines
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try encoder.encode(self)
    }

    /// Writes `<model>-<device>-<timestamp>.json` into `directory`.
    @discardableResult
    public func write(into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: startedAt)
            .replacingOccurrences(of: ":", with: "")
        let name = "\(modelID.replacingOccurrences(of: "/", with: "_"))-\(environment.device)-\(stamp).json"
        let url = directory.appendingPathComponent(name)
        try jsonData().write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Runner

/// Runs one model through the fixtures and reports latency, throughput,
/// memory, stalls and audio levels. The same code runs on macOS (through the
/// test target) and on a device (through the demo app's `--benchmark` mode).
///
/// Definitions used throughout:
/// - *first audio*: wall time from the synthesize call to the first non-padding
///   buffer, model already loaded unless the trial is marked cold.
/// - *realtime factor*: seconds of audio per wall second for the whole request.
/// - *stall*: the moment a player that started at first audio and never paused
///   would have run out of buffered audio.
/// - *MLX peak*: the runtime's active-memory high-water mark during the trial;
///   *resident*: the process's physical footprint, which is what iOS judges.
public enum TTSBenchmarkRunner {
    public static func run(
        _ configuration: TTSBenchmarkConfiguration,
        store: TTSModelStore? = nil,
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) async throws -> TTSBenchmarkReport {
        let startedAt = Date()
        var notes: [String] = []
        guard let entry = TTSMLX.modelCatalog.first(where: { $0.id == configuration.modelID }) else {
            throw TTSError.modelNotFound(configuration.modelID)
        }
        guard let descriptor = entry.descriptor else {
            throw TTSError.unsupportedModel(configuration.modelID)
        }
        let store = store ?? TTSModelStore()
        let synthesizer = TTSSpeechSynthesizer(modelStore: store, runtimeCacheLimitMB: configuration.runtimeCacheLimitMB)

        log("[bench] preparing \(descriptor.id) (download if missing)")
        let lastReported = TTSBenchmarkProbe.Counter()
        let installed = try await store.ensureDownloaded(descriptor, hfToken: configuration.hfToken) { update in
            if update.stage == .downloadingModel, let fraction = update.fractionCompleted {
                let step = Int(fraction * 10) * 10
                if lastReported.advance(to: step) { log("[bench] downloading \(step)%") }
            }
        }
        let revision = TTSBenchmarkProbe.snapshotRevision(at: installed.location)
        log("[bench] model=\(descriptor.id) at \(installed.location.path) sizeMB=\(installed.sizeBytes / 1_000_000)")

        var voice = configuration.voice
        if voice == nil, descriptor.capabilities.supportsReferenceAudio == false, let first = descriptor.suggestedVoices.first {
            voice = first
        }
        func options(mode: TTSBenchmarkMode, fixture: TTSBenchmarkFixture) -> TTSSynthesisOptions {
            var options = TTSSynthesisOptions(
                language: configuration.language ?? fixture.language,
                voice: voice,
                generationProfile: configuration.profile,
                hfToken: configuration.hfToken)
            if mode == .stream { options.streamingInterval = configuration.streamingInterval }
            return options
        }

        // Load timing. The cold number includes Metal pipeline compilation on a
        // fresh process; the warm one is a reload after `unload` with the file
        // cache hot (what a relaunch looks like).
        var load: TTSBenchmarkLoad?
        var trials: [TTSBenchmarkTrial] = []
        var abortedWith: String?
        do {
        if configuration.measuresLoad {
            log("[bench] loading \(descriptor.id) cold")
            let coldStart = Date()
            try await synthesizer.warmUp(descriptor, hfToken: configuration.hfToken)
            let cold = Date().timeIntervalSince(coldStart)
            // The first utterance after a cold load materialises the weights
            // and compiles the Metal kernels; measure it as its own trial.
            let coldFixture = configuration.fixtures.first { $0.id == TTSBenchmarkFixture.sentence.id }
                ?? configuration.fixtures.first ?? .sentence
            let coldTrial = try await runTrialRetryingCancellation(
                fixture: coldFixture, mode: .narration, index: -1, includesLoad: true,
                descriptor: descriptor, options: options(mode: .narration, fixture: coldFixture),
                synthesizer: synthesizer, audioOutput: nil, notes: &notes, log: log)
            trials.append(coldTrial)
            configuration.partialReportHandler?(TTSBenchmarkReport(
                modelID: descriptor.id, modelRevision: revision,
                modelSizeMB: Int(installed.sizeBytes / 1_000_000), modelLocation: installed.location.path,
                environment: .current(), profile: configuration.profile, voice: voice?.identifier,
                streamingInterval: configuration.streamingInterval,
                runtimeCacheLimitMB: configuration.runtimeCacheLimitMB,
                startedAt: startedAt, finishedAt: Date(), load: nil, trials: trials,
                notes: notes + ["partial: run still in progress"]))
            await synthesizer.unload(descriptor.id)
            log("[bench] reloading \(descriptor.id) warm")
            let warmStart = Date()
            try await synthesizer.warmUp(descriptor, hfToken: configuration.hfToken)
            let warm = Date().timeIntervalSince(warmStart)
            let memory = TTSRuntimeMemory.current()
            load = TTSBenchmarkLoad(
                coldLoadSeconds: cold, coldFirstAudioSeconds: cold + coldTrial.firstAudioSeconds, warmLoadSeconds: warm,
                mlxActiveAfterLoadMB: Double(memory.activeBytes) / 1_048_576,
                residentAfterLoadMB: TTSBenchmarkProbe.residentMB())
            log(String(format: "[bench] load cold=%.2fs coldFirstAudio=%.2fs warm=%.2fs active=%.0fMB resident=%.0fMB",
                       cold, load!.coldFirstAudioSeconds ?? 0, warm, load!.mlxActiveAfterLoadMB, load!.residentAfterLoadMB))
        }

        for fixture in configuration.fixtures {
            for mode in configuration.modes {
                if mode == .stream, fixture.wordCount > configuration.streamWordLimit {
                    continue
                }
                if mode == .stream, !descriptor.capabilities.supportsStreaming {
                    notes.append("\(fixture.id)/stream skipped: the model does not stream")
                    continue
                }
                for index in 0..<configuration.trials {
                    // Without a load phase the first trial pays the load itself.
                    let includesLoad = !configuration.measuresLoad && trials.isEmpty
                    let trial = try await runTrialRetryingCancellation(
                        fixture: fixture, mode: mode, index: index, includesLoad: includesLoad,
                        descriptor: descriptor, options: options(mode: mode, fixture: fixture),
                        synthesizer: synthesizer,
                        audioOutput: index == 0 ? configuration.audioOutputDirectory : nil,
                        notes: &notes, log: log)
                    trials.append(trial)
                    configuration.partialReportHandler?(TTSBenchmarkReport(
                        modelID: descriptor.id, modelRevision: revision,
                        modelSizeMB: Int(installed.sizeBytes / 1_000_000), modelLocation: installed.location.path,
                        environment: .current(), profile: configuration.profile, voice: voice?.identifier,
                        streamingInterval: configuration.streamingInterval,
                        runtimeCacheLimitMB: configuration.runtimeCacheLimitMB,
                        startedAt: startedAt, finishedAt: Date(), load: load, trials: trials,
                        notes: notes + ["partial: run still in progress"]))
                }
            }
        }
        } catch {
            // Keep what was measured; the report says where it stopped.
            abortedWith = "aborted at trial \(trials.count): \(error)"
            notes.append(abortedWith!)
            log("[bench] \(abortedWith!)")
            if trials.isEmpty { throw error }
        }

        let report = TTSBenchmarkReport(
            modelID: descriptor.id, modelRevision: revision,
            modelSizeMB: Int(installed.sizeBytes / 1_000_000), modelLocation: installed.location.path,
            environment: .current(), profile: configuration.profile, voice: voice?.identifier,
            streamingInterval: configuration.streamingInterval,
            runtimeCacheLimitMB: configuration.runtimeCacheLimitMB,
            startedAt: startedAt, finishedAt: Date(), load: load, trials: trials, notes: notes)
        for line in report.textLines() where line.hasPrefix("[bench] summary") || line.hasPrefix("[bench] note") {
            log(line)
        }
        log("[bench] finished \(descriptor.id)")
        await synthesizer.unloadAll()
        return report
    }

    /// On a phone the synthesizer cancels in-flight generation whenever the
    /// app resigns active (lock screen, notification shade, a call), which
    /// surfaces as `CancellationError`. That is the device, not the model, so
    /// the trial is repeated up to five times and each retry is noted.
    static func runTrialRetryingCancellation(
        fixture: TTSBenchmarkFixture, mode: TTSBenchmarkMode, index: Int, includesLoad: Bool,
        descriptor: TTSModelDescriptor, options: TTSSynthesisOptions,
        synthesizer: TTSSpeechSynthesizer, audioOutput: URL?,
        notes: inout [String], log: @escaping @Sendable (String) -> Void
    ) async throws -> TTSBenchmarkTrial {
        var attempt = 0
        while true {
            do {
                return try await runTrial(
                    fixture: fixture, mode: mode, index: index, includesLoad: includesLoad,
                    descriptor: descriptor, options: options, synthesizer: synthesizer,
                    audioOutput: audioOutput, log: log)
            } catch is CancellationError where attempt < 5 && !Task.isCancelled {
                // A suspended app does not run this code; the sleep elapses
                // once it is active again, so five tries cover a lock/unlock.
                attempt += 1
                let note = "\(fixture.id)/\(mode.rawValue) #\(index) was cancelled (app inactive?), retry \(attempt)"
                notes.append(note)
                log("[bench] \(note)")
                try await Task.sleep(for: .seconds(3))
            }
        }
    }

    static func runTrial(
        fixture: TTSBenchmarkFixture, mode: TTSBenchmarkMode, index: Int, includesLoad: Bool,
        descriptor: TTSModelDescriptor, options: TTSSynthesisOptions,
        synthesizer: TTSSpeechSynthesizer, audioOutput: URL?,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> TTSBenchmarkTrial {
        log("[bench] running \(fixture.id)/\(mode.rawValue) #\(index)\(includesLoad ? " (cold)" : "") on \(descriptor.id)")
        TTSRuntimeMemory.resetPeak()
        let cpuStart = TTSBenchmarkProbe.cpuSeconds()
        let started = Date()
        var firstAudio: TimeInterval?
        var playableUntil: TimeInterval = 0
        var stalls = 0, stallSeconds = 0.0
        var deliveredAudio = 0.0, preroll = 0.0
        var chunks = 0, overruns = 0
        var longestTail = 0.0
        var sampleRate = Double(descriptor.capabilities.sampleRate ?? 24_000)
        var samples: [Float] = []

        let stream: AsyncThrowingStream<TTSAudioBufferChunk, Error> = switch mode {
        case .narration: try await synthesizer.synthesizeLong(fixture.text, using: descriptor, options: options)
        case .stream: try await synthesizer.synthesizeStream(fixture.text, using: descriptor, options: options)
        }
        for try await chunk in stream {
            let now = Date().timeIntervalSince(started)
            let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            sampleRate = chunk.buffer.format.sampleRate
            if !chunk.isPadding, firstAudio == nil {
                firstAudio = now
                playableUntil = now
            }
            if let firstAudio {
                if chunks > 0, now > playableUntil + 0.005 {
                    stalls += 1
                    stallSeconds += now - playableUntil
                    playableUntil = now
                }
                playableUntil += duration
                // How far behind an uninterrupted player this chunk arrived.
                preroll = max(preroll, now - (firstAudio + deliveredAudio))
                deliveredAudio += duration
            }
            chunks += 1
            if !chunk.isPadding {
                let tail = TTSBenchmarkProbe.trailingSilence(chunk.buffer)
                longestTail = max(longestTail, tail)
                if tail > 2 { overruns += 1 }
            }
            samples.append(contentsOf: TTSBenchmarkProbe.samples(of: chunk.buffer))
        }
        let wall = Date().timeIntervalSince(started)
        let cpu = TTSBenchmarkProbe.cpuSeconds() - cpuStart
        let memory = TTSRuntimeMemory.current()
        let analysis = TTSAudioAnalysis.analyze(samples: samples, sampleRate: Int(sampleRate))
        let battery = await TTSBenchmarkProbe.batteryLevel()

        if let audioOutput {
            let name = "\(descriptor.id.replacingOccurrences(of: "/", with: "_"))-\(fixture.id)-\(mode.rawValue).wav"
            do {
                try TTSBenchmarkProbe.write(samples: samples, sampleRate: Int(sampleRate), to: audioOutput.appendingPathComponent(name))
            } catch {
                log("[bench] could not write \(name): \(error)")
            }
        }

        let trial = TTSBenchmarkTrial(
            fixtureID: fixture.id, mode: mode, index: index, includesLoad: includesLoad,
            characters: fixture.characterCount,
            firstAudioSeconds: firstAudio ?? wall,
            audioSeconds: Double(samples.count) / sampleRate, wallSeconds: wall,
            chunkCount: chunks, stallCount: stalls, stallSeconds: stallSeconds,
            stallFreePrerollSeconds: preroll, overrunChunks: overruns, longestTrailingSilenceSeconds: longestTail,
            // Silence (a cancelled take) analyses to -inf, which JSON cannot carry.
            peakDBFS: analysis.peakDBFS.isFinite ? analysis.peakDBFS : -120,
            rmsDBFS: analysis.rmsDBFS.isFinite ? analysis.rmsDBFS : -120,
            mlxPeakMB: Double(memory.peakBytes) / 1_048_576,
            mlxActiveMB: Double(memory.activeBytes) / 1_048_576,
            mlxCacheMB: Double(memory.cacheBytes) / 1_048_576,
            residentMB: TTSBenchmarkProbe.residentMB(),
            cpuUtilization: wall > 0 ? cpu / wall : 0,
            thermalState: TTSBenchmarkProbe.thermalState(),
            batteryLevel: battery,
            availableMemoryMB: TTSBenchmarkProbe.availableMemoryMB())
        let report = TTSBenchmarkReport(
            modelID: descriptor.id, modelRevision: nil, modelSizeMB: 0, modelLocation: "",
            environment: .current(), profile: nil, voice: nil, streamingInterval: 0, runtimeCacheLimitMB: nil,
            startedAt: started, finishedAt: Date(), load: nil, trials: [trial], notes: [])
        if let line = report.textLines().dropFirst().first { log(line) }
        return trial
    }
}

// MARK: - Probes

enum TTSBenchmarkProbe {
    /// Monotonic step reporter for progress callbacks that fire many times
    /// per percent.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1
        func advance(to step: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard step > value else { return false }
            value = step
            return true
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
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

    /// User plus system CPU seconds consumed by this process so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func batteryLevel() async -> Double? {
        #if os(iOS)
        return await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            return level >= 0 ? Double(level) : nil
        }
        #else
        return nil
        #endif
    }

    static func availableMemoryMB() -> Double? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return nil
        #endif
    }

    static func snapshotRevision(at location: URL) -> String? {
        let url = location.appendingPathComponent(".mlx-audio-snapshot.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["revision"] as? String
    }

    /// Seconds of near-silence at the end of a buffer.
    static func trailingSilence(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        var index = count
        while index > 0, abs(channel[index - 1]) < 1e-3 { index -= 1 }
        return Double(count - index) / buffer.format.sampleRate
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw TTSError.invalidResponse }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
