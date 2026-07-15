import SwiftUI
import SwiftData

/// Third tab: review new voices (card stack) and manage known people.
struct PeopleView: View {
    @Query(
        filter: SpeakerReviewItem.pendingPredicate,
        sort: \SpeakerReviewItem.createdAt,
        order: .reverse
    )
    private var pendingItems: [SpeakerReviewItem]

    @Query(sort: \Speaker.createdAt)
    private var speakers: [Speaker]

    var body: some View {
        NavigationStack {
            Group {
                if pendingItems.isEmpty && speakers.isEmpty {
                    ContentUnavailableView(
                        "No voices yet",
                        systemImage: "person.2",
                        description: Text("When recordings are processed, new voices show up here so you can name who's who. Named people are tagged automatically in future transcripts.")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("People")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !pendingItems.isEmpty {
                    Text("New voices")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal)
                    ReviewQueueView(items: pendingItems, speakers: speakers)
                        .padding(.horizontal)
                }

                if !speakers.isEmpty {
                    Text("Known people")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal)
                        .padding(.top, pendingItems.isEmpty ? 0 : 8)
                    SpeakerListView(speakers: speakers)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }
}

#Preview {
    PeopleView()
        .modelContainer(PreviewData.container)
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
