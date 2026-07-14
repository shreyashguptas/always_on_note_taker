import Foundation
import SwiftData

/// A finalized stretch of transcribed speech with its position in the
/// session's audio file, so transcript lines can seek playback.
@Model
final class TranscriptSegment {
    var index: Int
    var text: String
    /// Seconds from the start of the session's audio file.
    var startTime: TimeInterval
    var endTime: TimeInterval
    var session: RecordingSession?

    init(index: Int, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.index = index
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
