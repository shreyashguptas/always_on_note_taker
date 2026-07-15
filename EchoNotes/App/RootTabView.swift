import SwiftUI
import SwiftData

struct RootTabView: View {
    @Query(filter: SpeakerReviewItem.pendingPredicate)
    private var pendingReviewItems: [SpeakerReviewItem]

    var body: some View {
        TabView {
            Tab("Record", systemImage: "waveform.circle.fill") {
                RecordView()
            }

            Tab("Notes", systemImage: "note.text") {
                NotesListView()
            }

            Tab("People", systemImage: "person.2.fill") {
                PeopleView()
            }
            .badge(pendingReviewItems.count)
        }
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
