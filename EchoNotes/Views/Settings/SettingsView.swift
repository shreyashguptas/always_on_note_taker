import SwiftUI

/// Model management for the post-session pass: pick a Whisper size, download
/// or remove the multilingual + speaker models, and read the privacy story.
struct SettingsView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private var models: EnrichmentModelManager { coordinator.enrichmentModels }

    var body: some View {
        NavigationStack {
            Form {
                multilingualSection
                speakerSection
                privacySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Switching to an already-installed variant makes the pass ready
            // without a download completing — sweep parked recordings then too.
            .onChange(of: models.selectedVariant) { _, _ in
                if models.isReady {
                    coordinator.transcribeBacklog()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var multilingualSection: some View {
        @Bindable var models = models

        Section {
            Picker("Model", selection: $models.selectedVariant) {
                ForEach(EnrichmentModelManager.WhisperVariant.allCases) { variant in
                    Text(variant.displayName).tag(variant)
                }
            }
            .disabled(models.isDownloading)

            Text(models.selectedVariant.displayDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            statusRow(title: "Language model", state: models.whisperState)
        } header: {
            Text("Transcription")
        } footer: {
            Text("Recordings are transcribed after each session by an on-device Whisper model that detects the language as it goes — Hindi, Spanish, English, German, French, Italian and ~95 more — even when a conversation switches between them.")
        }
    }

    private var speakerSection: some View {
        Section {
            statusRow(title: "Speaker recognition models", state: models.diarizerState)

            if !models.isReady {
                Button {
                    Task {
                        await models.ensureModelsInstalled()
                        // Recordings made before the download were parked
                        // audio-only; transcribe them now.
                        coordinator.transcribeBacklog()
                    }
                } label: {
                    Label(
                        models.isDownloading ? "Downloading…" : "Download models",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(models.isDownloading)
            }

            // Gated on ANY variant's files, not the selected one's — after
            // switching the picker to an uninstalled variant, the previous
            // 626 MB download must still be removable.
            if models.anyVariantInstalled, !models.isDownloading {
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
            Text("Speaker recognition")
        } footer: {
            Text("Tells voices apart, so transcripts show who said what. Name a voice once in the People tab and it's recognized automatically from then on. One-time download of roughly \(models.selectedVariant == .largeTurbo ? "700 MB" : "330 MB") total; models are stored on this device.")
        }
    }

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

    // MARK: - Pieces

    private func statusRow(title: String, state: EnrichmentModelManager.ModelState) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch state {
            case .downloading(let fraction):
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .ready:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
            case .notDownloaded:
                Text("Not downloaded")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(RecordingCoordinator(modelContext: PreviewData.container.mainContext))
}
