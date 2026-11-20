import MergeTetherRemote
import SwiftUI

struct MergeRequestDescription: View {
    let source: String?
    let title: LocalizedStringResource
    let expandHint: LocalizedStringResource
    let collapseHint: LocalizedStringResource
    @State private var isExpanded = false

    var body: some View {
        if let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                isExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title).font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(SafeInlineMarkdown.render(source) ?? AttributedString(source))
                        .font(.callout)
                        .lineSpacing(3)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(isExpanded ? collapseHint : expandHint))
            .accessibilityIdentifier("mr.description")
        }
    }
}
