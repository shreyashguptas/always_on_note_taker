import SwiftUI
import SwiftData

@main
struct EchoNotesApp: App {
    private let container = Persistence.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }
}
