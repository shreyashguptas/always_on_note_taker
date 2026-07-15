import AVFAudio
import Foundation
import Observation

/// Plays back a session's recording with scrubbing, seeking, and adjustable
/// speed. One instance per note-detail screen.
@MainActor
@Observable
final class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0

    var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// When set, playback auto-pauses at this time (review-card snippets).
    private var stopAt: TimeInterval?

    deinit {
        // Normally .onDisappear stops playback first; this catches teardown
        // paths that skip it so the repeating timer can't outlive the service.
        ticker?.invalidate()
    }

    func load(url: URL) {
        guard player?.url != url else { return }
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            isLoaded = false
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isLoaded = true
        } catch {
            isLoaded = false
        }
    }

    func playPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        // If the always-on engine isn't holding the session, make sure one is
        // active for playback. (While capture runs, .playAndRecord already is.)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        stopAt = nil
        player.currentTime = max(0, min(time, duration))
        currentTime = player.currentTime
    }

    /// Seek then play — used by transcript timestamp taps.
    func playFrom(_ time: TimeInterval) {
        seek(to: time)
        if !isPlaying { play() }
    }

    /// Plays just `start...end`, pausing automatically at the end — how
    /// review cards audition a voice without clipping out snippet files.
    func playRange(from start: TimeInterval, to end: TimeInterval) {
        seek(to: start)
        stopAt = max(start, end)
        if !isPlaying { play() }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        isLoaded = false
        duration = 0
        currentTime = 0
        stopAt = nil
        stopTicker()
    }

    // MARK: - Progress ticker

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if let stopAt = self.stopAt, player.currentTime >= stopAt {
                    self.stopAt = nil
                    self.pause()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            // Rewind the player itself, not just the published time, so the
            // next play() starts from the beginning instead of the end.
            self.player?.currentTime = 0
            self.currentTime = 0
            self.stopTicker()
        }
    }
}
