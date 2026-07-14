import AVFAudio
import Foundation
import Observation
import SwiftData

/// The app's engine room: owns the capture service and the session pipeline,
/// reacts to interruptions, and persists sessions to SwiftData. Lives on the
/// main actor; audio-thread work stays inside the services it owns.
@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        /// Toggle is off.
        case off
        /// Toggle on, permissions/model being checked, engine starting.
        case starting
        /// Engine running, waiting for speech.
        case listening
        /// A session is actively being recorded.
        case recording
        /// The system took the mic (call, Siri…); we resume when possible.
        case interrupted
        case error(String)
    }

    private(set) var state: State = .off
    private(set) var isEnabled = false
    private(set) var micPermissionDenied = false
    /// Rolling mic levels (0...1) for the waveform, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: 60)
    private(set) var speechActive = false
    private(set) var currentSessionStartedAt: Date?

    private let capture = AudioCaptureService()
    private let pipeline = SessionPipeline()
    private let modelContext: ModelContext
    private var resumeTask: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext

        capture.onBuffer = { [pipeline] buffer, _ in
            pipeline.ingest(buffer)
        }
        capture.onEvent = { [weak self] event in
            self?.handleCaptureEvent(event)
        }
        pipeline.emit = { [weak self] event in
            self?.handlePipelineEvent(event)
        }
    }

    // MARK: - Toggle

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        if enabled {
            await enable()
        } else {
            disable()
        }
    }

    private func enable() async {
        state = .starting
        micPermissionDenied = false

        guard await AudioCaptureService.requestMicrophonePermission() else {
            micPermissionDenied = true
            state = .off
            return
        }

        isEnabled = true
        startCaptureOrRetry()
    }

    private func disable() {
        isEnabled = false
        resumeTask?.cancel()
        resumeTask = nil
        currentSessionStartedAt = nil
        pipeline.stop(reason: .manualStop) { [weak self] in
            self?.capture.stop()
        }
        state = .off
        speechActive = false
        levels = Array(repeating: 0, count: levels.count)
    }

    // MARK: - Capture lifecycle

    private func startCaptureOrRetry() {
        guard isEnabled else { return }
        do {
            try capture.restart()
            state = currentSessionStartedAt == nil ? .listening : .recording
        } catch {
            state = .interrupted
            scheduleResumeAttempts()
        }
    }

    /// Retry loop for reclaiming the mic after failures/interruptions. Runs
    /// until capture is back or the toggle goes off.
    private func scheduleResumeAttempts() {
        guard resumeTask == nil else { return }
        resumeTask = Task { [weak self] in
            defer { self?.resumeTask = nil }
            while let self, self.isEnabled, !self.capture.isRunning {
                if Task.isCancelled { return }
                do {
                    try self.capture.restart()
                    self.state = self.currentSessionStartedAt == nil ? .listening : .recording
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func handleCaptureEvent(_ event: AudioCaptureService.Event) {
        guard isEnabled else { return }
        switch event {
        case .interruptionBegan:
            state = .interrupted
            // Audio input has stopped; close out the in-flight session so its
            // note gets generated rather than sitting open indefinitely.
            pipeline.stop(reason: .interruption)
            currentSessionStartedAt = nil

        case .interruptionEndedShouldResume, .interruptionEnded:
            startCaptureOrRetry()

        case .configurationChanged:
            // Input hardware changed (headset in/out…). Restart capture; the
            // active session continues — writers convert across formats.
            startCaptureOrRetry()

        case .mediaServicesReset:
            pipeline.stop(reason: .interruption)
            currentSessionStartedAt = nil
            do {
                try capture.rebuildAfterMediaServicesReset()
                state = .listening
            } catch {
                state = .interrupted
                scheduleResumeAttempts()
            }
        }
    }

    // MARK: - Pipeline events

    private func handlePipelineEvent(_ event: SessionPipeline.Event) {
        switch event {
        case .level(let level, let isSpeech):
            levels.removeFirst()
            levels.append(level)
            speechActive = isSpeech

        case .sessionStarted(let id, let fileName, let startedAt):
            let session = RecordingSession(id: id, startedAt: startedAt)
            session.audioFileName = fileName
            session.status = .recording
            modelContext.insert(session)
            try? modelContext.save()
            currentSessionStartedAt = startedAt
            if isEnabled { state = .recording }

        case .sessionEnded(let id, let fileName, let duration, let endedAt, _, let discarded):
            currentSessionStartedAt = nil
            if isEnabled, state == .recording { state = .listening }
            guard let session = fetchSession(id: id) else {
                if discarded { Persistence.deleteAudioFile(named: fileName) }
                return
            }
            if discarded {
                Persistence.deleteAudioFile(named: fileName)
                modelContext.delete(session)
                try? modelContext.save()
                return
            }
            session.endedAt = endedAt
            session.duration = duration
            session.status = .complete
            try? modelContext.save()
        }
    }

    // MARK: - Helpers

    private func fetchSession(id: UUID) -> RecordingSession? {
        var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
