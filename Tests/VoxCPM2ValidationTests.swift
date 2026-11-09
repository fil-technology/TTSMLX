import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import Testing
@testable import TTSMLX

/// End-to-end validation of VoxCPM2's feature set against the acceptance
/// list in Docs/voxcpm2-integration.md. Off by default (it downloads the
/// 2.3 GB checkpoint and two Whisper models and runs for several minutes);
/// enable with `TTS_VOXCPM2=1` through `xcodebuild test` (Metal), with
/// `TTS_VOXCPM2_OUT=<dir>` for the WAVs and the JSON report and
/// `TTS_VOXCPM2_STT=<path>` to the fork's `mlx-audio-swift-stt` executable
/// for the Whisper scoring (linking the STT library into the test bundle
/// crashes the Release linker, so it runs as a subprocess; without it the
/// intelligibility part is skipped and logged):
///
///     TEST_RUNNER_TTS_VOXCPM2=1 TEST_RUNNER_TTS_VOXCPM2_OUT=$TTSMLX_WORK/voxcpm2 \
///       TEST_RUNNER_TTS_VOXCPM2_STT=$TTSMLX_WORK/build/mlx-audio-swift/release/mlx-audio-swift-stt \
///       TEST_RUNNER_HF_HOME=$HF_HOME \
///       xcodebuild test -scheme TTSMLX -destination platform=macOS \
///       -configuration Release ENABLE_TESTABILITY=YES \
///       -only-testing:TTSMLXTests/VoxCPM2ValidationTests
///
/// What it checks: a fixed seed reproduces a take sample for sample; voice
/// design, reference cloning, controllable cloning and high-fidelity
/// continuation each produce speech of plausible length; the stream path
/// delivers its first buffer well before the take is done; ten languages
/// synthesize (Ukrainian as the unsupported-language experiment); Whisper
/// large-v3-turbo transcribes the English takes with a bounded word error
/// rate and the European-language ones with a logged one. Speaker similarity is not
/// scored (no speaker-embedding model in the runtime); the WAVs are kept for
/// listening.
@Suite("VoxCPM2 validation (TTS_VOXCPM2=1)", .serialized)
struct VoxCPM2ValidationTests {
    static let enabled = ProcessInfo.processInfo.environment["TTS_VOXCPM2"] != nil
    static let modelID = "mlx-community/VoxCPM2-4bit"

    static var outDir: URL {
        let env = ProcessInfo.processInfo.environment
        let dir = env["TTS_VOXCPM2_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ttsmlx-voxcpm2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct Take: Codable {
        var name: String
        var text: String
        var language: String?
        /// Two-letter code used to pick the Whisper model and language hint.
        var code: String?
        var seconds: Double
        var wallSeconds: Double
        var firstAudioSeconds: Double?
        var peakDBFS: Double
        var transcript: String?
        var wer: Double?
        var note: String?
    }

    static let english = "The lighthouse keeper climbed the spiral stairs every evening, counting each step out of habit."
    static let languageFixtures: [(TTSLanguage, String, String)] = [
        (.english, "en", english),
        (.russian, "ru", "Маяк стоял на скале, и его свет был виден далеко в море."),
        (.hebrew, "he", "שומר המגדלור עלה במדרגות בכל ערב וספר את הצעדים."),
        (.ukrainian, "uk", "Доглядач маяка щовечора піднімався сходами і рахував кроки."),
        (.german, "de", "Der Leuchtturmwärter stieg jeden Abend die Wendeltreppe hinauf."),
        (.french, "fr", "Le gardien du phare montait l'escalier en colimaçon chaque soir."),
        (.spanish, "es", "El farero subía la escalera de caracol cada tarde, contando los peldaños."),
        (.italian, "it", "Il guardiano del faro saliva la scala a chiocciola ogni sera."),
        (.japanese, "ja", "灯台守は毎晩、螺旋階段を登りながら段を数えていた。"),
        (.chinese, "zh", "灯塔看守人每天傍晚都会爬上螺旋楼梯，习惯性地数着台阶。"),
    ]

    @Test("VoxCPM2 feature validation")
    func validate() async throws {
        guard Self.enabled else { return }
        MLX.Memory.cacheLimit = 512 * 1_048_576
        let store = TTSModelStore()
        let synthesizer = TTSSpeechSynthesizer(modelStore: store)
        let model = try #require(TTSMLX.modelCatalog.first { $0.id == Self.modelID }?.descriptor)
        _ = try await store.ensureDownloaded(model)
        let out = Self.outDir
        var takes: [Take] = []
        func log(_ message: String) { print("[voxcpm2] \(message)") }

        func synth(_ name: String, _ text: String, _ options: TTSSynthesisOptions, code: String = "en", note: String? = nil) async throws -> (URL, Take) {
            var options = options
            options.outputURL = out.appendingPathComponent("\(name).wav")
            let t0 = Date()
            let file = try await synthesizer.synthesize(text, using: model, options: options)
            let wall = Date().timeIntervalSince(t0)
            let (seconds, peak) = try Self.measure(file.url)
            var take = Take(name: name, text: text, language: options.language?.identifier, code: code, seconds: seconds,
                            wallSeconds: wall, peakDBFS: peak, note: note)
            take.note = note
            takes.append(take)
            log("\(name): \(String(format: "%.1f", seconds))s audio in \(String(format: "%.1f", wall))s, peak \(String(format: "%.1f", peak)) dBFS")
            let nonFinite = try Self.samples(file.url).filter { !$0.isFinite || abs($0) > 1.5 }.count
            #expect(nonFinite == 0, "\(name) has \(nonFinite) non-finite or out-of-range samples")
            #expect(seconds > 1, "\(name) produced \(seconds)s of audio")
            #expect(seconds < 30, "\(name) ran away: \(seconds)s")
            #expect(peak > -40, "\(name) is near-silent: \(peak) dBFS")
            return (file.url, take)
        }

        // 1. Reproducibility: the same seed twice.
        let (seedA, _) = try await synth("seed42-a", Self.english, .init(language: .english, seed: 42))
        let (seedB, _) = try await synth("seed42-b", Self.english, .init(language: .english, seed: 42))
        let diff = try Self.maxDifference(seedA, seedB)
        log("seed 42 twice: max sample difference \(diff)")
        #expect(diff < 1e-5, "a fixed seed should reproduce the take (max diff \(diff))")
        let (seedC, _) = try await synth("seed43", Self.english, .init(language: .english, seed: 43))
        let diffOther = try Self.maxDifference(seedA, seedC)
        log("seed 42 vs 43: max sample difference \(diffOther)")
        #expect(diffOther > 1e-3, "a different seed should change the take")

        // 2. Voice design from controls (no clip).
        let (_, _) = try await synth(
            "design-narrator", Self.english,
            .init(language: .english, voice: TTSVoice("A mature male narrator with a warm, deep, slightly raspy voice"),
                  instruction: "calm and reassuring delivery", speed: .slow, seed: 7),
            note: "voice design")
        let (_, _) = try await synth(
            "design-anchor", Self.english,
            .init(language: .english, voice: TTSVoice(TTSVoiceDesign(gender: .female, age: .young, pitch: .high, qualities: ["bright"], pace: .brisk, style: "news anchor").description), seed: 7),
            note: "structured voice design")

        // 3. Cloning modes, using the first take as the clip (its text is known exactly).
        let cloneText = "Later that night the wind changed, and the sea grew restless under a thin moon."
        let (_, _) = try await synth("clone-reference", cloneText, .init(language: .english, referenceAudio: seedA, seed: 7), note: "reference cloning (clip only)")
        let (_, _) = try await synth("clone-controllable", cloneText, .init(language: .english, referenceAudio: seedA, instruction: "whispering, urgent", speed: .fast, seed: 7), note: "controllable cloning (clip + style)")
        let (_, _) = try await synth("clone-hifi", cloneText, .init(language: .english, referenceAudio: seedA, referenceText: Self.english, seed: 7), note: "high-fidelity continuation (clip + transcript)")

        // 4. Streaming: first buffer well before the end.
        do {
            let t0 = Date()
            var first: TimeInterval?
            var chunks = 0
            var frames = 0
            for try await chunk in try await synthesizer.synthesizeStream(Self.english, using: model, options: .init(language: .english, seed: 7)) {
                if chunk.isPadding { continue }
                if first == nil { first = Date().timeIntervalSince(t0) }
                chunks += 1
                frames += Int(chunk.buffer.frameLength)
            }
            let wall = Date().timeIntervalSince(t0)
            let seconds = Double(frames) / 48_000
            log("stream: first audio \(String(format: "%.2f", first ?? -1))s, \(chunks) chunks, \(String(format: "%.1f", seconds))s audio in \(String(format: "%.1f", wall))s")
            takes.append(Take(name: "stream", text: Self.english, language: "English", code: "en", seconds: seconds, wallSeconds: wall, firstAudioSeconds: first, peakDBFS: 0, note: "stream path"))
            #expect((first ?? 99) < 2, "first audio should arrive within 2 s on the stream path")
            #expect(chunks >= 4, "the stream path should yield several buffers, got \(chunks)")
        }

        // 5. Languages.
        for (language, code, text) in Self.languageFixtures where code != "en" {
            let note = code == "uk" ? "unsupported-language experiment (not one of the 30)" : nil
            _ = try await synth("lang-\(code)", text, .init(language: language, seed: 7), code: code, note: note)
        }

        // 6. Intelligibility with Whisper through the fork's CLI.
        await synthesizer.releaseRuntimeBuffers()
        if let stt = ProcessInfo.processInfo.environment["TTS_VOXCPM2_STT"], FileManager.default.isExecutableFile(atPath: stt) {
            for i in takes.indices where takes[i].name != "stream" {
                guard let code = takes[i].code else { continue }
                let multilingual = ["ru", "he", "de", "fr", "es", "it", "uk"].contains(code)
                guard code == "en" || multilingual else { continue }
                let url = out.appendingPathComponent("\(takes[i].name).wav")
                // The only mlx-community Whisper with safetensors (the fork does not read .npz).
                let model = "mlx-community/whisper-large-v3-turbo"
                guard let text = try? Self.transcribe(url, cli: stt, model: model, language: code) else {
                    log("\(takes[i].name): transcription failed")
                    continue
                }
                let wer = Self.wordErrorRate(reference: takes[i].text, hypothesis: text)
                takes[i].transcript = text
                takes[i].wer = wer
                log("\(takes[i].name): WER \(String(format: "%.2f", wer)) — \(text)")
                if code == "en" { #expect(wer < 0.35, "\(takes[i].name) WER \(wer): \(text)") }
            }
        } else {
            log("TTS_VOXCPM2_STT not set: intelligibility scoring skipped")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(takes).write(to: out.appendingPathComponent("report.json"))
        log("report: \(out.appendingPathComponent("report.json").path)")
    }

    // MARK: - Helpers

    static func measure(_ url: URL) throws -> (seconds: Double, peakDBFS: Double) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard count > 0, let channel = buffer.floatChannelData?[0] else { return (0, -120) }
        var peak: Float = 0
        for i in 0 ..< count { peak = max(peak, abs(channel[i])) }
        let dbfs = peak > 0 ? 20 * log10(Double(peak)) : -120
        return (Double(count) / file.processingFormat.sampleRate, dbfs)
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    static func maxDifference(_ a: URL, _ b: URL) throws -> Float {
        let x = try samples(a), y = try samples(b)
        guard x.count == y.count else { return .infinity }
        var m: Float = 0
        for i in x.indices { m = max(m, abs(x[i] - y[i])) }
        return m
    }

    static func transcribe(_ url: URL, cli: String, model: String, language: String) throws -> String {
        let stem = url.deletingPathExtension().appendingPathExtension("whisper").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["--model", model, "--audio", url.path, "--output-path", stem, "--format", "txt", "--language", language]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        // The CLI writes to the stem as given; older builds appended the format.
        let path = FileManager.default.fileExists(atPath: stem) ? stem : stem + ".txt"
        return try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Word-level Levenshtein distance over the reference length.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0 ... h.count)
        for i in 1 ... r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

@Suite("VoxCPM2 validation helpers")
struct VoxCPM2ValidationHelperTests {
    @Test("Word error rate counts substitutions, insertions and deletions over the reference")
    func wer() {
        #expect(VoxCPM2ValidationTests.wordErrorRate(reference: "the cat sat", hypothesis: "the cat sat") == 0)
        #expect(VoxCPM2ValidationTests.wordErrorRate(reference: "the cat sat", hypothesis: "the dog sat") == 1.0 / 3)
        #expect(VoxCPM2ValidationTests.wordErrorRate(reference: "The cat, sat!", hypothesis: "the cat sat") == 0)
        #expect(VoxCPM2ValidationTests.wordErrorRate(reference: "a b", hypothesis: "") == 1)
    }
}
