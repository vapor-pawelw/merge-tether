import SwiftUI

/// Uses the reference's last baseline for vertical spacing while retaining the controls' full hit areas.
struct MRCardMetadataLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let row = measure(width: width, subviews: subviews)
        let contentWidth = row.reference.width + row.spacing + row.controls.width
        return CGSize(width: max(width ?? 0, contentWidth),
                      height: row.reference.width > 0 ? row.reference[.lastTextBaseline] : row.controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = measure(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                         proposal: row.referenceProposal)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                         proposal: ProposedViewSize(row.controls))
    }

    private func measure(width: CGFloat?, subviews: Subviews)
        -> (reference: ViewDimensions, referenceProposal: ProposedViewSize, controls: CGSize, spacing: CGFloat) {
        let controls = subviews[1].sizeThatFits(.unspecified)
        let spacing: CGFloat = controls.width > 0 ? 16 : 0
        let referenceProposal = ProposedViewSize(width: width.map { max(0, $0 - controls.width - spacing) }, height: nil)
        return (subviews[0].dimensions(in: referenceProposal), referenceProposal, controls, spacing)
    }
}
