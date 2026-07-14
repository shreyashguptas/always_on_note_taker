import SwiftUI

/// Live transcript of the in-flight session: finalized text in primary color,
/// the current volatile guess dimmed, auto-scrolled to the newest words.
struct LiveTranscriptView: View {
    let finalizedText: String
    let volatileText: String

    private let bottomAnchor = "live-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    (Text(finalizedText)
                        + Text(finalizedText.isEmpty || volatileText.isEmpty ? "" : " ")
                        + Text(volatileText).foregroundStyle(.secondary))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(14)
            }
            .onChange(of: finalizedText) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: volatileText) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            Label("Live transcript", systemImage: "text.quote")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.thinMaterial, in: .capsule)
                .padding(6)
        }
    }
}

#Preview {
    LiveTranscriptView(
        finalizedText: "Okay so the plan for Saturday is to leave around nine.",
        volatileText: "and grab breakfast on the"
    )
    .frame(height: 160)
    .padding()
}
