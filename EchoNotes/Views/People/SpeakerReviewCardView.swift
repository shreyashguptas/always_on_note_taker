import SwiftUI
import SwiftData

/// One "who is this?" card: plays a ~10 s snippet of the unknown voice, and
/// resolves it by tapping a suggested/known person, "Me", or typing a new
/// name. "Not a person" dismisses the voice for good.
struct SpeakerReviewCardView: View {
    let item: SpeakerReviewItem
    let speakers: [Speaker]
    let isTop: Bool
    let onSkip: () -> Void

    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

    @State private var playback = AudioPlaybackService()
    @State private var newName = ""
    @FocusState private var nameFieldFocused: Bool

    private var session: RecordingSession? {
        let id = item.sessionID
        var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private var suggestedSpeaker: Speaker? {
        guard let id = item.suggestedSpeakerID else { return nil }
        return speakers.first { $0.id == id }
    }

    private var hasMe: Bool {
        speakers.contains { $0.isMe }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            snippetPlayer
            suggestionRow
            knownPeopleRow
            newNameRow
            actionRow
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .onDisappear { playback.stop() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Who is this?")
                .font(.headline)
            Text(context)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var context: String {
        var parts: [String] = []
        if let session {
            parts.append(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            parts.append(TimeFormatting.spoken(session.duration) + " recording")
        }
        if item.occurrenceCount > 1 {
            parts.append("heard in \(item.occurrenceCount) recordings")
        }
        return parts.isEmpty ? "From a processed recording" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var snippetPlayer: some View {
        if let url = session?.audioFileURL, FileManager.default.fileExists(atPath: url.path) {
            Button {
                if playback.isPlaying {
                    playback.pause()
                } else {
                    if !playback.isLoaded { playback.load(url: url) }
                    playback.playRange(from: item.snippetStart, to: item.snippetEnd)
                }
            } label: {
                Label(
                    playback.isPlaying ? "Pause" : "Play voice sample",
                    systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                )
                .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        } else {
            Label("The audio for this voice is gone", systemImage: "speaker.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if let suggested = suggestedSpeaker {
            Button {
                assign(to: suggested)
            } label: {
                Label("Is this \(suggested.name)?", systemImage: "person.fill.questionmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var knownPeopleRow: some View {
        if !speakers.isEmpty || !hasMe {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if !hasMe {
                        chip(label: "Me", systemImage: "person.crop.circle.badge.checkmark") {
                            _ = coordinator.speakerIdentityService.createSpeaker(named: "Me", isMe: true, from: item)
                        }
                    }
                    ForEach(speakers) { speaker in
                        chip(label: speaker.name, colorIndex: speaker.colorIndex) {
                            assign(to: speaker)
                        }
                    }
                }
            }
        }
    }

    private var newNameRow: some View {
        HStack(spacing: 8) {
            TextField("New person's name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit(createFromName)
            Button("Add", action: createFromName)
                .buttonStyle(.bordered)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Skip for now", action: onSkip)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Not a person", role: .destructive) {
                playback.stop()
                coordinator.speakerIdentityService.dismiss(item)
            }
            .font(.footnote)
        }
    }

    private func chip(label: String, systemImage: String? = nil, colorIndex: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                if let colorIndex {
                    Circle()
                        .fill(SpeakerPalette.color(for: colorIndex))
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func assign(to speaker: Speaker) {
        playback.stop()
        coordinator.speakerIdentityService.assign(item, to: speaker)
    }

    private func createFromName() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        playback.stop()
        nameFieldFocused = false
        coordinator.speakerIdentityService.createSpeaker(named: name, from: item)
        newName = ""
    }
}
