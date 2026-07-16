import Foundation
import Testing
@testable import EchoNotes

struct SpeakerAttributionTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerAttribution.TimedText {
        .init(text: text, start: start, end: end)
    }

    private func turn(_ key: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerAttribution.SpeakerTurn {
        .init(speakerKey: key, start: start, end: end)
    }

    @Test func splitsAtSpeakerChange() {
        let words = [
            word(" Hello", 0.0, 0.4), word(" there", 0.5, 0.9),
            word(" Hi", 2.0, 2.3), word(" back", 2.4, 2.8),
        ]
        let turns = [turn("S1", 0, 1.5), turn("S2", 1.8, 3.0)]
        let runs = SpeakerAttribution.attribute(words: words, turns: turns)

        #expect(runs.count == 2)
        #expect(runs[0].speakerKey == "S1")
        #expect(runs[0].text == "Hello there")
        #expect(runs[1].speakerKey == "S2")
        #expect(runs[1].text == "Hi back")
    }

    @Test func wordChoosesMaxOverlapTurn() {
        // Word 1.0–2.0 overlaps S1 by 0.2 and S2 by 0.8.
        let key = SpeakerAttribution.dominantSpeaker(
            for: word("x", 1.0, 2.0),
            in: [turn("S1", 0, 1.2), turn("S2", 1.2, 3.0)]
        )
        #expect(key == "S2")
    }

    @Test func gapWordInheritsPreviousSpeaker() {
        // Second word sits in a diarization gap; it stays with S1 rather
        // than becoming its own unattributed run.
        let words = [word(" one", 0.0, 0.5), word(" two", 1.6, 1.9), word(" three", 2.5, 3.0)]
        let turns = [turn("S1", 0, 1.5), turn("S2", 2.4, 3.5)]
        let runs = SpeakerAttribution.attribute(words: words, turns: turns)

        #expect(runs.count == 2)
        #expect(runs[0].text == "one two")
        #expect(runs[0].speakerKey == "S1")
        #expect(runs[1].speakerKey == "S2")
    }

    @Test func leadingOrphanTakesFirstFollowingTurn() {
        let words = [word(" early", 0.0, 0.3), word(" main", 1.0, 1.4)]
        let turns = [turn("S1", 0.8, 2.0)]
        let runs = SpeakerAttribution.attribute(words: words, turns: turns)

        #expect(runs.count == 1)
        #expect(runs[0].speakerKey == "S1")
        #expect(runs[0].text == "early main")
    }

    @Test func noTurnsYieldsSingleUnattributedRun() {
        let words = [word(" a", 0, 1), word(" b", 1, 2)]
        let runs = SpeakerAttribution.attribute(words: words, turns: [])

        #expect(runs.count == 1)
        #expect(runs[0].speakerKey == nil)
        #expect(runs[0].text == "a b")
    }

    @Test func emptyWordsYieldNothing() {
        #expect(SpeakerAttribution.attribute(words: [], turns: [turn("S1", 0, 1)]).isEmpty)
    }

    @Test func runTimesSpanTheirWords() {
        let words = [word(" a", 0.5, 1.0), word(" b", 1.2, 2.2)]
        let runs = SpeakerAttribution.attribute(words: words, turns: [turn("S1", 0, 3)])

        #expect(runs.count == 1)
        #expect(runs[0].start == 0.5)
        #expect(runs[0].end == 2.2)
    }

    @Test func whitespaceOnlyRunsAreDropped() {
        let runs = SpeakerAttribution.attribute(
            words: [word("  ", 0, 1)],
            turns: [turn("S1", 0, 2)]
        )
        #expect(runs.isEmpty)
    }
}
