import Foundation
import SwiftData

/// Decides who each diarized voice belongs to. Confident matches against the
/// stored voiceprints are tagged automatically; everything else becomes a
/// review card in the People tab. Owns all Speaker/SpeakerReviewItem
/// mutations so the matching policy lives in exactly one place.
@MainActor
final class SpeakerIdentityService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Post-enrichment entry point

    /// Called once per enriched session with every distinct voice found.
    /// Auto-tags confident matches, queues the rest for review. Returns the
    /// names it assigned (cluster key → person name) so the caller can label
    /// the transcript without re-faulting the just-inserted segments.
    @discardableResult
    func processClusters(
        _ clusters: [TranscriptEnrichmentService.SpeakerCluster],
        sessionID: UUID
    ) -> [String: String] {
        var assignedNames: [String: String] = [:]
        let speakers = allSpeakers()
        // Mutable so cards created for earlier clusters of THIS call are
        // seen by later clusters — the diarizer sometimes splits one voice
        // into two clusters, and they must not become two cards.
        var pending = pendingReviewItems()

        for cluster in clusters {
            // Too little speech to identify anyone reliably (TV, passersby):
            // segments keep their anonymous "Speaker n" label, no card.
            guard cluster.totalSpeech >= AppSettings.speakerMinimumSpeech else { continue }

            let embedding = VoiceEmbedding.normalized(cluster.embedding)
            let match = bestMatch(for: embedding, among: speakers)

            if let best = match.best,
               match.similarity >= AppSettings.speakerMatchThreshold,
               match.margin >= AppSettings.speakerMatchMargin {
                tagSegments(sessionID: sessionID, speakerKey: cluster.key, with: best)
                fold(embedding, into: best)
                assignedNames[cluster.key] = best.name
                continue
            }

            // The same unknown voice may already be waiting for review —
            // record this occurrence on that card instead of stacking a new
            // one, so assigning it later retro-tags this session too.
            if let existing = pending.first(where: {
                VoiceEmbedding.cosineSimilarity($0.embedding, embedding) >= AppSettings.speakerMatchThreshold
            }) {
                existing.linkOccurrence(sessionID: sessionID, speakerKey: cluster.key)
                continue
            }

            let suggestion: UUID? = (match.similarity >= AppSettings.speakerSuggestThreshold) ? match.best?.id : nil
            let item = SpeakerReviewItem(
                sessionID: sessionID,
                speakerKey: cluster.key,
                snippetStart: cluster.snippetStart,
                snippetEnd: cluster.snippetEnd,
                embedding: embedding,
                suggestedSpeakerID: suggestion
            )
            modelContext.insert(item)
            pending.append(item)
        }
        try? modelContext.save()
        return assignedNames
    }

    // MARK: - Review actions

    /// The user named this voice: tag its segments in every session it was
    /// heard in, teach the voiceprint, and see whether other pending cards
    /// were the same person.
    func assign(_ item: SpeakerReviewItem, to speaker: Speaker) {
        item.status = .assigned
        for occurrence in item.allOccurrences {
            tagSegments(sessionID: occurrence.sessionID, speakerKey: occurrence.speakerKey, with: speaker)
        }
        fold(item.embedding, into: speaker)

        // Naming Dad once should clear his other queued cards too.
        for other in pendingReviewItems() where other.id != item.id {
            if VoiceEmbedding.cosineSimilarity(other.embedding, speaker.embedding) >= AppSettings.speakerMatchThreshold {
                other.status = .assigned
                for occurrence in other.allOccurrences {
                    tagSegments(sessionID: occurrence.sessionID, speakerKey: occurrence.speakerKey, with: speaker)
                }
                fold(other.embedding, into: speaker)
            }
        }
        try? modelContext.save()
    }

    /// Creates a new person from a review card and assigns it.
    @discardableResult
    func createSpeaker(named name: String, isMe: Bool = false, from item: SpeakerReviewItem) -> Speaker {
        let speaker = Speaker(
            name: name,
            isMe: isMe,
            embedding: item.embedding,
            colorIndex: nextColorIndex()
        )
        modelContext.insert(speaker)
        assign(item, to: speaker)
        return speaker
    }

    /// "Not a person" / not worth tracking — the card goes away for good.
    func dismiss(_ item: SpeakerReviewItem) {
        item.status = .dismissed
        try? modelContext.save()
    }

    // MARK: - Speaker management

    /// Folds `source` into `target` (two cards accidentally became two
    /// people): segments move over, voiceprints merge count-weighted.
    func merge(_ source: Speaker, into target: Speaker) {
        guard source.id != target.id else { return }
        for segment in source.segments {
            segment.speaker = target
        }
        let total = max(1, source.embeddingCount + target.embeddingCount)
        let sourceWeight = Float(source.embeddingCount) / Float(total)
        let targetWeight = Float(target.embeddingCount) / Float(total)
        let merged = zip(source.embedding, target.embedding).map { $0 * sourceWeight + $1 * targetWeight }
        if merged.count == target.embedding.count, !merged.isEmpty {
            target.embedding = VoiceEmbedding.normalized(merged)
        }
        target.embeddingCount = min(total, AppSettings.speakerEmbeddingUpdateCap)
        target.isMe = target.isMe || source.isMe
        modelContext.delete(source)
        try? modelContext.save()
    }

    func deleteSpeaker(_ speaker: Speaker) {
        // Relationship rule nullifies segments; their speakerKey survives so
        // the transcript falls back to "Speaker n", not blank.
        modelContext.delete(speaker)
        try? modelContext.save()
    }

    // MARK: - Matching

    private func bestMatch(for embedding: [Float], among speakers: [Speaker]) -> (best: Speaker?, similarity: Float, margin: Float) {
        var best: (speaker: Speaker, similarity: Float)?
        var second: Float = -1
        for speaker in speakers {
            let similarity = VoiceEmbedding.cosineSimilarity(embedding, speaker.embedding)
            if similarity > (best?.similarity ?? -1) {
                second = best?.similarity ?? -1
                best = (speaker, similarity)
            } else if similarity > second {
                second = similarity
            }
        }
        guard let best else { return (nil, 0, 0) }
        // With a single known speaker there is no second-best; the margin
        // rule shouldn't block the match then.
        let margin = second < 0 ? 1 : best.similarity - second
        return (best.speaker, best.similarity, margin)
    }

    /// Only confident evidence teaches the voiceprint — borderline matches
    /// would drift it toward whoever they actually were.
    private func fold(_ embedding: [Float], into speaker: Speaker) {
        guard speaker.embeddingCount < AppSettings.speakerEmbeddingUpdateCap else { return }
        speaker.embedding = VoiceEmbedding.runningMean(
            current: speaker.embedding,
            count: speaker.embeddingCount,
            adding: embedding
        )
        speaker.embeddingCount += 1
    }

    private func tagSegments(sessionID: UUID, speakerKey: String, with speaker: Speaker) {
        let descriptor = FetchDescriptor<TranscriptSegment>(predicate: #Predicate {
            $0.session?.id == sessionID && $0.speakerKey == speakerKey
        })
        guard let segments = try? modelContext.fetch(descriptor) else { return }
        for segment in segments {
            segment.speaker = speaker
        }
    }

    // MARK: - Fetches

    private func allSpeakers() -> [Speaker] {
        (try? modelContext.fetch(FetchDescriptor<Speaker>())) ?? []
    }

    private func pendingReviewItems() -> [SpeakerReviewItem] {
        let descriptor = FetchDescriptor<SpeakerReviewItem>(predicate: SpeakerReviewItem.pendingPredicate)
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func nextColorIndex() -> Int {
        let used = allSpeakers().map(\.colorIndex)
        return (used.max() ?? -1) + 1
    }

    /// A session is being deleted: scrub it out of the review queue without
    /// losing voices that were also heard elsewhere. Cards whose only
    /// occurrence was this session go away; cards with occurrences in other
    /// sessions survive, re-anchored to one of those sessions (with a
    /// snippet recomputed from that session's segments) when their snippet
    /// audio belonged to the deleted one.
    func purgeReviewItems(for sessionID: UUID) {
        for item in pendingReviewItems() {
            let remaining = item.allOccurrences.filter { $0.sessionID != sessionID }
            if remaining.isEmpty {
                modelContext.delete(item)
                continue
            }
            guard remaining.count != item.allOccurrences.count else { continue } // untouched

            let primaryChanged = item.sessionID != remaining[0].sessionID
            item.setOccurrences(remaining)
            if primaryChanged {
                // The snippet range referred to the deleted session's audio;
                // find this voice's longest stretch in the new primary.
                let snippet = longestSegmentRange(sessionID: item.sessionID, speakerKey: item.speakerKey)
                item.snippetStart = snippet?.start ?? 0
                item.snippetEnd = snippet?.end ?? 0
            }
        }
        try? modelContext.save()
    }

    /// Midpoint window of the longest transcript segment this cluster spoke
    /// in the given session — a serviceable review snippet when the original
    /// one is gone.
    private func longestSegmentRange(sessionID: UUID, speakerKey: String) -> (start: TimeInterval, end: TimeInterval)? {
        let descriptor = FetchDescriptor<TranscriptSegment>(predicate: #Predicate {
            $0.session?.id == sessionID && $0.speakerKey == speakerKey
        })
        guard let segments = try? modelContext.fetch(descriptor),
              let longest = segments.max(by: { ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime) }) else {
            return nil
        }
        let length = min(AppSettings.speakerSnippetDuration, longest.endTime - longest.startTime)
        let start = longest.startTime + ((longest.endTime - longest.startTime) - length) / 2
        return (start, start + length)
    }
}
