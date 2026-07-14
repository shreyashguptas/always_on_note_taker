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
    private var transcriber: SpeechTranscriber?
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    // Guarded by `lock`: buffering until the analyzer is ready, plus the
    // converter that resamples tap audio into the analyzer's format.
    private let lock = NSLock()
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pendingBuffers: [AVAudioPCMBuffer] = []
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
        self.transcriber = transcriber
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
            finished = true
            lock.unlock()
            return
        }

        // Analyzer is live: flush everything buffered while it started.
        lock.lock()
        analyzerFormat = format
        let held = pendingBuffers
        pendingBuffers.removeAll()
        lock.unlock()

        for buffer in held {
            convertAndYield(buffer)
        }
    }

    // MARK: - Feeding audio (called on the pipeline queue)

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if analyzerFormat == nil {
            // Cap the holding buffer at roughly 60 seconds of audio in case
            // startup stalls; oldest audio drops first.
            if pendingBuffers.count > 700 {
                pendingBuffers.removeFirst()
            }
            pendingBuffers.append(buffer)
            lock.unlock()
            return
        }
        lock.unlock()
        convertAndYield(buffer)
    }

    private func convertAndYield(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !finished, let format = analyzerFormat else {
            lock.unlock()
            return
        }

        if buffer.format == format {
            fedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            lock.unlock()
            inputBuilder.yield(AnalyzerInput(buffer: buffer))
            return
        }

        // Rebuild the converter if the input format changed (route change).
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converterInputFormat = buffer.format
        }
        guard let converter else {
            lock.unlock()
            return
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            lock.unlock()
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, converted.frameLength > 0 else {
            lock.unlock()
            return
        }
        fedSeconds += Double(converted.frameLength) / format.sampleRate
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
        lock.lock()
        let alreadyFinished = finished
        finished = true
        pendingBuffers.removeAll()
        lock.unlock()
        guard !alreadyFinished else { return }

        // Make sure startup completed before finalizing.
        await startTask?.value
        inputBuilder.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
    }

    /// Abandon without finalizing (discarded sessions).
    func cancel() {
        lock.lock()
        finished = true
        pendingBuffers.removeAll()
        lock.unlock()
        inputBuilder.finish()
        resultsTask?.cancel()
        Task { [analyzer] in
            await analyzer?.cancelAndFinishNow()
        }
    }
}
