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

        if db < noiseFloorDB {
            noiseFloorDB = db
        } else {
            noiseFloorDB = min(db, noiseFloorDB + floorRisePerSecond * Float(bufferSeconds))
        }
        noiseFloorDB = max(noiseFloorDB, -80)

        let threshold = max(noiseFloorDB + AppSettings.vadSpeechMarginDB, AppSettings.vadAbsoluteFloorDB)
        let rawSpeech = db > threshold

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
