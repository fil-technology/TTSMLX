import AVFoundation
import Foundation
import Observation
import TTSMLX
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private final class AudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
    nonisolated(unsafe) var onFinish: (@MainActor @Sendable (Bool) -> Void)?
    nonisolated(unsafe) var onDecodeError: (@MainActor @Sendable (Error?) -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = self.onFinish
        Task { @MainActor in
            onFinish?(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let onDecodeError = self.onDecodeError
        Task { @MainActor in
            onDecodeError?(error)
        }
    }
}

@MainActor
@Observable
final class DemoModel {
    private struct PersistedSettings: Codable {
        var selectedModelID: String
        var selectedLanguageMode: String
        var customLanguage: String
        var selectedVoiceMode: String
        var customVoice: String
        var selectedGenerationProfile: String
        var maxTokens: String
        var temperature: String
        var topP: String
        var referenceAudioPath: String?
        var referenceText: String?
    }

    struct GeneratedAudioRecord: Identifiable, Hashable {
        let id: UUID
        let audio: TTSAudioFile
        let createdAt: Date
        let modelName: String
        let modelID: String
        let languageID: String
        let languageDescription: String
        let voiceID: String
        let voiceDescription: String
        let sourceText: String
        let textPreview: String
        let streamed: Bool
    }

    var inputText = "Hello from TTSMLX."
    var modelSearchQuery = "mlx tts"
    var selectedGenerationProfile: TTSGenerationProfile = .balanced {
        didSet { persistSettings() }
    }
    var customVoice = "" {
        didSet { persistSettings() }
    }
    var customLanguage = "" {
        didSet { persistSettings() }
    }
    var customMaxTokens = "" {
        didSet { persistSettings() }
    }
    var customTemperature = "" {
        didSet { persistSettings() }
    }
    var customTopP = "" {
        didSet { persistSettings() }
    }
    var customReferenceAudioPath = "" {
        didSet { persistSettings() }
    }
    var customReferenceText = "" {
        didSet { persistSettings() }
    }

    var recommendedModels: [TTSModelDescriptor] = TTSMLX.defaultModels
    var searchedModels: [TTSModelDescriptor] = []
    var installedModels: [TTSInstalledModel] = []
    var generatedAudios: [GeneratedAudioRecord] = []
    var selectedModelMetadata: TTSModelMetadata?

    var selectedModelID: String = TTSMLX.defaultModels.first?.id ?? "" {
        didSet { persistSettings() }
    }
    var selectedLanguageMode: LanguageMode = .automatic {
        didSet { persistSettings() }
    }
    var selectedVoiceMode: VoiceMode = .automatic {
        didSet { persistSettings() }
    }

    var isSearching = false
    var isLoadingInstalled = false
    var isSynthesizing = false
    var isStreaming = false
    var isPlayingAudio = false
    var downloadingModelID: String?
    var status = "Ready"
    var progressMessage = ""
    var progressValue: Double?
    var lastAudio: TTSAudioFile?
    var activityState: DemoActivityState = .idle

    var supportsStreamingForSelectedModel: Bool {
        selectedModel.capabilities.isRuntimeSupported && selectedModel.capabilities.supportsStreaming
    }

    var supportsReferenceAudioForSelectedModel: Bool {
        selectedModel.capabilities.isRuntimeSupported && selectedModel.capabilities.supportsReferenceAudio
    }

    var isSelectedModelRuntimeSupported: Bool {
        selectedModel.capabilities.isRuntimeSupported
    }

    private let synthesizer = TTSSpeechSynthesizer()
    private let store = TTSModelStore()
    private var audioPlayer: AVAudioPlayer?
    private var streamingEngine: AVAudioEngine?
    private var streamingNode: AVAudioPlayerNode?
    private let playerDelegate = AudioPlayerDelegateProxy()
    private var knownInstalledModelIDs = Set<String>()
    private let userDefaults = UserDefaults.standard
    private let settingsKey = "com.filtechnology.ttsmlx.demo.settings"

    init() {
        restoreSettings()

        playerDelegate.onFinish = { [weak self] success in
            guard let self else { return }
            self.audioPlayer = nil
            self.isPlayingAudio = false
            if self.activityState == .playing {
                self.activityState = .idle
            }
            if success {
                self.status = "Playback finished."
            }
        }

        playerDelegate.onDecodeError = { [weak self] error in
            guard let self else { return }
            self.audioPlayer = nil
            self.isPlayingAudio = false
            if self.activityState == .playing {
                self.activityState = .idle
            }
            self.status = "Playback failed: \(error?.localizedDescription ?? "Unknown audio decoding error.")"
        }
    }

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

    var languageOptions: [LanguageMode] {
        var options: [LanguageMode] = [.automatic]
        let languages = selectedModel.capabilities.supportedLanguages.isEmpty
            ? selectedModel.supportedLanguages
            : selectedModel.capabilities.supportedLanguages
        for language in languages {
            let mode: LanguageMode = .preset(language.identifier)
            if options.contains(mode) == false {
                options.append(mode)
            }
        }

        if selectedLanguageMode == .custom || !customLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options.append(.custom)
        }
        return options
    }

    var supportedLanguageSummary: String {
        let languages = (selectedModel.capabilities.supportedLanguages.isEmpty
            ? selectedModel.supportedLanguages
            : selectedModel.capabilities.supportedLanguages)
            .map(\.identifier)
        guard !languages.isEmpty else { return "Unknown" }
        return languages.joined(separator: ", ")
    }

    var trimmedInputText: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentInputRecord: GeneratedAudioRecord? {
        let trimmedInputText = trimmedInputText
        guard !trimmedInputText.isEmpty else { return nil }
        let currentLanguageID = resolvedLanguage()?.identifier ?? "automatic"
        let currentVoiceID = resolvedVoice()?.identifier ?? "automatic"

        return generatedAudios.first(where: {
            $0.sourceText == trimmedInputText &&
            $0.modelID == selectedModel.id &&
            $0.languageID == currentLanguageID &&
            $0.voiceID == currentVoiceID
        })
    }

    var hasGeneratedAudioForCurrentInput: Bool {
        currentInputRecord != nil
    }

    var canGenerateSelectedModel: Bool {
        isSelectedModelRuntimeSupported
    }

    var canDownloadSelectedModel: Bool {
        isSelectedModelRuntimeSupported && !isInstalled(selectedModelID)
    }

    var selectedModelStatusLine: String {
        if isInstalled(selectedModelID) {
            return isSelectedModelRuntimeSupported
                ? "Installed and ready for local generation."
                : "Installed locally, but unsupported by the current MLX runtime."
        }

        if isSelectedModelRuntimeSupported {
            return "Runtime-supported. Download on demand before first synthesis."
        }

        return "Discovery only. This upstream model family is not wired through the current local runtime yet."
    }

    var composerPrimarySymbolName: String {
        if isSynthesizing || isStreaming {
            return "stop.fill"
        }
        return hasGeneratedAudioForCurrentInput ? "play.fill" : "waveform"
    }

    var composerPrimaryLabel: String {
        if isSynthesizing {
            return "Generating"
        }
        if isStreaming {
            return "Streaming"
        }
        if !canGenerateSelectedModel && !hasGeneratedAudioForCurrentInput {
            return "Unavailable"
        }
        return hasGeneratedAudioForCurrentInput ? "Play" : "Generate"
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
        activityState = .searching
        defer { isSearching = false }
        defer {
            if activityState == .searching {
                activityState = .idle
            }
        }

        do {
            searchedModels = try await store.searchModels(query: query)
            sanitizeSelectedModel()
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
            knownInstalledModelIDs.formUnion(installedModels.map(\.id))
            sanitizeSelectedModel()
        } catch {
            status = "Could not read installed models: \(error.localizedDescription)"
        }
    }

    func downloadSelectedModel() async {
        await download(model: selectedModel)
    }

    func download(modelID: String) async {
        guard let descriptor = allModels.first(where: { $0.id == modelID }) else {
            status = "Model not found."
            return
        }
        await download(model: descriptor)
    }

    func isDownloading(_ modelID: String) -> Bool {
        downloadingModelID == modelID
    }

    func isInstalled(_ modelID: String) -> Bool {
        knownInstalledModelIDs.contains(modelID) || installedModels.contains { $0.id == modelID }
    }

    func removeSelectedModel() async {
        await removeModel(id: selectedModelID)
    }

    func removeModel(id: String) async {
        do {
            try await store.removeModel(id: id)
            knownInstalledModelIDs.remove(id)
            installedModels.removeAll { $0.id == id }
            status = "Removed model: \(id)"
            await refreshInstalledModels()
            await refreshSelectedModelMetadata()
        } catch {
            status = "Could not remove model: \(error.localizedDescription)"
        }
    }

    private func download(model: TTSModelDescriptor) async {
        guard model.capabilities.isRuntimeSupported else {
            status = "This model is discoverable, but the current MLX runtime cannot download and synthesize it yet."
            return
        }

        downloadingModelID = model.id
        activityState = .downloading
        progressMessage = "Waiting to download \(model.displayName)..."
        progressValue = nil
        defer {
            downloadingModelID = nil
            if activityState == .downloading {
                activityState = .idle
            }
        }

        do {
            let installed = try await store.ensureDownloaded(model) { update in
                self.apply(progress: update)
            }
            knownInstalledModelIDs.insert(model.id)
            knownInstalledModelIDs.insert(installed.id)
            if installedModels.contains(where: { $0.id == installed.id }) == false {
                installedModels.append(installed)
            }
            status = "Model ready: \(model.displayName)"
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
        guard isSelectedModelRuntimeSupported else {
            status = "This model is listed for discovery, but the current MLX runtime cannot synthesize with it yet."
            return
        }

        let trimmed = trimmedInputText
        guard !trimmed.isEmpty else {
            status = "Enter some text first."
            return
        }

        isSynthesizing = true
        activityState = .preparing
        defer { isSynthesizing = false }
        defer {
            if !isPlayingAudio, activityState != .streaming {
                activityState = .idle
            }
        }

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
        guard isSelectedModelRuntimeSupported else {
            status = "This model is listed for discovery, but the current MLX runtime cannot stream with it yet."
            return
        }

        guard supportsStreamingForSelectedModel else {
            status = "Streaming is not supported for this model."
            return
        }

        let trimmed = trimmedInputText
        guard !trimmed.isEmpty else {
            status = "Enter some text first."
            return
        }

        isStreaming = true
        activityState = .streaming
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
            isPlayingAudio = false
            if activityState == .streaming {
                activityState = .idle
            }
            status = receivedChunk
                ? "Streaming playback finished. The current TTSMLX wrapper exposes streamed buffers only and does not record a file artifact for this run."
                : "No streamed audio chunks received."
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

    func performPrimaryComposerAction() async {
        if isSynthesizing || isStreaming {
            stopSpeaking()
            return
        }

        if let currentInputRecord {
            playAudio(currentInputRecord)
            return
        }

        await synthesize()
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        stopStreamingPlayback()
        isPlayingAudio = false
        progressMessage = ""
        progressValue = nil
        if !isSynthesizing, !isStreaming, downloadingModelID == nil, !isSearching {
            activityState = .idle
        }
        status = "Playback stopped."
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

    func shareAudio(_ record: GeneratedAudioRecord) {
        #if os(macOS)
        guard
            let window = NSApp.keyWindow,
            let contentView = window.contentView
        else {
            NSWorkspace.shared.open(record.audio.url)
            return
        }

        let picker = NSSharingServicePicker(items: [record.audio.url])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
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
        synchronizeSelectedGenerationProfile()
        coerceReferenceInputs()
        coerceSelectedLanguageMode()
    }

    private func synthesisOptions() -> TTSSynthesisOptions {
        .init(
            language: resolvedLanguage(),
            voice: resolvedVoice(),
            referenceAudio: resolvedReferenceAudio(),
            referenceText: resolvedReferenceText(),
            generationProfile: selectedGenerationProfile,
            maxTokens: parsed(customMaxTokens),
            temperature: parsed(customTemperature),
            topP: parsed(customTopP)
        )
    }

    private func resolvedReferenceAudio() -> URL? {
        guard supportsReferenceAudioForSelectedModel else { return nil }
        let trimmedPath = customReferenceAudioPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let expanded = NSString(string: trimmedPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func resolvedReferenceText() -> String? {
        guard supportsReferenceAudioForSelectedModel else { return nil }
        let trimmedText = customReferenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private func parsed(_ value: String) -> Float? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Float(text)
    }

    private func parsed(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    private func resolvedLanguage() -> TTSLanguage? {
        switch selectedLanguageMode {
        case .automatic:
            return nil
        case .preset(let identifier):
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : TTSLanguage(trimmed)
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
        audioPlayer?.delegate = playerDelegate
        audioPlayer?.volume = 1
        audioPlayer?.prepareToPlay()
        audioPlayer?.play()
        isPlayingAudio = true
        activityState = .playing
    }

    private func apply(progress: TTSProgressUpdate) {
        progressMessage = progress.message
        progressValue = progress.fractionCompleted
        switch progress.stage {
        case .resolvingModel, .loadingModel:
            activityState = .preparing
        case .downloadingModel:
            activityState = .downloading
        case .generatingAudio, .writingFile:
            activityState = .generating
        case .completed:
            if isPlayingAudio {
                activityState = .playing
            } else if isStreaming {
                activityState = .streaming
            } else if downloadingModelID == nil, !isSearching {
                activityState = .idle
            }
        }
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
        isPlayingAudio = true
        activityState = .streaming
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
        if isStreaming == false {
            isPlayingAudio = false
        }
    }

    private func appendGeneratedAudio(_ audio: TTSAudioFile, streamed: Bool) {
        let sourceText = trimmedInputText
        let languageID = resolvedLanguage()?.identifier ?? "automatic"
        let voiceID = resolvedVoice()?.identifier ?? "automatic"
        let record = GeneratedAudioRecord(
            id: UUID(),
            audio: audio,
            createdAt: Date(),
            modelName: selectedModel.displayName,
            modelID: selectedModel.id,
            languageID: languageID,
            languageDescription: languageID == "automatic" ? "Automatic" : languageID,
            voiceID: voiceID,
            voiceDescription: voiceID == "automatic" ? "Automatic" : voiceID,
            sourceText: sourceText,
            textPreview: String(sourceText.prefix(120)),
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

    private func persistSettings() {
        let settings = PersistedSettings(
            selectedModelID: selectedModelID,
            selectedLanguageMode: selectedLanguageMode.persistenceValue,
            customLanguage: customLanguage,
            selectedVoiceMode: selectedVoiceMode.persistenceValue,
            customVoice: customVoice,
            selectedGenerationProfile: selectedGenerationProfile.rawValue,
            maxTokens: customMaxTokens,
            temperature: customTemperature,
            topP: customTopP,
            referenceAudioPath: customReferenceAudioPath,
            referenceText: customReferenceText
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: settingsKey)
    }

    private func restoreSettings() {
        guard
            let data = userDefaults.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data)
        else { return }

        let availableModelIDs = Set(TTSMLX.defaultModels.map(\.id))
        if availableModelIDs.contains(settings.selectedModelID) {
            selectedModelID = settings.selectedModelID
        }
        selectedLanguageMode = LanguageMode(persistenceValue: settings.selectedLanguageMode) ?? .automatic
        customLanguage = settings.customLanguage
        selectedVoiceMode = VoiceMode(persistenceValue: settings.selectedVoiceMode) ?? .automatic
        customVoice = settings.customVoice
        selectedGenerationProfile = TTSGenerationProfile(rawValue: settings.selectedGenerationProfile) ?? .balanced
        customMaxTokens = settings.maxTokens
        customTemperature = settings.temperature
        customTopP = settings.topP
        customReferenceAudioPath = settings.referenceAudioPath ?? ""
        customReferenceText = settings.referenceText ?? ""
    }

    private func coerceSelectedLanguageMode() {
        let supported = Set(languageOptions.compactMap { mode in
            switch mode {
            case .preset(let identifier):
                return identifier
            default:
                return nil
            }
        })
        if case .preset(let identifier) = selectedLanguageMode, !supported.contains(identifier) {
            selectedLanguageMode = .automatic
        }
    }

    private func synchronizeSelectedGenerationProfile() {
        let defaultProfile = selectedModel.capabilities.defaultGenerationProfile
        if selectedGenerationProfile != defaultProfile {
            selectedGenerationProfile = defaultProfile
        }
    }

    private func coerceReferenceInputs() {
        if supportsReferenceAudioForSelectedModel {
            return
        }

        if customReferenceAudioPath.isEmpty == false {
            customReferenceAudioPath = ""
        }

        if customReferenceText.isEmpty == false {
            customReferenceText = ""
        }
    }

    private func sanitizeSelectedModel() {
        let availableModelIDs = Set(allModels.map(\.id))
        guard !availableModelIDs.isEmpty else { return }
        guard availableModelIDs.contains(selectedModelID) == false else { return }
        selectedModelID = recommendedModels.first?.id ?? allModels.first?.id ?? selectedModelID
    }
}

enum DemoActivityState: Hashable {
    case idle
    case searching
    case downloading
    case preparing
    case generating
    case streaming
    case playing

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .searching:
            return "Searching"
        case .downloading:
            return "Downloading"
        case .preparing:
            return "Preparing"
        case .generating:
            return "Generating"
        case .streaming:
            return "Streaming"
        case .playing:
            return "Playing"
        }
    }

    var accentColorName: String {
        switch self {
        case .idle:
            return "secondary"
        case .searching:
            return "cyan"
        case .downloading:
            return "blue"
        case .preparing:
            return "indigo"
        case .generating:
            return "orange"
        case .streaming:
            return "pink"
        case .playing:
            return "green"
        }
    }
}

enum LanguageMode: Hashable {
    case automatic
    case preset(String)
    case custom

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .preset(let value): value
        case .custom: "Custom"
        }
    }

    var persistenceValue: String {
        switch self {
        case .automatic: "automatic"
        case .preset(let identifier): "preset:\(identifier)"
        case .custom: "custom"
        }
    }

    init?(persistenceValue: String) {
        switch persistenceValue {
        case "automatic": self = .automatic
        case let value where value.starts(with: "preset:"):
            self = .preset(String(value.dropFirst("preset:".count)))
        case "custom": self = .custom
        case "english": self = .preset("English")
        case "spanish": self = .preset("Spanish")
        default: return nil
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

    var persistenceValue: String {
        switch self {
        case .automatic:
            return "automatic"
        case .preset(let voice):
            return "preset:\(voice.identifier)"
        case .custom:
            return "custom"
        }
    }

    init?(persistenceValue: String) {
        if persistenceValue == "automatic" {
            self = .automatic
            return
        }
        if persistenceValue == "custom" {
            self = .custom
            return
        }
        if persistenceValue.hasPrefix("preset:") {
            self = .preset(TTSVoice(String(persistenceValue.dropFirst("preset:".count))))
            return
        }
        return nil
    }
}
