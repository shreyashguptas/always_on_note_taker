import AVFAudio

/// Converts PCM buffers to a fixed output format, rebuilding the underlying
/// AVAudioConverter whenever the input format changes (headset plug/unplug
/// changes the tap's sample rate or channel count mid-session).
///
/// Not internally synchronized — each owner must call it from a single
/// queue/lock, which both call sites (file writer queue, transcription lock)
/// already do.
final class AudioBufferConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    /// Returns the buffer converted to `outputFormat`, the original buffer if
    /// it already matches, or nil if conversion fails.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat {
            return buffer
        }

        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
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

        guard conversionError == nil, converted.frameLength > 0 else { return nil }
        return converted
    }
}
