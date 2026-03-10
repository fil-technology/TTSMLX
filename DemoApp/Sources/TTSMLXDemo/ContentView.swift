import SwiftUI
import TTSMLX

struct ContentView: View {
    @State private var model = DemoModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    progressSection
                    textSection
                    modelSection
                    optionsSection
                    generatedAudioSection
                    installedSection
                    statusSection
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("TTSMLX Demo")
            .task {
                await model.loadInitialData()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simple on-device text to speech")
                .font(.title.bold())
            Text("This demo uses the local TTSMLX package, downloads models from Hugging Face when needed, and generates a WAV file with MLX.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    Task { await model.synthesize() }
                } label: {
                    ZStack {
                        Text("Synthesize")
                            .opacity(model.isSynthesizing ? 0 : 1)
                        if model.isSynthesizing {
                            ProgressView()
                        }
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSynthesizing)

                Button {
                    Task { await model.streamSpeak() }
                } label: {
                    if model.isStreaming {
                        ProgressView()
                    } else {
                        Text("Stream Speak")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStreaming || model.isSynthesizing)

                Button("Download Model") {
                    Task { await model.downloadSelectedModel() }
                }
                .buttonStyle(.bordered)

                Button("Play Last Audio") {
                    model.playLatestAudio()
                }
                .buttonStyle(.bordered)

                Button("Reveal File") {
                    model.revealLatestAudio()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text")
                .font(.headline)

            TextEditor(text: $model.inputText)
                .font(.body)
                .frame(minHeight: 160)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(18)
        .background(sectionBackground)
    }

    @ViewBuilder
    private var progressSection: some View {
        if !model.progressMessage.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Progress")
                    .font(.headline)

                if let progressValue = model.progressValue {
                    ProgressView(value: progressValue)
                } else {
                    ProgressView()
                }

                Text(model.progressMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(18)
            .background(sectionBackground)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)

            Picker(
                "Selected Model",
                selection: Binding(
                    get: { model.selectedModelID },
                    set: { newValue in
                        Task { await model.selectModel(newValue) }
                    }
                )
            ) {
                ForEach(model.allModels, id: \.id) { item in
                    Text(item.displayName).tag(item.id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedModel.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if let summary = model.selectedModel.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Languages: \(model.supportedLanguageSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let metadata = model.selectedModelMetadata {
                DisclosureGroup("Model Metadata") {
                    VStack(alignment: .leading, spacing: 6) {
                        metadataRow("Pipeline", metadata.pipelineTag ?? "Unknown")
                        metadataRow("Model Type", metadata.modelType ?? "Unknown")
                        metadataRow("License", metadata.license ?? "Unknown")
                        metadataRow("Sample Rate", metadata.sampleRate.map(String.init) ?? "Unknown")
                        metadataRow("Architectures", metadata.architectures.isEmpty ? "Unknown" : metadata.architectures.joined(separator: ", "))
                        metadataRow("Tags", metadata.tags.isEmpty ? "None" : metadata.tags.prefix(8).joined(separator: ", "))
                    }
                    .padding(.top, 6)
                }
            }

            HStack {
                TextField("Search Hugging Face models", text: $model.modelSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Button("Search") {
                    Task { await model.searchModels() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isSearching)
            }

            if model.isSearching {
                ProgressView("Searching models...")
            }

            if !model.searchedModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Results")
                        .font(.subheadline.weight(.semibold))

                    ForEach(model.searchedModels.prefix(6), id: \.id) { item in
                        Button {
                            Task { await model.selectModel(item.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .foregroundStyle(.primary)
                                    Text(item.id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.id == model.selectedModelID {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Language")
                        .font(.subheadline.weight(.semibold))
                    Picker("Language", selection: $model.selectedLanguageMode) {
                        ForEach(LanguageMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.selectedLanguageMode == .custom {
                        TextField("Custom language", text: $model.customLanguage)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice")
                        .font(.subheadline.weight(.semibold))
                    Picker("Voice", selection: $model.selectedVoiceMode) {
                        ForEach(model.voiceChoices, id: \.self) { voice in
                            Text(voice.title).tag(voice)
                        }
                    }
                    if case .custom = model.selectedVoiceMode {
                        TextField("Custom voice ID", text: $model.customVoice)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Models")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshInstalledModels() }
                }
                .buttonStyle(.bordered)
            }

            if model.isLoadingInstalled {
                ProgressView("Loading installed models...")
            } else if model.installedModels.isEmpty {
                ContentUnavailableView(
                    "No Downloaded Models",
                    systemImage: "square.and.arrow.down",
                    description: Text("Download one of the recommended models to start generating speech.")
                )
            } else {
                ForEach(model.installedModels, id: \.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.descriptor.displayName)
                            Text(item.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var generatedAudioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Generated Audio")
                    .font(.headline)
                Spacer()
                Text("\(model.generatedAudios.count) item\(model.generatedAudios.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.generatedAudios.isEmpty {
                ContentUnavailableView(
                    "No Generated Audio Yet",
                    systemImage: "waveform",
                    description: Text("Run `Synthesize` to create WAV files that can be played, exported, or revealed later.")
                )
            } else {
                ForEach(model.generatedAudios) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.audio.url.lastPathComponent)
                                Text(record.modelName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Button("Play") {
                                    model.playAudio(record)
                                }
                                .buttonStyle(.bordered)

                                Button("Replay") {
                                    model.replayAudio(record)
                                }
                                .buttonStyle(.bordered)

                                Button("Export") {
                                    model.exportAudio(record)
                                }
                                .buttonStyle(.bordered)

                                Button("Locate") {
                                    model.revealAudio(record)
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        DisclosureGroup("Details") {
                            VStack(alignment: .leading, spacing: 6) {
                                metadataRow("Model", record.modelID)
                                metadataRow("Language", record.languageDescription)
                                metadataRow("Voice", record.voiceDescription)
                                metadataRow("Sample Rate", "\(record.audio.sampleRate) Hz")
                                metadataRow("Mode", record.streamed ? "Streamed playback" : "WAV file synthesis")
                                metadataRow("Preview", record.textPreview)
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status")
                .font(.headline)

            Text(model.status)
                .textSelection(.enabled)

            if let lastAudio = model.lastAudio {
                Text(lastAudio.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var sectionBackground: some ShapeStyle {
        .thinMaterial
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}
