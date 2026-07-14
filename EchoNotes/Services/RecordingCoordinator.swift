import AVFAudio
import Foundation
import Observation
import SwiftData

/// Thread-safe map of session id → live transcription service. Buffers arrive
/// on the pipeline queue; the coordinator manages lifecycles on the main
/// actor. Services are created lazily on the first buffer of a session so the
/// pre-roll is never missed.
final class TranscriptionRegistry {
    private let lock = NSLock()
    private var services: [UUID: TranscriptionService] = [:]
    private var locale: Locale = .current
    /// Configures callbacks on a freshly created service. Set once by the
    /// coordinator; invoked on the pipeline queue.
    var configure: ((UUID, TranscriptionService) -> Void)?

    func setLocale(_ locale: Locale) {
        lock.lock()
        self.locale = locale
        lock.unlock()
    }

    func feed(id: UUID, buffer: AVAudioPCMBuffer) {
        lock.lock()
        var service = services[id]
        if service == nil {
            let created = TranscriptionService(locale: locale)
            services[id] = created
            service = created
            lock.unlock()
            configure?(id, created)
        } else {
            lock.unlock()
        }
        service?.enqueue(buffer)
    }

    func remove(id: UUID) -> TranscriptionService? {
        lock.lock()
        defer { lock.unlock() }
        return services.removeValue(forKey: id)
    }

    func removeAll() -> [TranscriptionService] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(services.values)
        services.removeAll()
        return all
    }
}

/// The app's engine room: owns the capture service, the session pipeline, and
/// per-session transcription, reacts to interruptions, and persists sessions
/// to SwiftData. Lives on the main actor; audio-thread work stays inside the
/// services it owns.
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

    /// Live transcript of the in-flight session.
    private(set) var liveFinalizedText = ""
    private(set) var liveVolatileText = ""

    let speechModel = SpeechModelManager()

    private let capture = AudioCaptureService()
    private let pipeline = SessionPipeline()
    private let transcriptions = TranscriptionRegistry()
    private let modelContext: ModelContext
    private var resumeTask: Task<Void, Never>?
    private var activeSessionID: UUID?

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
        pipeline.speechSink = { [transcriptions] id, buffer in
            transcriptions.feed(id: id, buffer: buffer)
        }
        transcriptions.configure = { [weak self] id, service in
            service.onVolatileText = { text in
                self?.updateVolatileText(text, for: id)
            }
            service.onFinalSegment = { segment in
                self?.appendSegment(segment, to: id)
            }
        }

        Task { [weak self] in
            self?.recoverInterruptedSessions()
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

        await speechModel.ensureModelInstalled()
        switch speechModel.state {
        case .ready:
            break
        case .unsupportedLocale:
            state = .error("On-device transcription isn't available for your language yet.")
            return
        case .failed(let message):
            state = .error(message)
            return
        default:
            state = .error("The speech model isn't ready yet. Try again in a moment.")
            return
        }
        transcriptions.setLocale(speechModel.locale)

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
            activeSessionID = id
            currentSessionStartedAt = startedAt
            liveFinalizedText = ""
            liveVolatileText = ""
            if isEnabled { state = .recording }

        case .sessionEnded(let id, let fileName, let duration, let endedAt, _, let discarded):
            if activeSessionID == id {
                activeSessionID = nil
                currentSessionStartedAt = nil
                liveVolatileText = ""
            }
            if isEnabled, state == .recording { state = .listening }

            let service = transcriptions.remove(id: id)

            guard let session = fetchSession(id: id), !discarded else {
                service?.cancel()
                Persistence.deleteAudioFile(named: fileName)
                if let session = fetchSession(id: id) {
                    modelContext.delete(session)
                    try? modelContext.save()
                }
                return
            }

            session.endedAt = endedAt
            session.duration = duration
            session.status = .transcribing
            try? modelContext.save()

            Task { [weak self] in
                await service?.finishAndWait()
                self?.finalizeSession(id: id)
            }
        }
    }

    /// Called after the last transcript segment has been persisted.
    private func finalizeSession(id: UUID) {
        guard let session = fetchSession(id: id) else { return }
        if session.segments.isEmpty {
            // Nothing intelligible was said; keep the recording but mark it done.
            session.status = .complete
            try? modelContext.save()
            return
        }
        summarize(session)
    }

    // MARK: - Note generation

    private func summarize(_ session: RecordingSession) {
        session.status = .summarizing
        try? modelContext.save()

        let id = session.id
        let transcript = session.fullTranscript
        Task { [weak self] in
            let result = await SummarizationService.generateNote(from: transcript)
            self?.attachNote(result, to: id)
        }
    }

    private func attachNote(_ result: SummarizationService.NoteResult, to id: UUID) {
        guard let session = fetchSession(id: id) else { return }
        if let old = session.note {
            modelContext.delete(old)
        }
        let note = GeneratedNote(
            title: result.title,
            overview: result.overview,
            keyPoints: result.keyPoints,
            actionItems: result.actionItems,
            tags: result.tags,
            generatorUsed: result.generator
        )
        modelContext.insert(note)
        session.note = note
        session.status = .complete
        try? modelContext.save()
    }

    /// Re-runs note generation for an existing session (e.g. after enabling
    /// Apple Intelligence, or if the first result was weak).
    func regenerateNote(for session: RecordingSession) {
        guard !session.segments.isEmpty, session.status == .complete || session.status == .failed else { return }
        summarize(session)
    }

    // MARK: - Launch recovery

    /// Sessions left mid-flight by a crash, force-quit, or kill are recovered:
    /// their incrementally persisted segments become the transcript, and note
    /// generation is re-run. Empty leftovers are removed.
    func recoverInterruptedSessions() {
        let recording = RecordingSession.Status.recording.rawValue
        let transcribing = RecordingSession.Status.transcribing.rawValue
        let summarizing = RecordingSession.Status.summarizing.rawValue
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate {
            $0.statusRaw == recording || $0.statusRaw == transcribing || $0.statusRaw == summarizing
        })
        guard let orphans = try? modelContext.fetch(descriptor), !orphans.isEmpty else { return }

        for session in orphans {
            let segments = session.sortedSegments
            if segments.isEmpty {
                Persistence.deleteAudioFile(named: session.audioFileName)
                modelContext.delete(session)
                continue
            }
            let lastEnd = segments.last?.endTime ?? 0
            if session.duration == 0 { session.duration = lastEnd }
            if session.endedAt == nil {
                session.endedAt = session.startedAt.addingTimeInterval(lastEnd)
            }
            summarize(session)
        }
        try? modelContext.save()
    }

    // MARK: - Transcription callbacks (main queue)

    private func updateVolatileText(_ text: String, for id: UUID) {
        guard id == activeSessionID else { return }
        liveVolatileText = text
    }

    private func appendSegment(_ segment: TranscriptionService.Segment, to id: UUID) {
        guard let session = fetchSession(id: id) else { return }
        let stored = TranscriptSegment(
            index: session.segments.count,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime
        )
        modelContext.insert(stored)
        stored.session = session
        if session.transcriptPreview.count < 500 {
            let combined = session.transcriptPreview.isEmpty
                ? segment.text
                : session.transcriptPreview + " " + segment.text
            session.transcriptPreview = String(combined.prefix(500))
        }
        try? modelContext.save()

        if id == activeSessionID {
            liveFinalizedText = liveFinalizedText.isEmpty
                ? segment.text
                : liveFinalizedText + " " + segment.text
        }
    }

    // MARK: - Helpers

    private func fetchSession(id: UUID) -> RecordingSession? {
        var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
