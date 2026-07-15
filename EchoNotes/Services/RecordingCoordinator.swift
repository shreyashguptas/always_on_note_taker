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
    /// When live transcription can't run (no on-device model for the user's
    /// language), audio still records and the post-session pass transcribes;
    /// this just stops per-session services from being created.
    private var liveEnabled = true
    /// Configures callbacks on a freshly created service. Set once by the
    /// coordinator before capture ever starts; invoked on the pipeline queue.
    var configure: ((UUID, TranscriptionService) -> Void)?

    func setLocale(_ locale: Locale) {
        lock.lock()
        self.locale = locale
        lock.unlock()
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool) {
        lock.lock()
        liveEnabled = enabled
        lock.unlock()
    }

    func feed(id: UUID, buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard liveEnabled || services[id] != nil else {
            lock.unlock()
            return
        }
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
    private(set) var levels: [Float] = Array(repeating: 0, count: AppSettings.waveformBarCount)
    private(set) var currentSessionStartedAt: Date?
    /// Why AI summaries are degraded right now, if they are (checked at enable).
    private(set) var aiUnavailabilityMessage: String?
    /// Set when live transcription can't run for the user's language; the
    /// post-session pass still transcribes everything.
    private(set) var liveTranscriptUnavailableMessage: String?
    /// Per-session progress of the multilingual/speaker pass, for row UI.
    private(set) var enrichmentProgress: [UUID: TranscriptEnrichmentService.Phase] = [:]

    /// Live transcript of the in-flight session.
    private(set) var liveFinalizedText = ""
    private(set) var liveVolatileText = ""

    let speechModel = SpeechModelManager()
    let enrichmentModels = EnrichmentModelManager()

    private let capture = AudioCaptureService()
    private let pipeline = SessionPipeline()
    private let transcriptions = TranscriptionRegistry()
    private let enrichment = TranscriptEnrichmentService()
    private let speakerIdentity: SpeakerIdentityService
    private let modelContext: ModelContext
    /// Sessions whose preliminary (live) segments have already been replaced
    /// by enriched ones this launch; the first enriched window clears them.
    private var enrichmentReplacedSessions: Set<UUID> = []
    private var resumeTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    /// Monotonic per-session segment indices; avoids faulting the whole
    /// segments relationship just to count it on every append (including the
    /// end-of-session burst after a session stops being "active").
    private var segmentCounters: [UUID: Int] = [:]
    private var lastSegmentSave = Date.distantPast

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.speakerIdentity = SpeakerIdentityService(modelContext: modelContext)

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

        enrichment.onProgress = { [weak self] id, phase in
            self?.enrichmentProgress[id] = phase
        }
        enrichment.onWindowSegments = { [weak self] segments, id in
            self?.applyEnrichedSegments(segments, to: id)
        }
        enrichment.onFinished = { [weak self] id, clusters in
            self?.finishEnrichment(for: id, clusters: clusters)
        }
        enrichment.onFailed = { [weak self] id, message in
            self?.failEnrichment(for: id, message: message)
        }

        // Main-actor ordering guarantees this runs before any user-initiated
        // enable() can create a live session.
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
        // Flip immediately so a second tap during the (potentially long)
        // startup reads as "turn off" instead of spawning a parallel enable.
        isEnabled = true
        state = .starting
        micPermissionDenied = false

        guard await AudioCaptureService.requestMicrophonePermission() else {
            micPermissionDenied = true
            isEnabled = false
            state = .off
            return
        }
        guard isEnabled else { return } // toggled off while the dialog was up

        await speechModel.ensureModelInstalled()
        guard isEnabled else { return } // toggled off during the download

        // Live transcription is a nice-to-have now that the post-session
        // pass produces the authoritative transcript: when the live model
        // can't run (a Hindi-locale device, a failed download), recording
        // continues without it rather than blocking.
        switch speechModel.state {
        case .ready:
            liveTranscriptUnavailableMessage = nil
            transcriptions.setLiveTranscriptionEnabled(true)
            transcriptions.setLocale(speechModel.locale)
        case .unsupportedLocale:
            transcriptions.setLiveTranscriptionEnabled(false)
            liveTranscriptUnavailableMessage = "Live transcription isn't available for your language. Recordings are transcribed right after each session instead."
        default:
            transcriptions.setLiveTranscriptionEnabled(false)
            liveTranscriptUnavailableMessage = "The live speech model isn't available. Recordings are transcribed right after each session instead."
        }
        enrichmentModels.refreshInstalledState()
        aiUnavailabilityMessage = SummarizationService.unavailabilityMessage

        startCaptureOrRetry()
    }

    private func disable() {
        isEnabled = false
        resumeTask?.cancel()
        resumeTask = nil
        currentSessionStartedAt = nil
        liveFinalizedText = ""
        liveVolatileText = ""
        pipeline.stop(reason: .manualStop) { [weak self] in
            // If the user re-enabled before this deferred stop landed, the
            // fresh engine must not be torn down by the old disable.
            guard let self, !self.isEnabled else { return }
            self.capture.stop()
        }
        state = .off
        levels = Array(repeating: 0, count: levels.count)
    }

    // MARK: - Capture lifecycle

    /// Starts (or restarts) capture and opens the pipeline gate. Returns
    /// whether capture is running.
    private func restartCapture() -> Bool {
        // Open the gate first so the very first tap buffers aren't dropped.
        pipeline.beginAccepting()
        do {
            try capture.restart()
            state = currentSessionStartedAt == nil ? .listening : .recording
            return true
        } catch {
            return false
        }
    }

    private func startCaptureOrRetry() {
        guard isEnabled else { return }
        if !restartCapture() {
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
                if self.restartCapture() { return }
                try? await Task.sleep(for: .seconds(3))
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
            // active session continues — converters handle the new format.
            startCaptureOrRetry()

        case .mediaServicesReset:
            pipeline.stop(reason: .interruption)
            currentSessionStartedAt = nil
            do {
                try capture.rebuildAfterMediaServicesReset()
                pipeline.beginAccepting()
                state = .listening
            } catch {
                state = .interrupted
                scheduleResumeAttempts()
            }
        }
    }

    // MARK: - Pipeline events

    /// The Record tab calls this so waveform updates stop costing anything —
    /// including the main-queue hop — while the tab isn't visible.
    func setLevelUpdatesWanted(_ wanted: Bool) {
        pipeline.setLevelEmissionEnabled(wanted)
    }

    private func handlePipelineEvent(_ event: SessionPipeline.Event) {
        switch event {
        case .level(let level):
            levels.removeFirst()
            levels.append(level)

        case .sessionStarted(let id, let fileName, let startedAt):
            let session = RecordingSession(id: id, startedAt: startedAt)
            session.audioFileName = fileName
            session.status = .recording
            modelContext.insert(session)
            try? modelContext.save()
            activeSessionID = id
            segmentCounters[id] = 0
            currentSessionStartedAt = startedAt
            liveFinalizedText = ""
            liveVolatileText = ""
            if isEnabled { state = .recording }

        case .sessionEnded(let id, let fileName, let duration, let endedAt, _, let discarded):
            if activeSessionID == id {
                activeSessionID = nil
                currentSessionStartedAt = nil
                liveFinalizedText = ""
                liveVolatileText = ""
                // Only the *active* session's end returns the UI to listening;
                // a late event from an interrupted session must not clobber a
                // newer session's state.
                if isEnabled, state == .recording { state = .listening }
            }

            let service = transcriptions.remove(id: id)
            let session = fetchSession(id: id)

            if discarded || session == nil {
                service?.cancel()
                segmentCounters.removeValue(forKey: id)
                Persistence.deleteAudioFile(named: fileName)
                if let session {
                    modelContext.delete(session)
                    try? modelContext.save()
                }
                return
            }

            session?.endedAt = endedAt
            session?.duration = duration
            session?.status = .transcribing
            try? modelContext.save()

            Task { [weak self] in
                await service?.finishAndWait()
                self?.finalizeSession(id: id)
            }
        }
    }

    /// Called after the last transcript segment has been persisted.
    private func finalizeSession(id: UUID) {
        segmentCounters.removeValue(forKey: id)
        guard let session = fetchSession(id: id) else { return }

        // The multilingual/speaker pass runs whenever its models are here —
        // even when the live transcript came up empty, because speech in an
        // unsupported language produces no live segments at all.
        if startEnrichmentIfPossible(for: session) { return }

        session.enrichmentState = .skipped
        if session.segments.isEmpty {
            // Nothing intelligible was said; keep the recording but mark it done.
            session.status = .complete
            try? modelContext.save()
            return
        }
        summarize(session)
    }

    // MARK: - Post-session enrichment (multilingual transcript + speakers)

    /// Queues the enrichment pass; returns false when it can't run (models
    /// not downloaded, no audio file).
    private func startEnrichmentIfPossible(for session: RecordingSession) -> Bool {
        guard enrichmentModels.isReady,
              let whisperFolder = enrichmentModels.whisperModelFolder,
              let audioURL = session.audioFileURL,
              FileManager.default.fileExists(atPath: audioURL.path) else {
            return false
        }
        session.status = .enriching
        session.enrichmentState = .pending
        try? modelContext.save()
        enrichment.enqueue(TranscriptEnrichmentService.Job(
            sessionID: session.id,
            audioURL: audioURL,
            whisperModelFolder: whisperFolder,
            whisperVariant: enrichmentModels.selectedVariant.whisperKitModelName
        ))
        return true
    }

    /// Re-runs the pass for a finished session (failed run, or models were
    /// downloaded after the fact).
    func retryEnrichment(for session: RecordingSession) {
        guard session.status == .complete || session.status == .failed else { return }
        enrichmentReplacedSessions.remove(session.id)
        _ = startEnrichmentIfPossible(for: session)
    }

    /// One enriched window arrived: the first replaces the preliminary live
    /// segments, later ones append behind it.
    private func applyEnrichedSegments(_ segments: [TranscriptEnrichmentService.EnrichedSegment], to id: UUID) {
        guard let session = fetchSession(id: id) else { return }

        if !enrichmentReplacedSessions.contains(id) {
            enrichmentReplacedSessions.insert(id)
            for old in session.segments {
                modelContext.delete(old)
            }
            session.transcriptPreview = ""
            segmentCounters[id] = 0
        }

        var index = segmentCounters[id] ?? 0
        for segment in segments {
            let stored = TranscriptSegment(
                index: index,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                languageCode: segment.languageCode,
                speakerKey: segment.speakerKey
            )
            index += 1
            modelContext.insert(stored)
            stored.session = session

            if session.transcriptPreview.count < AppSettings.transcriptPreviewLength {
                let combined = session.transcriptPreview.isEmpty
                    ? segment.text
                    : session.transcriptPreview + " " + segment.text
                session.transcriptPreview = String(combined.prefix(AppSettings.transcriptPreviewLength))
            }
        }
        segmentCounters[id] = index
        try? modelContext.save()
    }

    private func finishEnrichment(for id: UUID, clusters: [TranscriptEnrichmentService.SpeakerCluster]) {
        enrichmentProgress.removeValue(forKey: id)
        segmentCounters.removeValue(forKey: id)
        guard let session = fetchSession(id: id) else { return }

        speakerIdentity.processClusters(clusters, sessionID: id)
        session.enrichmentState = .done
        if session.segments.isEmpty {
            session.status = .complete
            try? modelContext.save()
        } else {
            summarize(session)
        }
    }

    private func failEnrichment(for id: UUID, message: String) {
        enrichmentProgress.removeValue(forKey: id)
        segmentCounters.removeValue(forKey: id)
        guard let session = fetchSession(id: id) else { return }

        session.enrichmentState = .failed
        if session.segments.isEmpty {
            // Whatever the pass got through is gone AND there was no
            // preliminary transcript to fall back to.
            session.status = .failed
            try? modelContext.save()
        } else {
            // Keep whatever transcript exists (preliminary, or the enriched
            // windows that landed before the failure) and finish the note.
            summarize(session)
        }
    }

    /// Deleting a note should also drop any pending voice-review cards that
    /// point at its (soon to be deleted) audio.
    func purgeSpeakerReviewItems(for sessionID: UUID) {
        speakerIdentity.purgeReviewItems(for: sessionID)
    }

    /// The People tab's actions, routed through the one policy owner.
    var speakerIdentityService: SpeakerIdentityService { speakerIdentity }

    // MARK: - Note generation

    private func summarize(_ session: RecordingSession) {
        session.status = .summarizing
        try? modelContext.save()

        let id = session.id
        // Speaker- and language-annotated when enrichment ran; the plain
        // transcript otherwise.
        let transcript = session.attributedTranscript
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
    /// generation is re-run. Sessions caught mid-enrichment restart the pass
    /// from the top — speaker-cluster identities can't survive a process
    /// death, and re-running is cheap next to a wrong who-said-what. Empty
    /// leftovers with no audio are removed.
    func recoverInterruptedSessions() {
        let recording = RecordingSession.Status.recording.rawValue
        let transcribing = RecordingSession.Status.transcribing.rawValue
        let enriching = RecordingSession.Status.enriching.rawValue
        let summarizing = RecordingSession.Status.summarizing.rawValue
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate {
            $0.statusRaw == recording || $0.statusRaw == transcribing
                || $0.statusRaw == enriching || $0.statusRaw == summarizing
        })
        guard let orphans = try? modelContext.fetch(descriptor), !orphans.isEmpty else { return }

        var toSummarize: [UUID] = []
        for session in orphans where session.id != activeSessionID {
            let segments = session.sortedSegments
            let lastEnd = segments.last?.endTime ?? 0
            if session.duration == 0 { session.duration = lastEnd }
            if session.endedAt == nil {
                session.endedAt = session.startedAt.addingTimeInterval(max(lastEnd, session.duration))
            }

            // Prefer re-running the multilingual/speaker pass whenever it
            // can run — it supersedes whatever transcript state was left.
            if startEnrichmentIfPossible(for: session) { continue }

            if segments.isEmpty {
                Persistence.deleteAudioFile(named: session.audioFileName)
                modelContext.delete(session)
                continue
            }
            if session.enrichmentState == .pending { session.enrichmentState = .failed }
            session.status = .summarizing
            toSummarize.append(session.id)
        }
        try? modelContext.save()

        // One note at a time: several crash-orphaned sessions must not spin
        // up parallel language-model runs during a cold launch.
        guard !toSummarize.isEmpty else { return }
        Task { [weak self] in
            for id in toSummarize {
                guard let self, let session = self.fetchSession(id: id) else { continue }
                let result = await SummarizationService.generateNote(from: session.attributedTranscript)
                self.attachNote(result, to: id)
            }
        }
    }

    // MARK: - Transcription callbacks (main queue)

    private func updateVolatileText(_ text: String, for id: UUID) {
        guard id == activeSessionID else { return }
        liveVolatileText = text
    }

    private func appendSegment(_ segment: TranscriptionService.Segment, to id: UUID) {
        guard let session = fetchSession(id: id) else { return }

        let index = segmentCounters[id] ?? session.segments.count
        segmentCounters[id] = index + 1
        let stored = TranscriptSegment(
            index: index,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime
        )
        modelContext.insert(stored)
        stored.session = session

        if session.transcriptPreview.count < AppSettings.transcriptPreviewLength {
            let combined = session.transcriptPreview.isEmpty
                ? segment.text
                : session.transcriptPreview + " " + segment.text
            session.transcriptPreview = String(combined.prefix(AppSettings.transcriptPreviewLength))
        }

        // Persist at most every few seconds — enough for crash recovery
        // without a disk commit per spoken sentence. (Session end always
        // saves explicitly.)
        if Date.now.timeIntervalSince(lastSegmentSave) > 3 {
            try? modelContext.save()
            lastSegmentSave = .now
        }

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
