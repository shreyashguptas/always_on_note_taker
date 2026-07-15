import Foundation
import SwiftData

/// The AI-organized note produced from a session's transcript.
@Model
final class GeneratedNote {
    var title: String
    /// Two-to-three sentence overview of the conversation.
    var overview: String
    var keyPoints: [String]
    var actionItems: [String]
    var tags: [String]
    var generatedAt: Date
    /// Which engine produced this note; lets the UI offer "retry with Apple
    /// Intelligence" when the fallback was used.
    var generatorUsed: String
    var session: RecordingSession?

    static let foundationModelsGenerator = "apple-intelligence"
    static let fallbackGenerator = "on-device-extractive"

    init(
        title: String,
        overview: String,
        keyPoints: [String],
        actionItems: [String],
        tags: [String],
        generatedAt: Date = .now,
        generatorUsed: String
    ) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.actionItems = actionItems
        self.tags = tags
        self.generatedAt = generatedAt
        self.generatorUsed = generatorUsed
    }

    var usedAppleIntelligence: Bool { generatorUsed == Self.foundationModelsGenerator }
}
