import Foundation
import Testing
@testable import EchoNotes

/// TranscriptFormatting is the single home of summarizer-facing transcript
/// labeling — these tests pin the contract that named and unnamed voices
/// share one numbering, and that the two producers (model path and
/// enrichment-finish path) can't disagree.
struct TranscriptFormattingTests {
    private func line(
        _ text: String,
        language: String? = nil,
        key: String? = nil,
        name: String? = nil
    ) -> TranscriptFormatting.Line {
        .init(text: text, languageCode: language, speakerKey: key, speakerName: name)
    }

    @Test func plainLinesCollapseToSpaceJoinedTranscript() {
        let text = TranscriptFormatting.attributedText([line("Hello."), line("World.")])
        #expect(text == "Hello. World.")
    }

    @Test func namedSpeakersKeepTheirClusterNumberClaimed() {
        // S1 is named; the unknown S2 must still be "Speaker 2" — the same
        // label the transcript UI shows — not renumbered to "Speaker 1".
        let text = TranscriptFormatting.attributedText([
            line("Book the flights.", key: "S1", name: "Priya"),
            line("I can do that.", key: "S2"),
        ])
        #expect(text == "Priya: Book the flights.\nSpeaker 2: I can do that.")
    }

    @Test func languageMarkersOnlyOnNonDominantLines() {
        let text = TranscriptFormatting.attributedText([
            line("First point.", language: "en"),
            line("दूसरा मुद्दा।", language: "hi"),
            line("Third point.", language: "en"),
        ])
        #expect(text == "First point.\n[hi] दूसरा मुद्दा।\nThird point.")
    }

    @Test func dominantLanguageIsTheMostFrequent() {
        #expect(TranscriptFormatting.dominantLanguage(of: ["hi", "en", "hi", nil]) == "hi")
        #expect(TranscriptFormatting.dominantLanguage(of: [nil, nil]) == nil)
    }

    @Test func speakerNumbersFollowFirstAppearance() {
        let numbers = TranscriptFormatting.speakerNumbers(forKeysInOrder: ["S9", nil, "S2", "S9", "S5"])
        #expect(numbers == ["S9": 1, "S2": 2, "S5": 3])
    }
}
