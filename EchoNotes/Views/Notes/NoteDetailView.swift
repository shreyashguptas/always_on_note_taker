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
    @State private var playback = AudioPlaybackService()

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
                TranscriptSectionView(session: session, seek: seekFromTranscript)
            case .audio:
                AudioPlayerView(session: session, playback: playback)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            playback.stop()
        }
    }

    /// Tapping a transcript timestamp starts playback at that moment.
    private func seekFromTranscript(_ time: TimeInterval) {
        if !playback.isLoaded, let fileName = session.audioFileName {
            playback.load(url: Persistence.audioURL(forFileName: fileName))
        }
        guard playback.isLoaded else { return }
        playback.playFrom(time)
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(session: try! PreviewData.container.mainContext.fetch(FetchDescriptor<RecordingSession>()).first!)
    }
    .modelContainer(PreviewData.container)
    .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
