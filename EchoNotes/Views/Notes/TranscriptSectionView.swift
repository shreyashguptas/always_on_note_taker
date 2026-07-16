import SwiftUI

struct TranscriptSectionView: View {
    let session: RecordingSession
    /// Wired to audio playback when available; timestamps become tappable.
    var seek: ((TimeInterval) -> Void)? = nil

    @Environment(RecordingCoordinator.self) private var coordinator

    /// Sorting + numbering a multi-thousand-segment transcript is too heavy
    /// to redo on every render (progress ticks re-render this view while a
    /// recording is being re-transcribed), so the derived data is cached and
    /// refreshed only when the segment set changes size.
    @State private var segments: [TranscriptSegment] = []
    @State private var dominantLanguage: String?
    @State private var speakerNumbers: [String: Int] = [:]

    var body: some View {
        content
            .onAppear { rebuildDerivedData() }
            .onChange(of: session.segments.count) { _, _ in rebuildDerivedData() }
    }

    private func rebuildDerivedData() {
        segments = session.sortedSegments
        dominantLanguage = RecordingSession.dominantLanguageCode(of: segments)
        // Canonical numbering shared with attributedTranscript, so the
        // note's "Speaker 2" is the same voice as the UI's "Speaker 2".
        speakerNumbers = RecordingSession.speakerNumbersByFirstAppearance(of: segments)
    }

    @ViewBuilder
    private var content: some View {
        if segments.isEmpty {
            ContentUnavailableView(
                session.isProcessing ? "Transcribing…" : "No transcript",
                systemImage: "text.quote",
                description: Text(session.isProcessing
                    ? "The transcript will appear as soon as processing finishes."
                    : "No speech was transcribed for this recording.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.status == .enriching {
                        // Only reachable when a finished transcript is being
                        // re-processed (Retry) — fresh sessions have no
                        // segments to show until transcription completes.
                        StatusBanner(
                            kind: .progress(enrichmentFraction),
                            message: "Re-transcribing this recording — the transcript will update when it finishes…"
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

    /// Fraction of the audio processed so far, nil while queued.
    private var enrichmentFraction: Double? {
        if case .processing(let fraction) = coordinator.enrichmentProgress[session.id] {
            return fraction
        }
        return nil
    }
}
