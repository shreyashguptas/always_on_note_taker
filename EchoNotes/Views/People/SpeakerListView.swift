import SwiftUI

/// Known people: rename, merge duplicates, or delete. Deleting keeps their
/// transcript segments (they fall back to anonymous "Speaker n" labels).
struct SpeakerListView: View {
    let speakers: [Speaker]

    @Environment(RecordingCoordinator.self) private var coordinator

    @State private var renaming: Speaker?
    @State private var renameText = ""
    @State private var deleting: Speaker?
    /// Recording counts fault every segment of every speaker — far too heavy
    /// to recompute per render (the People tab re-renders while review cards
    /// animate), so they're computed per appearance.
    @State private var sessionCounts: [UUID: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(speakers) { speaker in
                row(speaker)
                if speaker.id != speakers.last?.id {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .onAppear { rebuildCounts() }
        .onChange(of: speakers.count) { _, _ in rebuildCounts() }
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
                        TagChipView(tag: "Me")
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

    private func rebuildCounts() {
        sessionCounts = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.sessionCount) })
    }

    private func sessionCountText(_ speaker: Speaker) -> String {
        switch sessionCounts[speaker.id] ?? 0 {
        case 0: return "Not in any recordings yet"
        case 1: return "In 1 recording"
        case let count: return "In \(count) recordings"
        }
    }
}
