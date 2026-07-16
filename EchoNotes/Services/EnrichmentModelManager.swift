import FluidAudio
import Foundation
import Observation
import UIKit
import WhisperKit

/// Downloads and tracks the two model sets that transcription needs: the
/// multilingual Whisper model (WhisperKit, Core ML) and the speaker
/// diarization models (FluidAudio, Core ML). Both are one-time downloads,
/// after which everything runs on-device.
///
/// Downloads run one at a time — the small speaker models first, then the
/// large Whisper model — each with real percentage progress. The Whisper
/// download goes through `WhisperModelDownloader` (a background URLSession),
/// so it keeps going when the user leaves the app, and a retry resumes from
/// the files already downloaded. After the files land, the model is loaded
/// once to verify the install end-to-end (this also caches WhisperKit's
/// tokenizer while the network is still around) before anything is marked
/// installed.
///
/// The models' absence never blocks recording: sessions captured before the
/// download are kept audio-only and transcribed automatically afterwards.
@MainActor
@Observable
final class EnrichmentModelManager {
    enum ModelState: Equatable {
        case notDownloaded
        /// Queued behind the other model's download (they run sequentially).
        case waiting
        /// Fraction completed, when known.
        case downloading(Double?)
        /// Files are down; the model is being loaded once to prove the
        /// install works (and to warm the Core ML + tokenizer caches).
        case verifying
        case ready
        case failed(String)
    }

    /// The one Whisper model this app uses: Argmax's compressed large-v3
    /// turbo — the most accurate multilingual option that runs well on
    /// iPhone (Hindi, Spanish, German, French, Italian, mixed-language talk).
    static let whisperModelName = "large-v3-v20240930_626MB"

    private(set) var whisperState: ModelState = .notDownloaded
    private(set) var diarizerState: ModelState = .notDownloaded

    /// Where the downloaded Whisper model lives, once installed.
    private(set) var whisperModelFolder: URL?

    /// Both model sets installed — enrichment can run.
    var isReady: Bool { whisperState == .ready && diarizerState == .ready }

    /// Fired (on the main actor) whenever `isReady` flips to true, so the
    /// coordinator can sweep recordings that were parked waiting for models.
    var onBecameReady: (() -> Void)?

    var isDownloading: Bool {
        isBusy(whisperState) || isBusy(diarizerState)
    }

    private func isBusy(_ state: ModelState) -> Bool {
        switch state {
        case .waiting, .downloading, .verifying: true
        case .notDownloaded, .ready, .failed: false
        }
    }

    private static let diarizerInstalledKey = "enrichment.diarizerInstalled"
    /// Set only after a downloaded Whisper install passed the verify-load.
    private static let whisperInstalledKey = "enrichment.whisperInstalled"
    /// Pre-1.1 installs stored the folder WhisperKit.download produced,
    /// relative to the download base; still honored so upgraders don't
    /// re-download 626 MB.
    private static let legacyWhisperFolderKey = "enrichment.whisperFolder.largeTurbo"

    private let downloader = WhisperModelDownloader.shared

    init() {
        downloader.onProgress = { [weak self] fraction in
            guard let self else { return }
            // A straggler progress hop must not overwrite a terminal state.
            if case .downloading = self.whisperState {
                self.whisperState = .downloading(fraction)
            }
        }
        downloader.onFinished = { [weak self] folder in
            Task { @MainActor in
                await self?.verifyWhisperInstall(folder)
            }
        }
        downloader.onFailed = { [weak self] message in
            self?.whisperState = .failed(message)
        }

        refreshInstalledState()
        resumeInterruptedDownloads()
    }

    /// Cheap re-check of what's on disk; safe to call at every enable.
    func refreshInstalledState() {
        guard !isDownloading else { return }
        whisperModelFolder = installedWhisperFolder()
        if case .failed = whisperState, whisperModelFolder == nil {
            // Keep the failure message visible until a retry or an install.
        } else {
            whisperState = whisperModelFolder == nil ? .notDownloaded : .ready
        }
        if case .failed = diarizerState {
            // Same: don't silently clear an error the user hasn't acted on.
        } else {
            diarizerState = UserDefaults.standard.bool(forKey: Self.diarizerInstalledKey)
                ? .ready
                : .notDownloaded
        }
    }

    /// Whether any Whisper model files are on disk — "Remove downloaded
    /// models" is offered based on this, so a half-finished download's
    /// partial files can always be cleaned up.
    var anyModelFilesPresent: Bool {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: WhisperModelDownloader.downloadBase.path
        )
        return !(contents ?? []).isEmpty
            || UserDefaults.standard.bool(forKey: Self.diarizerInstalledKey)
    }

    /// An enrichment job failed to load its models: whatever install state
    /// we believed is stale (OS purged a cache, files vanished). Reset both
    /// install flags' derived state so Settings shows the re-download
    /// instead of a permanent "Installed" lie.
    func noteModelLoadFailure() {
        guard !isDownloading else { return }
        UserDefaults.standard.set(false, forKey: Self.diarizerInstalledKey)
        refreshInstalledState()
    }

    /// Kicks off whatever downloads are missing, one model set at a time.
    /// Also the Retry action: completed Whisper files are kept, so a retry
    /// resumes rather than starting over.
    func startDownloads() {
        guard !isDownloading else { return }
        Task { await ensureModelsInstalled() }
    }

    /// Called at init and on every foreground: if a Whisper download was
    /// interrupted (app killed mid-download, transient failure while
    /// backgrounded), quietly pick it back up.
    func resumeInterruptedDownloads() {
        guard !isDownloading, whisperState != .ready else { return }
        if downloader.hasPartialDownload {
            Task { await ensureModelsInstalled() }
        }
    }

    /// Downloads whichever of the two model sets is missing — speaker models
    /// first (small, quick win), then the big Whisper model, which continues
    /// in the background if the user leaves. Idempotent and cheap when both
    /// are installed.
    func ensureModelsInstalled() async {
        guard !isDownloading else { return }
        let needsWhisper = installedWhisperFolder() == nil
        if needsWhisper { whisperState = .waiting }

        await installDiarizerIfNeeded()

        if needsWhisper {
            whisperState = .downloading(downloader.currentProgress)
            downloader.startOrResume()
        } else if whisperState != .ready {
            whisperModelFolder = installedWhisperFolder()
            whisperState = .ready
        }
    }

    /// Removes the downloaded Whisper model files (and any half-finished
    /// download) and forgets the diarizer install. (FluidAudio manages its
    /// own model cache; marking it not-installed makes the next download
    /// re-fetch or reuse that cache.)
    func deleteDownloadedModels() {
        guard !isDownloading else { return }
        downloader.reset()
        try? FileManager.default.removeItem(at: WhisperModelDownloader.downloadBase)
        UserDefaults.standard.set(false, forKey: Self.whisperInstalledKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyWhisperFolderKey)
        UserDefaults.standard.set(false, forKey: Self.diarizerInstalledKey)
        whisperState = .notDownloaded
        diarizerState = .notDownloaded
        refreshInstalledState()
    }

    // MARK: - Diarizer (FluidAudio)

    private func installDiarizerIfNeeded() async {
        if UserDefaults.standard.bool(forKey: Self.diarizerInstalledKey) {
            diarizerState = .ready
            return
        }
        diarizerState = .downloading(0)

        // The models are small (~80 MB); a background-task assertion buys
        // enough time to finish even if the user backgrounds the app.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "SpeakerModelDownload")
        defer {
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        }

        for attempt in 1...2 {
            do {
                _ = try await DiarizerModels.downloadIfNeeded(progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.diarizerState else { return }
                        self.diarizerState = .downloading(fraction)
                    }
                })
                UserDefaults.standard.set(true, forKey: Self.diarizerInstalledKey)
                diarizerState = .ready
                noteReadinessChange()
                return
            } catch {
                if attempt == 1 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        diarizerState = .failed("Couldn't download the speaker models. Check your connection and tap Retry.")
    }

    // MARK: - Whisper install verification

    /// All files are on disk with the right sizes; now prove the install by
    /// loading the model once. This catches a corrupt download before it can
    /// fail every future transcription, warms the Core ML compile cache, and
    /// fetches WhisperKit's tokenizer into its cache while the network is
    /// still available — so Airplane Mode works from the very first session.
    private func verifyWhisperInstall(_ folder: URL) async {
        whisperState = .verifying
        do {
            let config = WhisperKitConfig(
                model: Self.whisperModelName,
                modelFolder: folder.path,
                load: true,
                download: false
            )
            _ = try await WhisperKit(config) // released immediately after the check
            UserDefaults.standard.set(true, forKey: Self.whisperInstalledKey)
            whisperModelFolder = folder
            whisperState = .ready
            noteReadinessChange()
        } catch {
            // Files are kept: sizes were verified per-file, so the likeliest
            // causes are transient (tokenizer fetch, memory pressure). Retry
            // re-checks the files (instant) and verifies again.
            whisperState = .failed("The model downloaded but couldn't be loaded. Tap Retry to try again.")
        }
    }

    private func noteReadinessChange() {
        if isReady { onBecameReady?() }
    }

    // MARK: - Install lookup

    /// The installed Whisper model folder, when a verified install (or a
    /// pre-1.1 legacy install) is still on disk with files inside.
    private func installedWhisperFolder() -> URL? {
        if UserDefaults.standard.bool(forKey: Self.whisperInstalledKey) {
            let folder = downloader.modelFolder
            if folderHasContents(folder) { return folder }
        }
        if let relative = UserDefaults.standard.string(forKey: Self.legacyWhisperFolderKey) {
            let folder = WhisperModelDownloader.downloadBase
                .appending(path: relative, directoryHint: .isDirectory)
            if folderHasContents(folder) { return folder }
        }
        return nil
    }

    private func folderHasContents(_ folder: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return !contents.isEmpty
    }
}
