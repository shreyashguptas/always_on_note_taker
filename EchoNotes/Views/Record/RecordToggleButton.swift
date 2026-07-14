import SwiftUI

/// The app's centerpiece: a large circular on/off control. Off is a quiet
/// gray power button; on becomes a gradient disc with soft pulsing rings
/// while listening/recording.
struct RecordToggleButton: View {
    let isOn: Bool
    let isRecording: Bool
    let action: () -> Void

    @State private var pulse = false

    private let diameter: CGFloat = 168

    var body: some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    // Pulsing halo rings.
                    ForEach(0..<2, id: \.self) { ring in
                        Circle()
                            .stroke(ringColor.opacity(0.35), lineWidth: 2)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(pulse ? 1.45 + 0.18 * CGFloat(ring) : 1)
                            .opacity(pulse ? 0 : 0.8)
                            .animation(
                                .easeOut(duration: 1.8)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(ring) * 0.6),
                                value: pulse
                            )
                    }
                }

                Circle()
                    .fill(fill)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: shadowColor, radius: isOn ? 24 : 10, y: 6)

                VStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 44, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(isOn ? Color.white : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .onAppear { pulse = true }
        .accessibilityLabel(isOn ? "Stop listening" : "Start listening")
        .accessibilityHint("EchoNotes records and transcribes on this device while listening is on.")
    }

    private var icon: String {
        if !isOn { return "power" }
        return isRecording ? "waveform" : "mic.fill"
    }

    private var label: String {
        if !isOn { return "Off" }
        return isRecording ? "Recording" : "Listening"
    }

    private var fill: some ShapeStyle {
        if !isOn {
            return AnyShapeStyle(Color(.secondarySystemBackground))
        }
        if isRecording {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.red, Color.pink],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [Color.accentColor, Color.purple],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }

    private var ringColor: Color { isRecording ? .red : .accentColor }

    private var shadowColor: Color {
        guard isOn else { return .black.opacity(0.08) }
        return (isRecording ? Color.red : Color.accentColor).opacity(0.35)
    }
}

#Preview("Off") {
    RecordToggleButton(isOn: false, isRecording: false, action: {})
}

#Preview("Listening") {
    RecordToggleButton(isOn: true, isRecording: false, action: {})
}

#Preview("Recording") {
    RecordToggleButton(isOn: true, isRecording: true, action: {})
}
