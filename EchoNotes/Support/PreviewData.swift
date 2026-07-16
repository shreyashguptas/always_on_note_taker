import Foundation
import SwiftData

/// In-memory sample content so SwiftUI previews and simulator demos have
/// something to show before any real recording exists.
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let container = Persistence.makeContainer(inMemory: true)
        seed(into: container.mainContext)
        return container
    }()

    static func seed(into context: ModelContext) {
        let calendar = Calendar.current

        // Two known voices so the People screen and speaker-tagged transcripts
        // have something to show. (Preview embeddings are toy 4-dim vectors;
        // real ones are 256-dim.)
        let me = Speaker(name: "Me", isMe: true, embedding: [1, 0, 0, 0], colorIndex: 0)
        let maya = Speaker(name: "Maya", embedding: [0, 1, 0, 0], colorIndex: 1)
        context.insert(me)
        context.insert(maya)

        let standup = RecordingSession(startedAt: calendar.date(byAdding: .hour, value: -2, to: .now)!)
        standup.status = .complete
        standup.enrichmentState = .done
        standup.duration = 14 * 60 + 32
        standup.endedAt = standup.startedAt.addingTimeInterval(standup.duration)
        standup.transcriptPreview = "Okay so quick update from my side, the beta build went out yesterday evening…"
        let standupSegments = [
            TranscriptSegment(index: 0, text: "Okay so quick update from my side, the beta build went out yesterday evening.", startTime: 0.4, endTime: 5.8, languageCode: "en", speakerKey: "S1"),
            TranscriptSegment(index: 1, text: "Crash-free rate is at ninety nine point six, which is better than the last release.", startTime: 6.1, endTime: 11.9, languageCode: "en", speakerKey: "S1"),
            TranscriptSegment(index: 2, text: "Maya, can you take the onboarding copy review before Thursday?", startTime: 12.4, endTime: 16.0, languageCode: "en", speakerKey: "S1"),
            TranscriptSegment(index: 3, text: "हाँ, मैं कल दोपहर तक बदलाव भेज दूँगी।", startTime: 16.2, endTime: 18.9, languageCode: "hi", speakerKey: "S2"),
        ]
        for segment in standupSegments.dropLast() { segment.speaker = me }
        standupSegments.last?.speaker = maya
        standup.segments = standupSegments
        standup.note = GeneratedNote(
            title: "Team standup — beta release check-in",
            overview: "The team reviewed the beta rollout that shipped yesterday, with a 99.6% crash-free rate. Onboarding copy review was assigned ahead of Thursday's deadline.",
            keyPoints: [
                "Beta build shipped yesterday evening",
                "Crash-free rate improved to 99.6%",
                "Onboarding copy needs review before Thursday",
            ],
            actionItems: [
                "Maya to return onboarding copy edits tomorrow afternoon",
            ],
            tags: ["standup", "beta", "release"],
            generatorUsed: GeneratedNote.foundationModelsGenerator
        )

        let groceries = RecordingSession(startedAt: calendar.date(byAdding: .day, value: -1, to: .now)!)
        groceries.status = .complete
        groceries.duration = 42
        groceries.endedAt = groceries.startedAt.addingTimeInterval(groceries.duration)
        groceries.transcriptPreview = "Remind me to grab olive oil, coffee beans and something for Saturday dinner…"
        groceries.segments = [
            TranscriptSegment(index: 0, text: "Remind me to grab olive oil, coffee beans and something for Saturday dinner.", startTime: 0.2, endTime: 5.4),
            TranscriptSegment(index: 1, text: "Maybe salmon if it looks good, otherwise the mushroom pasta thing again.", startTime: 5.9, endTime: 10.8),
        ]
        groceries.note = GeneratedNote(
            title: "Grocery reminders for the week",
            overview: "A quick self-reminder covering pantry restocking and options for Saturday dinner.",
            keyPoints: ["Olive oil and coffee beans needed", "Saturday dinner: salmon or mushroom pasta"],
            actionItems: ["Buy olive oil, coffee beans", "Pick salmon or pasta ingredients for Saturday"],
            tags: ["personal", "shopping"],
            generatorUsed: GeneratedNote.fallbackGenerator
        )

        let processing = RecordingSession(startedAt: calendar.date(byAdding: .minute, value: -3, to: .now)!)
        processing.status = .summarizing
        processing.duration = 8 * 60
        processing.endedAt = .now
        processing.transcriptPreview = "So for the kitchen we're thinking about moving the island…"
        processing.segments = [
            TranscriptSegment(index: 0, text: "So for the kitchen we're thinking about moving the island toward the window.", startTime: 0.5, endTime: 4.9),
        ]

        for session in [standup, groceries, processing] {
            context.insert(session)
        }

        // One unknown voice awaiting review, so the People screen shows a card.
        let review = SpeakerReviewItem(
            sessionID: standup.id,
            speakerKey: "S3",
            snippetStart: 12.0,
            snippetEnd: 22.0,
            embedding: [0.2, 0.9, 0.1, 0],
            suggestedSpeakerID: maya.id
        )
        review.occurrenceCount = 2
        context.insert(review)

        try? context.save()
    }
}
