import SwiftUI
import SwiftData

@main
struct EchoNotesApp: App {
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
