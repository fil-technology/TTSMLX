import SwiftUI

struct TabRootView: View {
    @State private var model = DemoModel()

    var body: some View {
        TabView {
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
