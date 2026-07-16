import Foundation
import SwiftData

/// One continuous stretch of captured speech. Each session produces one note.
@Model
final class RecordingSession {
    enum Status: String, Codable {
        case recording      // audio is being captured right now
        /// Legacy (pre-Whisper live transcription); kept so rows stored by
        /// older builds still decode and recover. New sessions never enter it.
        case transcribing
        case enriching      // multilingual + speaker transcription of the audio file
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
    /// TranscriptEnrichmentService.FailureReason raw value when the last
    /// pass failed — shown next to Retry so the user knows what to fix.
    var enrichmentFailureReasonRaw: String?

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

    /// User-facing explanation of the last transcription failure, if any.
    var enrichmentFailureMessage: String? {
        enrichmentFailureReasonRaw
            .flatMap(TranscriptEnrichmentService.FailureReason.init(rawValue:))?
            .userMessage
    }

    /// Resolved location of this session's recording, when one exists.
    var audioFileURL: URL? {
        guard let audioFileName, !audioFileName.isEmpty else { return nil }
        return Persistence.audioURL(forFileName: audioFileName)
    }

    /// The one home for the fetch-by-id descriptor.
    static func fetch(id: UUID, in context: ModelContext) -> RecordingSession? {
        var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.index < $1.index }
    }

    var fullTranscript: String {
        sortedSegments.map(\.text).joined(separator: " ")
    }

    static func dominantLanguageCode(of segments: [TranscriptSegment]) -> String? {
        TranscriptFormatting.dominantLanguage(of: segments.lazy.map(\.languageCode))
    }

    /// Canonical "Speaker n" numbering — see TranscriptFormatting, which
    /// both the transcript UI and the summarizer input share.
    static func speakerNumbersByFirstAppearance(of segments: [TranscriptSegment]) -> [String: Int] {
        TranscriptFormatting.speakerNumbers(forKeysInOrder: segments.lazy.map(\.speakerKey))
    }

    /// Transcript with one line per segment, prefixed with the speaker's name
    /// when known ("Priya: book the flights") and a language marker when a
    /// segment strays from the recording's dominant language ("[hi] …") —
    /// the form the summarizer consumes so action items can name people.
    /// Falls back to the plain transcript when nothing is attributed.
    var attributedTranscript: String {
        TranscriptFormatting.attributedText(sortedSegments.map {
            TranscriptFormatting.Line(
                text: $0.text,
                languageCode: $0.languageCode,
                speakerKey: $0.speakerKey,
                speakerName: $0.speaker?.name
            )
        })
    }

    // MARK: - Transcript preview (denormalized for search/list rows)

    /// Single home for the preview-building policy: the first ~500
    /// characters of the transcript, space-joined.
    func rebuildTranscriptPreview(from texts: [String]) {
        var preview = ""
        for text in texts {
            if preview.count >= AppSettings.transcriptPreviewLength { break }
            preview = preview.isEmpty ? text : preview + " " + text
        }
        transcriptPreview = String(preview.prefix(AppSettings.transcriptPreviewLength))
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
