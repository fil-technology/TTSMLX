import SwiftUI
import TTSMLX

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var model = DemoModel()
    @State private var isShowingIOSOptions = false
    @FocusState private var isComposerFocused: Bool
    @State private var hasShownComposerHint = false
    @State private var isShowingComposerHint = false

    #if os(iOS)
    private let composerMinHeight: CGFloat = 64
    private let composerMaxHeight: CGFloat = 104
    #endif

    var body: some View {
        #if os(iOS)
        iosBody
        #else
        macBody
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isComposerFocused = false
                }

            VStack(spacing: 0) {
                HStack {
                    Text("TTSMLX Voice")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        isShowingIOSOptions = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(.thinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer(minLength: 24)

                VStack(spacing: 18) {
                    ActivityOrbView(
                        state: model.activityState == .idle ? .playing : model.activityState,
                        progress: model.progressValue
                    )
                    .frame(width: 184, height: 184)

                    VStack(spacing: 8) {
                        Text(primaryStatusTitle)
                            .font(.title2.weight(.semibold))

                        Text(secondaryStatusMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)

                        if let progressValue = model.progressValue {
                            ProgressView(value: progressValue)
                                .tint(Self.activityColor(for: model.activityState == .idle ? .playing : model.activityState))
                                .padding(.horizontal, 40)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        isShowingIOSOptions = true
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.selectedModel.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(model.selectedVoiceMode.title) • \(model.selectedLanguageMode.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let metadata = model.selectedModelMetadata {
                                        Text("Size: \(metadata.storageSizeBytes.map(formatByteCount) ?? "Unknown")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if !model.isInstalled(model.selectedModelID) {
                                    Text(downloadLabelText)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }

                            if model.isDownloading(model.selectedModelID) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if !model.progressMessage.isEmpty {
                                        Text(model.progressMessage)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    ProgressView(value: model.progressValue ?? 0)
                                        .tint(.blue)

                                    if let progressValue = model.progressValue {
                                        Text("\(Int(progressValue * 100))% downloaded")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Button {
                                openSelectedModelPage()
                            } label: {
                                Label("Open on Hugging Face", systemImage: "link")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                            if model.isInstalled(model.selectedModelID) {
                                Button(role: .destructive) {
                                    Task { await model.removeSelectedModel() }
                                } label: {
                                    Label("Delete downloaded model", systemImage: "trash")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            iosComposer
        }
        .sheet(isPresented: $isShowingIOSOptions) {
            iosOptionsSheet
        }
        .task {
            await model.loadInitialData()
        }
    }
    #endif

    #if os(iOS)
    private var iosComposer: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: composerHeight)

                ZStack(alignment: .topLeading) {
                    if model.inputText.isEmpty {
                        Text("Text to speak")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                            .padding(.top, 18)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $model.inputText)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.primary)
                        .focused($isComposerFocused)
                        .padding(.leading, 16)
                        .padding(.trailing, 72)
                        .padding(.vertical, 10)
                        .frame(height: composerHeight, alignment: .leading)
                }
                .frame(height: composerHeight)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .onTapGesture {
                    isComposerFocused = true
                    showComposerHintIfNeeded()
                }

                composerPrimaryButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .frame(height: composerHeight, alignment: .bottomTrailing)
            }
            .frame(height: composerHeight)

            if isShowingComposerHint {
                ComposerTipBubble(text: model.hasGeneratedAudioForCurrentInput ? "Tap to play. Long press to stream." : "Tap to generate. Long press to stream.")
                    .padding(.trailing, 8)
                    .offset(y: -56)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.2), value: isShowingComposerHint)
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                showComposerHintIfNeeded()
            }
        }
    }
    #endif

    #if os(iOS)
    private var composerPrimaryButton: some View {
        let isBusy = model.isSynthesizing || model.isStreaming
        let isDisabled = model.trimmedInputText.isEmpty && !isBusy

        return Circle()
            .fill(isDisabled ? Color.white.opacity(0.28) : Color.white)
            .frame(width: 42, height: 42)
            .overlay {
                if isBusy {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: model.composerPrimarySymbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                guard !isDisabled else { return }
                isComposerFocused = false
                Task { await model.performPrimaryComposerAction() }
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                guard !isDisabled, !isBusy else { return }
                isComposerFocused = false
                Task { await model.streamSpeak() }
            }
            .accessibilityElement()
            .accessibilityLabel(model.composerPrimaryLabel)
            .accessibilityHint("Long press to stream audio.")
    }
    #endif

    #if os(iOS)
    private func showComposerHintIfNeeded() {
        guard hasShownComposerHint == false else { return }
        hasShownComposerHint = true
        withAnimation(.spring(duration: 0.28)) {
            isShowingComposerHint = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.2)) {
                isShowingComposerHint = false
            }
        }
    }
    #endif

    #if os(iOS)
    private var composerHeight: CGFloat {
        let newlineCount = model.inputText.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        let estimatedLineCount = max(1, min(3, newlineCount + 1))
        return min(composerMaxHeight, composerMinHeight + CGFloat(estimatedLineCount - 1) * 20)
    }
    #endif

    #if os(iOS)
    private var primaryStatusTitle: String {
        model.activityState == .idle ? "Ready" : model.activityState.title
    }
    #endif

    #if os(iOS)
    private var secondaryStatusMessage: String {
        if !model.progressMessage.isEmpty {
            return model.progressMessage
        }
        if model.activityState == .idle {
            return model.status == "Ready" ? "Enter text to generate speech." : model.status
        }
        if model.status == primaryStatusTitle {
            return "Working with \(model.selectedModel.displayName)."
        }
        return model.status
    }
    #endif

    #if os(iOS)
    private var downloadLabelText: String {
        if model.isDownloading(model.selectedModelID), let progressValue = model.progressValue {
            return "Downloading \(Int(progressValue * 100))%"
        }
        return model.isDownloading(model.selectedModelID) ? "Downloading" : "Download"
    }
    #endif

    private func openSelectedModelPage() {
        guard let url = URL(string: "https://huggingface.co/\(model.selectedModel.id)") else { return }
        openURL(url)
    }

    #if os(iOS)
    private var iosOptionsSheet: some View {
        NavigationStack {
            Form {
                Section("Model") {
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
                    .pickerStyle(.navigationLink)

                    LabeledContent("Identifier") {
                        Text(model.selectedModel.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let metadata = model.selectedModelMetadata {
                        LabeledContent("Remote Size") {
                            Text(metadata.storageSizeBytes.map(formatByteCount) ?? "Unknown")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        openSelectedModelPage()
                    } label: {
                        Label("Open on Hugging Face", systemImage: "link")
                    }

                    if !model.isInstalled(model.selectedModelID) {
                        Button("Download Selected Model") {
                            Task { await model.downloadSelectedModel() }
                        }
                    } else {
                        Button("Delete Selected Model", role: .destructive) {
                            Task { await model.removeSelectedModel() }
                        }
                    }

                    if model.isDownloading(model.selectedModelID) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !model.progressMessage.isEmpty {
                                Text(model.progressMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: model.progressValue ?? 0)
                            if let progressValue = model.progressValue {
                                Text("\(Int(progressValue * 100))% downloaded")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Section("Voice & Language") {
                    Picker("Language", selection: $model.selectedLanguageMode) {
                        ForEach(LanguageMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if model.selectedLanguageMode == .custom {
                        TextField("Custom language", text: $model.customLanguage)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Picker("Voice", selection: $model.selectedVoiceMode) {
                        ForEach(model.voiceChoices, id: \.self) { voice in
                            Text(voice.title).tag(voice)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if case .custom = model.selectedVoiceMode {
                        TextField("Custom voice ID", text: $model.customVoice)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Discover Models") {
                    TextField("Search Hugging Face models", text: $model.modelSearchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Search") {
                        Task { await model.searchModels() }
                    }
                    .disabled(model.isSearching)

                    if model.isSearching {
                        ProgressView("Searching…")
                    }

                    if !model.searchedModels.isEmpty {
                        ForEach(model.searchedModels.prefix(5), id: \.id) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    Task { await model.selectModel(item.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.displayName)
                                            .foregroundStyle(.primary)
                                        Text(item.id)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                HStack {
                                    if item.id == model.selectedModelID {
                                        Label("Selected", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !model.isInstalled(item.id) {
                                        Button(model.isDownloading(item.id) ? "Downloading…" : "Download") {
                                            Task { await model.download(modelID: item.id) }
                                        }
                                        .disabled(model.downloadingModelID != nil)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isShowingIOSOptions = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    #endif

    private var macBody: some View {
        GeometryReader { proxy in
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
                .padding(isCompactLayout ? 14 : 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task {
                await model.loadInitialData()
            }
        }
    }

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simple on-device text to speech")
                .font(.title.bold())
            Text("This demo uses the local TTSMLX package, downloads models from Hugging Face when needed, and generates a WAV file with MLX.")
                .foregroundStyle(.secondary)
            Text("Recommended and supported models are only listed here. Nothing is downloaded until you explicitly choose a model and download it, or synthesize with that selected model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isCompactLayout {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    headerActionButtons
                }
            } else {
                HStack(spacing: 12) {
                    headerActionButtons
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var headerActionButtons: some View {
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
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isSynthesizing)

        Button {
            Task { await model.streamSpeak() }
        } label: {
            ZStack {
                Text("Stream Speak")
                    .opacity(model.isStreaming ? 0 : 1)
                if model.isStreaming {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isStreaming || model.isSynthesizing)

        if !model.isInstalled(model.selectedModelID) {
            Button("Download Selected Model") {
                Task { await model.downloadSelectedModel() }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .buttonStyle(.bordered)
            .disabled(model.downloadingModelID != nil)
        }

        Button("Play Last Audio") {
            model.playLatestAudio()
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .buttonStyle(.bordered)

        Button("Stop") {
            model.stopSpeaking()
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .buttonStyle(.bordered)
        .disabled(!model.isPlayingAudio && !model.isStreaming)

        Button("Reveal File") {
            model.revealLatestAudio()
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .buttonStyle(.bordered)
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
        if model.activityState != .idle || !model.progressMessage.isEmpty {
            if isCompactLayout {
                VStack(alignment: .leading, spacing: 14) {
                    ActivityOrbView(
                        state: model.activityState,
                        progress: model.progressValue
                    )
                    .frame(maxWidth: .infinity)

                    progressDescription
                }
                .padding(18)
                .background(sectionBackground)
            } else {
                HStack(spacing: 18) {
                    ActivityOrbView(
                        state: model.activityState,
                        progress: model.progressValue
                    )

                    progressDescription

                    Spacer(minLength: 0)
                }
                .padding(18)
                .background(sectionBackground)
            }
        }
    }

    private var progressDescription: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.activityState.title)
                .font(.headline)

            Text(model.progressMessage.isEmpty ? model.status : model.progressMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let progressValue = model.progressValue {
                ProgressView(value: progressValue)
                    .tint(Self.activityColor(for: model.activityState))
            }

            if model.isPlayingAudio || model.isStreaming {
                Button("Stop Speaking") {
                    model.stopSpeaking()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func activityColor(for state: DemoActivityState) -> Color {
        switch state {
        case .idle:
            return .secondary
        case .searching:
            return .cyan
        case .downloading:
            return .blue
        case .preparing:
            return .indigo
        case .generating:
            return .orange
        case .streaming:
            return .pink
        case .playing:
            return .green
        }
    }

    private static func activityGradient(for state: DemoActivityState) -> AngularGradient {
        let base = activityColor(for: state)
        return AngularGradient(
            colors: [
                base.opacity(0.15),
                base.opacity(0.95),
                .white.opacity(0.9),
                base.opacity(0.35)
            ],
            center: .center
        )
    }

    private static func activityBackground(for state: DemoActivityState) -> LinearGradient {
        let base = activityColor(for: state)
        return LinearGradient(
            colors: [
                base.opacity(0.28),
                base.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

private struct ActivityOrbView: View {
        let state: DemoActivityState
        let progress: Double?

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let primaryRotation = Angle.degrees(time * 110)
                let secondaryRotation = Angle.degrees(time * -75)
                let pulse = 0.88 + (sin(time * 2.2) * 0.08)

                ZStack {
                    Circle()
                        .fill(ContentView.activityBackground(for: state))
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }

                    Circle()
                        .trim(from: 0.08, to: 0.38)
                        .stroke(
                            ContentView.activityGradient(for: state),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(primaryRotation)

                    Circle()
                        .trim(from: 0.55, to: 0.82)
                        .stroke(
                            ContentView.activityGradient(for: state),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(secondaryRotation)
                        .blur(radius: 0.4)

                    if let progress, progress > 0, progress < 1 {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                .white.opacity(0.95),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .padding(8)
                    }

                    Circle()
                        .fill(ContentView.activityGradient(for: state))
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse)
                        .blur(radius: state == .playing ? 0.5 : 0)
                }
                .frame(width: 84, height: 84)
                .shadow(color: ContentView.activityColor(for: state).opacity(0.22), radius: 18, y: 8)
            }
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

                Button {
                    openSelectedModelPage()
                } label: {
                    Label("Open on Hugging Face", systemImage: "link")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)

                if let summary = model.selectedModel.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Languages: \(model.supportedLanguageSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Only the selected model downloads. Models are fetched one at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Supported Models")
                    .font(.subheadline.weight(.semibold))

                ForEach(model.recommendedModels, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName)
                            Text(item.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if let summary = item.summary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        actionRow {
                            Button(item.id == model.selectedModelID ? "Selected" : "Select") {
                                Task { await model.selectModel(item.id) }
                            }
                            .buttonStyle(.bordered)

                            if !model.isInstalled(item.id) {
                                Button(model.isDownloading(item.id) ? "Downloading..." : "Download") {
                                    Task { await model.download(modelID: item.id) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.downloadingModelID != nil)
                            }
                        }
                    }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if let metadata = model.selectedModelMetadata {
                DisclosureGroup("Model Metadata") {
                    VStack(alignment: .leading, spacing: 6) {
                        metadataRow("Pipeline", metadata.pipelineTag ?? "Unknown")
                        metadataRow("Model Type", metadata.modelType ?? "Unknown")
                        metadataRow("License", metadata.license ?? "Unknown")
                        metadataRow("Remote Size", metadata.storageSizeBytes.map(formatByteCount) ?? "Unknown")
                        metadataRow("Sample Rate", metadata.sampleRate.map(String.init) ?? "Unknown")
                        metadataRow("Architectures", metadata.architectures.isEmpty ? "Unknown" : metadata.architectures.joined(separator: ", "))
                        metadataRow("Tags", metadata.tags.isEmpty ? "None" : metadata.tags.prefix(8).joined(separator: ", "))
                    }
                    .padding(.top, 6)
                }
            }

            if isCompactLayout {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search Hugging Face models", text: $model.modelSearchQuery)
                        .textFieldStyle(.roundedBorder)

                    Button("Search") {
                        Task { await model.searchModels() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSearching)
                }
            } else {
                HStack(spacing: 10) {
                    TextField("Search Hugging Face models", text: $model.modelSearchQuery)
                        .textFieldStyle(.roundedBorder)

                    Button("Search") {
                        Task { await model.searchModels() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSearching)
                }
            }

            if model.isSearching {
                ProgressView("Searching models...")
            }

            if !model.searchedModels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Results")
                        .font(.subheadline.weight(.semibold))

                    ForEach(model.searchedModels.prefix(6), id: \.id) { item in
                        VStack(alignment: .leading, spacing: 12) {
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

                            actionRow {
                                if !model.isInstalled(item.id) {
                                    Button(model.isDownloading(item.id) ? "Downloading..." : "Download") {
                                        Task { await model.download(modelID: item.id) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.downloadingModelID != nil)
                                }
                            }
                        }
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

            if isCompactLayout {
                VStack(alignment: .leading, spacing: 12) {
                    settingsGroup(title: "Language") {
                        languagePicker
                    }
                    settingsGroup(title: "Voice") {
                        voicePicker
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    settingsGroup(title: "Language") {
                        languagePicker
                    }
                    settingsGroup(title: "Voice") {
                        voicePicker
                    }
                }
            }
        }
        .padding(18)
        .background(sectionBackground)
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Language", selection: $model.selectedLanguageMode) {
                ForEach(LanguageMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            if model.selectedLanguageMode == .custom {
                TextField("Custom language", text: $model.customLanguage)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Voice", selection: $model.selectedVoiceMode) {
                ForEach(model.voiceChoices, id: \.self) { voice in
                    Text(voice.title).tag(voice)
                }
            }
            .pickerStyle(.menu)
            if case .custom = model.selectedVoiceMode {
                TextField("Custom voice ID", text: $model.customVoice)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.descriptor.displayName)
                            Text(item.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Delete", role: .destructive) {
                                Task { await model.removeModel(id: item.id) }
                            }
                            .buttonStyle(.bordered)
                        }
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
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.audio.url.lastPathComponent)
                            Text(record.modelName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        actionRow {
                            Button("Play") {
                                model.playAudio(record)
                            }
                            .buttonStyle(.bordered)

                            Button("Replay") {
                                model.replayAudio(record)
                            }
                            .buttonStyle(.bordered)

                            Button("Share") {
                                model.shareAudio(record)
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

    private func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private func actionRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if isCompactLayout {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                content()
            }
        } else {
            HStack(spacing: 8) {
                content()
            }
        }
    }
}

#if os(iOS)
private struct ComposerTipBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Triangle()
                .fill(.thinMaterial)
                .frame(width: 14, height: 10)
                .offset(x: -18, y: 8)
        }
        .frame(maxWidth: 260, alignment: .trailing)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
#endif
