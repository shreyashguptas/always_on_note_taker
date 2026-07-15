import SwiftUI
import SwiftData

@main
struct EchoNotesApp: App {
    private let container: ModelContainer
    @State private var coordinator: RecordingCoordinator

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
    }
}
