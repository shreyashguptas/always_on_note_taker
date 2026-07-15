import Foundation
import SwiftData

/// An unrecognized voice waiting for the user to name it in the People tab.
/// Created when enrichment finds a speaker whose voiceprint doesn't
/// confidently match anyone known; resolved by assigning a person (existing
/// or new) or dismissing it.
@Model
final class SpeakerReviewItem {
    enum Status: String, Codable {
        case pending
        case assigned
        case dismissed
    }

    @Attribute(.unique) var id: UUID
    /// Deliberately a plain UUID, not a relationship: deleting a session
    /// cascades through segments/notes, and a pending voice must not vanish
    /// with it silently — the coordinator purges review items explicitly.
    var sessionID: UUID
    /// Session-local diarization cluster ("S1"…) so assignment can
    /// retroactively tag that session's segments.
    var speakerKey: String
    /// Clearest ~10 s of this voice, as a position in the session's audio
    /// file — playback reads the .m4a directly, no snippet files.
    var snippetStart: TimeInterval
    var snippetEnd: TimeInterval
    /// 256 × Float32 voiceprint of the cluster (see VoiceEmbedding).
    var embeddingData: Data
    /// How many sessions this same unknown voice has shown up in — review
    /// cards for recurring voices matter more.
    var occurrenceCount: Int
    /// Borderline match: "Is this X?" without auto-tagging.
    var suggestedSpeakerID: UUID?
    var createdAt: Date
    var statusRaw: String

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        speakerKey: String,
        snippetStart: TimeInterval,
        snippetEnd: TimeInterval,
        embedding: [Float],
        suggestedSpeakerID: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.speakerKey = speakerKey
        self.snippetStart = snippetStart
        self.snippetEnd = snippetEnd
        self.embeddingData = VoiceEmbedding.data(from: VoiceEmbedding.normalized(embedding))
        self.occurrenceCount = 1
        self.suggestedSpeakerID = suggestedSpeakerID
        self.createdAt = createdAt
        self.statusRaw = Status.pending.rawValue
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var embedding: [Float] {
        VoiceEmbedding.floats(from: embeddingData)
    }
}
