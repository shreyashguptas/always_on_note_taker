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

        let standup = RecordingSession(startedAt: calendar.date(byAdding: .hour, value: -2, to: .now)!)
        standup.status = .complete
        standup.duration = 14 * 60 + 32
        standup.endedAt = standup.startedAt.addingTimeInterval(standup.duration)
        standup.transcriptPreview = "Okay so quick update from my side, the beta build went out yesterday evening…"
        standup.segments = [
            TranscriptSegment(index: 0, text: "Okay so quick update from my side, the beta build went out yesterday evening.", startTime: 0.4, endTime: 5.8),
            TranscriptSegment(index: 1, text: "Crash-free rate is at ninety nine point six, which is better than the last release.", startTime: 6.1, endTime: 11.9),
            TranscriptSegment(index: 2, text: "Maya, can you take the onboarding copy review before Thursday?", startTime: 12.4, endTime: 16.0),
            TranscriptSegment(index: 3, text: "Sure, I'll have edits back tomorrow afternoon.", startTime: 16.2, endTime: 18.9),
        ]
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
        try? context.save()
    }
}
