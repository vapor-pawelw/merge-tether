import SwiftUI

struct StatusFlowLayout: Layout {
    var spacing: CGFloat = 7
    var centerRows = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowStart = 0
        var usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        func alignRow() {
            if centerRows {
                for index in rowStart..<frames.count {
                    frames[index].origin.y += (rowHeight - frames[index].height) / 2
                }
            }
            rowStart = frames.count
        }
        for subview in subviews {
            let size = subview.sizeThatFits(width.isFinite ? ProposedViewSize(width: width, height: nil) : .unspecified)
            if x > 0, x + size.width > width {
                alignRow()
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        alignRow()
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
