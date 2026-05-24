import SwiftUI

@main
struct TTSMLXDemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabRootView()
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 680)
                #endif
        }
    }
}
