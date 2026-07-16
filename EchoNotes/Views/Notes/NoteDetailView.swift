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
    /// Whether the audio is present AND readable — probed once per
    /// appearance (it opens the file, too heavy for every render).
    @State private var audioIsUsable = false

    var body: some View {
        VStack(spacing: 0) {
            if session.enrichmentState == .failed, let message = session.enrichmentFailureMessage {
                StatusBanner(kind: .warning, message: message)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

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
        .onAppear {
            audioIsUsable = Self.probeAudio(of: session)
        }
        .onChange(of: session.enrichmentStateRaw) { _, _ in
            audioIsUsable = Self.probeAudio(of: session)
        }
        .onDisappear {
            playback.stop()
        }
    }

    /// Offer a re-run when the transcription pass failed or never ran — but
    /// only when it can actually run now (models installed, audio readable),
    /// so the button never silently does nothing. Uses the same probe as
    /// the coordinator's enqueue gate.
    private var showsRetry: Bool {
        guard session.status == .complete || session.status == .failed else { return false }
        switch session.enrichmentState {
        case .failed, .skipped, .none:
            return coordinator.enrichmentModels.isReady && audioIsUsable
        case .pending, .done:
            return false
        }
    }

    private static func probeAudio(of session: RecordingSession) -> Bool {
        guard let seconds = RecordingCoordinator.readableAudioSeconds(of: session.audioFileURL) else {
            return false
        }
        return seconds >= AppSettings.minimumSessionDuration
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
