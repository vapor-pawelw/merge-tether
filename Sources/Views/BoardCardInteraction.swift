import SwiftUI

private struct BoardHeaderControlHover: ViewModifier {
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background(Color.accentColor.opacity(hovered && enabled ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct BoardActionsMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            BoardCardActionIcon(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .boardHeaderControlHover()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
        .help(Text(.CommandCenter.commandCenterActions))
        .controlSize(.small)
    }
}

/// The background exposes a keyboard action; the fallback tap also covers static text.
private struct BoardCardInteraction: ViewModifier {
    let onDetails: () -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                Button(action: onDetails) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(isHovered ? 0.045 : 0))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.Board.boardDetails))
            }
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onDetails)
    }
}

extension View {
    func boardHeaderControlHover() -> some View {
        modifier(BoardHeaderControlHover())
    }

    func boardCardInteraction(onDetails: @escaping () -> Void) -> some View {
        modifier(BoardCardInteraction(onDetails: onDetails))
    }
}

struct BoardItemDetailSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(.CommandCenter.commandCenterOverview).font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text(.CommandCenter.commandCenterClose))
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16, content: content)
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 440, idealHeight: 640)
    }
}
