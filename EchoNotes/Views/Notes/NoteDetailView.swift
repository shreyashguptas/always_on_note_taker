import SwiftUI
import SwiftData

struct NoteDetailView: View {
    let session: RecordingSession
    @Environment(RecordingCoordinator.self) private var coordinator

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
        .toolbar {
            if showsRetry {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        coordinator.retryEnrichment(for: session)
                    }
                    .help("Re-run language detection and speaker recognition")
                }
            }
        }
        .onDisappear {
            playback.stop()
        }
    }

    /// Offer a re-run when the multilingual/speaker pass failed, or never
    /// ran but its models have since been downloaded.
    private var showsRetry: Bool {
        guard session.status == .complete || session.status == .failed else { return false }
        switch session.enrichmentState {
        case .failed: return true
        case .skipped, .none: return coordinator.enrichmentModels.isReady && session.audioFileURL != nil
        case .pending, .done: return false
        }
    }

    /// Tapping a transcript timestamp starts playback at that moment.
    private func seekFromTranscript(_ time: TimeInterval) {
        if !playback.isLoaded, let url = session.audioFileURL {
            playback.load(url: url)
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
