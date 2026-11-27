import SwiftUI

struct MRCardContentSpacing: LayoutValueKey {
    static let defaultValue: CGFloat = 8
}

/// Places the card's heading, people and controls, then gives each status row the width available at its height.
struct MRCardMetadataLayout: Layout {
    var referenceToTitleSpacing: CGFloat = 10
    var titleToPeopleSpacing: CGFloat = 10
    var keepsBadgesUnderActions = false
    var alignsActionsAtTop = false
    var placesTitleBelowActions = false

    private let controlsClearance: CGFloat = 16
    private let badgeSpacing: CGFloat = 8

    private struct Placement {
        let index: Int
        let x: CGFloat
        let top: CGFloat
        let proposal: ProposedViewSize
        var trailing = false

        func place(in bounds: CGRect, subviews: LayoutSubviews) {
            subviews[index].place(
                at: CGPoint(x: (trailing ? bounds.maxX : bounds.minX) + x, y: bounds.minY + top),
                anchor: trailing ? .topTrailing : .topLeading, proposal: proposal)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        return measure(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for placement in measure(width: bounds.width, subviews: subviews).placements {
            placement.place(in: bounds, subviews: subviews)
        }
    }

    // The first five subviews are the reference, title, people, actions and badges respectively.
    // The remaining subviews are status rows in reading order.
    private func measure(width: CGFloat?, subviews: Subviews) -> (size: CGSize, placements: [Placement]) {
        let referenceIndex = 0
        let titleIndex = 1
        let peopleIndex = 2
        let actionsIndex = 3
        let badgesIndex = 4
        let actions = subviews[actionsIndex].sizeThatFits(.unspecified)
        let badges = subviews[badgesIndex].dimensions(in: .unspecified)
        let badgeSize = CGSize(width: badges.width, height: badges.height)
        let hasBadges = badges.width > 0 && badges.height > 0
        let hasActions = actions.width > 0 && actions.height > 0
        let actionReserve = hasActions ? actions.width + controlsClearance : 0
        let idealReferenceWidth = subviews[referenceIndex].sizeThatFits(.unspecified).width
        let inlineWidth = idealReferenceWidth + badgeSpacing + badges.width + actionReserve
        let badgesInline = hasBadges && !keepsBadgesUnderActions && (width.map { inlineWidth <= $0 } ?? true)
        let badgesTrailing = hasBadges && !badgesInline

        func proposedWidth(reserving reserved: CGFloat = 0) -> ProposedViewSize {
            ProposedViewSize(width: width.map { max(0, $0 - reserved) }, height: nil)
        }

        let earlyBadgeReserve = badgesTrailing && keepsBadgesUnderActions ? badges.width + controlsClearance : 0
        let referenceReserve = max(actionReserve, earlyBadgeReserve)
        let referenceProposal = proposedWidth(reserving: referenceReserve + (badgesInline ? badgeSpacing + badges.width : 0))
        let reference = subviews[referenceIndex].dimensions(in: referenceProposal)
        let actionsTop = alignsActionsAtTop ? 0 : (reference.height - actions.height) / 2
        let actionsBottom = hasActions ? actionsTop + actions.height : 0
        let earlyBadgeTop = hasActions ? actionsBottom + 4 : 0
        let earlyBadgeBottom = earlyBadgeReserve > 0 ? earlyBadgeTop + badges.height : 0

        // The reference baseline and the gap below the title compensate for the text line boxes.
        let preferredTitleTop = reference.height > 0 ? reference[.lastTextBaseline] + referenceToTitleSpacing : 0
        let titleTop = placesTitleBelowActions ? max(preferredTitleTop, actionsBottom) : preferredTitleTop
        let titleReserve = max(titleTop < actionsBottom ? actionReserve : 0,
                               titleTop < earlyBadgeBottom ? earlyBadgeReserve : 0)
        let titleProposal = proposedWidth(reserving: titleReserve)
        let title = subviews[titleIndex].sizeThatFits(titleProposal)

        let peopleTop = titleTop + title.height + titleToPeopleSpacing
        let peopleReserve = peopleTop < earlyBadgeBottom ? earlyBadgeReserve : 0
        let peopleProposal = proposedWidth(reserving: peopleReserve)
        let people = subviews[peopleIndex].sizeThatFits(peopleProposal)
        let peopleBottom = peopleTop + people.height
        let badgeTop = badgesInline ? reference[.firstTextBaseline] - badges[.firstTextBaseline]
            : keepsBadgesUnderActions ? earlyBadgeTop : peopleBottom + 4
        let badgesBottom = hasBadges ? badgeTop + badges.height : 0

        var placements = [
            Placement(index: referenceIndex, x: 0, top: 0, proposal: referenceProposal),
            Placement(index: titleIndex, x: 0, top: titleTop, proposal: titleProposal),
            Placement(index: peopleIndex, x: 0, top: peopleTop, proposal: peopleProposal),
            Placement(index: actionsIndex, x: 0, top: actionsTop, proposal: ProposedViewSize(actions), trailing: true)
        ]
        if hasBadges {
            placements.append(Placement(index: badgesIndex, x: badgesInline ? reference.width + badgeSpacing : 0,
                                        top: badgeTop, proposal: ProposedViewSize(badgeSize), trailing: badgesTrailing))
        }

        let referenceWidth = reference.width + referenceReserve + (badgesInline ? badgeSpacing + badges.width : 0)
        var usedWidth = max(width ?? 0, referenceWidth, title.width + titleReserve, people.width + peopleReserve, badges.width)
        var bottom = people.height > 0 ? peopleBottom : titleTop + title.height
        var firstStatus = true
        for index in subviews.indices.dropFirst(5) {
            let row = subviews[index]
            let spacing = max(firstStatus ? 16 : 0, row[MRCardContentSpacing.self])
            let top = bottom + spacing
            let badgeReserve = badgesTrailing && top < badgesBottom ? badges.width + controlsClearance : 0
            let reserve = max(top < actionsBottom ? actionReserve : 0, badgeReserve)
            let proposal = proposedWidth(reserving: reserve)
            let size = row.sizeThatFits(proposal)
            placements.append(Placement(index: index, x: 0, top: top, proposal: proposal))
            if size.height > 0 {
                firstStatus = false
                bottom = top + size.height
                usedWidth = max(usedWidth, size.width + reserve)
            }
        }
        return (CGSize(width: usedWidth, height: max(bottom, actionsBottom, badgesBottom)), placements)
    }
}

struct MRCardStatusLayout<Heading: View, Status: View>: ViewModifier {
    let heading: Heading
    let status: Status

    func body(content: Content) -> some View {
        MRCardMetadataLayout {
            heading
            status
            content
        }
    }
}
