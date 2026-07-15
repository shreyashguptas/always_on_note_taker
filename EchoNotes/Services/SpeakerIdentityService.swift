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
    /// Auto-tags confident matches, queues the rest for review.
    func processClusters(_ clusters: [TranscriptEnrichmentService.SpeakerCluster], sessionID: UUID) {
        let speakers = allSpeakers()
        let pending = pendingReviewItems()

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
                continue
            }

            // The same unknown voice may already be waiting for review from
            // an earlier session — bump that card instead of stacking a new
            // one per session.
            if let existing = pending.first(where: {
                VoiceEmbedding.cosineSimilarity($0.embedding, embedding) >= AppSettings.speakerMatchThreshold
            }) {
                existing.occurrenceCount += 1
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
        }
        try? modelContext.save()
    }

    // MARK: - Review actions

    /// The user named this voice: tag the session's segments, teach the
    /// voiceprint, and see whether other pending cards were the same person.
    func assign(_ item: SpeakerReviewItem, to speaker: Speaker) {
        item.status = .assigned
        tagSegments(sessionID: item.sessionID, speakerKey: item.speakerKey, with: speaker)
        fold(item.embedding, into: speaker)

        // Naming Dad once should clear his other queued cards too.
        for other in pendingReviewItems() where other.id != item.id {
            if VoiceEmbedding.cosineSimilarity(other.embedding, speaker.embedding) >= AppSettings.speakerMatchThreshold {
                other.status = .assigned
                tagSegments(sessionID: other.sessionID, speakerKey: other.speakerKey, with: speaker)
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
        let pending = SpeakerReviewItem.Status.pending.rawValue
        let descriptor = FetchDescriptor<SpeakerReviewItem>(predicate: #Predicate {
            $0.statusRaw == pending
        })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func nextColorIndex() -> Int {
        let used = allSpeakers().map(\.colorIndex)
        return (used.max() ?? -1) + 1
    }

    /// Removes pending cards pointing at a session being deleted — their
    /// snippet audio is about to disappear.
    func purgeReviewItems(for sessionID: UUID) {
        let descriptor = FetchDescriptor<SpeakerReviewItem>(predicate: #Predicate {
            $0.sessionID == sessionID
        })
        guard let items = try? modelContext.fetch(descriptor) else { return }
        for item in items where item.status == .pending {
            modelContext.delete(item)
        }
    }
}
