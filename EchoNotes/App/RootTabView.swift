import SwiftUI
import SwiftData

struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Record", systemImage: "waveform.circle.fill") {
                RecordView()
            }

            Tab("Notes", systemImage: "note.text") {
                NotesListView()
            }
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
