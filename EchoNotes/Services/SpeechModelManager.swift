import Foundation
import Observation
import Speech

/// Makes sure the on-device speech model for the user's locale is installed
/// before the pipeline starts. Models are system assets downloaded once via
/// AssetInventory and shared across apps.
@MainActor
@Observable
final class SpeechModelManager {
    enum ModelState: Equatable {
        case unknown
        case checking
        /// Fraction completed, when known.
        case downloading(Double?)
        case ready
        case unsupportedLocale
        case failed(String)
    }

    private(set) var state: ModelState = .unknown
    /// The locale transcription will actually run in (falls back to en-US if
    /// the user's locale isn't supported).
    private(set) var locale: Locale = .current

    var isReady: Bool { state == .ready }

    /// Idempotent: cheap when the model is already installed.
    func ensureModelInstalled() async {
        if state == .ready { return }
        state = .checking

        let supported = await SpeechTranscriber.supportedLocales
        guard let target = Self.pickLocale(from: supported) else {
            state = .unsupportedLocale
            return
        }
        locale = target

        let transcriber = SpeechTranscriber(
            locale: target,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .downloading(nil)
                let progress = request.progress
                let poller = Task { [weak self] in
                    while !Task.isCancelled {
                        await MainActor.run { self?.state = .downloading(progress.fractionCompleted) }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                defer { poller.cancel() }
                try await request.downloadAndInstall()
            }
            state = .ready
        } catch {
            state = .failed("Couldn't download the speech model. Check your connection and try again.")
        }
    }

    /// Prefer the user's exact locale, then a same-language variant, then
    /// English (US) as the final fallback.
    private static func pickLocale(from supported: [Locale]) -> Locale? {
        let current = Locale.current
        if let exact = supported.first(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) {
            return exact
        }
        if let language = current.language.languageCode,
           let sameLanguage = supported.first(where: { $0.language.languageCode == language }) {
            return sameLanguage
        }
        return supported.first(where: { $0.identifier(.bcp47) == "en-US" }) ?? supported.first
    }
}
