import Accelerate
import Foundation

/// Pure math over speaker voiceprints: 256-dim Float32 vectors from the
/// diarizer's embedding model, L2-normalized so cosine similarity is a plain
/// dot product. Persisted as raw little-endian bytes on SwiftData models.
enum VoiceEmbedding {
    // MARK: - Data <-> [Float]

    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else { return [] }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats
    }

    // MARK: - Similarity

    /// Cosine similarity in -1...1. Zero-length or mismatched vectors score 0
    /// so a corrupt embedding can never match anyone.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var magA: Float = 0
        var magB: Float = 0
        vDSP_svesq(a, 1, &magA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magB, vDSP_Length(b.count))
        let denominator = sqrt(magA) * sqrt(magB)
        guard denominator > .ulpOfOne else { return 0 }
        return dot / denominator
    }

    /// L2-normalizes a vector; returns it unchanged when its norm is ~0.
    static func normalized(_ vector: [Float]) -> [Float] {
        var squared: Float = 0
        vDSP_svesq(vector, 1, &squared, vDSP_Length(vector.count))
        let norm = sqrt(squared)
        guard norm > .ulpOfOne else { return vector }
        var scale = 1 / norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Folds a new observation into a running-mean voiceprint and
    /// renormalizes, so a speaker's identity converges over sessions:
    /// `mean = normalize((mean * n + new) / (n + 1))`.
    static func runningMean(current: [Float], count: Int, adding observation: [Float]) -> [Float] {
        guard current.count == observation.count, !current.isEmpty else {
            return normalized(observation)
        }
        let n = Float(max(0, count))
        var result = [Float](repeating: 0, count: current.count)
        for i in current.indices {
            result[i] = (current[i] * n + observation[i]) / (n + 1)
        }
        return normalized(result)
    }
}
