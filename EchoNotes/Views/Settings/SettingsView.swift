import SwiftUI

/// Model management for the post-session pass — download or remove the
/// multilingual + speaker models with per-model progress — plus the privacy
/// story and the build's version/commit.
struct SettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private var models: EnrichmentModelManager { coordinator.enrichmentModels }

    var body: some View {
        NavigationStack {
            Form {
                modelsSection
                privacySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            modelRow(
                title: "Transcription",
                detail: "Whisper Large v3 Turbo · ≈626 MB",
                state: models.whisperState
            )
            modelRow(
                title: "Speaker recognition",
                detail: "Diarization + voiceprints · ≈80 MB",
                state: models.diarizerState
            )

            if !models.isReady {
                Button {
                    models.startDownloads()
                } label: {
                    Label(
                        downloadButtonTitle,
                        systemImage: anyDownloadFailed ? "arrow.clockwise.circle" : "arrow.down.circle"
                    )
                }
                .disabled(models.isDownloading)
            }

            if models.isDownloading {
                Text("Downloads run one at a time. You can leave this screen — or the app — and the download keeps going in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if models.anyModelFilesPresent, !models.isDownloading {
                Button(role: .destructive) {
                    models.deleteDownloadedModels()
                } label: {
                    Label("Remove downloaded models", systemImage: "trash")
                }
                // A queued/in-flight processing job holds a path into these
                // files; deleting them out from under it would fail that
                // recording's only transcription attempt.
                .disabled(coordinator.isEnrichmentActive)
                if coordinator.isEnrichmentActive {
                    Text("A recording is being processed — models can be removed when it finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("On-device models")
        } footer: {
            Text("One button downloads both models, one after the other. Transcription detects the language as it goes — Hindi, Spanish, English, German, French, Italian and ~95 more, even mid-conversation. Speaker recognition tells voices apart; name a voice once in the People tab and it's recognized from then on. Recordings made before the download finish are transcribed automatically afterwards.")
        }
    }

    private var downloadButtonTitle: String {
        if models.isDownloading { return "Downloading…" }
        return anyDownloadFailed ? "Retry download" : "Download models"
    }

    private var anyDownloadFailed: Bool {
        if case .failed = models.whisperState { return true }
        if case .failed = models.diarizerState { return true }
        return false
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Label {
                Text("Recordings, transcripts, voices, and notes never leave this device. The network is used only for these one-time model downloads — feel free to verify in Airplane Mode afterwards.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - About

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    private static let buildNumber =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    private static let gitCommit =
        Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String

    private var aboutSection: some View {
        Section {
            let commit = Self.gitCommit
            let versionText = "\(Self.appVersion) (\(Self.buildNumber))"
            if let commit, commit != "dev",
               let url = URL(string: "https://github.com/shreyashguptas/always_on_note_taker/commit/\(commit)") {
                Link(destination: url) {
                    aboutRow(version: versionText, commit: commit)
                }
            } else {
                aboutRow(version: versionText, commit: commit ?? "dev")
            }
        } header: {
            Text("About")
        } footer: {
            if let commit = Self.gitCommit, commit != "dev" {
                Text("Tap to open this build's exact code change on GitHub.")
            }
        }
    }

    private func aboutRow(version: String, commit: String) -> some View {
        HStack {
            Text("Version")
                .foregroundStyle(.primary)
            Spacer()
            Text(version)
                .foregroundStyle(.secondary)
            Text(commit)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    // MARK: - Pieces

    private func modelRow(title: String, detail: String, state: EnrichmentModelManager.ModelState) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusView(for: state)
        }
    }

    @ViewBuilder
    private func statusView(for state: EnrichmentModelManager.ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Text("Not downloaded")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .waiting:
            Text("Waiting…")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .frame(width: 70)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        case .verifying:
            HStack(spacing: 8) {
                Text("Preparing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
        case .ready:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}

#Preview {
    SettingsView()
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
