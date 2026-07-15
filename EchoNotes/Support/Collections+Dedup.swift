import Foundation

extension Array where Element: Hashable {
    /// Order-preserving de-duplication. Used on model-generated lists (tags,
    /// key points, action items) because SwiftUI `ForEach(id: \.self)` breaks
    /// on duplicate values.
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
