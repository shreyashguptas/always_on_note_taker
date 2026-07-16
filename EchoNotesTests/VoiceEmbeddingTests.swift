import Foundation
import Testing
@testable import EchoNotes

struct VoiceEmbeddingTests {
    @Test func dataRoundTrip() {
        let floats: [Float] = [0.5, -1.25, 3.75, 0]
        let data = VoiceEmbedding.data(from: floats)
        #expect(VoiceEmbedding.floats(from: data) == floats)
    }

    @Test func floatsFromCorruptDataIsEmpty() {
        #expect(VoiceEmbedding.floats(from: Data()) == [])
        #expect(VoiceEmbedding.floats(from: Data([1, 2, 3])) == []) // not a multiple of 4
    }

    @Test func cosineSimilarityOfIdenticalVectorsIsOne() {
        let v: [Float] = [0.3, 0.4, 0.5]
        #expect(abs(VoiceEmbedding.cosineSimilarity(v, v) - 1) < 1e-5)
    }

    @Test func cosineSimilarityOfOrthogonalVectorsIsZero() {
        #expect(abs(VoiceEmbedding.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
    }

    @Test func cosineSimilarityOfOppositeVectorsIsMinusOne() {
        #expect(abs(VoiceEmbedding.cosineSimilarity([1, 2], [-1, -2]) + 1) < 1e-5)
    }

    @Test func cosineSimilarityGuardsDegenerateInput() {
        #expect(VoiceEmbedding.cosineSimilarity([], []) == 0)
        #expect(VoiceEmbedding.cosineSimilarity([1, 2], [1]) == 0)      // mismatched
        #expect(VoiceEmbedding.cosineSimilarity([0, 0], [1, 1]) == 0)   // zero norm
    }

    @Test func normalizedHasUnitLength() {
        let n = VoiceEmbedding.normalized([3, 4])
        #expect(abs(n[0] - 0.6) < 1e-6)
        #expect(abs(n[1] - 0.8) < 1e-6)
    }

    @Test func normalizedLeavesZeroVectorAlone() {
        #expect(VoiceEmbedding.normalized([0, 0]) == [0, 0])
    }

    @Test func runningMeanConvergesTowardObservations() {
        // Mean of [1,0] with count 1, adding [0,1]: raw mean (0.5, 0.5),
        // renormalized to (√2/2, √2/2).
        let mean = VoiceEmbedding.runningMean(current: [1, 0], count: 1, adding: [0, 1])
        #expect(abs(mean[0] - mean[1]) < 1e-6)
        let norm = sqrt(mean[0] * mean[0] + mean[1] * mean[1])
        #expect(abs(norm - 1) < 1e-5)
    }

    @Test func runningMeanWithHighCountBarelyMoves() {
        let mean = VoiceEmbedding.runningMean(current: [1, 0], count: 49, adding: [0, 1])
        #expect(mean[0] > 0.99) // 49 observations of x barely notice one of y
    }

    @Test func runningMeanWithMismatchedVectorFallsBackToObservation() {
        let mean = VoiceEmbedding.runningMean(current: [1, 0, 0], count: 5, adding: [3, 4])
        #expect(abs(mean[0] - 0.6) < 1e-6)
        #expect(abs(mean[1] - 0.8) < 1e-6)
    }
}
