import AVFAudio
import Foundation

/// Consumes raw mic buffers and turns them into recording sessions:
/// waits for speech (keeping a pre-roll so first words aren't clipped),
/// writes each session to its own audio file, and decides when a session
/// ends (long silence, max duration, manual stop, interruption).
///
/// All internal state is confined to a private serial queue. Events are
/// delivered on the main queue.
final class SessionPipeline {
    enum EndReason: String {
        case silence
        case maxDuration
        case manualStop
        case interruption
    }

    enum Event {
        /// Mic level for the waveform (~12 Hz, one per tap buffer).
        case level(Float)
        case sessionStarted(id: UUID, fileName: String, startedAt: Date)
        case sessionEnded(id: UUID, fileName: String, duration: TimeInterval, endedAt: Date, reason: EndReason, discarded: Bool)
    }

    /// Delivered on the main queue.
    var emit: ((Event) -> Void)?
    /// Called synchronously on the pipeline queue with every buffer belonging
    /// to a session (pre-roll included) — the transcription feed.
    var speechSink: ((UUID, AVAudioPCMBuffer) -> Void)?

    private let queue = DispatchQueue(label: "echonotes.pipeline", qos: .userInitiated)
    private let vad = VoiceActivityDetector()

    /// Gate closed by stop(): buffers that race in while a stop is settling
    /// (the tap is torn down asynchronously) must not start a new session.
    private var accepting = false

    // Pre-roll kept while waiting for speech.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollSeconds: TimeInterval = 0

    private struct ActiveSession {
        let id: UUID
        let fileName: String
        let writer: AudioFileWriter
        let startedAt: Date
        /// Audio time (seconds of processed frames) since session start.
        var clock: TimeInterval = 0
        var lastSpeechAt: TimeInterval = 0
        var totalSpeechSeconds: TimeInterval = 0
    }

    private var active: ActiveSession?

    // MARK: - Gate

    /// Opens the pipeline for new sessions. Called after capture (re)starts.
    func beginAccepting() {
        queue.async { [self] in
            accepting = true
        }
    }

    // MARK: - Ingest (called from the audio tap)

    func ingest(_ buffer: AVAudioPCMBuffer) {
        // The tap's buffer is only guaranteed valid inside the tap callback;
        // everything downstream holds buffers (pre-roll, transcription hold),
        // so copy before leaving this thread.
        guard let copy = buffer.deepCopy() else { return }
        queue.async { [self] in
            process(copy)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard accepting else { return }

        let reading = vad.process(buffer)
        let bufferSeconds = Double(buffer.frameLength) / buffer.format.sampleRate

        dispatchToMain(.level(reading.normalizedLevel))

        if var session = active {
            session.clock += bufferSeconds
            session.writer.write(buffer)
            speechSink?(session.id, buffer)
            if reading.isSpeech {
                session.lastSpeechAt = session.clock
                session.totalSpeechSeconds += bufferSeconds
            }
            active = session

            let silence = session.clock - session.lastSpeechAt
            if silence >= AppSettings.sessionSilenceGap {
                endActiveSession(reason: .silence)
            } else if session.clock >= AppSettings.maxSessionDuration {
                endActiveSession(reason: .maxDuration)
            }
        } else if reading.isSpeech {
            startSession(triggeredBy: buffer)
        } else {
            appendToPreRoll(buffer, seconds: bufferSeconds)
        }
    }

    // MARK: - Session lifecycle (pipeline queue)

    private func startSession(triggeredBy buffer: AVAudioPCMBuffer) {
        let id = UUID()
        let fileName = "\(id.uuidString).m4a"
        let url = Persistence.audioURL(forFileName: fileName)

        guard let writer = try? AudioFileWriter(url: url, inputFormat: buffer.format) else {
            return
        }

        let startedAt = Date.now.addingTimeInterval(-preRollSeconds)
        var session = ActiveSession(id: id, fileName: fileName, writer: writer, startedAt: startedAt)

        // Pre-roll and the triggering buffer flow to both the file and the
        // transcriber, so file positions and transcript timestamps line up.
        for held in preRoll {
            writer.write(held)
            speechSink?(id, held)
            session.clock += Double(held.frameLength) / held.format.sampleRate
        }
        preRoll.removeAll()
        preRollSeconds = 0

        writer.write(buffer)
        speechSink?(id, buffer)
        session.clock += Double(buffer.frameLength) / buffer.format.sampleRate
        session.lastSpeechAt = session.clock

        active = session
        dispatchToMain(.sessionStarted(id: id, fileName: fileName, startedAt: startedAt))
    }

    private func endActiveSession(reason: EndReason) {
        guard let session = active else { return }
        active = nil

        // Too little speech means an accidental trigger — discard.
        let discarded = session.totalSpeechSeconds < AppSettings.minimumSessionDuration

        // Report speech-trimmed duration for silence-terminated sessions so a
        // 90-second silent tail doesn't inflate the note's length.
        let duration: TimeInterval = reason == .silence
            ? min(session.clock, session.lastSpeechAt + AppSettings.vadHangover)
            : session.clock

        let emitEvent = emit
        session.writer.finish {
            DispatchQueue.main.async {
                emitEvent?(.sessionEnded(
                    id: session.id,
                    fileName: session.fileName,
                    duration: duration,
                    endedAt: session.startedAt.addingTimeInterval(session.clock),
                    reason: reason,
                    discarded: discarded
                ))
            }
        }
    }

    /// Finalize any active session (toggle off, interruption) and close the
    /// gate so racing buffers can't start a new one. The completion runs on
    /// the main queue after pipeline state is settled.
    func stop(reason: EndReason, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            accepting = false
            endActiveSession(reason: reason)
            preRoll.removeAll()
            preRollSeconds = 0
            vad.reset()
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func appendToPreRoll(_ buffer: AVAudioPCMBuffer, seconds: TimeInterval) {
        preRoll.append(buffer)
        preRollSeconds += seconds
        while preRollSeconds > AppSettings.preRollDuration, !preRoll.isEmpty {
            let removed = preRoll.removeFirst()
            preRollSeconds -= Double(removed.frameLength) / removed.format.sampleRate
        }
    }

    private func dispatchToMain(_ event: Event) {
        guard let emit else { return }
        DispatchQueue.main.async { emit(event) }
    }
}
