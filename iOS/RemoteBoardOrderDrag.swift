import MergeTetherRemote
import SwiftUI
import UniformTypeIdentifiers

private struct RemoteBoardOrderDrag: Codable, Transferable {
    let source: RemoteBoardOrderMove.Source

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.vaporpw.mergetether.remote-board-card", conformingTo: .data))
            .visibility(.ownProcess)
    }
}

struct RemoteBoardOrderInteraction: ViewModifier {
    let card: RemoteCard
    let model: RemotePhoneModel
    let source: RemoteBoardOrderMove.Source
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        content
            .contentShape([.interaction, .dragPreview], shape)
            .draggable(RemoteBoardOrderDrag(source: source))
            .accessibilityHint(Text(.Remote.remoteBoardReorder))
            .overlay {
                if isTargeted {
                    shape.strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: RemoteBoardOrderDrag.self) { dragged, _ in
                guard dragged.count == 1, let source = dragged.first?.source, source.cardID != card.id else { return false }
                let move = RemoteBoardOrderMove(source: source, destinationID: card.id)
                Task { await model.moveBoardCard(move) }
                return true
            } isTargeted: {
                isTargeted = $0
            }
    }
}
