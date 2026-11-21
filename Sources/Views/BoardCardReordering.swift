import MergeTetherRemote
import UniformTypeIdentifiers

struct BoardCardDrag {
    static let type = UTType(exportedAs: "com.vaporpw.mergetether.board-card", conformingTo: .data)

    let entry: MRBoardManualOrder.Entry
    let accountRevision: UInt64

    func destination(beside anchor: MRAutomationScope.Target, insertion: BoardOrderInsertion,
                     in entries: [MRBoardManualOrder.Entry]) -> MRAutomationScope.Target? {
        guard entries.first(where: { $0.target == entry.target })?.group == entry.group else { return nil }
        let group = entries.filter { $0.group == entry.group }.map(\.target)
        return insertion.destination(moving: entry.target, beside: anchor, in: group)
    }
}
