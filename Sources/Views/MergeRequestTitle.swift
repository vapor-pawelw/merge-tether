import SwiftUI

/// A draft remains identifiable even when its title is truncated or omits "Draft:".
struct MergeRequestTitle: View {
    let title: String
    let isDraft: Bool
    var lineLimit: Int? = 2
    var font: Font = .subheadline.weight(.semibold)
    var titleColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title)
                .font(font)
                .foregroundStyle(isDraft ? Color.secondary : titleColor)
                .multilineTextAlignment(.leading)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isDraft {
                Text(.Menu.menuMrDraftBadge)
                    .font(.caption2.weight(.bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(.secondary.opacity(0.3), lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }
}
