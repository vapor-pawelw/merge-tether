import SwiftUI

struct MRDetailStatusCard: ViewModifier {
    var isPresented = true

    func body(content: Content) -> some View {
        if isPresented {
            content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.secondary.opacity(0.15), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

#if os(macOS)
struct MRDetailDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MRDetailDisclosureButton(isExpanded: configuration.$isExpanded) { configuration.label }
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct MRDetailDisclosureButton<Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 9)
                    .accessibilityHidden(true)
                label()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isExpanded ? .MRDiscussions.mrDiscussionsExpanded : .MRDiscussions.mrDiscussionsCollapsed))
    }
}
#endif
