import SwiftUI

struct AudioPlayerView: View {
    let session: RecordingSession
    @Bindable var playback: AudioPlaybackService

    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor.gradient)

            if playback.isLoaded {
                controls
            } else {
                ContentUnavailableView(
                    "Audio unavailable",
                    systemImage: "speaker.slash",
                    description: Text("The audio file for this note could not be found.")
                )
            }

            Spacer()

            LabeledContent("Recorded", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .onAppear {
            if let url = session.audioFileURL {
                playback.load(url: url)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            // Scrubber
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                HStack {
                    Text(TimeFormatting.clock(playback.currentTime))
                    Spacer()
                    Text("−" + TimeFormatting.clock(max(0, playback.duration - playback.currentTime)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 44) {
                Button {
                    playback.seek(to: playback.currentTime - 15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }

                Button {
                    playback.playPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .contentTransition(.symbolEffect(.replace))
                }

                Button {
                    playback.seek(to: playback.currentTime + 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
            }
            .foregroundStyle(Color.accentColor)

            Menu {
                ForEach(rates, id: \.self) { rate in
                    Button {
                        playback.rate = rate
                    } label: {
                        if playback.rate == rate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(rateLabel(playback.rate))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: .capsule)
            }
        }
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == 1.0 ? "1×" : String(format: "%g×", rate)
    }
}
