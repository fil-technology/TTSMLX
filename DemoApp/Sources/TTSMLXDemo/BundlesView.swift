import SwiftUI
import TTSMLX

struct BundlesView: View {
    @Bindable var model: DemoModel
    @State private var bundles: [DemoModel.PreparedBundleEntry] = []
    @State private var isShowingBakeSheet = false
    @State private var playingBundleURL: URL?
    @State private var currentWord: String = ""

    var body: some View {
        NavigationStack {
            List {
                if bundles.isEmpty {
                    Section {
                        Text("No baked bundles yet. Tap 'Bake new' to generate one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(bundles) { entry in
                            BundleRow(
                                entry: entry,
                                isPlaying: playingBundleURL == entry.url,
                                currentWord: playingBundleURL == entry.url ? currentWord : ""
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                play(entry)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bundles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingBakeSheet = true
                    } label: {
                        Label("Bake new", systemImage: "plus")
                    }
                }
                if playingBundleURL != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .destructive) {
                            stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingBakeSheet, onDismiss: refresh) {
                BakeBundleSheet(model: model)
            }
            .task { refresh() }
            .refreshable { refresh() }
        }
    }

    private func refresh() {
        bundles = model.bakedBundles()
    }

    private func play(_ entry: DemoModel.PreparedBundleEntry) {
        do {
            playingBundleURL = entry.url
            currentWord = ""
            try model.playBundle(
                at: entry.url,
                onWord: { timing in
                    let text = entry.sourceText
                    let utf16Count = text.utf16.count
                    let lower = timing.characterRange.lowerBound
                    let upper = min(timing.characterRange.upperBound, utf16Count)
                    guard lower >= 0, lower < upper, upper <= utf16Count else { return }
                    let startIdx = String.Index(utf16Offset: lower, in: text)
                    let endIdx = String.Index(utf16Offset: upper, in: text)
                    guard startIdx < endIdx else { return }
                    currentWord = String(text[startIdx..<endIdx])
                },
                onPlaybackEnd: {
                    playingBundleURL = nil
                    currentWord = ""
                }
            )
        } catch {
            model.status = "Bundle playback failed: \(error.localizedDescription)"
            playingBundleURL = nil
        }
    }

    private func stop() {
        model.stopBundlePlayback()
        playingBundleURL = nil
        currentWord = ""
    }

    private func delete(_ entry: DemoModel.PreparedBundleEntry) {
        if playingBundleURL == entry.url {
            stop()
        }
        model.deleteBundle(at: entry.url)
        refresh()
    }
}

private struct BundleRow: View {
    let entry: DemoModel.PreparedBundleEntry
    let isPlaying: Bool
    let currentWord: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.displayName)
                    .font(.headline)
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                }
                Spacer()
                Text(formatDuration(entry.totalDuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(entry.sourcePreview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Label(entry.modelID, systemImage: "cpu")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.chunkCount) chunk\(entry.chunkCount == 1 ? "" : "s")")
                Text(entry.modifiedAt, style: .date)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            if isPlaying, !currentWord.isEmpty {
                Text("Now: \(currentWord)")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let total = Int(value.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct BakeBundleSheet: View {
    @Bindable var model: DemoModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat."
    @State private var modelID: String = ""
    @State private var voiceMode: VoiceMode = .automatic
    @State private var filename: String = "chapter-1"
    @State private var mode: DemoModel.BakeMode = .oneShot
    @State private var isBaking = false
    @State private var errorMessage: String?

    private var selectedDescriptor: TTSModelDescriptor? {
        model.allModels.first { $0.id == modelID }
    }

    private var voiceOptions: [VoiceMode] {
        guard let descriptor = selectedDescriptor else { return [.automatic] }
        return [.automatic] + descriptor.suggestedVoices.map { .preset($0) }
    }

    private var canBake: Bool {
        !isBaking
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedDescriptor != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                }

                Section("Model") {
                    Picker("Model", selection: $modelID) {
                        ForEach(model.allModels) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    Picker("Voice", selection: $voiceMode) {
                        ForEach(voiceOptions, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section("Output") {
                    TextField("Filename", text: $filename)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Picker("Mode", selection: $mode) {
                        Text(DemoModel.BakeMode.oneShot.title).tag(DemoModel.BakeMode.oneShot)
                        Text(DemoModel.BakeMode.streamCache.title).tag(DemoModel.BakeMode.streamCache)
                    }
                    .pickerStyle(.segmented)
                }

                if isBaking {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            if let p = model.progressValue {
                                ProgressView(value: p)
                            } else {
                                ProgressView()
                            }
                            Text(model.progressMessage.isEmpty ? "Working..." : model.progressMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Bake bundle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isBaking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bake") {
                        Task { await bake() }
                    }
                    .disabled(!canBake)
                }
            }
            .onAppear {
                if modelID.isEmpty {
                    modelID = model.selectedModelID
                }
            }
        }
    }

    private func bake() async {
        guard let descriptor = selectedDescriptor else { return }
        isBaking = true
        errorMessage = nil
        defer { isBaking = false }

        let voice: TTSVoice?
        switch voiceMode {
        case .automatic: voice = nil
        case .preset(let v): voice = v
        case .custom: voice = nil
        }

        do {
            try await model.bake(
                text: text,
                model: descriptor,
                voice: voice,
                filename: filename,
                mode: mode
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
