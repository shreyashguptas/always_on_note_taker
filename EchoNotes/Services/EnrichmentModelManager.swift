import FluidAudio
import Foundation
import Observation
import WhisperKit

/// Downloads and tracks the two model sets that post-session enrichment
/// needs: a multilingual Whisper model (WhisperKit, Core ML) and the speaker
/// diarization models (FluidAudio, Core ML). Both are one-time downloads,
/// after which everything runs on-device — the same deal as the Apple speech
/// model that `SpeechModelManager` installs.
///
/// Unlike the live speech model, these are OPTIONAL: when they're absent the
/// app records and transcribes exactly like v1, and enrichment is skipped.
@MainActor
@Observable
final class EnrichmentModelManager {
    enum ModelState: Equatable {
        case unknown
        case checking
        /// Fraction completed, when known.
        case downloading(Double?)
        case ready
        case notDownloaded
        case failed(String)
    }

    /// Which Whisper model to use. `largeTurbo` is Argmax's compressed
    /// large-v3-turbo — the most accurate multilingual option that runs well
    /// on iPhone. `small` trades accuracy (noticeably on Hindi and mixed-
    /// language speech) for size and speed.
    enum WhisperVariant: String, CaseIterable, Identifiable {
        case largeTurbo
        case small

        var id: String { rawValue }

        /// Model name in the argmaxinc/whisperkit-coreml repository.
        var whisperKitModelName: String {
            switch self {
            case .largeTurbo: "large-v3-v20240930_626MB"
            case .small: "small"
            }
        }

        var displayName: String {
            switch self {
            case .largeTurbo: "Best (Large v3 Turbo)"
            case .small: "Compact (Small)"
            }
        }

        var displayDetail: String {
            switch self {
            case .largeTurbo: "≈626 MB · most accurate for Hindi, Spanish, German, French, Italian and mixed-language talk"
            case .small: "≈250 MB · faster and lighter, less accurate on non-English speech"
            }
        }
    }

    private(set) var whisperState: ModelState = .unknown
    private(set) var diarizerState: ModelState = .unknown

    /// Where the downloaded Whisper model lives, once installed.
    private(set) var whisperModelFolder: URL?

    var selectedVariant: WhisperVariant {
        didSet {
            guard oldValue != selectedVariant else { return }
            UserDefaults.standard.set(selectedVariant.rawValue, forKey: Self.variantKey)
            // A different variant is a different download.
            whisperModelFolder = installedWhisperFolder()
            whisperState = whisperModelFolder == nil ? .notDownloaded : .ready
        }
    }

    /// Both model sets installed — enrichment can run.
    var isReady: Bool { whisperState == .ready && diarizerState == .ready }

    var isDownloading: Bool {
        if case .downloading = whisperState { return true }
        if case .downloading = diarizerState { return true }
        return false
    }

    private static let variantKey = "enrichment.whisperVariant"
    private static let diarizerInstalledKey = "enrichment.diarizerInstalled"
    /// Per-variant relative path (under Application Support) of the folder
    /// WhisperKit.download actually produced — the layout is the library's
    /// business, so remember what it returned instead of guessing.
    private static func whisperFolderKey(_ variant: WhisperVariant) -> String {
        "enrichment.whisperFolder.\(variant.rawValue)"
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.variantKey)
        selectedVariant = raw.flatMap(WhisperVariant.init(rawValue:)) ?? .largeTurbo
        refreshInstalledState()
    }

    /// Cheap re-check of what's on disk; safe to call at every enable.
    func refreshInstalledState() {
        if !isDownloading {
            whisperModelFolder = installedWhisperFolder()
            whisperState = whisperModelFolder == nil ? .notDownloaded : .ready
            diarizerState = UserDefaults.standard.bool(forKey: Self.diarizerInstalledKey)
                ? .ready
                : .notDownloaded
        }
    }

    /// Downloads whichever of the two model sets is missing. Idempotent and
    /// cheap when both are installed.
    func ensureModelsInstalled() async {
        guard !isDownloading else { return }
        await installWhisperIfNeeded()
        await installDiarizerIfNeeded()
    }

    /// Removes the downloaded Whisper model and forgets the diarizer install.
    /// (FluidAudio manages its own model cache; marking it not-installed
    /// makes the next download re-fetch or reuse that cache.)
    func deleteDownloadedModels() {
        guard !isDownloading else { return }
        if let base = Self.whisperDownloadBase {
            try? FileManager.default.removeItem(at: base)
        }
        for variant in WhisperVariant.allCases {
            UserDefaults.standard.removeObject(forKey: Self.whisperFolderKey(variant))
        }
        UserDefaults.standard.set(false, forKey: Self.diarizerInstalledKey)
        refreshInstalledState()
    }

    // MARK: - Whisper

    private func installWhisperIfNeeded() async {
        if let folder = installedWhisperFolder() {
            whisperModelFolder = folder
            whisperState = .ready
            return
        }
        whisperState = .downloading(nil)
        do {
            let folder = try await WhisperKit.download(
                variant: selectedVariant.whisperKitModelName,
                downloadBase: Self.whisperDownloadBase,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.whisperState = .downloading(fraction)
                    }
                }
            )
            // Store the location relative to Application Support: the
            // container's absolute path changes between launches.
            let relative = folder.path.replacingOccurrences(
                of: URL.applicationSupportDirectory.path + "/",
                with: ""
            )
            UserDefaults.standard.set(relative, forKey: Self.whisperFolderKey(selectedVariant))
            whisperModelFolder = folder
            whisperState = .ready
        } catch {
            whisperState = .failed("Couldn't download the multilingual model. Check your connection and try again.")
        }
    }

    /// Fixed download root so installs can be found again (and deleted)
    /// across launches: Application Support/WhisperModels/.
    private static let whisperDownloadBase: URL? = URL.applicationSupportDirectory
        .appending(path: "WhisperModels", directoryHint: .isDirectory)

    /// The folder a previous WhisperKit.download produced for the selected
    /// variant, when it still exists on disk with model files inside.
    private func installedWhisperFolder() -> URL? {
        guard let relative = UserDefaults.standard.string(forKey: Self.whisperFolderKey(selectedVariant)) else {
            return nil
        }
        let folder = URL.applicationSupportDirectory.appending(path: relative, directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.isEmpty ? nil : folder
    }

    // MARK: - Diarizer

    private func installDiarizerIfNeeded() async {
        if UserDefaults.standard.bool(forKey: Self.diarizerInstalledKey) {
            diarizerState = .ready
            return
        }
        // FluidAudio downloads into its own cache and reports no progress;
        // show an indeterminate spinner. The models are small (~80 MB).
        diarizerState = .downloading(nil)
        do {
            _ = try await DiarizerModels.downloadIfNeeded()
            UserDefaults.standard.set(true, forKey: Self.diarizerInstalledKey)
            diarizerState = .ready
        } catch {
            diarizerState = .failed("Couldn't download the speaker recognition models. Check your connection and try again.")
        }
    }
}
