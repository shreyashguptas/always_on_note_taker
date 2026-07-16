import AVFAudio
import Foundation
import Observation
import SwiftData

/// The app's engine room: owns the capture service, the session pipeline, and
/// post-session transcription, reacts to interruptions, and persists sessions
/// to SwiftData. Lives on the main actor; audio-thread work stays inside the
/// services it owns.
@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        /// Toggle is off.
        case off
        /// Toggle on, permissions being checked, engine starting.
        case starting
        /// Engine running, waiting for speech.
        case listening
        /// A session is actively being recorded.
        case recording
        /// The system took the mic (call, Siri…); we resume when possible.
        case interrupted
    }

    private(set) var state: State = .off
    private(set) var isEnabled = false
    private(set) var micPermissionDenied = false
    /// Rolling mic levels (0...1) for the waveform, newest last.
    private(set) var levels: [Float] = Array(repeating: 0, count: AppSettings.waveformBarCount)
    private(set) var currentSessionStartedAt: Date?
    /// Why AI summaries are degraded right now, if they are (checked at enable).
    private(set) var aiUnavailabilityMessage: String?
    /// Set while speech is being heard but can't be written to disk (disk
    /// full…); cleared when a session starts successfully or listening stops.
    private(set) var recordingProblemMessage: String?
    /// Per-session progress of the transcription pass, for row/banner UI.
    private(set) var enrichmentProgress: [UUID: TranscriptEnrichmentService.Phase] = [:]

    let enrichmentModels = EnrichmentModelManager()

    private let capture = AudioCaptureService()
    private let pipeline = SessionPipeline()
    private let enrichment = TranscriptEnrichmentService()
    private let speakerIdentity: SpeakerIdentityService
    private let modelContext: ModelContext
    private var resumeTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    /// Sessions the user deleted this launch. A progress callback already in
    /// flight when a note is deleted must not resurrect its
    /// enrichmentProgress entry — cancelled jobs fire no terminal callback,
    /// so a resurrected entry would never clear.
    private var deletedSessions: Set<UUID> = []

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

        enrichment.onProgress = { [weak self] id, phase in
            guard let self, !self.deletedSessions.contains(id) else { return }
            self.enrichmentProgress[id] = phase
        }
        enrichment.onFinished = { [weak self] id, segments, clusters in
            self?.finishEnrichment(for: id, segments: segments, clusters: clusters)
        }
        enrichment.onFailed = { [weak self] id, reason in
            self?.failEnrichment(for: id, reason: reason)
        }
        // The moment both model sets are installed, sweep recordings that
        // were parked waiting for them.
        enrichmentModels.onBecameReady = { [weak self] in
            self?.transcribeBacklog()
        }

        // Main-actor ordering guarantees this runs before any user-initiated
        // enable() can create a live session.
        Task { [weak self] in
            self?.recoverInterruptedSessions()
            self?.transcribeBacklog()
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

        // Recording never blocks on the transcription models: sessions
        // captured before they're downloaded are kept and transcribed once
        // they are.
        enrichmentModels.refreshInstalledState()
        transcribeBacklog()
        aiUnavailabilityMessage = SummarizationService.unavailabilityMessage

        startCaptureOrRetry()
    }

    /// Foreground kick: if the toggle is on but capture died while the app
    /// was away (an interruption whose end notification iOS never
    /// delivered), reclaim the mic now rather than waiting for a
    /// notification that may never come.
    func applicationDidBecomeActive() {
        // A model download interrupted while the app was away (or killed)
        // picks itself back up — no hunting for the download button again.
        enrichmentModels.resumeInterruptedDownloads()
        guard isEnabled, !capture.isRunning else { return }
        startCaptureOrRetry()
    }

    private func disable() {
        isEnabled = false
        resumeTask?.cancel()
        resumeTask = nil
        currentSessionStartedAt = nil
        recordingProblemMessage = nil
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
            // Don't rely on the interruption-ended notification — iOS
            // documents it may never arrive (e.g. the app was suspended
            // during the call). The retry loop reclaims the mic as soon as
            // the system allows and no-ops while it's still held.
            scheduleResumeAttempts()

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
            currentSessionStartedAt = startedAt
            recordingProblemMessage = nil
            if isEnabled { state = .recording }

        case .sessionStartFailed:
            // Speech is being heard and lost — say so instead of showing a
            // healthy "Listening" screen.
            recordingProblemMessage = "Recording isn't working — speech can't be saved right now. Check free storage."

        case .sessionEnded(let id, let fileName, let duration, let endedAt, let discarded):
            if activeSessionID == id {
                activeSessionID = nil
                currentSessionStartedAt = nil
                // Only the *active* session's end returns the UI to listening;
                // a late event from an interrupted session must not clobber a
                // newer session's state.
                if isEnabled, state == .recording { state = .listening }
            }

            let session = fetchSession(id: id)

            if discarded || session == nil {
                Persistence.deleteAudioFile(named: fileName)
                if let session {
                    modelContext.delete(session)
                    try? modelContext.save()
                }
                return
            }

            session?.endedAt = endedAt
            session?.duration = duration
            try? modelContext.save()

            finalizeSession(id: id)
        }
    }

    /// The session's audio file is closed: hand it to transcription, or park
    /// it retryable when the models aren't downloaded yet.
    private func finalizeSession(id: UUID) {
        guard let session = fetchSession(id: id) else { return }

        if startEnrichmentIfPossible(for: session) { return }

        // Kept, not deleted: the audio is fully transcribable later — the
        // note offers Retry once the models are downloaded.
        session.enrichmentState = .skipped
        session.status = .complete
        try? modelContext.save()
    }

    // MARK: - Post-session enrichment (multilingual transcript + speakers)

    /// Queues the enrichment pass; returns false when it can't run (models
    /// not downloaded, audio missing or unreadable). The readability probe
    /// matters: a half-written file from a mid-recording kill would
    /// otherwise be enqueued, fail, and offer a Retry that can never work.
    private func startEnrichmentIfPossible(for session: RecordingSession) -> Bool {
        guard enrichmentModels.isReady,
              let whisperFolder = enrichmentModels.whisperModelFolder,
              let audioURL = session.audioFileURL,
              let audioSeconds = Self.readableAudioSeconds(of: audioURL),
              audioSeconds >= AppSettings.minimumSessionDuration else {
            return false
        }
        session.status = .enriching
        session.enrichmentState = .pending
        session.enrichmentFailureReasonRaw = nil
        try? modelContext.save()
        enrichment.enqueue(TranscriptEnrichmentService.Job(
            sessionID: session.id,
            audioURL: audioURL,
            whisperModelFolder: whisperFolder,
            whisperVariant: EnrichmentModelManager.whisperModelName
        ))
        return true
    }

    /// Re-runs the pass for a finished session (failed run, or models were
    /// downloaded after the fact).
    func retryEnrichment(for session: RecordingSession) {
        guard session.status == .complete || session.status == .failed else { return }
        _ = startEnrichmentIfPossible(for: session)
    }

    /// Transcribes recordings that were captured before the models were
    /// downloaded (parked as skipped, audio kept). Called at launch and
    /// after a download completes, so the backlog clears itself — no
    /// note-by-note Retry hunting.
    func transcribeBacklog() {
        guard enrichmentModels.isReady else { return }
        let skipped = RecordingSession.EnrichmentState.skipped.rawValue
        let complete = RecordingSession.Status.complete.rawValue
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate {
            $0.enrichmentStateRaw == skipped && $0.statusRaw == complete
        })
        guard let parked = try? modelContext.fetch(descriptor) else { return }
        for session in parked where session.segments.isEmpty {
            _ = startEnrichmentIfPossible(for: session)
        }
    }

    /// The pass succeeded end-to-end: replace the preliminary transcript
    /// with the enriched one in a single transaction. Replacement only ever
    /// happens here — a failure partway through must never cost the
    /// transcript the session already has.
    private func finishEnrichment(
        for id: UUID,
        segments: [TranscriptEnrichmentService.EnrichedSegment],
        clusters: [TranscriptEnrichmentService.SpeakerCluster]
    ) {
        enrichmentProgress.removeValue(forKey: id)
        guard let session = fetchSession(id: id) else { return }

        for old in session.segments {
            modelContext.delete(old)
        }
        for (index, segment) in segments.enumerated() {
            let stored = TranscriptSegment(
                index: index,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                languageCode: segment.languageCode,
                speakerKey: segment.speakerKey
            )
            modelContext.insert(stored)
            stored.session = session
        }
        session.rebuildTranscriptPreview(from: segments.map(\.text))
        session.enrichmentState = .done
        session.enrichmentFailureReasonRaw = nil

        let assignedNames = speakerIdentity.processClusters(clusters, sessionID: id)
        if segments.isEmpty {
            session.status = .complete
            try? modelContext.save()
        } else {
            // Build the summarizer input from the structs in hand rather
            // than re-faulting and re-sorting the thousands of segments
            // that were just inserted.
            let transcript = TranscriptFormatting.attributedText(segments.map {
                TranscriptFormatting.Line(
                    text: $0.text,
                    languageCode: $0.languageCode,
                    speakerKey: $0.speakerKey,
                    speakerName: $0.speakerKey.flatMap { assignedNames[$0] }
                )
            })
            summarize(session, transcript: transcript)
        }
    }

    private func failEnrichment(for id: UUID, reason: TranscriptEnrichmentService.FailureReason) {
        enrichmentProgress.removeValue(forKey: id)

        // Model files vanishing (OS purged a cache, interrupted install) is
        // system state, not session state — reflect it in Settings so the
        // fix is one obvious re-download away.
        if reason == .modelLoadFailed {
            enrichmentModels.noteModelLoadFailure()
        }

        guard let session = fetchSession(id: id) else { return }
        session.enrichmentState = .failed
        session.enrichmentFailureReasonRaw = reason.rawValue
        if session.segments.isEmpty {
            // No earlier transcript exists to fall back to.
            session.status = .failed
            try? modelContext.save()
        } else {
            // The existing transcript is untouched (replacement only
            // happens on success); finish the note from it.
            summarize(session)
        }
    }

    /// Call before deleting a session: stops any queued/in-flight enrichment
    /// for it and drops pending voice-review cards that would point at its
    /// (soon to be deleted) audio.
    func sessionWillBeDeleted(_ sessionID: UUID) {
        deletedSessions.insert(sessionID)
        enrichment.cancel(sessionID: sessionID)
        enrichmentProgress.removeValue(forKey: sessionID)
        speakerIdentity.purgeReviewItems(for: sessionID)
    }

    /// Whether the multilingual/speaker pass is running or queued for any
    /// session — Settings uses this to keep "Remove models" safe.
    var isEnrichmentActive: Bool { !enrichmentProgress.isEmpty }

    /// The People tab's actions, routed through the one policy owner.
    var speakerIdentityService: SpeakerIdentityService { speakerIdentity }

    // MARK: - Note generation

    /// `transcript` lets callers that already hold the transcript text (the
    /// enrichment finish path) skip re-reading every segment; by default the
    /// speaker/language-annotated transcript is built from the model.
    private func summarize(_ session: RecordingSession, transcript: String? = nil) {
        session.status = .summarizing
        try? modelContext.save()

        let id = session.id
        let text = transcript ?? session.attributedTranscript
        Task { [weak self] in
            let result = await SummarizationService.generateNote(from: text)
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
    /// transcription is re-run whenever it can be (a mid-pass death restarts
    /// the pass from the top — speaker-cluster identities can't survive a
    /// process death, and re-running is cheap next to a wrong who-said-what);
    /// otherwise whatever transcript exists gets its note. Only leftovers
    /// with no usable audio and no transcript are removed. The "transcribing"
    /// status is legacy (pre-Whisper live transcription) kept so upgraders'
    /// mid-flight sessions still recover.
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

            // Prefer re-running the transcription pass whenever it can run —
            // EXCEPT when it already finished (.done): the transcript is
            // final and speaker identification already ran; re-running would
            // double-count voice evidence (self-matching review cards,
            // double-folded voiceprints). A .done orphan just needs its note.
            if session.enrichmentState != .done,
               startEnrichmentIfPossible(for: session) {
                continue
            }

            if segments.isEmpty {
                // No transcript — but the audio is transcribable once the
                // models are downloaded. Only a session with nothing to
                // recover from is deleted.
                if let audioSeconds = Self.readableAudioSeconds(of: session.audioFileURL),
                   audioSeconds >= AppSettings.minimumSessionDuration {
                    if session.duration == 0 { session.duration = audioSeconds }
                    session.enrichmentState = .skipped
                    session.status = .complete
                } else {
                    Persistence.deleteAudioFile(named: session.audioFileName)
                    modelContext.delete(session)
                }
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

    // MARK: - Helpers

    private func fetchSession(id: UUID) -> RecordingSession? {
        RecordingSession.fetch(id: id, in: modelContext)
    }

    /// Playable length of a session's audio file, or nil when the file is
    /// missing/unreadable (e.g. a writer killed mid-header). Also used by
    /// the note detail view to decide whether Retry can possibly work.
    static func readableAudioSeconds(of url: URL?) -> TimeInterval? {
        guard let url, FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }
}
