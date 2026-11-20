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

struct BoardCardReorderHandle: View {
    let drag: BoardCardDrag
    let title: String

    var body: some View {
        BoardCardActionIcon(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .draggable(drag) {
                Text(verbatim: title)
                    .font(.callout)
                    .lineLimit(1)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .help(Text(.BoardActivity.reorderCard))
            .accessibilityLabel(Text(.BoardActivity.reorderCard))
    }
}

struct BoardCardDropDestination: ViewModifier {
    let target: MRAutomationScope.Target
    let monitor: TodoMonitorService
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: BoardCardDrag.self) { dragged, _ in
                guard dragged.count == 1, let card = dragged.first else { return false }
                return monitor.moveBoardCard(card.target, to: target, accountRevision: card.accountRevision)
            } isTargeted: {
                isTargeted = $0
            }
    }
}
