import AppKit
import SwiftUI

/// A containing sheet must release Escape while a child popover owns dismissal.
struct BoardDetailPopoverPresentedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

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
    var onClick: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            BoardCardActionIcon(systemName: "ellipsis")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .background {
            if let onClick {
                BoardMenuTracking(action: onClick).allowsHitTesting(false)
            }
        }
        .boardHeaderControlHover()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
        .help(Text(.CommandCenter.commandCenterActions))
        .controlSize(.small)
    }
}

/// Wait for the native menu to close so marking a card seen cannot remove the menu's anchor in the New filter.
private struct BoardMenuTracking: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.observeMenus()
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class Anchor: NSView {
        var action: (() -> Void)?
        private weak var openedMenu: NSMenu?

        func observeMenus() {
            NotificationCenter.default.addObserver(self, selector: #selector(menuOpened(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(menuClosed(_:)),
                name: NSMenu.didEndTrackingNotification, object: nil)
        }

        @objc private func menuOpened(_ notification: Notification) {
            guard let window, let event = NSApp.currentEvent,
                  event.type == .leftMouseDown || event.type == .leftMouseUp,
                  event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return }
            openedMenu = notification.object as? NSMenu
        }

        @objc private func menuClosed(_ notification: Notification) {
            guard let openedMenu, notification.object as? NSMenu === openedMenu else { return }
            self.openedMenu = nil
            action?()
        }
    }
}

/// The background exposes a keyboard action; the fallback tap also covers static text.
private struct BoardCardInteraction: ViewModifier {
    let background: Color?
    let backgroundOpacity: Double
    let detailsLabel: LocalizedStringResource
    let onDetails: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background {
                Button(action: onDetails) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background ?? Color(white: dark ? 0.095 : 0.99))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHovered ? Color.primary.opacity(dark ? 0.02 : 0.045) : Color.clear)
                        }
                        .opacity(backgroundOpacity)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(detailsLabel))
            }
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onDetails)
    }
}

extension View {
    func boardHeaderControlHover() -> some View {
        modifier(BoardHeaderControlHover())
    }

    func boardCardInteraction(title: String, repositoryPath: String, iid: Int? = nil,
                              background: Color? = nil, backgroundOpacity: Double = 1,
                              onDetails: @escaping () -> Void) -> some View {
        let reference = iid.map { "\(repositoryPath) !\($0)" } ?? repositoryPath
        return modifier(BoardCardInteraction(background: background, backgroundOpacity: backgroundOpacity,
            detailsLabel: .Board.boardDetailsFor(title, reference), onDetails: onDetails))
    }
}

struct BoardItemDetailSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var detailPopoverPresented = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(.CommandCenter.commandCenterOverview).font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
                    .disabled(detailPopoverPresented)
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
        .interactiveDismissDisabled(detailPopoverPresented)
        .onPreferenceChange(BoardDetailPopoverPresentedKey.self) { detailPopoverPresented = $0 }
    }
}
