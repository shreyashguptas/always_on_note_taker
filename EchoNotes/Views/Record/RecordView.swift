import SwiftUI

struct RecordView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

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

                if coordinator.state == .recording || !coordinator.liveFinalizedText.isEmpty {
                    LiveTranscriptView(
                        finalizedText: coordinator.liveFinalizedText,
                        volatileText: coordinator.liveVolatileText
                    )
                    .frame(maxHeight: 180)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                WaveformView(levels: coordinator.levels, active: coordinator.isEnabled)
                    .frame(height: 64)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .navigationTitle("EchoNotes")
            .navigationBarTitleDisplayMode(.inline)
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
            Text("Turn on listening and EchoNotes will transcribe and organize everything it hears — entirely on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        case .listening:
            Text("A note starts automatically when you speak. Recording continues with the screen locked.")
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

        switch coordinator.speechModel.state {
        case .checking:
            StatusBanner(kind: .progress(nil), message: "Checking the on-device speech model…")
        case .downloading(let fraction):
            StatusBanner(kind: .progress(fraction), message: "Downloading the on-device speech model…")
        case .failed(let message):
            StatusBanner(kind: .warning, message: message)
        case .unsupportedLocale:
            StatusBanner(kind: .warning, message: "On-device transcription isn't available for your language yet.")
        case .unknown, .ready:
            EmptyView()
        }

        if coordinator.isEnabled, let message = coordinator.aiUnavailabilityMessage {
            StatusBanner(kind: .info, message: message)
        }
    }
}
