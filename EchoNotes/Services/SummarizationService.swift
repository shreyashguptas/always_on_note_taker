import Foundation
import FoundationModels

/// Turns a finished transcript into an organized note, entirely on-device.
///
/// Primary path: the Apple Intelligence system model via the Foundation
/// Models framework, with guided generation into `NotePayload`. The model's
/// context window is ~4K tokens shared across instructions, prompt, and
/// response, so long transcripts are handled map-reduce style: summarize
/// chunks, then compose the note from the chunk digests.
///
/// Any unavailability or generation failure falls back to the extractive
/// `FallbackSummarizer`, so a note is always produced.
enum SummarizationService {
    struct NoteResult {
        let title: String
        let overview: String
        let keyPoints: [String]
        let actionItems: [String]
        let tags: [String]
        let generator: String
    }

    private static let instructions = """
        You organize transcripts of personal voice recordings (meetings, \
        conversations, spoken reminders) into clear notes. Use only \
        information that appears in the transcript. Never invent names, \
        dates, or facts. Write in plain, direct language. Lines may be \
        prefixed with the speaker's name ("Priya: …") — when a task clearly \
        belongs to a named speaker, name them in the action item ("Priya: \
        book the flights"). The transcript may mix several languages; \
        stretches in another language are marked like [hi] or [es]. Write \
        the note in English, keeping names and short quoted phrases as \
        spoken.
        """

    /// True when the Apple Intelligence model can be used right now.
    static var appleIntelligenceAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// A user-facing explanation when Apple Intelligence can't be used, or
    /// nil when it's available.
    static var unavailabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence, so notes use the basic on-device summarizer."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings for smarter summaries. Notes use the basic summarizer until then."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is getting ready. Notes use the basic summarizer until it's available."
        case .unavailable:
            return "Apple Intelligence is unavailable right now, so notes use the basic on-device summarizer."
        }
    }

    // MARK: - Entry point

    static func generateNote(from transcript: String) async -> NoteResult {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return FallbackSummarizer.summarize(text)
        }

        guard appleIntelligenceAvailable else {
            return FallbackSummarizer.summarize(text)
        }

        do {
            return try await generateWithModel(text, chunkSize: AppSettings.summarizationChunkCharacters)
        } catch {
            // One retry with half-size chunks handles context-window overflow;
            // anything else lands in the fallback.
            do {
                return try await generateWithModel(text, chunkSize: AppSettings.summarizationChunkCharacters / 2)
            } catch {
                return FallbackSummarizer.summarize(text)
            }
        }
    }

    // MARK: - Foundation Models pipeline

    private static func generateWithModel(_ transcript: String, chunkSize: Int) async throws -> NoteResult {
        let chunks = chunk(transcript, limit: chunkSize)

        if chunks.count == 1 {
            let payload = try await composeNote(from: "Transcript:\n\n\(chunks[0])")
            return result(from: payload)
        }

        // Map: digest each chunk with a fresh session so context never
        // accumulates across requests.
        var digests: [ChunkDigest] = []
        for (index, chunkText) in chunks.enumerated() {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
                This is part \(index + 1) of \(chunks.count) of one recording's transcript. \
                Summarize just this part.

                \(chunkText)
                """
            let response = try await session.respond(to: prompt, generating: ChunkDigest.self)
            digests.append(response.content)
        }

        // Reduce: compose the final note from the digests, condensing
        // hierarchically if even the digests outgrow one request.
        var combined = combinedText(from: digests)
        var rounds = 0
        while combined.count > chunkSize, rounds < 3 {
            var condensed: [ChunkDigest] = []
            for part in chunk(combined, limit: chunkSize) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: "Condense these meeting notes, keeping every distinct topic and task:\n\n\(part)",
                    generating: ChunkDigest.self
                )
                condensed.append(response.content)
            }
            combined = combinedText(from: condensed)
            rounds += 1
        }

        let payload = try await composeNote(from: """
            These are section summaries of one recording, in order. Merge them \
            into a single organized note. Merge duplicate action items.

            \(combined)
            """)
        return result(from: payload)
    }

    private static func composeNote(from prompt: String) async throws -> NotePayload {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: NotePayload.self)
        return response.content
    }

    private static func combinedText(from digests: [ChunkDigest]) -> String {
        digests.enumerated().map { index, digest in
            var block = "Section \(index + 1): \(digest.summary)"
            if !digest.actionItems.isEmpty {
                block += "\nTasks: " + digest.actionItems.joined(separator: "; ")
            }
            return block
        }
        .joined(separator: "\n\n")
    }

    private static func result(from payload: NotePayload) -> NoteResult {
        // De-duplicate model output: repeated strings break SwiftUI ForEach
        // identity, and lowercasing tags can itself create duplicates.
        NoteResult(
            title: payload.title.trimmingCharacters(in: CharacterSet(charactersIn: "\" .")),
            overview: payload.overview,
            keyPoints: payload.keyPoints.removingDuplicates(),
            actionItems: payload.actionItems.removingDuplicates(),
            tags: payload.tags.map { $0.lowercased() }.removingDuplicates(),
            generator: GeneratedNote.foundationModelsGenerator
        )
    }

    // MARK: - Chunking

    /// Splits on sentence/word boundaries so no chunk exceeds `limit`
    /// characters (roughly limit/3.5 tokens — comfortably inside the window).
    static func chunk(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        var chunks: [String] = []
        var remaining = Substring(text)

        while remaining.count > limit {
            let window = remaining.prefix(limit)
            var cut = window.endIndex

            // Prefer a sentence boundary, then any whitespace — always cutting
            // AFTER the boundary character so each iteration must advance.
            if let sentenceEnd = window.lastIndex(where: { ".!?\n".contains($0) }),
               window.distance(from: window.startIndex, to: sentenceEnd) > limit / 2 {
                cut = window.index(after: sentenceEnd)
            } else if let space = window.lastIndex(where: { $0 == " " }),
                      space > window.startIndex {
                cut = window.index(after: space)
            }

            // Forced progress: a single token longer than `limit` (spoken-out
            // URL, run-on) gets hard-cut rather than looping forever.
            if cut <= remaining.startIndex { cut = window.endIndex }

            let piece = remaining[remaining.startIndex..<cut]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[cut...]
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }
}
