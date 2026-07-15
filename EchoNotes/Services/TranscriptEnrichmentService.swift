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
/// samples, and a two-hour file would be ~460 MB decoded at once — and each
/// window's segments are delivered incrementally so the transcript fills in
/// visibly. Models are loaded lazily on the first job and released when the
/// queue drains (they hold north of a gigabyte).
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

    struct Job {
        let sessionID: UUID
        let audioURL: URL
        let whisperModelFolder: URL
        let whisperVariant: String
    }

    // All callbacks delivered on the main queue.
    var onProgress: ((UUID, Phase) -> Void)?
    /// One batch of finalized segments per decoded window, in order.
    var onWindowSegments: (([EnrichedSegment], UUID) -> Void)?
    var onFinished: ((UUID, [SpeakerCluster]) -> Void)?
    var onFailed: ((UUID, String) -> Void)?

    private let lock = NSLock()
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?

    var isProcessing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return worker != nil
    }

    // Engines live only while the queue is non-empty.
    private var whisper: WhisperKit?
    private var loadedWhisperVariant: String?
    private var diarizer: DiarizerManager?

    // MARK: - Queueing

    func enqueue(_ job: Job) {
        lock.lock()
        // A session already queued must not run twice (retry taps, recovery).
        guard !queue.contains(where: { $0.sessionID == job.sessionID }) else {
            lock.unlock()
            return
        }
        queue.append(job)
        let needsWorker = worker == nil
        lock.unlock()

        dispatchProgress(job.sessionID, .waiting)
        if needsWorker {
            startWorker()
        }
    }

    private func startWorker() {
        let task = Task.detached(priority: .utility) { [weak self] in
            while let self, let job = self.dequeue() {
                await self.process(job)
            }
            self?.unloadEngines()
        }
        lock.lock()
        worker = task
        lock.unlock()
    }

    private func dequeue() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        if queue.isEmpty {
            worker = nil
            return nil
        }
        return queue.removeFirst()
    }

    private func unloadEngines() {
        // Runs on the worker after the queue drains; ~1.5 GB back to the
        // system until the next session ends.
        whisper = nil
        loadedWhisperVariant = nil
        diarizer = nil
    }

    // MARK: - Processing one session

    private func process(_ job: Job) async {
        do {
            try await loadEnginesIfNeeded(job)
        } catch {
            dispatchFailed(job.sessionID, "The processing models couldn't be loaded. You can retry from the note.")
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: job.audioURL)
        } catch {
            dispatchFailed(job.sessionID, "The recording's audio file couldn't be read.")
            return
        }

        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let totalSeconds = Double(totalFrames) / sampleRate
        guard totalSeconds > 0 else {
            dispatchFailed(job.sessionID, "The recording's audio file is empty.")
            return
        }

        let decoder = WindowedAudioDecoder(file: file)
        var clusters = ClusterAccumulator()
        var windowStart: TimeInterval = 0

        while windowStart < totalSeconds {
            await waitWhileThermallyConstrained()

            let windowSeconds = min(AppSettings.enrichmentWindowSeconds, totalSeconds - windowStart)
            let samples: [Float]
            do {
                samples = try decoder.readWindow(seconds: windowSeconds)
            } catch {
                dispatchFailed(job.sessionID, "The recording's audio couldn't be decoded.")
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

            let segments: [EnrichedSegment]
            do {
                segments = try await transcribeWindow(samples, windowStart: windowStart, turns: turns)
            } catch {
                dispatchFailed(job.sessionID, "Transcription failed partway through. You can retry from the note.")
                return
            }

            if !segments.isEmpty {
                dispatchWindowSegments(segments, job.sessionID)
            }
            windowStart += windowSeconds
            dispatchProgress(job.sessionID, .processing(min(1, windowStart / totalSeconds)))
        }

        dispatchFinished(job.sessionID, clusters.finish())
    }

    private func loadEnginesIfNeeded(_ job: Job) async throws {
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
        if diarizer == nil {
            // Models were installed by EnrichmentModelManager; this reuses
            // the local cache and only hits the network if it was wiped.
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            diarizer = manager
        }
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

    /// Enrichment is deferrable by definition; never fight a hot phone.
    private func waitWhileThermallyConstrained() async {
        while true {
            let state = ProcessInfo.processInfo.thermalState
            if state != .serious && state != .critical { return }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    // MARK: - Cluster accumulation

    /// Folds per-window diarization results into per-speaker totals: net
    /// speech, latest embedding, and the longest single turn (whose middle
    /// ten seconds become the review snippet).
    private struct ClusterAccumulator {
        private struct Entry {
            var embedding: [Float]
            var totalSpeech: TimeInterval = 0
            var longestTurnStart: TimeInterval = 0
            var longestTurnEnd: TimeInterval = 0
        }

        private var entries: [String: Entry] = [:]

        mutating func fold(_ result: DiarizationResult, windowStart: TimeInterval) {
            for segment in result.segments {
                let start = TimeInterval(segment.startTimeSeconds) + windowStart
                let end = TimeInterval(segment.endTimeSeconds) + windowStart
                var entry = entries[segment.speakerId] ?? Entry(embedding: [])
                entry.totalSpeech += end - start
                if end - start > entry.longestTurnEnd - entry.longestTurnStart {
                    entry.longestTurnStart = start
                    entry.longestTurnEnd = end
                }
                entries[segment.speakerId] = entry
            }
            // The diarizer's database carries the up-to-date embedding per
            // speaker; later windows refine earlier ones.
            if let database = result.speakerDatabase {
                for (speakerId, embedding) in database {
                    entries[speakerId]?.embedding = embedding
                }
            }
        }

        func finish() -> [SpeakerCluster] {
            entries.compactMap { key, entry in
                guard !entry.embedding.isEmpty else { return nil }
                let turnLength = entry.longestTurnEnd - entry.longestTurnStart
                let snippetLength = min(AppSettings.speakerSnippetDuration, turnLength)
                let snippetStart = entry.longestTurnStart + (turnLength - snippetLength) / 2
                return SpeakerCluster(
                    key: key,
                    embedding: entry.embedding,
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

    private func dispatchWindowSegments(_ segments: [EnrichedSegment], _ id: UUID) {
        guard let onWindowSegments else { return }
        DispatchQueue.main.async { onWindowSegments(segments, id) }
    }

    private func dispatchFinished(_ id: UUID, _ clusters: [SpeakerCluster]) {
        guard let onFinished else { return }
        DispatchQueue.main.async { onFinished(id, clusters) }
    }

    private func dispatchFailed(_ id: UUID, _ message: String) {
        guard let onFailed else { return }
        DispatchQueue.main.async { onFailed(id, message) }
    }
}

/// Sequentially decodes an audio file into 16 kHz mono Float32 windows,
/// reading in small sub-chunks so peak memory stays at the size of one
/// converted window rather than the raw file.
private final class WindowedAudioDecoder {
    private let file: AVAudioFile
    private let converter: AudioBufferConverter
    private let outputFormat: AVAudioFormat

    init(file: AVAudioFile) {
        self.file = file
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AppSettings.enrichmentSampleRate,
            channels: 1,
            interleaved: false
        )!
        self.converter = AudioBufferConverter(outputFormat: outputFormat)
    }

    /// Returns the next `seconds` of audio as 16 kHz mono samples; shorter
    /// (or empty) at end of file.
    func readWindow(seconds: TimeInterval) throws -> [Float] {
        let sourceRate = file.processingFormat.sampleRate
        var framesWanted = AVAudioFrameCount(seconds * sourceRate)
        let subChunkFrames = AVAudioFrameCount(30 * sourceRate)

        var window: [Float] = []
        window.reserveCapacity(Int(seconds * AppSettings.enrichmentSampleRate))

        while framesWanted > 0 {
            let toRead = min(framesWanted, subChunkFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: toRead) else {
                break
            }
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
