import AVFoundation
import Foundation
import Observation
import TTSMLX
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class DemoModel {
    struct GeneratedAudioRecord: Identifiable, Hashable {
        let id: UUID
        let audio: TTSAudioFile
        let createdAt: Date
        let modelName: String
        let modelID: String
        let languageDescription: String
        let voiceDescription: String
        let textPreview: String
        let streamed: Bool
    }

    var inputText = "Hello from TTSMLX."
    var modelSearchQuery = "mlx tts"
    var customVoice = ""
    var customLanguage = ""

    var recommendedModels: [TTSModelDescriptor] = TTSMLX.defaultModels
    var searchedModels: [TTSModelDescriptor] = []
    var installedModels: [TTSInstalledModel] = []
    var generatedAudios: [GeneratedAudioRecord] = []
    var selectedModelMetadata: TTSModelMetadata?

    var selectedModelID: String = TTSMLX.defaultModels.first?.id ?? ""
    var selectedLanguageMode: LanguageMode = .automatic
    var selectedVoiceMode: VoiceMode = .automatic

    var isSearching = false
    var isLoadingInstalled = false
    var isSynthesizing = false
    var isStreaming = false
    var status = "Ready"
    var progressMessage = ""
    var progressValue: Double?
    var lastAudio: TTSAudioFile?

    private let synthesizer = TTSSpeechSynthesizer()
    private let store = TTSModelStore()
    private var audioPlayer: AVAudioPlayer?
    private var streamingEngine: AVAudioEngine?
    private var streamingNode: AVAudioPlayerNode?

    var selectedModel: TTSModelDescriptor {
        if let match = allModels.first(where: { $0.id == selectedModelID }) {
            return match
        }
        return recommendedModels.first ?? .init(id: selectedModelID)
    }

    var allModels: [TTSModelDescriptor] {
        var seen = Set<String>()
        let merged = recommendedModels + searchedModels + installedModels.map(\.descriptor)
        return merged.filter { seen.insert($0.id).inserted }
    }

    var voiceChoices: [VoiceMode] {
        [.automatic] + selectedModel.suggestedVoices.map { .preset($0) } + [.custom]
    }

    var supportedLanguageSummary: String {
        let languages = selectedModel.metadata?.languageIdentifiers
            ?? selectedModelMetadata?.languageIdentifiers
            ?? selectedModel.supportedLanguages.map(\.identifier)
        guard !languages.isEmpty else { return "Unknown" }
        return languages.joined(separator: ", ")
    }

    func loadInitialData() async {
        await refreshInstalledModels()
        await refreshSelectedModelMetadata()
    }

    func searchModels() async {
        let query = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchedModels = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchedModels = try await store.searchModels(query: query)
            status = searchedModels.isEmpty ? "No matching models found." : "Found \(searchedModels.count) models."
            await refreshSelectedModelMetadata()
        } catch {
            status = "Model search failed: \(error.localizedDescription)"
        }
    }

    func refreshInstalledModels() async {
        isLoadingInstalled = true
        defer { isLoadingInstalled = false }

        do {
            installedModels = try await store.installedModels()
        } catch {
            status = "Could not read installed models: \(error.localizedDescription)"
        }
    }

    func downloadSelectedModel() async {
        do {
            _ = try await store.ensureDownloaded(selectedModel) { update in
                self.apply(progress: update)
            }
            status = "Model ready: \(selectedModel.displayName)"
            progressMessage = ""
            progressValue = nil
            await refreshInstalledModels()
            await refreshSelectedModelMetadata()
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            progressMessage = ""
            progressValue = nil
        }
    }

    func synthesize() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter some text first."
            return
        }

        isSynthesizing = true
        defer { isSynthesizing = false }

        do {
            let audio = try await synthesizer.synthesize(
                trimmed,
                using: selectedModel,
                options: synthesisOptions(),
                progressHandler: { update in
                    self.apply(progress: update)
                }
            )
            lastAudio = audio
            appendGeneratedAudio(audio, streamed: false)
            status = "Saved audio to \(audio.url.lastPathComponent)"
            progressMessage = ""
            progressValue = nil
            try play(audio)
            await refreshInstalledModels()
        } catch {
            status = "Synthesis failed: \(error.localizedDescription)"
            progressMessage = ""
            progressValue = nil
        }
    }

    func streamSpeak() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Enter some text first."
            return
        }

        isStreaming = true
        defer { isStreaming = false }

        do {
            let stream = try await synthesizer.synthesizeStream(
                trimmed,
                using: selectedModel,
                options: synthesisOptions(),
                progressHandler: { update in
                    self.apply(progress: update)
                }
            )

            try startStreamingPlayback()
            var receivedChunk = false

            for try await chunk in stream {
                receivedChunk = true
                scheduleStreamingBuffer(chunk.buffer)
            }

            progressMessage = ""
            progressValue = nil
            status = receivedChunk ? "Streaming playback finished." : "No streamed audio chunks received."
            await refreshInstalledModels()
        } catch {
            status = "Streaming failed: \(error.localizedDescription)"
            progressMessage = ""
            progressValue = nil
            stopStreamingPlayback()
        }
    }

    func playLatestAudio() {
        guard let lastAudio else {
            status = "No audio has been generated yet."
            return
        }

        do {
            try play(lastAudio)
            status = "Playing \(lastAudio.url.lastPathComponent)"
        } catch {
            status = "Playback failed: \(error.localizedDescription)"
        }
    }

    func revealLatestAudio() {
        guard let lastAudio else {
            status = "No generated file to reveal."
            return
        }

        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([lastAudio.url])
        #else
        UIApplication.shared.open(lastAudio.url)
        #endif
    }

    func playAudio(_ record: GeneratedAudioRecord) {
        do {
            try play(record.audio)
            status = "Playing \(record.audio.url.lastPathComponent)"
        } catch {
            status = "Playback failed: \(error.localizedDescription)"
        }
    }

    func replayAudio(_ record: GeneratedAudioRecord) {
        do {
            audioPlayer?.stop()
            try play(record.audio)
            audioPlayer?.currentTime = 0
            audioPlayer?.play()
            status = "Replaying \(record.audio.url.lastPathComponent)"
        } catch {
            status = "Replay failed: \(error.localizedDescription)"
        }
    }

    func revealAudio(_ record: GeneratedAudioRecord) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([record.audio.url])
        #else
        UIApplication.shared.open(record.audio.url)
        #endif
    }

    func exportAudio(_ record: GeneratedAudioRecord) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.audio.url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                try export(record: record, to: destination)
                status = "Exported to \(destination.lastPathComponent)"
            } catch {
                status = "Export failed: \(error.localizedDescription)"
            }
        }
        #else
        let controller = UIActivityViewController(activityItems: [record.audio.url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .present(controller, animated: true)
        #endif
    }

    func selectModel(_ modelID: String) async {
        selectedModelID = modelID
        await refreshSelectedModelMetadata()
    }

    func refreshSelectedModelMetadata() async {
        do {
            selectedModelMetadata = try await store.fetchMetadata(for: selectedModelID)
        } catch {
            selectedModelMetadata = nil
        }
    }

    private func synthesisOptions() -> TTSSynthesisOptions {
        .init(
            language: resolvedLanguage(),
            voice: resolvedVoice()
        )
    }

    private func resolvedLanguage() -> TTSLanguage? {
        switch selectedLanguageMode {
        case .automatic:
            return nil
        case .english:
            return .english
        case .spanish:
            return .spanish
        case .custom:
            let trimmed = customLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TTSLanguage(trimmed)
        }
    }

    private func resolvedVoice() -> TTSVoice? {
        switch selectedVoiceMode {
        case .automatic:
            return nil
        case .preset(let voice):
            return voice
        case .custom:
            let trimmed = customVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TTSVoice(trimmed)
        }
    }

    private func play(_ audio: TTSAudioFile) throws {
        stopStreamingPlayback()
        configurePlaybackSessionIfNeeded()
        audioPlayer = try AVAudioPlayer(contentsOf: audio.url)
        audioPlayer?.volume = 1
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
    }

    private func apply(progress: TTSProgressUpdate) {
        progressMessage = progress.message
        progressValue = progress.fractionCompleted
    }

    private func configurePlaybackSessionIfNeeded() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.duckOthers, .mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = "Audio session setup failed: \(error.localizedDescription)"
        }
        #endif
    }

    private func startStreamingPlayback() throws {
        stopStreamingPlayback()
        configurePlaybackSessionIfNeeded()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        try engine.start()
        node.play()

        streamingEngine = engine
        streamingNode = node
    }

    private func scheduleStreamingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let engine = streamingEngine, let node = streamingNode else { return }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        if buffer.format == outputFormat {
            node.scheduleBuffer(buffer)
            return
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            return
        }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let estimatedCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedCapacity) else {
            return
        }

        var conversionError: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, status == .haveData || status == .inputRanDry || status == .endOfStream else {
            return
        }

        node.scheduleBuffer(converted)
    }

    private func stopStreamingPlayback() {
        streamingNode?.stop()
        streamingEngine?.stop()
        streamingNode = nil
        streamingEngine = nil
    }

    private func appendGeneratedAudio(_ audio: TTSAudioFile, streamed: Bool) {
        let record = GeneratedAudioRecord(
            id: UUID(),
            audio: audio,
            createdAt: Date(),
            modelName: selectedModel.displayName,
            modelID: selectedModel.id,
            languageDescription: resolvedLanguage()?.identifier ?? "Automatic",
            voiceDescription: resolvedVoice()?.identifier ?? "Automatic",
            textPreview: String(inputText.prefix(120)),
            streamed: streamed
        )
        generatedAudios.insert(record, at: 0)
    }

    private func export(record: GeneratedAudioRecord, to destination: URL) throws {
        let destinationURL = destination.pathExtension.isEmpty
            ? destination.appendingPathExtension("wav")
            : destination
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: record.audio.url, to: destinationURL)
    }
}

enum LanguageMode: Hashable, CaseIterable {
    case automatic
    case english
    case spanish
    case custom

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .spanish: "Spanish"
        case .custom: "Custom"
        }
    }
}

enum VoiceMode: Hashable {
    case automatic
    case preset(TTSVoice)
    case custom

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .preset(let voice):
            return voice.identifier
        case .custom:
            return "Custom"
        }
    }
}
