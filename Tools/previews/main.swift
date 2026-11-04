import AVFoundation
import Foundation
import MLX
import TTSMLX

// Preview generator for Docs/previews. Not part of the library build: add
//   .executableTarget(name: "TTSMLXPreviews", dependencies: ["TTSMLX"], path: "Tools/previews")
// to Package.swift temporarily, then
//   swift run TTSMLXPreviews <output-dir> [model-id,...]
// With PREVIEWS_MANIFEST_ONLY=1 it only records the clips already on disk.
// It writes manifest.json (every catalog entry, with languages, voices and
// capabilities) and one WAV per clip spec below, skipping clips that already
// exist so it can be run in several passes on a disk-constrained machine.
// Tools/render-previews.py turns the output into Docs/previews.

struct ClipSpec {
    let label: String
    let voice: String?
    let language: String?
    let text: String
}

let english = "The quick brown fox jumps over the lazy dog. This is TTSMLX running on Apple silicon, and numbers like 3.14 and 10:30 should survive."
let french = "Bonjour à tous ! Ceci est un aperçu de la synthèse vocale en français, générée sur Apple Silicon. Est-ce que cela sonne naturel ?"
let german = "Guten Tag! Dies ist eine Vorschau der deutschen Sprachsynthese, erzeugt auf Apple Silicon. Klingt das natürlich?"
let tagged = "Oh, that's hilarious! [laugh] Anyway, we do have a new model in store, and it runs on the phone. Would you like me to read the headlines for you?"

let specs: [String: [ClipSpec]] = [
    "mlx-community/pocket-tts": [
        .init(label: "alba-en", voice: "alba", language: nil, text: english),
        .init(label: "javert-en", voice: "javert", language: nil, text: english),
    ],
    "mlx-community/Soprano-80M-bf16": [.init(label: "default-en", voice: nil, language: nil, text: english)],
    "mlx-community/Soprano-1.1-80M-bf16": [.init(label: "default-en", voice: nil, language: nil, text: english)],
    "mlx-community/Soprano-80M-4bit": [.init(label: "default-en", voice: nil, language: nil, text: english)],
    "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit": [.init(label: "default-en", voice: nil, language: nil, text: english)],
    "mlx-community/VyvoTTS-EN-Beta-4bit": [.init(label: "en-us-1", voice: "en-us-1", language: nil, text: english)],
    "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit": [
        .init(label: "default-en", voice: nil, language: "English", text: english),
        .init(label: "default-fr", voice: nil, language: "French", text: french),
    ],
    "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit": [.init(label: "default-en", voice: nil, language: "English", text: english)],
    "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit": [.init(label: "speaker-en", voice: nil, language: "English", text: english)],
    "mlx-community/Kokoro-82M-bf16": [
        .init(label: "af_heart-en", voice: "af_heart", language: "English", text: english),
        .init(label: "bm_george-en", voice: "bm_george", language: "English", text: english),
        .init(label: "ff_siwis-fr", voice: "ff_siwis", language: "French", text: french),
    ],
    "gradium/phonon-31m-en": [.init(label: "default-en", voice: "default", language: nil, text: english)],
    "mlx-community/MeloTTS-English-MLX": [
        .init(label: "EN-US", voice: "EN-US", language: nil, text: english),
        .init(label: "EN-BR", voice: "EN-BR", language: nil, text: english),
    ],
    "mlx-community/MOSS-TTS-Nano-100M": [
        .init(label: "en_news", voice: "en_news", language: nil, text: english),
        .init(label: "en_2", voice: "en_2", language: nil, text: english),
    ],
    "mlx-community/Ming-3.0-tts-0.5B-bf16": [
        .init(label: "UK_George-en", voice: "UK_George", language: "English", text: english),
        .init(label: "US_Emma-en", voice: "US_Emma", language: "English", text: english),
        .init(label: "UK_George-fr", voice: "UK_George", language: "French", text: french),
    ],
    "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit": [
        .init(label: "casual_male-en", voice: "casual_male", language: "English", text: english),
        .init(label: "fr_female-fr", voice: "fr_female", language: "French", text: french),
    ],
    "mlx-community/OmniVoice": [
        .init(label: "design-en", voice: "female, warm, clear voice", language: "English", text: english),
    ],
    "mlx-community/chatterbox-turbo-4bit": [
        .init(label: "default-en", voice: nil, language: nil, text: english),
        .init(label: "default-tags", voice: nil, language: nil, text: tagged),
    ],
    "mlx-community/chatterbox-4bit": [
        .init(label: "default-en", voice: nil, language: "English", text: english),
        .init(label: "default-fr", voice: nil, language: "French", text: french),
        .init(label: "default-de", voice: nil, language: "German", text: german),
    ],
]

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: TTSMLXPreviews <output-dir> [model-id,...]"); exit(2) }
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let only: Set<String>? = args.count >= 3 ? Set(args[2].split(separator: ",").map(String.init)) : nil
let manifestOnly = ProcessInfo.processInfo.environment["PREVIEWS_MANIFEST_ONLY"] != nil
MLX.Memory.cacheLimit = 512 * 1_048_576

func slug(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "__") }

func duration(_ url: URL) -> Double {
    guard let f = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(f.length) / f.processingFormat.sampleRate
}

let store = TTSModelStore()
let synth = TTSSpeechSynthesizer(modelStore: store)
let validated = Set(TTSMLX.supportedModels.map(\.id))
var manifest: [[String: Any]] = []

for entry in TTSMLX.modelCatalog {
    var record: [String: Any] = [
        "id": entry.id,
        "displayName": entry.displayName,
        "summary": entry.summary,
        "supportStage": validated.contains(entry.id) ? "validated" : "\(entry.supportStage)",
        "languages": entry.supportedLanguages.map(\.identifier),
        "runtimeNotes": entry.runtimeNotes ?? "",
        "modelURL": entry.modelURL?.absoluteString ?? "",
        "projectURL": entry.projectURL?.absoluteString ?? "",
    ]
    if let d = entry.descriptor {
        record["voices"] = d.suggestedVoices.map(\.identifier)
        record["supportsReferenceAudio"] = d.capabilities.supportsReferenceAudio
        record["supportsStreaming"] = d.capabilities.supportsStreaming
        record["peakMemoryMB"] = d.capabilities.peakMemoryMB ?? 0
        record["minimumDeviceClass"] = d.capabilities.minimumDeviceClass.map { "\($0)" } ?? ""
        record["defaultGenerationProfile"] = "\(d.capabilities.defaultGenerationProfile)"
        record["files"] = d.files ?? []
        record["features"] = d.sortedFeatures.map(\.displayName)
        record["license"] = entry.license.name
        record["usageTier"] = entry.license.tier.displayName
        record["eventTags"] = d.supportedEventTags.map { "\($0.marker) → \(d.capabilities.eventTags[$0]!)" }
        record["sampleRate"] = d.capabilities.sampleRate ?? 0
        record["voiceDetails"] = d.suggestedVoices.map {
            ["id": $0.identifier, "name": $0.name, "language": $0.language?.identifier ?? "",
             "gender": $0.gender?.rawValue ?? "", "summary": $0.summary ?? ""]
        }
    }
    var clips: [[String: Any]] = []
    if let d = entry.descriptor, let list = specs[entry.id] {
        // `only` (argv) and PREVIEWS_MANIFEST_ONLY gate generation; clips that
        // already exist on disk are always recorded so the manifest stays
        // complete across passes.
        let mayGenerate = !manifestOnly && (only == nil || only!.contains(entry.id))
        for spec in list {
            let file = outDir.appendingPathComponent("\(slug(entry.id))--\(spec.label).wav")
            if FileManager.default.fileExists(atPath: file.path) {
                clips.append(["label": spec.label, "file": file.lastPathComponent, "voice": spec.voice ?? "", "language": spec.language ?? "", "text": spec.text, "seconds": duration(file), "cached": true])
                continue
            }
            guard mayGenerate else { continue }
            do {
                _ = try await store.ensureDownloaded(d)
                let voice = spec.voice.map { TTSVoice($0) } ?? d.suggestedVoices.first
                let options = TTSSynthesisOptions(language: spec.language.map { TTSLanguage($0) }, voice: voice, outputURL: file)
                let t0 = Date()
                let result = try await synth.synthesize(spec.text, using: d, options: options)
                let gen = Date().timeIntervalSince(t0)
                let secs = duration(result.url)
                print(String(format: "OK   %@ %@: %.1fs audio in %.1fs", entry.id, spec.label, secs, gen))
                clips.append(["label": spec.label, "file": file.lastPathComponent, "voice": voice?.identifier ?? "", "language": spec.language ?? "", "text": spec.text, "seconds": secs, "generationSeconds": gen])
            } catch {
                print("FAIL \(entry.id) \(spec.label): \(error)")
                clips.append(["label": spec.label, "error": "\(error)"])
            }
        }
        await synth.releaseRuntimeBuffers()
    }
    record["clips"] = clips
    manifest.append(record)
}

let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outDir.appendingPathComponent("manifest.json"))
print("manifest: \(manifest.count) entries -> \(outDir.path)")
