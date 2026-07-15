import SwiftUI

struct TranscriptSectionView: View {
    let session: RecordingSession
    /// Wired to audio playback when available; timestamps become tappable.
    var seek: ((TimeInterval) -> Void)? = nil

    var body: some View {
        let segments = session.sortedSegments
        if segments.isEmpty {
            ContentUnavailableView(
                session.isProcessing ? "Transcribing…" : "No transcript",
                systemImage: "text.quote",
                description: Text(session.isProcessing
                    ? "The transcript will appear as soon as processing finishes."
                    : "No speech was transcribed for this recording.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(segments, id: \.persistentModelID) { segment in
                        segmentRow(segment)
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let seek {
                Button {
                    seek(segment.startTime)
                } label: {
                    timestampLabel(segment)
                }
                .buttonStyle(.plain)
            } else {
                timestampLabel(segment)
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func timestampLabel(_ segment: TranscriptSegment) -> some View {
        Label(TimeFormatting.clock(segment.startTime), systemImage: seek == nil ? "clock" : "play.circle")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.accentColor)
            .labelStyle(.titleAndIcon)
    }
}
