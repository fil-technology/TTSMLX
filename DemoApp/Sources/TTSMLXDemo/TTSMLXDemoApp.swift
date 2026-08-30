import SwiftUI
import TTSMLX

#if os(iOS)
import UIKit

/// Exists solely to hand background-download events back to TTSMLX.
///
/// A background `URLSession` finishes its work while the app is suspended, or
/// after relaunching it in the background. iOS delivers that through the app
/// delegate, and the completion handler must be called once the app has
/// finished processing — SwiftUI has no equivalent hook, hence the adaptor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // UIKit hands back a non-Sendable closure; the downloader stores it
        // and invokes it on the main queue, which is where UIKit requires it,
        // so carrying it across is safe.
        nonisolated(unsafe) let handler = completionHandler
        TTSBackgroundModelDownloader.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: { handler() }
        )
    }
}
#endif

@main
struct TTSMLXDemoApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            TabRootView()
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 680)
                #endif
        }
    }
}
