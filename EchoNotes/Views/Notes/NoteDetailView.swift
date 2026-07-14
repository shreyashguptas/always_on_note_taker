import SwiftUI
import SwiftData

struct NoteDetailView: View {
    let session: RecordingSession

    private enum Section: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case audio = "Audio"
        var id: String { rawValue }
    }

    @State private var section: Section = .summary

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch section {
            case .summary:
                SummarySectionView(session: session)
            case .transcript:
                TranscriptSectionView(session: session)
            case .audio:
                AudioSectionView(session: session)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder until playback lands; shows recording metadata.
struct AudioSectionView: View {
    let session: RecordingSession

    var body: some View {
        List {
            LabeledContent("Recorded", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Duration", value: TimeFormatting.clock(session.duration))
        }
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(session: try! PreviewData.container.mainContext.fetch(FetchDescriptor<RecordingSession>()).first!)
    }
    .modelContainer(PreviewData.container)
}
