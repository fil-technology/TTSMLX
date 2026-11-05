import SwiftUI

struct TabRootView: View {
    @State private var model = DemoModel()

    var body: some View {
        tabs
            // Synthesis must not be interrupted by auto-lock: a backgrounded app
            // loses Metal compute. Keep the screen on while the demo generates.
            .onChange(of: model.isSynthesizing || model.isStreaming, initial: true) { _, busy in
                KeepAwake.set(busy)
            }
    }

    private var tabs: some View {
        TabView {
            ReaderView(model: model)
                .tabItem {
                    Label("Reader", systemImage: "book")
                }

            LiveView(model: model)
                .tabItem {
                    Label("Live", systemImage: "bubble.left.and.bubble.right")
                }

            ContentView(model: model)
                .tabItem {
                    Label("Synthesize", systemImage: "waveform")
                }

            BundlesView(model: model)
                .tabItem {
                    Label("Bundles", systemImage: "tray.full")
                }

            ModelsView(model: model)
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }
        }
    }
}
