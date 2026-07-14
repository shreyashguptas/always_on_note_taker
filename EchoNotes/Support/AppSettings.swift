import Foundation

/// Tunables for the always-on pipeline. Kept in one place so behavior is easy
/// to reason about and adjust.
enum AppSettings {
    /// Continuous silence that ends the current session (a new one starts
    /// automatically at the next detected speech).
    static let sessionSilenceGap: TimeInterval = 90

    /// Hard cap per session; on hitting it the session is finalized and a new
    /// one begins immediately so recording never stops.
    static let maxSessionDuration: TimeInterval = 2 * 60 * 60

    /// Sessions with less speech than this are discarded (stray noises,
    /// accidental toggles).
    static let minimumSessionDuration: TimeInterval = 5

    /// Audio kept in memory while waiting for speech, prepended to the session
    /// so the first words aren't clipped.
    static let preRollDuration: TimeInterval = 5

    /// Speech must exceed the adaptive noise floor by this many dB to count as
    /// voice activity.
    static let vadSpeechMarginDB: Float = 9

    /// Absolute floor: anything quieter than this is never speech.
    static let vadAbsoluteFloorDB: Float = -55

    /// After speech is detected, activity is held for this long so natural
    /// mid-sentence pauses don't read as silence.
    static let vadHangover: TimeInterval = 2

    /// Transcript chunk size (in characters) fed to one Foundation Models
    /// request. Conservative to stay well inside the ~4K-token context.
    static let summarizationChunkCharacters = 9_000
}
