import AVFAudio

/// Writes PCM buffers from the mic tap into an AAC `.m4a` file, one file per
/// session. All writes happen on a private serial queue so the audio thread is
/// never blocked on disk I/O.
final class AudioFileWriter {
    let url: URL
    private let queue = DispatchQueue(label: "echonotes.audiofile", qos: .userInitiated)
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private let sampleRate: Double

    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.url = url
        self.sampleRate = inputFormat.sampleRate

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let file else { return }
            do {
                if buffer.format == file.processingFormat {
                    try file.write(from: buffer)
                } else {
                    try writeConverted(buffer, to: file)
                }
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            } catch {
                // Dropping a buffer is preferable to crashing the pipeline;
                // the transcript is unaffected.
            }
        }
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
        }
        guard let converter else { return }
        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }

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
        if conversionError == nil, converted.frameLength > 0 {
            try file.write(from: converted)
        }
    }

    /// Flushes pending writes and closes the file. Returns the written
    /// duration in seconds. Safe to call once.
    func finish(completion: @escaping (TimeInterval) -> Void) {
        queue.async { [self] in
            let duration = TimeInterval(framesWritten) / sampleRate
            file = nil // AVAudioFile closes on deinit
            completion(duration)
        }
    }
}
