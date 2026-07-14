import SwiftUI

struct SummarySectionView: View {
    let session: RecordingSession
    @Environment(RecordingCoordinator.self) private var coordinator

    var body: some View {
        if let note = session.note {
            noteContent(note)
        } else if session.isProcessing {
            ContentUnavailableView(
                "Working on it…",
                systemImage: "sparkles",
                description: Text("The note is being generated on-device and will appear here shortly.")
            )
        } else {
            ContentUnavailableView(
                "No summary",
                systemImage: "sparkles",
                description: Text("This recording has no generated note.")
            )
        }
    }

    private func noteContent(_ note: GeneratedNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !note.tags.isEmpty {
                    TagChipsRow(tags: note.tags)
                }

                if !note.overview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Overview", systemImage: "text.alignleft")
                        Text(note.overview)
                            .textSelection(.enabled)
                    }
                }

                if !note.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Key points", systemImage: "list.bullet")
                        ForEach(note.keyPoints, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                Text(point).textSelection(.enabled)
                            }
                        }
                    }
                }

                if !note.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Action items", systemImage: "checkmark.circle")
                        ForEach(note.actionItems, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                                Text(item).textSelection(.enabled)
                            }
                        }
                    }
                }

                generatorFooter(note)

                Button {
                    coordinator.regenerateNote(for: session)
                } label: {
                    Label("Regenerate summary", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .disabled(session.isProcessing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func generatorFooter(_ note: GeneratedNote) -> some View {
        Label(
            note.usedAppleIntelligence
                ? "Generated on-device with Apple Intelligence"
                : "Generated on-device (basic summarizer)",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }
}
