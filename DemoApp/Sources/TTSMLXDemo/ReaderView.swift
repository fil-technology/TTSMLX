import SwiftUI
import TTSMLX
import UniformTypeIdentifiers
import Darwin

/// Long-text reviewer: drop or paste a long passage, pick a model, and watch it
/// stream with karaoke word-by-word highlighting while a live readout shows
/// time-to-first-word and resident memory — so you can confirm it stays fast
/// and bounded (doesn't pile the whole book into RAM) on real text.
struct ReaderView: View {
    @Bindable var model: DemoModel
    @State private var paragraphs: [ReaderParagraph] = []
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlBar
            statsBar
            Divider()
            textArea
        }
        .padding()
        .onAppear { recomputeParagraphs() }
        .onChange(of: model.readerText) { _, _ in recomputeParagraphs() }
        #if os(macOS)
        .navigationTitle("Reader")
        #endif
    }

    // MARK: - Controls

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Model", selection: $model.readerSelectedModelID) {
                    ForEach(model.readerModelChoices) { choice in
                        Text(choice.stage == .validated ? choice.label : "\(choice.label) · \(choice.stage.title.lowercased())")
                            .tag(choice.id)
                    }
                }
                .frame(maxWidth: 360)
                .disabled(model.readerIsActive)

                Spacer()

                Stepper(value: $model.readerLookAheadSeconds, in: 0...60, step: 2) {
                    Text(model.readerLookAheadSeconds <= 0
                         ? "Look-ahead: unbounded"
                         : "Look-ahead: \(Int(model.readerLookAheadSeconds)) s")
                    .monospacedDigit()
                }
                .frame(maxWidth: 240)
                .disabled(model.readerIsActive)
            }

            HStack(spacing: 10) {
                if model.readerIsActive {
                    Button(role: .destructive) { model.stopReader() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    Button { model.playbackController.pause() } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    Button { model.playbackController.resume() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button { model.startReader() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.readerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button { model.readerText = Self.sampleText; recomputeParagraphs() } label: {
                        Label("Load sample", systemImage: "text.append")
                    }
                    Button { model.readerText = ""; paragraphs = [] } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .disabled(model.readerText.isEmpty)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Stats

    private var statsBar: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
            HStack(spacing: 16) {
                Label(model.readerStatus, systemImage: "info.circle")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let ttf = model.readerTimeToFirstWord {
                    metric("first word", String(format: "%.1fs", ttf))
                }
                metric("memory", "\(Int(residentMemoryMB())) MB")
                metric("words", "\(paragraphs.reduce(0) { $0 + $1.text.split(separator: " ").count })")
            }
            .font(.callout)
            .overlay(alignment: .bottom) {
                if let p = model.readerProgress, model.readerTimeToFirstWord == nil {
                    ProgressView(value: p).offset(y: 12)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).monospacedDigit().bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Text area (editor when idle, karaoke when playing)

    @ViewBuilder
    private var textArea: some View {
        if model.readerIsActive || model.readerHighlight != nil {
            karaokeView
        } else {
            editorView
        }
    }

    private var editorView: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.readerText)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            if model.readerText.isEmpty {
                Text("Drop a .txt file here, or paste a long passage…")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .text, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            Task { @MainActor in
                if let text = await Self.loadDroppedText(from: providers) {
                    model.readerText = text
                    recomputeParagraphs()
                }
            }
            return true
        }
    }

    private var karaokeView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(paragraphs) { para in
                        Text(attributed(for: para))
                            .font(.system(size: 19))
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(para.id)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            .onChange(of: model.readerHighlight?.lowerBound) { _, _ in
                guard let id = activeParagraphID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Karaoke rendering helpers

    private var activeParagraphID: Int? {
        guard let hl = model.readerHighlight else { return nil }
        return paragraphs.first { hl.lowerBound >= $0.start && hl.lowerBound < $0.start + $0.text.count }?.id
    }

    private func attributed(for para: ReaderParagraph) -> AttributedString {
        var attr = AttributedString(para.text)
        guard let hl = model.readerHighlight else { return attr }
        let paraEnd = para.start + para.text.count
        let lo = max(hl.lowerBound, para.start)
        let hi = min(hl.upperBound, paraEnd)
        guard lo < hi else { return attr }
        let chars = attr.characters
        let startIdx = chars.index(chars.startIndex, offsetBy: lo - para.start, limitedBy: chars.endIndex) ?? chars.endIndex
        let endIdx = chars.index(chars.startIndex, offsetBy: hi - para.start, limitedBy: chars.endIndex) ?? chars.endIndex
        guard startIdx < endIdx else { return attr }
        attr[startIdx..<endIdx].backgroundColor = .yellow
        attr[startIdx..<endIdx].foregroundColor = .black
        attr[startIdx..<endIdx].font = .system(size: 19, weight: .bold)
        return attr
    }

    private func recomputeParagraphs() {
        paragraphs = Self.computeParagraphs(model.readerText)
    }

    /// Splits into paragraphs while preserving each paragraph's Character offset
    /// in the full text, matching the coordinate space of `TTSWordTiming.characterRange`.
    static func computeParagraphs(_ text: String) -> [ReaderParagraph] {
        var result: [ReaderParagraph] = []
        var offset = 0
        var id = 0
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(ReaderParagraph(id: id, start: offset, text: line))
                id += 1
            }
            offset += line.count + (i < lines.count - 1 ? 1 : 0) // +1 for the consumed '\n'
        }
        return result
    }

    // MARK: - Drop loading (no captured model in @Sendable closures)

    @MainActor
    static func loadDroppedText(from providers: [NSItemProvider]) async -> String? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await provider.loadDroppedURL(),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            if let string = await provider.loadDroppedString() { return string }
        }
        return nil
    }

    // MARK: - Sample

    static let sampleText = """
    The lighthouse keeper had not spoken to another soul in forty-three days. \
    Each morning he climbed the one hundred and twelve steps, wound the great \
    clockwork that turned the lamp, and watched the grey sea refuse to change.

    On the forty-fourth day, a bottle washed ashore. Inside was a single sheet \
    of paper, folded twice, and on it a question written in a careful hand: \
    "If a light shines and no ship sees it, does it still keep anyone safe?"

    He thought about this for a long time. Then he climbed the stairs again, \
    lit the lamp though it was barely noon, and let it burn for no one in \
    particular — which is to say, for everyone who might yet come.
    """
}

/// A paragraph plus its Character offset in the full reader text.
struct ReaderParagraph: Identifiable, Hashable {
    let id: Int
    let start: Int
    let text: String
}

@MainActor
private extension NSItemProvider {
    func loadDroppedURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = self.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    func loadDroppedString() async -> String? {
        await withCheckedContinuation { continuation in
            _ = self.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }
}

/// Resident physical-memory footprint of this process, for the live readout.
func residentMemoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / (1024 * 1024)
}
