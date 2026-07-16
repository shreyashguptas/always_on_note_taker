import Foundation

/// THE one place transcript lines get labeled for the summarizer: speaker
/// prefixes ("Priya: …", "Speaker 2: …") and language markers ("[hi] …" when
/// a line strays from the dominant language). Both producers — the persisted
/// model (`RecordingSession.attributedTranscript`) and the enrichment finish
/// path that still holds plain structs — go through here, so a note's
/// "Speaker 2" can never mean a different voice than the transcript UI's.
enum TranscriptFormatting {
    struct Line {
        let text: String
        let languageCode: String?
        let speakerKey: String?
        /// Resolved person name, when the voice is identified.
        let speakerName: String?

        init(text: String, languageCode: String? = nil, speakerKey: String? = nil, speakerName: String? = nil) {
            self.text = text
            self.languageCode = languageCode
            self.speakerKey = speakerKey
            self.speakerName = speakerName
        }
    }

    /// Most common language across the lines, when any is known.
    static func dominantLanguage<S: Sequence>(of codes: S) -> String? where S.Element == String? {
        var counts: [String: Int] = [:]
        for code in codes {
            if let code {
                counts[code, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Canonical "Speaker n" numbering: every cluster key gets a number by
    /// first appearance in order — including keys later resolved to named
    /// people, so numbering never shifts depending on who has been named.
    static func speakerNumbers<S: Sequence>(forKeysInOrder keys: S) -> [String: Int] where S.Element == String? {
        var numbers: [String: Int] = [:]
        for key in keys {
            if let key, numbers[key] == nil {
                numbers[key] = numbers.count + 1
            }
        }
        return numbers
    }

    /// The summarizer-facing transcript. Lines with no attribution at all
    /// collapse to a plain space-joined transcript.
    static func attributedText(_ lines: [Line]) -> String {
        let hasAttribution = lines.contains {
            $0.speakerName != nil || $0.speakerKey != nil || $0.languageCode != nil
        }
        guard hasAttribution else {
            return lines.map(\.text).joined(separator: " ")
        }

        let dominant = dominantLanguage(of: lines.lazy.map(\.languageCode))
        let numbers = speakerNumbers(forKeysInOrder: lines.lazy.map(\.speakerKey))
        return lines.map { line in
            var prefix = ""
            if let code = line.languageCode, code != dominant {
                prefix += "[\(code)] "
            }
            if let name = line.speakerName, !name.isEmpty {
                prefix += "\(name): "
            } else if let key = line.speakerKey, let number = numbers[key] {
                prefix += "Speaker \(number): "
            }
            return prefix + line.text
        }
        .joined(separator: "\n")
    }
}
