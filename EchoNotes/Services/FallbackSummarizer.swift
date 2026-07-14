import Foundation
import NaturalLanguage

/// Extractive, no-LLM note generation used when Apple Intelligence isn't
/// available (unsupported device, disabled, or model busy). Works everywhere,
/// fully offline: frequency-scored key sentences, pattern-matched action
/// items, and entity/keyword tags.
enum FallbackSummarizer {
    static func summarize(_ transcript: String) -> SummarizationService.NoteResult {
        let sentences = sentenceList(transcript)
        guard !sentences.isEmpty else {
            return SummarizationService.NoteResult(
                title: "Voice note",
                overview: "",
                keyPoints: [],
                actionItems: [],
                tags: [],
                generator: GeneratedNote.fallbackGenerator
            )
        }

        let frequencies = wordFrequencies(transcript)
        let scored = sentences.enumerated().map { index, sentence in
            (index: index, sentence: sentence, score: score(sentence, frequencies: frequencies))
        }

        // Overview: the two highest-scoring sentences, kept in spoken order.
        let overview = scored
            .sorted { $0.score > $1.score }
            .prefix(2)
            .sorted { $0.index < $1.index }
            .map(\.sentence)
            .joined(separator: " ")

        // Key points: next tier of informative sentences, spoken order.
        let keyPoints = scored
            .sorted { $0.score > $1.score }
            .prefix(5)
            .sorted { $0.index < $1.index }
            .map { condense($0.sentence) }

        return SummarizationService.NoteResult(
            title: makeTitle(from: sentences, frequencies: frequencies),
            overview: overview,
            keyPoints: Array(keyPoints),
            actionItems: actionItems(in: sentences),
            tags: tags(in: transcript, frequencies: frequencies),
            generator: GeneratedNote.fallbackGenerator
        )
    }

    // MARK: - Pieces

    private static func sentenceList(_ text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 2 { sentences.append(sentence) }
            return true
        }
        return sentences
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "if", "then", "that", "this",
        "these", "those", "i", "you", "he", "she", "it", "we", "they", "them",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does",
        "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "of", "to", "in", "on", "at", "for", "with", "from", "by", "about",
        "as", "into", "like", "just", "not", "no", "yes", "yeah", "okay", "ok",
        "um", "uh", "gonna", "wanna", "there", "here", "what", "when", "where",
        "who", "how", "why", "which", "their", "your", "my", "our", "his", "her",
        "its", "me", "him", "us", "them", "also", "very", "really", "kind",
        "sort", "thing", "things", "stuff", "know", "think", "mean", "going",
        "get", "got", "one", "two", "some", "any", "all", "lot", "bit",
    ]

    private static func wordFrequencies(_ text: String) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count > 3, !stopwords.contains(word) {
                frequencies[word, default: 0] += 1
            }
            return true
        }
        return frequencies
    }

    private static func score(_ sentence: String, frequencies: [String: Int]) -> Double {
        let words = sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
        guard !words.isEmpty else { return 0 }
        let total = words.reduce(0.0) { $0 + Double(frequencies[$1] ?? 0) }
        // Normalize so long rambles don't automatically win.
        return total / Double(words.count + 3)
    }

    private static func condense(_ sentence: String, maxWords: Int = 24) -> String {
        let words = sentence.split(separator: " ")
        guard words.count > maxWords else { return sentence }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    private static let actionPatterns: [String] = [
        "need to", "needs to", "have to", "has to", "don't forget", "remember to",
        "remind me", "i'll ", "i will", "we'll ", "we will", "we should",
        "i should", "you should", "let's ", "make sure", "follow up", "to do",
        "todo", "by tomorrow", "by monday", "by tuesday", "by wednesday",
        "by thursday", "by friday", "next week", "action item", "take care of",
        "can you ", "could you ",
    ]

    private static func actionItems(in sentences: [String]) -> [String] {
        var items: [String] = []
        for sentence in sentences {
            let lowered = sentence.lowercased()
            if actionPatterns.contains(where: { lowered.contains($0) }) {
                items.append(condense(sentence))
                if items.count == 5 { break }
            }
        }
        return items
    }

    private static func tags(in text: String, frequencies: [String: Int]) -> [String] {
        var tags: [String] = []

        // Named entities first (people, places, organizations).
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                let entity = String(text[range]).lowercased()
                if !tags.contains(entity) { tags.append(entity) }
            }
            return tags.count < 3
        }

        // Fill remaining slots with the most frequent content words.
        for (word, _) in frequencies.sorted(by: { $0.value > $1.value }) {
            if tags.count >= 4 { break }
            if !tags.contains(word) { tags.append(word) }
        }
        return Array(tags.prefix(4))
    }

    private static func makeTitle(from sentences: [String], frequencies: [String: Int]) -> String {
        guard let first = sentences.first else { return "Voice note" }
        let words = first.split(separator: " ")
        let title = words.prefix(8).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
        return title.isEmpty ? "Voice note" : title
    }
}
