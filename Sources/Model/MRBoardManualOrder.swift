import Foundation

enum MRBoardOrderingMethod: String {
    case manual, automatic
}

/// Saved positions and the last observed attention status belong to each authenticated MR.
struct MRBoardManualOrder: Codable, Equatable {
    typealias Target = MRAutomationScope.Target

    struct Group: Hashable {
        let reviewing: Bool
        let automationEnabled: Bool
        let pinned: Bool
    }

    struct Entry {
        let target: Target
        let group: Group
        let needsAttention: Bool
        /// A review that just arrived in Reviewing; it stays in the active block until the user acts on it.
        var isNew = false
    }

    private struct Card: Codable, Equatable {
        let target: Target
        var needsAttention: Bool
    }

    private var cards: [Card] = []

    func ranked(_ entries: [Entry]) -> [Entry] {
        let positions = Dictionary(cards.enumerated().map { ($0.element.target, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        func rank(_ entry: Entry) -> (Int, Int, Int, Int, Int) {
            ((entry.group.automationEnabled || entry.isNew) ? 0 : 1, entry.group.pinned ? 0 : 1,
             positions[entry.target] ?? Int.max, entry.target.projectID, entry.target.iid ?? 0)
        }
        return entries.sorted { rank($0) < rank($1) }
    }

    mutating func observe(_ entries: [Entry], promotesAttention: Bool) {
        let previous = Dictionary(cards.map { ($0.target, $0.needsAttention) },
            uniquingKeysWith: { first, _ in first })
        appendNewCards(entries)
        let current = Dictionary(entries.map { ($0.target, $0.needsAttention) },
            uniquingKeysWith: { first, _ in first })
        for index in cards.indices {
            if let needsAttention = current[cards[index].target] {
                cards[index].needsAttention = needsAttention
            }
        }

        guard promotesAttention else { return }
        let promoted = Set(entries.filter { $0.needsAttention && previous[$0.target] != true }.map(\.target))
        guard !promoted.isEmpty else { return }
        // Each group reads only its own cards from this list, so peers in other groups retain their order.
        cards = cards.filter { promoted.contains($0.target) } + cards.filter { !promoted.contains($0.target) }
    }

    mutating func move(_ source: Target, to destination: Target, in entries: [Entry]) -> Bool {
        guard source != destination, source.host == destination.host, source.username == destination.username,
              let dragged = entries.first(where: { $0.target == source }),
              let droppedOn = entries.first(where: { $0.target == destination }),
              dragged.group == droppedOn.group else { return false }

        appendNewCards(entries)
        guard let start = cards.firstIndex(where: { $0.target == source }),
              let end = cards.firstIndex(where: { $0.target == destination }) else { return false }
        let card = cards.remove(at: start)
        cards.insert(card, at: end)
        return true
    }

    /// Arrivals go below the cards that already need attention, on top of everything else.
    private mutating func appendNewCards(_ entries: [Entry]) {
        var known = Set(cards.map(\.target))
        var arrivals: [Card] = []
        var others: [Card] = []
        for entry in entries where known.insert(entry.target).inserted {
            let card = Card(target: entry.target, needsAttention: entry.needsAttention)
            if entry.isNew { arrivals.append(card) } else { others.append(card) }
        }
        let top = cards.firstIndex { !$0.needsAttention } ?? cards.count
        cards.insert(contentsOf: arrivals, at: top)
        cards.append(contentsOf: others)
    }
}
