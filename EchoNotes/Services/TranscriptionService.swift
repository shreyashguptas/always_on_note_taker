import AVFAudio
import Foundation
import Speech

/// One instance per recording session. Streams mic buffers into Apple's
/// on-device SpeechAnalyzer/SpeechTranscriber and reports volatile text (for
/// the live view) and finalized, timestamped segments (persisted as the
/// transcript).
///
/// `enqueue(_:)` is safe to call before the analyzer finishes starting:
/// buffers are held and flushed once the analyzer format is known, so the
/// session's first words are never lost.
final class TranscriptionService {
    struct Segment {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Delivered on the main queue.
    var onVolatileText: ((String) -> Void)?
    /// Delivered on the main queue, in order.
    var onFinalSegment: ((Segment) -> Void)?

    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    // Guarded by `lock`: buffering until the analyzer is ready, plus the
    // converter that resamples tap audio into the analyzer's format.
    private let lock = NSLock()
    private var converter: AudioBufferConverter?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingSeconds: TimeInterval = 0
    /// Set only after every startup-held buffer has been flushed, so live
    /// buffers can't jump the queue ahead of the pre-roll.
    private var ready = false
    private var finished = false
    /// Fallback clock (seconds fed to the analyzer) used when a result carries
    /// no audio time range.
    private var fedSeconds: TimeInterval = 0
    private var lastSegmentEnd: TimeInterval = 0

    init(locale: Locale) {
        self.locale = locale
        (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        startTask = Task { [weak self] in
            await self?.start()
        }
    }

    // MARK: - Startup

    private func start() async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result)
                }
            } catch {
                // Transcription errors end the stream; captured audio and any
                // already-finalized segments are unaffected.
            }
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            lock.lock()
            pendingBuffers.removeAll()
            pendingSeconds = 0
            finished = true
            lock.unlock()
            return
        }

        // Analyzer is live: drain everything buffered while it started.
        // `ready` flips only once the pending queue is empty at a lock check,
        // so buffers that arrive mid-drain append behind the held ones and
        // temporal order into the analyzer is preserved.
        lock.lock()
        if let format {
            converter = AudioBufferConverter(outputFormat: format)
        }
        lock.unlock()

        while true {
            lock.lock()
            if pendingBuffers.isEmpty {
                ready = true
                lock.unlock()
                break
            }
            let batch = pendingBuffers
            pendingBuffers.removeAll()
            pendingSeconds = 0
            lock.unlock()
            for buffer in batch {
                convertAndYield(buffer)
            }
        }
    }

    // MARK: - Feeding audio (called on the pipeline queue)

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if !ready {
            // Hold audio while the analyzer starts, bounded in case startup
            // stalls; oldest audio drops first.
            pendingBuffers.append(buffer)
            pendingSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            pendingBuffers.trimToDuration(
                cap: AppSettings.transcriptionHoldSeconds,
                accumulatedSeconds: &pendingSeconds
            )
            lock.unlock()
            return
        }
        lock.unlock()
        convertAndYield(buffer)
    }

    private func convertAndYield(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !finished, let converter, let converted = converter.convert(buffer) else {
            lock.unlock()
            return
        }
        fedSeconds += Double(converted.frameLength) / converted.format.sampleRate
        lock.unlock()
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isFinal {
            guard !text.isEmpty else {
                DispatchQueue.main.async { [weak self] in self?.onVolatileText?("") }
                return
            }

            // Pull the segment's position in the session audio from the
            // attributed runs; fall back to the fed-audio clock.
            var start: TimeInterval?
            var end: TimeInterval?
            for run in result.text.runs {
                if let range = run.audioTimeRange {
                    let runStart = range.start.seconds
                    let runEnd = range.end.seconds
                    start = min(start ?? runStart, runStart)
                    end = max(end ?? runEnd, runEnd)
                }
            }

            lock.lock()
            let fallbackStart = lastSegmentEnd
            let fallbackEnd = fedSeconds
            let segment = Segment(
                text: text,
                startTime: start ?? fallbackStart,
                endTime: end ?? fallbackEnd
            )
            lastSegmentEnd = segment.endTime
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onFinalSegment?(segment)
                self?.onVolatileText?("")
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onVolatileText?(text)
            }
        }
    }

    // MARK: - Shutdown

    /// Stops accepting audio, asks the analyzer to finalize everything it has
    /// heard, and waits until the last segment has been delivered.
    func finishAndWait() async {
        guard markFinished() else { return }

        // Make sure startup completed before finalizing.
        await startTask?.value
        inputBuilder.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
    }

    /// Abandon without finalizing (discarded sessions). Waits for startup so
    /// the analyzer that startup creates is always the one torn down.
    func cancel() {
        guard markFinished() else { return }
        Task { [self] in
            await startTask?.value
            inputBuilder.finish()
            resultsTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
    }

    /// Returns false if already finished.
    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        pendingBuffers.removeAll()
        pendingSeconds = 0
        return true
    }
}
