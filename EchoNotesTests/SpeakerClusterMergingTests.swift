import Foundation
import Testing
@testable import EchoNotes

/// Pins the split-voice repair: one quiet speaker the diarizer broke into
/// two clusters must come back out as ONE speaker (with the transcript keys
/// remapped), while genuinely different voices stay separate.
struct SpeakerClusterMergingTests {
    private func cluster(
        _ key: String,
        embedding: [Float],
        speech: TimeInterval,
        snippet: (TimeInterval, TimeInterval) = (0, 10)
    ) -> TranscriptEnrichmentService.SpeakerCluster {
        .init(
            key: key,
            embedding: VoiceEmbedding.normalized(embedding),
            totalSpeech: speech,
            snippetStart: snippet.0,
            snippetEnd: snippet.1
        )
    }

    @Test func sameVoiceSplitIntoTwoClustersMergesIntoDominantKey() {
        // Nearly identical directions — the classic diarizer over-split.
        let result = SpeakerClusterMerging.merge(
            [
                cluster("S1", embedding: [1, 0.1, 0], speech: 14),
                cluster("S2", embedding: [1, 0.12, 0.02], speech: 6),
            ],
            threshold: 0.6
        )
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].key == "S1")
        #expect(result.clusters[0].totalSpeech == 20)
        #expect(result.remap == ["S2": "S1"])
    }

    @Test func distinctVoicesAreNotMerged() {
        let result = SpeakerClusterMerging.merge(
            [
                cluster("S1", embedding: [1, 0, 0], speech: 30),
                cluster("S2", embedding: [0, 1, 0], speech: 20),
            ],
            threshold: 0.6
        )
        #expect(result.clusters.count == 2)
        #expect(result.remap.isEmpty)
    }

    @Test func absorbedClusterLandsOnItsBestMatchNotTheFirstSurvivor() {
        // S3 is similar to BOTH survivors but much closer to S2 — it must
        // fold into S2 even though S1 (more speech) is checked first.
        let result = SpeakerClusterMerging.merge(
            [
                cluster("S1", embedding: [1, 0.2, 0], speech: 40),
                cluster("S2", embedding: [0.2, 1, 0], speech: 30),
                cluster("S3", embedding: [0.22, 1, 0.05], speech: 5),
            ],
            threshold: 0.9
        )
        #expect(result.remap["S3"] == "S2")
        #expect(result.clusters.map(\.key).sorted() == ["S1", "S2"])
    }

    @Test func chainOfSplitsAllRemapToTheOneSurvivor() {
        let voice: [Float] = [0.3, 0.9, 0.1]
        let result = SpeakerClusterMerging.merge(
            [
                cluster("S1", embedding: voice, speech: 12),
                cluster("S2", embedding: voice.map { $0 * 1.01 }, speech: 7),
                cluster("S3", embedding: voice.map { $0 * 0.99 }, speech: 3),
            ],
            threshold: 0.6
        )
        #expect(result.clusters.count == 1)
        #expect(result.remap == ["S2": "S1", "S3": "S1"])
    }

    @Test func mergedClusterKeepsTheLongerSnippet() {
        // The absorbed cluster has the longer clean stretch — its snippet
        // should win so the review card plays the clearer sample.
        let result = SpeakerClusterMerging.merge(
            [
                cluster("S1", embedding: [1, 0.1, 0], speech: 15, snippet: (2, 6)),
                cluster("S2", embedding: [1, 0.11, 0], speech: 8, snippet: (20, 30)),
            ],
            threshold: 0.6
        )
        #expect(result.clusters.count == 1)
        #expect(result.clusters[0].snippetStart == 20)
        #expect(result.clusters[0].snippetEnd == 30)
    }

    @Test func emptyInputYieldsEmptyOutput() {
        let result = SpeakerClusterMerging.merge([], threshold: 0.6)
        #expect(result.clusters.isEmpty)
        #expect(result.remap.isEmpty)
    }
}
