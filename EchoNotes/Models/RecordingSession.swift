import Foundation
import SwiftData

/// One continuous stretch of captured speech. Each session produces one note.
@Model
final class RecordingSession {
    enum Status: String, Codable {
        case recording      // audio is being captured right now
        case transcribing   // capture ended, transcript still finalizing
        case summarizing    // transcript done, AI note generation running
        case complete
        case failed
    }

    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// Length of the captured audio in seconds.
    var duration: TimeInterval
    /// File name inside the app's Recordings directory. The full URL is derived
    /// at read time because the container path can change between launches.
    var audioFileName: String?
    var statusRaw: String
    /// Denormalized first ~500 characters of the transcript so search doesn't
    /// need to fault in every segment.
    var transcriptPreview: String

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \GeneratedNote.session)
    var note: GeneratedNote?

    init(id: UUID = UUID(), startedAt: Date = .now) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.duration = 0
        self.audioFileName = nil
        self.statusRaw = Status.recording.rawValue
        self.transcriptPreview = ""
        self.segments = []
        self.note = nil
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    /// Resolved location of this session's recording, when one exists.
    var audioFileURL: URL? {
        guard let audioFileName, !audioFileName.isEmpty else { return nil }
        return Persistence.audioURL(forFileName: audioFileName)
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.index < $1.index }
    }

    var fullTranscript: String {
        sortedSegments.map(\.text).joined(separator: " ")
    }

    /// Title to show in lists: the generated one when available, otherwise a
    /// time-based placeholder.
    var displayTitle: String {
        if let title = note?.title, !title.isEmpty { return title }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var isProcessing: Bool {
        switch status {
        case .recording, .transcribing, .summarizing: return true
        case .complete, .failed: return false
        }
    }
}
