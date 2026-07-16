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

    /// Denormalized transcript preview stored on the session for cheap search.
    static let transcriptPreviewLength = 500

    /// Bars in the live waveform (also the size of the rolling levels buffer).
    static let waveformBarCount = 60

    // MARK: - Post-session enrichment (multilingual transcription + speakers)

    /// Audio processed per enrichment window. Both models take raw Float32
    /// samples, so a whole 2 h file can't be decoded at once (~460 MB); one
    /// window is ~38 MB at 16 kHz mono.
    static let enrichmentWindowSeconds: TimeInterval = 600

    /// Sample rate both enrichment models expect.
    static let enrichmentSampleRate: Double = 16_000

    /// Whisper transcription segments whose no-speech probability exceeds
    /// this are dropped — Whisper hallucinates fluent text on silence/noise.
    static let whisperNoSpeechCutoff: Float = 0.8

    // MARK: - Speaker identification
    //
    // The similarity thresholds are starting points, not spec: published
    // defaults for the embedding model are tuned for clustering within one
    // file, while we match across sessions, rooms, and mic distances. Tune
    // against real family audio on device before trusting them.

    /// Cosine similarity at or above which a voice is auto-tagged as a known
    /// speaker (subject to the margin rule below).
    static let speakerMatchThreshold: Float = 0.65

    /// Best match must beat the second-best by this much to auto-tag —
    /// otherwise similar voices in one family would silently cross-tag.
    /// Borderline cases go to the review queue instead.
    static let speakerMatchMargin: Float = 0.10

    /// Similarity at or above which a review card suggests a known speaker
    /// ("Is this Priya?") without auto-tagging.
    static let speakerSuggestThreshold: Float = 0.50

    /// Voices with less net speech than this in a session are ignored for
    /// identification (TV in the background, passersby).
    static let speakerMinimumSpeech: TimeInterval = 8

    /// Length of the audio snippet a review card plays for an unknown voice.
    static let speakerSnippetDuration: TimeInterval = 10

    /// Observations folded into a speaker's running-mean embedding before it
    /// stops updating — keeps the identity plastic early, stable later.
    static let speakerEmbeddingUpdateCap = 50
}
