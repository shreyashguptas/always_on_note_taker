import SwiftUI

struct TagChipView: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .foregroundStyle(Color.accentColor)
    }
}

/// Simple wrapping row of tag chips.
struct TagChipsRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { TagChipView(tag: $0) }
        }
    }
}

#Preview {
    TagChipsRow(tags: ["standup", "beta", "release"])
        .padding()
}
