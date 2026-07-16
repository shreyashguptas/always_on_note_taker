import Foundation
import SwiftData

/// A person the app has learned to recognize by voice. The voiceprint is a
/// running mean of embedding observations, updated on confident matches and
/// manual assignments so recognition improves with every session.
@Model
final class Speaker {
    @Attribute(.unique) var id: UUID
    var name: String
    /// The app's owner — review cards offer a one-tap "Me" chip.
    var isMe: Bool
    /// 256 × Float32, L2-normalized running mean (see VoiceEmbedding).
    var embeddingData: Data
    /// Observations folded into the mean so far; capped by
    /// `AppSettings.speakerEmbeddingUpdateCap`.
    var embeddingCount: Int
    var createdAt: Date
    /// Stable palette index for this speaker's dot in transcripts.
    var colorIndex: Int

    @Relationship(deleteRule: .nullify, inverse: \TranscriptSegment.speaker)
    var segments: [TranscriptSegment]

    init(
        id: UUID = UUID(),
        name: String,
        isMe: Bool = false,
        embedding: [Float],
        colorIndex: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.embeddingData = VoiceEmbedding.data(from: VoiceEmbedding.normalized(embedding))
        self.embeddingCount = 1
        self.createdAt = createdAt
        self.colorIndex = colorIndex
        self.segments = []
    }

    var embedding: [Float] {
        get { VoiceEmbedding.floats(from: embeddingData) }
        set { embeddingData = VoiceEmbedding.data(from: newValue) }
    }

    /// Distinct recordings this speaker appears in.
    var sessionCount: Int {
        Set(segments.compactMap { $0.session?.id }).count
    }
}
