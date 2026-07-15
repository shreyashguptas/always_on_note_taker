import Foundation
import SwiftData

/// One continuous stretch of captured speech. Each session produces one note.
@Model
final class RecordingSession {
    enum Status: String, Codable {
        case recording      // audio is being captured right now
        case transcribing   // capture ended, transcript still finalizing
        case enriching      // multilingual + speaker pass over the audio file
        case summarizing    // transcript done, AI note generation running
        case complete
        case failed
    }

    /// Whether (and how) the post-session multilingual/speaker pass ran.
    /// Distinguishes a preliminary live transcript from an enriched one and
    /// drives the Retry affordance.
    enum EnrichmentState: String {
        case none       // predates the feature, or not applicable
        case pending    // queued or in progress
        case done       // transcript is the enriched one
        case failed     // pass failed; preliminary transcript kept
        case skipped    // models not downloaded when the session ended
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
    /// See EnrichmentState. Defaulted so pre-upgrade rows migrate lightly.
    var enrichmentStateRaw: String = EnrichmentState.none.rawValue

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
        self.enrichmentStateRaw = EnrichmentState.none.rawValue
        self.segments = []
        self.note = nil
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var enrichmentState: EnrichmentState {
        get { EnrichmentState(rawValue: enrichmentStateRaw) ?? EnrichmentState.none }
        set { enrichmentStateRaw = newValue.rawValue }
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

    /// Most common segment language in this recording, when known.
    var dominantLanguageCode: String? {
        let codes = segments.compactMap(\.languageCode)
        guard !codes.isEmpty else { return nil }
        let counts = Dictionary(grouping: codes, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }

    /// Transcript with one line per segment, prefixed with the speaker's name
    /// when known ("Priya: book the flights") and a language marker when a
    /// segment strays from the recording's dominant language ("[hi] …") —
    /// the form the summarizer consumes so action items can name people.
    /// Falls back to the plain transcript when nothing is attributed.
    var attributedTranscript: String {
        let segments = sortedSegments
        let hasAttribution = segments.contains { $0.speaker != nil || $0.speakerKey != nil || $0.languageCode != nil }
        guard hasAttribution else { return fullTranscript }

        let dominant = dominantLanguageCode
        var speakerNumbers: [String: Int] = [:]
        return segments.map { segment in
            var line = ""
            if let code = segment.languageCode, code != dominant {
                line += "[\(code)] "
            }
            if let name = segment.speaker?.name, !name.isEmpty {
                line += "\(name): "
            } else if let key = segment.speakerKey {
                let number = speakerNumbers[key] ?? speakerNumbers.count + 1
                speakerNumbers[key] = number
                line += "Speaker \(number): "
            }
            return line + segment.text
        }
        .joined(separator: "\n")
    }

    /// Title to show in lists: the generated one when available, otherwise a
    /// time-based placeholder.
    var displayTitle: String {
        if let title = note?.title, !title.isEmpty { return title }
        return startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var isProcessing: Bool {
        switch status {
        case .recording, .transcribing, .enriching, .summarizing: return true
        case .complete, .failed: return false
        }
    }
}
