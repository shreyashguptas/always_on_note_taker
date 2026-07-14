import AVFAudio
import UIKit

/// Owns the AVAudioEngine mic tap and the AVAudioSession lifecycle, including
/// every way iOS can take the microphone away (calls, Siri, route changes,
/// media-server resets). It reports what happened; the coordinator decides
/// how to react.
final class AudioCaptureService {
    enum Event {
        case interruptionBegan
        /// Interruption over and the system says we may resume.
        case interruptionEndedShouldResume
        /// Interruption over but no resume hint — try anyway, cautiously.
        case interruptionEnded
        /// Input route or engine configuration changed; the tap format may be
        /// different and capture must be restarted.
        case configurationChanged
        /// Media services crashed and were reset; rebuild everything.
        case mediaServicesReset
    }

    /// Called on the audio render thread with every captured buffer.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private var engine = AVAudioEngine()
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        registerForNotifications()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var currentInputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    // MARK: - Lifecycle

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord so note playback works without tearing down capture;
        // .mixWithOthers so recording keeps running while other apps play audio.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)

        installTap()
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Tears down and restarts capture (fresh tap, current input format).
    func restart() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try start()
    }

    /// After a media-services reset all audio objects are invalid; recreate
    /// the engine itself before restarting.
    func rebuildAfterMediaServicesReset() throws {
        engine = AVAudioEngine()
        try start()
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.onBuffer?(buffer, time)
        }
    }

    // MARK: - System notifications

    private func registerForNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
            self?.onEvent?(.mediaServicesReset)
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? AVAudioEngine) === self.engine else { return }
            self.isRunning = false
            self.onEvent?(.configurationChanged)
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isRunning = false
            onEvent?(.interruptionBegan)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            onEvent?(options.contains(.shouldResume) ? .interruptionEndedShouldResume : .interruptionEnded)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override, .wakeFromSleep:
            // Input hardware (and thus the tap format) may have changed.
            onEvent?(.configurationChanged)
        default:
            break
        }
    }

    // MARK: - Permission

    static var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
