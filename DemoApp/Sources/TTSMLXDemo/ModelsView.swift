import SwiftUI
import TTSMLX

struct ModelsView: View {
    @Bindable var model: DemoModel
    @State private var isShowingAddSheet = false
    @State private var backgroundState: TTSBackgroundModelDownloader.State = .idle

    /// MOSS is the model worth prefetching: it is the largest, and it needs a
    /// second repository for its codec.
    private var prefetchTarget: TTSModelDescriptor? {
        TTSMLX.modelCatalog
            .first(where: { $0.id == "mlx-community/MOSS-TTS-Nano-100M" })?
            .descriptor
    }

    @ViewBuilder
    private var backgroundDownloadSection: some View {
        Section("Background download") {
            Text("Downloads model weights with a background URLSession, so it "
                 + "keeps going when the app is suspended and resumes if the app "
                 + "is terminated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch backgroundState {
            case .idle:
                startButton
            case .preparing(let modelID):
                Label("Listing files for \(modelID)…", systemImage: "hourglass")
                    .font(.callout)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fractionCompleted)
                    Text("\(Int(progress.fractionCompleted * 100))% · "
                         + "\(progress.filesCompleted)/\(progress.filesTotal) files · "
                         + byteText(progress.completedBytes, progress.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) {
                        TTSBackgroundModelDownloader.shared.cancel()
                    }
                    .font(.caption.weight(.semibold))
                }
            case .finished(let modelID):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Downloaded — ready offline", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.semibold))
                    Text(modelID).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(_, let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    startButton
                }
            }
        }
    }

    @ViewBuilder
    private var startButton: some View {
        if let descriptor = prefetchTarget {
            Button {
                Task {
                    try? await TTSBackgroundModelDownloader.shared.startDownload(for: descriptor)
                }
            } label: {
                Label("Download \(descriptor.displayName) in background", systemImage: "arrow.down.circle")
            }
        } else {
            Text("No prefetchable model in the catalog.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func byteText(_ completed: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: completed)) / \(formatter.string(fromByteCount: total))"
    }

    var body: some View {
        NavigationStack {
            List {
                backgroundDownloadSection

                Section("Built-in models") {
                    ForEach(TTSMLX.validatedModels) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayName)
                                .font(.headline)
                            Text(entry.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Custom models") {
                    if model.customModels.descriptors.isEmpty {
                        Text("No custom models yet. Tap + to add a direct-download endpoint.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.customModels.descriptors) { descriptor in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(descriptor.displayName)
                                    .font(.headline)
                                Text(descriptor.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let url = descriptor.modelURL {
                                    Text(url.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let files = descriptor.files, !files.isEmpty {
                                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    model.customModels.remove(id: descriptor.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Models")
            .task {
                // Replays current state on subscribe, so returning to this tab
                // after a relaunch shows an in-flight download rather than a
                // stale idle state.
                for await state in TTSBackgroundModelDownloader.shared.events() {
                    backgroundState = state
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingAddSheet = true
                    } label: {
                        Label("Add custom model", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingAddSheet) {
                AddCustomModelSheet(registry: model.customModels)
            }
        }
    }
}

struct AddCustomModelSheet: View {
    let registry: CustomModelRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var id: String = ""
    @State private var displayName: String = ""
    @State private var baseURL: String = ""
    @State private var filesText: String = ""

    private var parsedFiles: [String] {
        filesText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var parsedURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private var canSave: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedURL != nil
            && !parsedFiles.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("ID (e.g. acme/cloudflare-tts-v1)", text: $id)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Display name (optional)", text: $displayName)
                }

                Section("Download") {
                    TextField("Base URL (e.g. https://models.acme.com/tts/v1)", text: $baseURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files (one per line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $filesText)
                            .frame(minHeight: 120)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Add custom model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = parsedURL, !trimmedID.isEmpty else { return }

        let descriptor = TTSModelDescriptor(
            id: trimmedID,
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            capabilities: .init(isRuntimeSupported: true),
            modelURL: url,
            files: parsedFiles
        )
        registry.add(descriptor)
    }
}
