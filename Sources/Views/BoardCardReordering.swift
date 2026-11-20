import SwiftUI
import UniformTypeIdentifiers

struct BoardCardDrag: Codable, Transferable {
    let target: MRAutomationScope.Target
    let accountRevision: UInt64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.vaporpw.mergetether.board-card", conformingTo: .data))
            .visibility(.ownProcess)
    }
}

struct BoardCardReorderInteraction: ViewModifier {
    let drag: BoardCardDrag
    let monitor: TodoMonitorService
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        content
            .contentShape([.interaction, .dragPreview], shape)
            .draggable(drag)
            .accessibilityHint(Text(.BoardActivity.reorderCard))
            .overlay {
                if isTargeted {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: BoardCardDrag.self) { dragged, _ in
                guard dragged.count == 1, let card = dragged.first else { return false }
                return monitor.moveBoardCard(card.target, to: drag.target, accountRevision: card.accountRevision)
            } isTargeted: {
                isTargeted = $0
            }
    }
}
