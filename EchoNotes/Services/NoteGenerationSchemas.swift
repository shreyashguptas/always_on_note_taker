import FoundationModels

/// Structured output the on-device model is constrained to produce for a
/// finished note. Guided generation guarantees a valid instance — no prose
/// parsing anywhere in the pipeline.
@Generable
struct NotePayload {
    @Guide(description: "A short, specific title for the note, at most eight words, no surrounding quotes.")
    var title: String

    @Guide(description: "A two to three sentence overview of what was discussed or said.")
    var overview: String

    @Guide(description: "The three to seven most important points, each a single concise sentence.")
    var keyPoints: [String]

    @Guide(description: "Concrete tasks, commitments, or follow-ups that were mentioned, including owner and deadline when stated. Empty if there are none.")
    var actionItems: [String]

    @Guide(description: "One to four short lowercase topic tags, each one or two words.")
    var tags: [String]
}

/// Intermediate result for one chunk of a long transcript (map step of the
/// map-reduce summarization).
@Generable
struct ChunkDigest {
    @Guide(description: "A compact summary of this part of the transcript, at most four sentences.")
    var summary: String

    @Guide(description: "Concrete tasks, commitments, or follow-ups mentioned in this part. Empty if none.")
    var actionItems: [String]
}
