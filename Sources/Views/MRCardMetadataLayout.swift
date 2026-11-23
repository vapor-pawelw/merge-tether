import SwiftUI

struct MRCardContentSpacing: LayoutValueKey {
    static let defaultValue: CGFloat = 8
}

/// Lays out content independently of the trailing controls, with full width below them.
struct MRCardMetadataLayout: Layout {
    private struct Row {
        let top: CGFloat
        let proposal: ProposedViewSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return measure(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let controls = subviews.last else { return }
        let layout = measure(width: bounds.width, subviews: subviews)
        for (subview, row) in zip(subviews.dropLast(), layout.rows) {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + row.top),
                          anchor: .topLeading, proposal: row.proposal)
        }
        controls.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                       proposal: ProposedViewSize(layout.controls))
    }

    // The last subview is the control stack. The others are content rows in reading order.
    private func measure(width: CGFloat?, subviews: Subviews)
        -> (size: CGSize, rows: [Row], controls: CGSize) {
        let controls = subviews.last?.sizeThatFits(.unspecified) ?? .zero
        let clearance = controls.width > 0 ? controls.width + 16 : 0
        var bottom: CGFloat = 0
        var usedWidth = max(width ?? 0, controls.width)
        var rows: [Row] = []
        for subview in subviews.dropLast() {
            let top = bottom > 0 ? bottom + subview[MRCardContentSpacing.self] : 0
            let reservedWidth = top < controls.height ? clearance : 0
            let proposal = ProposedViewSize(width: width.map { max(0, $0 - reservedWidth) }, height: nil)
            let size = subview.sizeThatFits(proposal)
            rows.append(Row(top: top, proposal: proposal))
            if size.height > 0 {
                bottom = top + size.height
                usedWidth = max(usedWidth, size.width + reservedWidth)
            }
        }
        return (CGSize(width: usedWidth, height: max(bottom, controls.height)), rows, controls)
    }
}

struct MRCardStatusLayout<CardContent: View, Controls: View>: ViewModifier {
    let cardContent: CardContent
    let controls: Controls

    func body(content: Content) -> some View {
        MRCardMetadataLayout {
            cardContent
            content
            controls.zIndex(1)
        }
    }
}

/// Measures the reference to its last baseline so font padding does not add to the title gap.
struct MRCardReferenceLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let reference = subviews[0].dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: reference.width, height: reference[.lastTextBaseline])
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
