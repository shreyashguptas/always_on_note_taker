import Foundation

/// Pure timeline math that merges transcription output with diarization
/// output: every transcribed word is attributed to the speaker turn it
/// overlaps most, and consecutive same-speaker words become one attributed
/// segment. Deliberately free of WhisperKit/FluidAudio types so it can be
/// unit-tested without either SDK.
enum SpeakerAttribution {
    /// A transcribed word (or whole segment, when word timing is missing)
    /// in absolute session time.
    struct TimedText {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// One diarized speaker turn in absolute session time.
    struct SpeakerTurn {
        let speakerKey: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// A run of consecutive words by one speaker.
    struct AttributedRun {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let speakerKey: String?
    }

    /// Splits a stretch of transcribed words at speaker changes. Words that
    /// overlap no turn inherit the previous word's speaker (diarization
    /// boundaries rarely land exactly on word boundaries); leading orphans
    /// get the first turn that follows them, or nil when there are no turns.
    static func attribute(words: [TimedText], turns: [SpeakerTurn]) -> [AttributedRun] {
        guard !words.isEmpty else { return [] }

        var runs: [AttributedRun] = []
        var currentKey: String?? = nil // nil = no word yet; .some(nil) = unattributed
        var currentText = ""
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0

        for word in words {
            var key = dominantSpeaker(for: word, in: turns)
            if key == nil, case .some(let previous) = currentKey {
                key = previous
            }
            if key == nil {
                key = firstTurnKey(onOrAfter: word.start, in: turns)
            }

            if currentKey == .some(key) {
                currentText += word.text
                currentEnd = max(currentEnd, word.end)
            } else {
                if case .some(let previous) = currentKey {
                    appendRun(&runs, text: currentText, start: currentStart, end: currentEnd, key: previous)
                }
                currentKey = .some(key)
                currentText = word.text
                currentStart = word.start
                currentEnd = word.end
            }
        }
        if case .some(let previous) = currentKey {
            appendRun(&runs, text: currentText, start: currentStart, end: currentEnd, key: previous)
        }
        return runs
    }

    /// The speaker whose turn overlaps this word the most, or nil when no
    /// turn overlaps it at all.
    static func dominantSpeaker(for word: TimedText, in turns: [SpeakerTurn]) -> String? {
        var bestKey: String?
        var bestOverlap: TimeInterval = 0
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestKey = turn.speakerKey
            }
        }
        return bestKey
    }

    private static func firstTurnKey(onOrAfter time: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        turns
            .filter { $0.end > time }
            .min { $0.start < $1.start }?
            .speakerKey
    }

    private static func appendRun(
        _ runs: inout [AttributedRun],
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        key: String?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runs.append(AttributedRun(text: trimmed, start: start, end: end, speakerKey: key))
    }
}
