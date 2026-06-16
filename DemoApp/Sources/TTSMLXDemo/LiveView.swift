import SwiftUI
import TTSMLX

/// Realtime conversational loop reviewer. Simulates the "external STT → this
/// framework speaks → repeat" flow: type what you "said" (standing in for a
/// recognizer's transcript) and press Send. Each Send speaks with low latency,
/// and (with barge-in on) a new Send instantly cuts off the current turn —
/// exactly what a live back-and-forth needs.
struct LiveView: View {
    @Bindable var model: DemoModel

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            conversation
            inputBar
        }
        .padding()
        #if os(macOS)
        .navigationTitle("Live")
        #endif
    }

    private var header: some View {
        HStack {
            Picker("Voice model", selection: $model.readerSelectedModelID) {
                ForEach(model.readerModelChoices) { choice in
                    Text(choice.stage == .validated ? choice.label : "\(choice.label) · \(choice.stage.title.lowercased())")
                        .tag(choice.id)
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            if let latency = model.realtimeLastLatency {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1fs", latency)).monospacedDigit().bold()
                    Text("first word").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.realtimeTurns) { turn in
                        bubble(turn).id(turn.id)
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: model.realtimeTurns.count) { _, _ in
                if let last = model.realtimeTurns.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func bubble(_ turn: DemoModel.RealtimeTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(attributed(turn))
                .font(.system(size: 17))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(bubbleColor(turn.status)))
            Text(statusLabel(turn.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(_ turn: DemoModel.RealtimeTurn) -> AttributedString {
        var attr = AttributedString(turn.text)
        guard model.realtimeHighlightTurn == turn.id, let hl = model.realtimeHighlight else { return attr }
        let lo = max(0, hl.lowerBound)
        let hi = min(turn.text.count, hl.upperBound)
        guard lo < hi else { return attr }
        let chars = attr.characters
        let start = chars.index(chars.startIndex, offsetBy: lo, limitedBy: chars.endIndex) ?? chars.endIndex
        let end = chars.index(chars.startIndex, offsetBy: hi, limitedBy: chars.endIndex) ?? chars.endIndex
        guard start < end else { return attr }
        attr[start..<end].backgroundColor = .yellow
        attr[start..<end].foregroundColor = .black
        attr[start..<end].font = .system(size: 17, weight: .bold)
        return attr
    }

    private func bubbleColor(_ status: DemoModel.RealtimeTurnStatus) -> Color {
        switch status {
        case .speaking: return .accentColor.opacity(0.18)
        case .done: return .gray.opacity(0.15)
        case .interrupted: return .orange.opacity(0.18)
        case .failed: return .red.opacity(0.18)
        }
    }

    private func statusLabel(_ status: DemoModel.RealtimeTurnStatus) -> String {
        switch status {
        case .speaking: return "speaking…"
        case .done: return "done"
        case .interrupted: return "interrupted (barge-in)"
        case .failed(let message): return "failed: \(message)"
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let progress = model.realtimeProgress {
                ProgressView(value: progress) {
                    Text(model.realtimeStatus).font(.caption)
                }
                .progressViewStyle(.linear)
            }
            HStack {
                Text(model.realtimeStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Toggle("Barge-in on send", isOn: $model.realtimeBargeIn)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Type what you ‘said’ (stand-in for speech-to-text)…", text: $model.realtimeInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.realtimeSend() }

                Button { model.realtimeSend() } label: { Label("Send", systemImage: "paperplane.fill") }
                    .disabled(model.realtimeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { model.realtimeInterrupt() } label: { Label("Stop", systemImage: "stop.fill") }
                Button { model.realtimeReset() } label: { Label("Clear", systemImage: "trash") }
            }
            .buttonStyle(.bordered)
        }
    }
}
