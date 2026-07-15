import SwiftUI

/// Known people: rename, merge duplicates, or delete. Deleting keeps their
/// transcript segments (they fall back to anonymous "Speaker n" labels).
struct SpeakerListView: View {
    let speakers: [Speaker]

    @Environment(RecordingCoordinator.self) private var coordinator

    @State private var renaming: Speaker?
    @State private var renameText = ""
    @State private var deleting: Speaker?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(speakers) { speaker in
                row(speaker)
                if speaker.id != speakers.last?.id {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let speaker = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { speaker.name = name }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Remove \(deleting?.name ?? "this person")? Their transcript lines stay, just without the name, and their voice will show up as new again.",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let speaker = deleting {
                    coordinator.speakerIdentityService.deleteSpeaker(speaker)
                }
                deleting = nil
            }
        }
    }

    private func row(_ speaker: Speaker) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SpeakerPalette.color(for: speaker.colorIndex))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(speaker.name)
                        .font(.body.weight(.medium))
                    if speaker.isMe {
                        Text("Me")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(sessionCountText(speaker))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Rename", systemImage: "pencil") {
                    renameText = speaker.name
                    renaming = speaker
                }
                if speakers.count > 1 {
                    Menu("Merge into…") {
                        ForEach(speakers.filter { $0.id != speaker.id }) { target in
                            Button(target.name) {
                                coordinator.speakerIdentityService.merge(speaker, into: target)
                            }
                        }
                    }
                }
                Button("Remove", systemImage: "trash", role: .destructive) {
                    deleting = speaker
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sessionCountText(_ speaker: Speaker) -> String {
        let count = speaker.sessionCount
        switch count {
        case 0: return "Not in any recordings yet"
        case 1: return "In 1 recording"
        default: return "In \(count) recordings"
        }
    }
}
