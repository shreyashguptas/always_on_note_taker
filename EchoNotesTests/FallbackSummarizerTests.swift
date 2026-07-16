import Foundation
import Testing
@testable import EchoNotes

struct FallbackSummarizerTests {
    @Test func keyPointsDoNotRepeatTheOverview() {
        // Sentence scores are driven by content-word frequency; "budget" and
        // "launch" repeat, so those sentences rank highest and become the
        // overview. The key points must be the NEXT tier, not copies.
        let transcript = """
        The budget review covered the launch budget in detail. \
        Everyone agreed the launch budget needs another revision. \
        Marketing wants three new banner designs before Friday. \
        The office move happens sometime next quarter. \
        Lunch orders were mixed up again yesterday.
        """
        let note = FallbackSummarizer.summarize(transcript)

        #expect(!note.overview.isEmpty)
        #expect(!note.keyPoints.isEmpty)
        for point in note.keyPoints {
            #expect(!note.overview.contains(point))
        }
    }

    @Test func tinyTranscriptProducesNoDuplicateKeyPoints() {
        // With two or fewer sentences everything is already the overview —
        // key points must be empty rather than a verbatim copy.
        let note = FallbackSummarizer.summarize("Buy milk tomorrow morning. Also grab coffee beans.")
        #expect(note.keyPoints.isEmpty)
    }
}
