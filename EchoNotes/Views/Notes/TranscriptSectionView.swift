import SwiftUI

struct TranscriptSectionView: View {
    let session: RecordingSession
    /// Wired to audio playback when available; timestamps become tappable.
    var seek: ((TimeInterval) -> Void)? = nil

    var body: some View {
        let segments = session.sortedSegments
        if segments.isEmpty {
            ContentUnavailableView(
                session.isProcessing ? "Transcribing…" : "No transcript",
                systemImage: "text.quote",
                description: Text(session.isProcessing
                    ? "The transcript will appear as soon as processing finishes."
                    : "No speech was transcribed for this recording.")
            )
        } else {
            let dominantLanguage = session.dominantLanguageCode
            let speakerNumbers = speakerNumbersByFirstAppearance(segments)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.status == .enriching {
                        StatusBanner(
                            kind: .progress(nil),
                            message: "Preliminary transcript — languages and speakers are being worked out…"
                        )
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.persistentModelID) { position, segment in
                        segmentRow(
                            segment,
                            // A speaker header only where the voice changes.
                            showsSpeaker: hasSpeakerInfo(segment) && !sameSpeaker(segment, position > 0 ? segments[position - 1] : nil),
                            speakerNumbers: speakerNumbers,
                            dominantLanguage: dominantLanguage
                        )
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func segmentRow(
        _ segment: TranscriptSegment,
        showsSpeaker: Bool,
        speakerNumbers: [String: Int],
        dominantLanguage: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsSpeaker {
                speakerHeader(segment, speakerNumbers: speakerNumbers)
                    .padding(.top, 4)
            }
            HStack(spacing: 8) {
                if let seek {
                    Button {
                        seek(segment.startTime)
                    } label: {
                        timestampLabel(segment)
                    }
                    .buttonStyle(.plain)
                } else {
                    timestampLabel(segment)
                }
                if let code = segment.languageCode, code != dominantLanguage {
                    languageBadge(code)
                }
            }
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func speakerHeader(_ segment: TranscriptSegment, speakerNumbers: [String: Int]) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(speakerColor(segment))
                .frame(width: 8, height: 8)
            Text(speakerName(segment, speakerNumbers: speakerNumbers))
                .font(.subheadline.weight(.semibold))
        }
    }

    private func timestampLabel(_ segment: TranscriptSegment) -> some View {
        Label(TimeFormatting.clock(segment.startTime), systemImage: seek == nil ? "clock" : "play.circle")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.accentColor)
            .labelStyle(.titleAndIcon)
    }

    private func languageBadge(_ code: String) -> some View {
        Text(SpeakerPalette.languageName(for: code))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: .capsule)
            .foregroundStyle(.secondary)
    }

    // MARK: - Speaker helpers

    private func hasSpeakerInfo(_ segment: TranscriptSegment) -> Bool {
        segment.speaker != nil || segment.speakerKey != nil
    }

    private func sameSpeaker(_ segment: TranscriptSegment, _ previous: TranscriptSegment?) -> Bool {
        guard let previous else { return false }
        if let speaker = segment.speaker, let previousSpeaker = previous.speaker {
            return speaker.id == previousSpeaker.id
        }
        return segment.speaker == nil && previous.speaker == nil
            && segment.speakerKey != nil && segment.speakerKey == previous.speakerKey
    }

    private func speakerName(_ segment: TranscriptSegment, speakerNumbers: [String: Int]) -> String {
        if let name = segment.speaker?.name, !name.isEmpty { return name }
        if let key = segment.speakerKey, let number = speakerNumbers[key] {
            return "Speaker \(number)"
        }
        return "Speaker"
    }

    private func speakerColor(_ segment: TranscriptSegment) -> Color {
        if let speaker = segment.speaker {
            return SpeakerPalette.color(for: speaker.colorIndex)
        }
        return SpeakerPalette.unidentified
    }

    /// "Speaker 1" is whoever talked first, per session.
    private func speakerNumbersByFirstAppearance(_ segments: [TranscriptSegment]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for segment in segments {
            if let key = segment.speakerKey, numbers[key] == nil {
                numbers[key] = numbers.count + 1
            }
        }
        return numbers
    }
}
