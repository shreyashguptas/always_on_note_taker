import SwiftUI
import SwiftData

struct NotesListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.startedAt, order: .reverse)
    private var sessions: [RecordingSession]

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Turn on listening in the Record tab and start talking. Notes appear here automatically.")
                    )
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    notesList
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search titles, summaries, transcripts")
        }
    }

    private var notesList: some View {
        List {
            ForEach(groupedByDay, id: \.day) { group in
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
            if session.displayTitle.localizedCaseInsensitiveContains(query) { return true }
            if session.transcriptPreview.localizedCaseInsensitiveContains(query) { return true }
            if let note = session.note {
                if note.overview.localizedCaseInsensitiveContains(query) { return true }
                if note.keyPoints.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                if note.actionItems.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
                if note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            }
            return session.fullTranscript.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedByDay: [(day: Date, sessions: [RecordingSession])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredSessions) { calendar.startOfDay(for: $0.startedAt) }
        return groups
            .map { (day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    private func delete(_ toDelete: [RecordingSession]) {
        for session in toDelete {
            Persistence.deleteAudioFile(named: session.audioFileName)
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}

#Preview {
    NotesListView()
        .modelContainer(PreviewData.container)
}
