import SwiftUI
import SwiftData
import UIKit

/// iOS relaunches the app in the background when the model download (a
/// background URLSession) finishes or fails while the app isn't running;
/// this hands the session's events to the downloader.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        WhisperModelDownloader.shared.handleBackgroundSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct EchoNotesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var coordinator: RecordingCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = Persistence.makeContainer()
        self.container = container
        _coordinator = State(initialValue: RecordingCoordinator(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(coordinator)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // Reclaim the mic on foreground if capture died while the app
            // was away (interruption whose end notification never arrived).
            if phase == .active {
                coordinator.applicationDidBecomeActive()
            }
        }
    }
}
