import SwiftUI

struct NoteRowView: View {
    let session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                if session.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let overview = session.note?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !session.transcriptPreview.isEmpty {
                Text(session.transcriptPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label(session.startedAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                Label(TimeFormatting.spoken(session.duration), systemImage: "waveform")
                if session.isProcessing {
                    Text(statusText)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let tags = session.note?.tags, !tags.isEmpty {
                    TagChipsRow(tags: Array(tags.prefix(2)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch session.status {
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .enriching: "Processing transcript…"
        case .summarizing: "Summarizing…"
        case .complete, .failed: ""
        }
    }
}
