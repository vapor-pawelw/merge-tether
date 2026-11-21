import MergeTetherRemote
import SwiftUI
import UniformTypeIdentifiers

struct RemoteBoardOrderDrag: ViewModifier {
    static let type = UTType(exportedAs: "com.vaporpw.mergetether.remote-board-card", conformingTo: .data)

    let source: RemoteBoardOrderMove.Source
    let session: BoardDragSession<RemoteBoardOrderMove.Source>

    func body(content: Content) -> some View {
        content
            .contentShape([.interaction, .dragPreview], RoundedRectangle(cornerRadius: 16))
            .onDrag { session.begin(source, type: Self.type) }
            .accessibilityHint(Text(.Remote.remoteBoardReorder))
    }
}
