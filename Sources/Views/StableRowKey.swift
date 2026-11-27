import Foundation

/// Identity for rows in a dynamic ForEach, keyed by the model's real ID so per-row state
/// survives insertions and removals above. Missing or repeated IDs fall back to a
/// position counted among the fallback rows only, which cannot collide with real IDs.
enum StableRowKey: Hashable {
    case id(Int)
    case position(Int)

    struct Row<Element> {
        let index: Int
        let key: StableRowKey
        let element: Element
    }

    static func rows<Element>(_ elements: [Element], id: (Element) -> Int?) -> [Row<Element>] {
        var seen = Set<Int>()
        var fallbackCount = 0
        return elements.enumerated().map { index, element in
            if let value = id(element), seen.insert(value).inserted {
                return Row(index: index, key: .id(value), element: element)
            }
            defer { fallbackCount += 1 }
            return Row(index: index, key: .position(fallbackCount), element: element)
        }
    }
}

extension StableRowKey.Row: Identifiable {
    var id: StableRowKey { key }
}
