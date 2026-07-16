import SwiftUI
import SwiftData

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RecordingCoordinator.self) private var coordinator
    @Query(sort: \RecordingSession.startedAt, order: .reverse)
    private var sessions: [RecordingSession]

    @Query(filter: SpeakerReviewItem.pendingPredicate)
    private var pendingReviewItems: [SpeakerReviewItem]

    @State private var searchText = ""
    @State private var showingPeople = false

    var body: some View {
        // Filter once per render; the grouping and empty-check share it.
        let filtered = filteredSessions

        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Turn on listening in the Record tab and start talking. Notes appear here automatically.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    notesList(groupedByDay(filtered))
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search titles, summaries, transcripts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    peopleButton
                }
            }
            .sheet(isPresented: $showingPeople) {
                PeopleView()
            }
        }
    }

    private var peopleButton: some View {
        Button {
            showingPeople = true
        } label: {
            Image(systemName: "person.2")
                .overlay(alignment: .topTrailing) {
                    if !pendingReviewItems.isEmpty {
                        Text("\(pendingReviewItems.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .accessibilityLabel(
            pendingReviewItems.isEmpty
                ? "People"
                : "People, \(pendingReviewItems.count) new voices to review"
        )
    }

    private func notesList(_ groups: [(day: Date, sessions: [RecordingSession])]) -> some View {
        List {
            ForEach(groups, id: \.day) { group in
                Section(TimeFormatting.dayHeader(group.day)) {
                    ForEach(group.sessions) { session in
                        NavigationLink(value: session.id) {
                            NoteRowView(session: session)
                        }
                    }
                    .onDelete { offsets in
                        delete(offsets.map { group.sessions[$0] })
                    }
                }
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let session = sessions.first(where: { $0.id == id }) {
                NoteDetailView(session: session)
            }
        }
    }

    private var filteredSessions: [RecordingSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            // Matches against the title, the denormalized transcript preview,
            // and the generated note — deliberately NOT the full transcript,
            // which would fault every segment of every session per keystroke.
            if session.displayTitle.localizedCaseInsensitiveContains(query) { return true }
            if session.transcriptPreview.localizedCaseInsensitiveContains(query) { return true }
            if let note = session.note {
                if note.overview.localizedCaseInsensitiveContains(query) { return true }
                if note.keyPoints.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                if note.actionItems.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                if note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            }
            return false
        }
    }

    private func groupedByDay(_ filtered: [RecordingSession]) -> [(day: Date, sessions: [RecordingSession])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.startedAt) }
        return groups
            .map { (day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    private func delete(_ toDelete: [RecordingSession]) {
        for session in toDelete {
            // A session still being recorded can't be deleted out from under
            // the audio writer — it becomes deletable the moment it ends.
            guard session.status != .recording else { continue }
            // Stops any in-flight processing of this recording and drops
            // pending voice-review cards that play audio from its file.
            coordinator.sessionWillBeDeleted(session.id)
            Persistence.deleteAudioFile(named: session.audioFileName)
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

#Preview {
    NotesListView()
        .modelContainer(PreviewData.container)
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
