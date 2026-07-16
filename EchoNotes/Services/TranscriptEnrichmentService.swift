import AVFAudio
import FluidAudio
import Foundation
import WhisperKit

/// The post-session pass that turns a finished recording into the
/// authoritative transcript: multilingual speech-to-text with per-segment
/// language detection (WhisperKit) plus speaker diarization with voiceprints
/// (FluidAudio), merged on the timeline so every segment knows its language
/// and its speaker. Everything runs on-device.
///
/// Jobs are processed strictly one at a time on a background task. The audio
/// file is decoded in ten-minute windows — both models take raw Float32
/// samples, and a two-hour file would be ~460 MB decoded at once. The full
/// result is delivered only on success (progress streams per window), so a
/// mid-file failure never costs a transcript. Models are loaded lazily on
/// the first job and released when the queue drains (they hold north of a
/// gigabyte).
final class TranscriptEnrichmentService {
    struct EnrichedSegment {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        /// ISO 639-1 ("hi", "de"…) detected for the ~30 s chunk this text
        /// came from — Whisper detects language per decoding window, so
        /// mid-sentence switches label as the dominant language.
        let languageCode: String?
        /// Session-local diarization cluster ("S1"…), nil when diarization
        /// produced nothing for this stretch.
        let speakerKey: String?
    }

    /// One distinct voice found in a session, with everything identification
    /// needs: the voiceprint, how much they spoke, and where their clearest
    /// stretch of speech sits (for the review card's snippet).
    struct SpeakerCluster {
        let key: String
        let embedding: [Float]
        let totalSpeech: TimeInterval
        let snippetStart: TimeInterval
        let snippetEnd: TimeInterval
    }

    enum Phase: Equatable {
        case waiting
        /// Fraction of the file processed so far.
        case processing(Double)
    }

    /// Why a pass failed — typed so the coordinator can persist it, the UI
    /// can explain it next to Retry, and model problems can heal install
    /// state. The copy lives here with the reason, in one place.
    enum FailureReason: String {
        case modelLoadFailed
        case unreadableAudio
        case emptyAudio
        case decodeFailed
        case transcriptionFailed

        var userMessage: String {
            switch self {
            case .modelLoadFailed:
                "The transcription models couldn't be loaded. Re-download them in Settings, then retry."
            case .unreadableAudio:
                "This recording's audio file couldn't be read."
            case .emptyAudio:
                "This recording's audio file is empty."
            case .decodeFailed:
                "The audio couldn't be decoded partway through."
            case .transcriptionFailed:
                "Transcription failed partway through. Retry to run it again."
            }
        }
    }

    struct Job {
        let sessionID: UUID
        let audioURL: URL
        let whisperModelFolder: URL
        let whisperVariant: String
    }

    // All callbacks delivered on the main queue.
    var onProgress: ((UUID, Phase) -> Void)?
    /// The complete enriched transcript plus every voice found — delivered
    /// once, only on full success, so the caller can replace the preliminary
    /// transcript atomically. A failure partway through must never cost the
    /// transcript the session already has.
    var onFinished: ((UUID, [EnrichedSegment], [SpeakerCluster]) -> Void)?
    var onFailed: ((UUID, FailureReason) -> Void)?

    private let lock = NSLock()
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    /// Sessions whose jobs should stop (their note was deleted).
    private var cancelled: Set<UUID> = []

    // Engines live only while the queue is non-empty. Touched exclusively by
    // the single worker task; the drain/unload happens under the lock (see
    // dequeue) so a racing enqueue can never start a second worker while
    // these are still being torn down.
    private var whisper: WhisperKit?
    private var loadedWhisperVariant: String?
    /// The diarizer's Core ML models are cached across jobs, but the manager
    /// itself is recreated per job: it accumulates a speaker database for
    /// cross-window consistency, and that database must not leak one
    /// session's voices into the next session's clustering.
    private var diarizerModels: DiarizerModels?

    // MARK: - Queueing

    func enqueue(_ job: Job) {
        lock.lock()
        // A session already queued must not run twice (retry taps, recovery).
        guard !queue.contains(where: { $0.sessionID == job.sessionID }) else {
            lock.unlock()
            return
        }
        cancelled.remove(job.sessionID)
        queue.append(job)
        if worker == nil {
            // Assigned under the same lock that dequeue() clears it under:
            // if the slot were filled after the task started, a task that
            // drains instantly could null the slot first and leave a dead
            // reference blocking every future job.
            worker = Task.detached(priority: .utility) { [weak self] in
                while let self, let job = self.dequeue() {
                    await self.process(job)
                }
            }
        }
        lock.unlock()

        dispatchProgress(job.sessionID, .waiting)
    }

    /// The session is being deleted: drop its queued job, or tell an
    /// in-flight one to stop at the next window boundary. No callbacks fire
    /// for a cancelled session.
    func cancel(sessionID: UUID) {
        lock.lock()
        queue.removeAll { $0.sessionID == sessionID }
        cancelled.insert(sessionID)
        lock.unlock()
    }

    private func isCancelled(_ sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(sessionID)
    }

    private func dequeue() -> Job? {
        lock.lock()
        if queue.isEmpty {
            // Unload the engines (~1.5 GB) BEFORE clearing `worker`, all
            // under the lock: once `worker` is nil a racing enqueue starts a
            // new worker, and it must never observe a half-torn-down engine.
            // The references are moved to locals so their (potentially slow)
            // deallocation happens after the lock is released.
            let oldWhisper = whisper
            let oldModels = diarizerModels
            whisper = nil
            loadedWhisperVariant = nil
            diarizerModels = nil
            worker = nil
            lock.unlock()
            _ = oldWhisper
            _ = oldModels
            return nil
        }
        let job = queue.removeFirst()
        lock.unlock()
        return job
    }

    // MARK: - Processing one session

    private func process(_ job: Job) async {
        guard !isCancelled(job.sessionID) else { return }

        let diarizer: DiarizerManager?
        do {
            diarizer = try await loadEngines(job)
        } catch {
            dispatchFailed(job.sessionID, .modelLoadFailed)
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: job.audioURL)
        } catch {
            dispatchFailed(job.sessionID, .unreadableAudio)
            return
        }

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let totalSeconds = Double(totalFrames) / sampleRate
        guard totalSeconds > 0 else {
            dispatchFailed(job.sessionID, .emptyAudio)
            return
        }

        let decoder = WindowedAudioDecoder(file: file)
        var clusters = ClusterAccumulator()
        var allSegments: [EnrichedSegment] = []
        var windowStart: TimeInterval = 0

        while windowStart < totalSeconds {
            if isCancelled(job.sessionID) { return }
            await waitWhileThermallyConstrained(sessionID: job.sessionID)
            if isCancelled(job.sessionID) { return }

            let windowSeconds = min(AppSettings.enrichmentWindowSeconds, totalSeconds - windowStart)
            let samples: [Float]
            do {
                samples = try decoder.readWindow(seconds: windowSeconds)
            } catch {
                dispatchFailed(job.sessionID, .decodeFailed)
                return
            }
            if samples.isEmpty { break }

            var turns: [SpeakerAttribution.SpeakerTurn] = []
            if let diarizer {
                // Diarization failing must not cost the transcript — the
                // window just goes out unattributed.
                if let result = try? diarizer.performCompleteDiarization(samples) {
                    turns = result.segments.map {
                        SpeakerAttribution.SpeakerTurn(
                            speakerKey: $0.speakerId,
                            start: TimeInterval($0.startTimeSeconds) + windowStart,
                            end: TimeInterval($0.endTimeSeconds) + windowStart
                        )
                    }
                    clusters.fold(result, windowStart: windowStart)
                }
            }

            do {
                allSegments += try await transcribeWindow(samples, windowStart: windowStart, turns: turns)
            } catch {
                dispatchFailed(job.sessionID, .transcriptionFailed)
                return
            }

            windowStart += windowSeconds
            dispatchProgress(job.sessionID, .processing(min(1, windowStart / totalSeconds)))
        }

        guard !isCancelled(job.sessionID) else { return }

        // Fold same-voice clusters the diarizer split (a quiet single
        // speaker must not come out as "Speaker 1" and "Speaker 2"), and
        // point the transcript's speaker keys at the surviving clusters.
        let (mergedClusters, remap) = SpeakerClusterMerging.merge(
            clusters.finish(),
            threshold: AppSettings.speakerClusterMergeThreshold
        )
        if !remap.isEmpty {
            allSegments = allSegments.map { segment in
                guard let key = segment.speakerKey, let survivor = remap[key] else { return segment }
                return EnrichedSegment(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    languageCode: segment.languageCode,
                    speakerKey: survivor
                )
            }
        }
        dispatchFinished(job.sessionID, allSegments, mergedClusters)
    }

    /// Loads (or reuses) the Whisper engine and builds a FRESH diarizer for
    /// this job, so speaker clustering starts from a clean database — one
    /// session's voices must not seed the next session's clusters.
    private func loadEngines(_ job: Job) async throws -> DiarizerManager? {
        if whisper == nil || loadedWhisperVariant != job.whisperVariant {
            let config = WhisperKitConfig(
                model: job.whisperVariant,
                modelFolder: job.whisperModelFolder.path,
                load: true,
                download: false
            )
            whisper = try await WhisperKit(config)
            loadedWhisperVariant = job.whisperVariant
        }
        if diarizerModels == nil {
            // Models were installed by EnrichmentModelManager; this reuses
            // the local cache and only hits the network if it was wiped.
            diarizerModels = try await DiarizerModels.downloadIfNeeded()
        }
        guard let diarizerModels else { return nil }
        let manager = DiarizerManager()
        manager.initialize(models: diarizerModels)
        return manager
    }

    // MARK: - Whisper

    private func transcribeWindow(
        _ samples: [Float],
        windowStart: TimeInterval,
        turns: [SpeakerAttribution.SpeakerTurn]
    ) async throws -> [EnrichedSegment] {
        guard let whisper else { return [] }

        let options = DecodingOptions(
            task: .transcribe,           // explicit: Whisper must never translate
            language: nil,               // auto-detect per chunk
            usePrefillPrompt: false,
            detectLanguage: true,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad       // ~30 s chunks on speech boundaries
        )

        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)

        var enriched: [EnrichedSegment] = []
        for result in results {
            let language = normalizedLanguageCode(result.language)
            for segment in result.segments {
                // Whisper writes fluent text over silence and noise; the
                // no-speech probability is the tell.
                if segment.noSpeechProb > AppSettings.whisperNoSpeechCutoff { continue }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }

                let words = (segment.words ?? []).map {
                    SpeakerAttribution.TimedText(
                        text: $0.word,
                        start: TimeInterval($0.start) + windowStart,
                        end: TimeInterval($0.end) + windowStart
                    )
                }
                let fallback = [SpeakerAttribution.TimedText(
                    text: text,
                    start: TimeInterval(segment.start) + windowStart,
                    end: TimeInterval(segment.end) + windowStart
                )]

                let runs = SpeakerAttribution.attribute(
                    words: words.isEmpty ? fallback : words,
                    turns: turns
                )
                enriched.append(contentsOf: runs.map {
                    EnrichedSegment(
                        text: $0.text,
                        startTime: $0.start,
                        endTime: $0.end,
                        languageCode: language,
                        speakerKey: $0.speakerKey
                    )
                })
            }
        }
        return enriched
    }

    /// Whisper reports "hi", "hindi", or occasionally "<|hi|>" depending on
    /// the path; reduce all of them to a bare ISO 639-1 code.
    private func normalizedLanguageCode(_ raw: String?) -> String? {
        guard var code = raw?.lowercased(), !code.isEmpty else { return nil }
        code = code.trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
        if code.count > 3 {
            code = Locale.Language(identifier: code).languageCode?.identifier ?? code
        }
        return code.isEmpty ? nil : code
    }

    // MARK: - Thermal backoff

    /// Enrichment is deferrable by definition; never fight a hot phone. A
    /// cancelled session must not keep the (single, serial) worker parked
    /// here for the rest of the thermal event, and a cancelled task must
    /// exit rather than busy-spin on a sleep that no longer sleeps.
    private func waitWhileThermallyConstrained(sessionID: UUID) async {
        while !isCancelled(sessionID) {
            let state = ProcessInfo.processInfo.thermalState
            if state != .serious && state != .critical { return }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
        }
    }

    // MARK: - Cluster accumulation

    /// Folds per-window diarization results into per-speaker totals: net
    /// speech, a duration-weighted voiceprint, and the longest single turn
    /// (whose middle ten seconds become the review snippet).
    private struct ClusterAccumulator {
        private struct Entry {
            /// Duration-weighted sum of segment embeddings — only direction
            /// matters for cosine similarity, so it's normalized at finish.
            var embeddingSum: [Float] = []
            var totalSpeech: TimeInterval = 0
            var longestTurnStart: TimeInterval = 0
            var longestTurnEnd: TimeInterval = 0
        }

        private var entries: [String: Entry] = [:]

        mutating func fold(_ result: DiarizationResult, windowStart: TimeInterval) {
            // Voiceprints come from the segments themselves:
            // `DiarizationResult.speakerDatabase` is only populated in the
            // library's debug mode, so relying on it silently produced zero
            // clusters — and an always-empty People tab.
            for segment in result.segments {
                let start = TimeInterval(segment.startTimeSeconds) + windowStart
                let end = TimeInterval(segment.endTimeSeconds) + windowStart
                var entry = entries[segment.speakerId] ?? Entry()
                entry.totalSpeech += end - start
                if end - start > entry.longestTurnEnd - entry.longestTurnStart {
                    entry.longestTurnStart = start
                    entry.longestTurnEnd = end
                }
                if !segment.embedding.isEmpty {
                    let weight = Float(max(0.1, end - start))
                    if entry.embeddingSum.count != segment.embedding.count {
                        entry.embeddingSum = [Float](repeating: 0, count: segment.embedding.count)
                    }
                    for i in segment.embedding.indices {
                        entry.embeddingSum[i] += segment.embedding[i] * weight
                    }
                }
                entries[segment.speakerId] = entry
            }
        }

        func finish() -> [SpeakerCluster] {
            entries.compactMap { key, entry in
                guard !entry.embeddingSum.isEmpty else { return nil }
                let turnLength = entry.longestTurnEnd - entry.longestTurnStart
                let snippetLength = min(AppSettings.speakerSnippetDuration, turnLength)
                let snippetStart = entry.longestTurnStart + (turnLength - snippetLength) / 2
                return SpeakerCluster(
                    key: key,
                    embedding: VoiceEmbedding.normalized(entry.embeddingSum),
                    totalSpeech: entry.totalSpeech,
                    snippetStart: snippetStart,
                    snippetEnd: snippetStart + snippetLength
                )
            }
            .sorted { $0.totalSpeech > $1.totalSpeech }
        }
    }

    // MARK: - Main-queue dispatch

    private func dispatchProgress(_ id: UUID, _ phase: Phase) {
        guard let onProgress else { return }
        DispatchQueue.main.async { onProgress(id, phase) }
    }

    private func dispatchFinished(_ id: UUID, _ segments: [EnrichedSegment], _ clusters: [SpeakerCluster]) {
        guard let onFinished else { return }
        DispatchQueue.main.async { onFinished(id, segments, clusters) }
    }

    private func dispatchFailed(_ id: UUID, _ reason: FailureReason) {
        guard let onFailed else { return }
        DispatchQueue.main.async { onFailed(id, reason) }
    }
}

/// Sequentially decodes an audio file into 16 kHz mono Float32 windows,
/// reading in small sub-chunks so peak memory stays at the size of one
/// converted window rather than the raw file. The sub-chunk read buffer is
/// allocated once and reused — hundreds of transient multi-megabyte buffers
/// would otherwise churn the allocator while the ML models already hold
/// most of the device's memory budget.
private final class WindowedAudioDecoder {
    private let file: AVAudioFile
    private let converter: AudioBufferConverter
    private let outputFormat: AVAudioFormat
    private let subChunkFrames: AVAudioFrameCount
    private let readBuffer: AVAudioPCMBuffer?

    init(file: AVAudioFile) {
        self.file = file
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppSettings.enrichmentSampleRate,
            channels: 1,
            interleaved: false
        )!
        self.converter = AudioBufferConverter(outputFormat: outputFormat)
        self.subChunkFrames = AVAudioFrameCount(30 * file.processingFormat.sampleRate)
        self.readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: subChunkFrames)
    }

    /// Returns the next `seconds` of audio as 16 kHz mono samples; shorter
    /// (or empty) at end of file.
    func readWindow(seconds: TimeInterval) throws -> [Float] {
        guard let buffer = readBuffer else { return [] }
        let sourceRate = file.processingFormat.sampleRate
        var framesWanted = AVAudioFrameCount(seconds * sourceRate)

        var window: [Float] = []
        window.reserveCapacity(Int(seconds * AppSettings.enrichmentSampleRate))

        while framesWanted > 0 {
            let toRead = min(framesWanted, subChunkFrames)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break } // end of file

            if let converted = converter.convert(buffer),
               let channel = converted.floatChannelData {
                window.append(contentsOf: UnsafeBufferPointer(
                    start: channel[0],
                    count: Int(converted.frameLength)
                ))
            }
            framesWanted -= buffer.frameLength
            if buffer.frameLength < toRead { break } // short read = end of file
        }
        return window
    }
}
