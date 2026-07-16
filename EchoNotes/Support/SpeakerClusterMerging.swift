import Foundation

/// Post-diarization cleanup: the diarizer sometimes splits one voice into
/// two clusters within a session (quiet speech, room changes), which showed
/// a single-person recording as "Speaker 1" and "Speaker 2". Clusters whose
/// voiceprints are clearly the same voice are folded back together, and the
/// transcript's speaker keys remapped to the surviving cluster.
enum SpeakerClusterMerging {
    /// Merges same-voice clusters (cosine similarity ≥ `threshold`).
    /// Clusters are processed by descending speech time, so the dominant
    /// cluster's key survives. Returns the merged clusters plus a remap of
    /// absorbed keys → surviving key (empty when nothing merged).
    static func merge(
        _ clusters: [TranscriptEnrichmentService.SpeakerCluster],
        threshold: Float
    ) -> (clusters: [TranscriptEnrichmentService.SpeakerCluster], remap: [String: String]) {
        var survivors: [TranscriptEnrichmentService.SpeakerCluster] = []
        var remap: [String: String] = [:]

        for cluster in clusters.sorted(by: { $0.totalSpeech > $1.totalSpeech }) {
            // Best-matching survivor above the threshold, not just the first:
            // with several voices in a session, an absorbed cluster must land
            // on the person it actually is.
            var bestIndex: Int?
            var bestSimilarity = threshold
            for (index, survivor) in survivors.enumerated() {
                let similarity = VoiceEmbedding.cosineSimilarity(survivor.embedding, cluster.embedding)
                if similarity >= bestSimilarity {
                    bestSimilarity = similarity
                    bestIndex = index
                }
            }

            guard let index = bestIndex else {
                survivors.append(cluster)
                continue
            }

            let survivor = survivors[index]
            remap[cluster.key] = survivor.key

            // Speech-time-weighted voiceprint; the longer snippet wins (both
            // are the same voice, the clearer sample makes the better card).
            let survivorWeight = Float(survivor.totalSpeech)
            let clusterWeight = Float(cluster.totalSpeech)
            var embedding = survivor.embedding
            if survivor.embedding.count == cluster.embedding.count, !embedding.isEmpty {
                embedding = VoiceEmbedding.normalized(
                    zip(survivor.embedding, cluster.embedding).map {
                        $0 * survivorWeight + $1 * clusterWeight
                    }
                )
            }
            let survivorSnippet = survivor.snippetEnd - survivor.snippetStart
            let clusterSnippet = cluster.snippetEnd - cluster.snippetStart
            let keepSurvivorSnippet = survivorSnippet >= clusterSnippet

            survivors[index] = TranscriptEnrichmentService.SpeakerCluster(
                key: survivor.key,
                embedding: embedding,
                totalSpeech: survivor.totalSpeech + cluster.totalSpeech,
                snippetStart: keepSurvivorSnippet ? survivor.snippetStart : cluster.snippetStart,
                snippetEnd: keepSurvivorSnippet ? survivor.snippetEnd : cluster.snippetEnd
            )
        }
        return (survivors, remap)
    }
}
