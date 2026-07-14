import SwiftUI

/// Live mic level bars, mirrored around the vertical center like the system
/// Voice Memos waveform. Renders the coordinator's rolling `levels` buffer.
struct WaveformView: View {
    let levels: [Float]
    var active: Bool = true

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }
            let spacing: CGFloat = 3
            let barWidth = max(2, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let midY = size.height / 2

            for (index, level) in levels.enumerated() {
                let height = max(3, CGFloat(level) * size.height)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                let opacity = 0.35 + 0.65 * Double(index) / Double(count)
                context.fill(path, with: .color(barColor.opacity(active ? opacity : 0.25)))
            }
        }
        .accessibilityHidden(true)
    }

    private var barColor: Color { active ? .accentColor : .secondary }
}

#Preview {
    WaveformView(levels: (0..<60).map { _ in Float.random(in: 0.05...0.9) })
        .frame(height: 80)
        .padding()
}
