import SwiftUI
import SwiftData

/// Card stack for naming new voices: the top card is interactive, the next
/// two peek out behind it. Swipe left (or "Skip") to send a card to the back
/// of the queue; naming happens through the card's own controls.
struct ReviewQueueView: View {
    let items: [SpeakerReviewItem]
    let speakers: [Speaker]

    /// Cards the user swiped past this visit; they stay pending but sink to
    /// the back of the stack.
    @State private var skippedIDs: [UUID] = []
    @State private var dragOffset: CGSize = .zero

    private var ordered: [SpeakerReviewItem] {
        // O(n): skippedIDs is already in skip order; recomputed every drag
        // frame, so it must stay cheap.
        let skippedSet = Set(skippedIDs)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return items.filter { !skippedSet.contains($0.id) } + skippedIDs.compactMap { byID[$0] }
    }

    var body: some View {
        ZStack {
            ForEach(Array(ordered.prefix(3).enumerated().reversed()), id: \.element.id) { depth, item in
                SpeakerReviewCardView(
                    item: item,
                    speakers: speakers,
                    isTop: depth == 0,
                    onSkip: { skip(item) }
                )
                .scaleEffect(1 - CGFloat(depth) * 0.04)
                .offset(y: CGFloat(depth) * 10)
                .offset(depth == 0 ? dragOffset : .zero)
                .rotationEffect(depth == 0 ? .degrees(dragOffset.width / 24) : .zero)
                .allowsHitTesting(depth == 0)
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(width: value.translation.width, height: 0)
                }
                .onEnded { value in
                    if abs(value.translation.width) > 110, let top = ordered.first {
                        skip(top)
                    }
                    withAnimation(.snappy) { dragOffset = .zero }
                }
        )
        .animation(.snappy, value: ordered.map(\.id))
    }

    private func skip(_ item: SpeakerReviewItem) {
        guard ordered.count > 1 else { return }
        withAnimation(.snappy) {
            skippedIDs.removeAll { $0 == item.id }
            skippedIDs.append(item.id)
        }
    }
}
