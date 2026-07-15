import Foundation
import Testing
@testable import EchoNotes

/// The speaker-numbering and language helpers are shared between the
/// transcript UI and the summarizer input — these tests pin the contract
/// that both sides label the same voice the same way.
struct TranscriptLabelingTests {
    private func segment(_ index: Int, language: String? = nil, speakerKey: String? = nil) -> TranscriptSegment {
        TranscriptSegment(
            index: index,
            text: "line \(index)",
            startTime: Double(index),
            endTime: Double(index) + 1,
            languageCode: language,
            speakerKey: speakerKey
        )
    }

    @Test func speakerNumbersFollowFirstAppearance() {
        let segments = [
            segment(0, speakerKey: "S2"),
            segment(1, speakerKey: "S7"),
            segment(2, speakerKey: "S2"),
            segment(3, speakerKey: "S1"),
        ]
        let numbers = RecordingSession.speakerNumbersByFirstAppearance(of: segments)
        #expect(numbers == ["S2": 1, "S7": 2, "S1": 3])
    }

    @Test func speakerNumbersIncludeEveryCluster() {
        // Named speakers must still claim their number — the UI and the
        // summarizer both consume this map, and skipping named clusters
        // would renumber the unknown ones inconsistently.
        let segments = [
            segment(0, speakerKey: "identified"),
            segment(1, speakerKey: "unknown"),
        ]
        let numbers = RecordingSession.speakerNumbersByFirstAppearance(of: segments)
        #expect(numbers["identified"] == 1)
        #expect(numbers["unknown"] == 2)
    }

    @Test func dominantLanguageIsTheMostFrequent() {
        let segments = [
            segment(0, language: "hi"),
            segment(1, language: "en"),
            segment(2, language: "hi"),
            segment(3),
        ]
        #expect(RecordingSession.dominantLanguageCode(of: segments) == "hi")
    }

    @Test func dominantLanguageIsNilWithoutAnyCodes() {
        #expect(RecordingSession.dominantLanguageCode(of: [segment(0), segment(1)]) == nil)
    }

    @Test func reviewItemOccurrenceLinking() {
        let sessionA = UUID()
        let sessionB = UUID()
        let item = SpeakerReviewItem(
            sessionID: sessionA,
            speakerKey: "S1",
            snippetStart: 0,
            snippetEnd: 10,
            embedding: [1, 0]
        )
        item.linkOccurrence(sessionID: sessionB, speakerKey: "S3")

        let occurrences = item.allOccurrences
        #expect(occurrences.count == 2)
        #expect(occurrences[0].sessionID == sessionA)
        #expect(occurrences[0].speakerKey == "S1")
        #expect(occurrences[1].sessionID == sessionB)
        #expect(occurrences[1].speakerKey == "S3")
        #expect(item.occurrenceCount == 2)
    }
}
