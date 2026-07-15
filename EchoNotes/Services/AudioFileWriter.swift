import AVFAudio

/// Writes PCM buffers from the mic tap into an AAC `.m4a` file, one file per
/// session. All writes happen on a private serial queue so the audio thread is
/// never blocked on disk I/O.
final class AudioFileWriter {
    let url: URL
    private let queue = DispatchQueue(label: "echonotes.audiofile", qos: .userInitiated)
    private var file: AVAudioFile?
    private var converter: AudioBufferConverter?

    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.url = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        self.converter = AudioBufferConverter(outputFormat: file.processingFormat)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let file, let converted = converter?.convert(buffer) else { return }
            // Dropping a buffer is preferable to crashing the pipeline; the
            // transcript is unaffected.
            try? file.write(from: converted)
        }
    }

    /// Flushes pending writes and closes the file. Safe to call once.
    func finish(completion: @escaping () -> Void) {
        queue.async { [self] in
            file = nil // AVAudioFile closes on deinit
            converter = nil
            completion()
        }
    }
}
