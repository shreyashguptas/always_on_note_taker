import AVFAudio
import Accelerate

/// Lightweight energy-based voice activity detection. Tracks an adaptive
/// noise floor so it works in quiet rooms and noisy cafés alike, and applies
/// a hangover so natural mid-sentence pauses don't register as silence.
final class VoiceActivityDetector {
    struct Reading {
        /// 0...1, for waveform display.
        let normalizedLevel: Float
        /// True while someone is speaking (including the hangover window).
        let isSpeech: Bool
    }

    /// Adaptive noise floor in dBFS. Drops instantly to quieter input, rises
    /// slowly (dB/sec) so speech doesn't drag the floor up.
    private var noiseFloorDB: Float = -60
    private let floorRisePerSecond: Float = 1.5
    /// Rise rate while speech is being detected. Not zero — steady loud
    /// noise misread as speech (an AC unit kicking in) must eventually be
    /// reclassified or a session would never end — but ~15x slower, so a
    /// dense conversation needs minutes of literally dip-free audio before
    /// the floor could reach it, and any brief pause resets the floor
    /// instantly anyway.
    private let floorRisePerSecondDuringSpeech: Float = 0.1
    private var hangoverRemaining: TimeInterval = 0

    func process(_ buffer: AVAudioPCMBuffer) -> Reading {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channel = buffer.floatChannelData?[0] else {
            return Reading(normalizedLevel: 0, isSpeech: hangoverRemaining > 0)
        }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frameCount))
        let db: Float = rms > 0 ? max(-80, 20 * log10(rms)) : -80

        let bufferSeconds = Double(frameCount) / buffer.format.sampleRate

        // Classify against the CURRENT floor before adapting it — the old
        // order let a long steady conversation drag the floor up to its own
        // level (1.5 dB/s) until the speaker was reclassified as background
        // noise and the session ended mid-sentence.
        let threshold = max(noiseFloorDB + AppSettings.vadSpeechMarginDB, AppSettings.vadAbsoluteFloorDB)
        let rawSpeech = db > threshold

        if db < noiseFloorDB {
            // Quieter input drops the floor instantly, speech or not.
            noiseFloorDB = max(db, -80)
        } else {
            let rate = (rawSpeech || hangoverRemaining > 0)
                ? floorRisePerSecondDuringSpeech
                : floorRisePerSecond
            noiseFloorDB = min(db, noiseFloorDB + rate * Float(bufferSeconds))
        }

        if rawSpeech {
            hangoverRemaining = AppSettings.vadHangover
        } else {
            hangoverRemaining = max(0, hangoverRemaining - bufferSeconds)
        }

        // Map -60...0 dBFS to 0...1 for the waveform.
        let normalized = max(0, min(1, (db + 60) / 60))
        return Reading(normalizedLevel: normalized, isSpeech: rawSpeech || hangoverRemaining > 0)
    }

    func reset() {
        noiseFloorDB = -60
        hangoverRemaining = 0
    }
}
