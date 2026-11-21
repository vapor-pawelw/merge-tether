import MergeTetherRemote
import SwiftUI
import UniformTypeIdentifiers

/// The source stays in this board. The pasteboard only advertises an app-local drag.
@MainActor final class BoardDragSession<Source> {
    private(set) var source: Source?

    func begin(_ source: Source, type: UTType) -> NSItemProvider {
        self.source = source
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data("board-card".utf8), nil)
            return nil
        }
        return provider
    }

    func finish() { source = nil }
}

struct BoardInsertionDrop: ViewModifier {
    let type: UTType
    var fixedInsertion: BoardOrderInsertion? = nil
    let allows: (BoardOrderInsertion) -> Bool
    let move: (BoardOrderInsertion) -> Bool
    @State private var insertion: BoardOrderInsertion?
    @State private var height: CGFloat = 0
    private var lineAlignment: Alignment {
        fixedInsertion == .before || (fixedInsertion == nil && insertion == .after) ? .bottom : .top
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: lineAlignment) {
                if let insertion, allows(insertion) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [type], delegate: InsertionDelegate(
                type: type, insertion: $insertion, position: { location in
                    fixedInsertion ?? (location < height / 2 ? .before : .after)
                }, allows: allows, move: move))
    }
}

private struct InsertionDelegate: DropDelegate {
    let type: UTType
    @Binding var insertion: BoardOrderInsertion?
    let position: (CGFloat) -> BoardOrderInsertion
    let allows: (BoardOrderInsertion) -> Bool
    let move: (BoardOrderInsertion) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [type]) && (allows(.before) || allows(.after))
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposed = position(info.location.y)
        insertion = allows(proposed) ? proposed : nil
        return DropProposal(operation: insertion == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        insertion = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        insertion = nil
        let proposed = position(info.location.y)
        return info.hasItemsConforming(to: [type]) && allows(proposed) && move(proposed)
    }
}
