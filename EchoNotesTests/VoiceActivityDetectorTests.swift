import AVFAudio
import Foundation
import Testing
@testable import EchoNotes

/// The regression these tests pin: the adaptive noise floor must not climb
/// to the level of ongoing speech and cut a long conversation off, but it
/// must still (slowly) absorb a genuine rise in background noise.
struct VoiceActivityDetectorTests {
    private let sampleRate = 16_000.0
    private let bufferSeconds = 0.25

    /// Constant-amplitude buffer at the given dBFS level (RMS-exact).
    private func buffer(atDB db: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(sampleRate * bufferSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let amplitude = pow(10, db / 20)
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = amplitude
        }
        return buffer
    }

    @Test func sustainedSpeechIsNotReclassifiedAsNoise() {
        let vad = VoiceActivityDetector()
        // 60 seconds of dense, dip-free talk at a steady level. Under the
        // old 1.5 dB/s always-on floor rise, the floor reached the speech
        // level after ~17 s and the "conversation" went silent.
        let speech = buffer(atDB: -25)
        for _ in 0..<240 {
            let reading = vad.process(speech)
            #expect(reading.isSpeech)
        }
    }

    @Test func pausesResetTheFloorDuringConversation() {
        let vad = VoiceActivityDetector()
        // Five minutes of talk in 4 s bursts with half-second pauses — the
        // realistic shape of a conversation. Speech must never be lost.
        for _ in 0..<60 {
            for _ in 0..<16 { // 4 s of speech
                #expect(vad.process(buffer(atDB: -25)).isSpeech)
            }
            for _ in 0..<2 { // 0.5 s pause (hangover keeps isSpeech true)
                _ = vad.process(buffer(atDB: -55))
            }
        }
        #expect(vad.process(buffer(atDB: -25)).isSpeech)
    }

    @Test func steadyLoudNoiseIsEventuallyReclassified() {
        let vad = VoiceActivityDetector()
        // An AC unit kicks in at a constant -40 dB: first misread as speech,
        // but the slow during-speech floor rise (0.1 dB/s) must absorb it —
        // otherwise a session near that noise would never end.
        let noise = buffer(atDB: -40)
        var lastReading = vad.process(noise)
        for _ in 0..<720 { // 3 minutes
            lastReading = vad.process(noise)
        }
        #expect(!lastReading.isSpeech)
    }

    @Test func quietRoomThenSpeechTriggersImmediately() {
        let vad = VoiceActivityDetector()
        for _ in 0..<40 {
            #expect(!vad.process(buffer(atDB: -70)).isSpeech)
        }
        #expect(vad.process(buffer(atDB: -30)).isSpeech)
    }
}
