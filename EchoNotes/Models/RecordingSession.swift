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
        Self.dominantLanguageCode(of: segments)
    }

    static func dominantLanguageCode(of segments: [TranscriptSegment]) -> String? {
        var counts: [String: Int] = [:]
        for segment in segments {
            if let code = segment.languageCode {
                counts[code, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// THE canonical "Speaker n" numbering: every diarized cluster gets a
    /// number by first appearance in transcript order, whether or not it was
    /// later resolved to a named person. The transcript UI and the
    /// summarizer input must both use this map — independent numbering
    /// would let a note's "Speaker 2: book flights" point at a different
    /// voice than the transcript's "Speaker 2" header.
    static func speakerNumbersByFirstAppearance(of segments: [TranscriptSegment]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for segment in segments {
            if let key = segment.speakerKey, numbers[key] == nil {
                numbers[key] = numbers.count + 1
            }
        }
        return numbers
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

        let dominant = Self.dominantLanguageCode(of: segments)
        let speakerNumbers = Self.speakerNumbersByFirstAppearance(of: segments)
        return segments.map { segment in
            var line = ""
            if let code = segment.languageCode, code != dominant {
                line += "[\(code)] "
            }
            if let name = segment.speaker?.name, !name.isEmpty {
                line += "\(name): "
            } else if let key = segment.speakerKey, let number = speakerNumbers[key] {
                line += "Speaker \(number): "
            }
            return line + segment.text
        }
        .joined(separator: "\n")
    }

    // MARK: - Transcript preview (denormalized for search/list rows)

    /// Single home for the preview-building policy, shared by the live
    /// transcription path (incremental) and the enrichment path (rebuild).
    func appendToTranscriptPreview(_ text: String) {
        guard transcriptPreview.count < AppSettings.transcriptPreviewLength else { return }
        let combined = transcriptPreview.isEmpty ? text : transcriptPreview + " " + text
        transcriptPreview = String(combined.prefix(AppSettings.transcriptPreviewLength))
    }

    func rebuildTranscriptPreview(from texts: [String]) {
        transcriptPreview = ""
        for text in texts {
            if transcriptPreview.count >= AppSettings.transcriptPreviewLength { break }
            appendToTranscriptPreview(text)
        }
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
