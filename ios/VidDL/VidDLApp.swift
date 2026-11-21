import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletion = completionHandler
    }
}

@main
struct VidDLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var manager = DownloadManager.shared
    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView().tabItem { Label("Download", systemImage: "arrow.down.circle") }
                DownloadsView().tabItem { Label("Library", systemImage: "film.stack") }
                SettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
            .environmentObject(manager)
            .tint(.orange)
        }
    }
}
