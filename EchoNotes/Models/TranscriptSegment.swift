import Foundation
import SwiftData

/// A finalized stretch of transcribed speech with its position in the
/// session's audio file, so transcript lines can seek playback.
///
/// Segments from the live transcriber carry only text and times; post-session
/// enrichment replaces them with segments that also know their language and
/// who spoke them. All three additions are optional so pre-enrichment (and
/// pre-upgrade) segments keep working untouched.
@Model
final class TranscriptSegment {
    var index: Int
    var text: String
    /// Seconds from the start of the session's audio file.
    var startTime: TimeInterval
    var endTime: TimeInterval
    /// ISO 639-1 code of the detected language ("hi", "de"…), from Whisper.
    var languageCode: String?
    /// Session-local diarization cluster ("S1"…). Kept even after a speaker
    /// is assigned so later assignments can retro-tag by cluster.
    var speakerKey: String?
    /// The identified person, once matched or manually assigned.
    /// (Inverse declared on Speaker.segments.)
    var speaker: Speaker?
    var session: RecordingSession?

    init(
        index: Int,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        languageCode: String? = nil,
        speakerKey: String? = nil
    ) {
        self.index = index
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.languageCode = languageCode
        self.speakerKey = speakerKey
    }
}
