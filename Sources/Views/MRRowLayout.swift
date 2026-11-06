import SwiftUI

enum MRRowLayout {
    static let listInset: CGFloat = 14
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 10
    static let accessorySize: CGFloat = 24
}

extension View {
    func mrRowContentPadding() -> some View {
        padding(.horizontal, MRRowLayout.horizontalInset)
            .padding(.vertical, MRRowLayout.verticalInset)
    }

    /// Different-sized symbols share a visible trailing edge and a full hit area.
    func mrRowAccessoryFrame() -> some View {
        frame(width: MRRowLayout.accessorySize, height: MRRowLayout.accessorySize, alignment: .topTrailing)
    }
}
