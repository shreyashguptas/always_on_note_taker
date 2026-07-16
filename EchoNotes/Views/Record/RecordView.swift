import SwiftUI

struct RecordView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banners
                    .padding(.horizontal)

                Spacer()

                statusHeadline
                    .padding(.bottom, 28)

                RecordToggleButton(
                    isOn: coordinator.isEnabled,
                    isRecording: coordinator.state == .recording
                ) {
                    let target = !coordinator.isEnabled
                    Task { await coordinator.setEnabled(target) }
                }

                statusDetail
                    .padding(.top, 28)

                Spacer()

                if let processing = processingStatus {
                    ProcessingCard(status: processing)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                WaveformView(levels: coordinator.levels, active: coordinator.isEnabled)
                    .frame(height: 64)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .navigationTitle("EchoNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showsSettings = true
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            // Waveform updates are pure UI; don't pay for them unless this
            // tab is visible AND the app is foreground. (scenePhase changes
            // reach retained-but-hidden tabs too, hence the isVisible check.)
            .onAppear {
                isVisible = true
                coordinator.setLevelUpdatesWanted(scenePhase == .active)
            }
            .onDisappear {
                isVisible = false
                coordinator.setLevelUpdatesWanted(false)
            }
            .onChange(of: scenePhase) { _, phase in
                coordinator.setLevelUpdatesWanted(isVisible && phase == .active)
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusHeadline: some View {
        switch coordinator.state {
        case .off:
            Text("Not listening")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        case .starting:
            Text("Starting…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        case .listening:
            Text("Listening for speech")
                .font(.title2.weight(.semibold))
        case .recording:
            if let start = coordinator.currentSessionStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Recording · \(TimeFormatting.clock(context.date.timeIntervalSince(start)))")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            } else {
                Text("Recording")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
            }
        case .interrupted:
            Text("Paused by the system")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)
        case .error(let message):
            Text(message)
                .font(.headline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch coordinator.state {
        case .off:
            Text("Turn on listening and EchoNotes records what it hears, then transcribes and organizes it into notes — every language, entirely on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        case .listening:
            Text("A note starts automatically when you speak, even with the screen locked. The transcript is ready shortly after each conversation ends.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        case .interrupted:
            Text("Another app or a call is using the microphone. EchoNotes will resume automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        default:
            EmptyView()
        }
    }

    // MARK: - Post-session transcription status

    private struct ProcessingStatus {
        let message: String
        /// nil = queued/indeterminate.
        let fraction: Double?
    }

    /// What the transcription queue is doing right now, if anything — this
    /// is where the live transcript used to sit, and it answers the same
    /// question: "is the app working on my words?"
    private var processingStatus: ProcessingStatus? {
        let phases = coordinator.enrichmentProgress
        guard !phases.isEmpty else { return nil }

        // At most one job runs at a time; show its fraction when it has one.
        let fraction: Double? = phases.values.compactMap {
            if case .processing(let value) = $0 { return value }
            return nil
        }.first

        let message = phases.count == 1
            ? "Transcribing your last recording…"
            : "Transcribing \(phases.count) recordings…"
        return ProcessingStatus(message: message, fraction: fraction)
    }

    private struct ProcessingCard: View {
        let status: ProcessingStatus

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.message)
                        .font(.footnote.weight(.medium))
                    if let fraction = status.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if coordinator.micPermissionDenied {
            StatusBanner(
                kind: .warning,
                message: "Microphone access is off, so EchoNotes can't hear anything.",
                actionTitle: "Settings"
            ) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }

        // Transcription models are the app's engine now — surface their
        // absence prominently rather than behind a dismissible hint.
        if coordinator.enrichmentModels.isDownloading {
            StatusBanner(kind: .progress(downloadFraction), message: "Downloading the transcription models…")
        } else if !coordinator.enrichmentModels.isReady {
            StatusBanner(
                kind: .warning,
                message: "Download the on-device models to transcribe recordings — Hindi, Spanish, English, German and ~95 more, plus who-said-what.",
                actionTitle: "Set up"
            ) {
                showsSettings = true
            }
        }

        if coordinator.isEnabled, let message = coordinator.aiUnavailabilityMessage {
            StatusBanner(kind: .info, message: message)
        }
    }

    private var downloadFraction: Double? {
        if case .downloading(let fraction) = coordinator.enrichmentModels.whisperState {
            return fraction
        }
        return nil
    }
}
