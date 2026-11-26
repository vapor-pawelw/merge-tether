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
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            BoardCardActionIcon(systemName: "ellipsis")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .boardHeaderControlHover()
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
        .help(Text(.CommandCenter.commandCenterActions))
        .controlSize(.small)
    }
}

struct OpenInGitLabMenuLink: View {
    let url: URL
    var showsOptionClick = true

    var body: some View {
        let title: LocalizedStringResource = showsOptionClick
            ? .CommandCenter.commandCenterOpenGitLabOptionClick
            : .CommandCenter.commandCenterOpenGitLab
        Link(destination: url) {
            Label(title, systemImage: "arrow.up.right.square")
        }
    }
}

enum BoardCardActivation {
    @MainActor
    static func perform(gitLabURL: URL?, event: NSEvent? = NSApp.currentEvent,
                        openURL: OpenURLAction, onActivate: () -> Void) {
        if let gitLabURL, let event, event.type == .leftMouseUp, event.modifierFlags.contains(.option) {
            openURL(gitLabURL)
        } else {
            onActivate()
        }
    }
}

struct BoardCardButton<Label: View>: View {
    let gitLabURL: URL?
    let onActivate: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            BoardCardActivation.perform(gitLabURL: gitLabURL, openURL: openURL, onActivate: onActivate)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

/// The background exposes a keyboard action; the fallback tap also covers static text.
private struct BoardCardInteraction: ViewModifier {
    let gitLabURL: URL?
    let background: Color?
    let backgroundOpacity: Double
    let actionLabel: LocalizedStringResource
    let onActivate: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background {
                BoardCardButton(gitLabURL: gitLabURL, onActivate: onActivate) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background ?? Color(white: dark ? 0.095 : 0.99))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isHovered ? Color.primary.opacity(dark ? 0.02 : 0.045) : Color.clear)
                        }
                        .opacity(backgroundOpacity)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(Text(actionLabel))
            }
            .onHover { isHovered = $0 }
            .onTapGesture {
                BoardCardActivation.perform(gitLabURL: gitLabURL, openURL: openURL, onActivate: onActivate)
            }
    }
}

extension View {
    func boardHeaderControlHover() -> some View {
        modifier(BoardHeaderControlHover())
    }

    func boardCardInteraction(title: String, repositoryPath: String, iid: Int? = nil, gitLabURL: URL?,
                              background: Color? = nil, backgroundOpacity: Double = 1,
                              actionLabel: LocalizedStringResource? = nil,
                              onActivate: @escaping () -> Void) -> some View {
        let reference = iid.map { "\(repositoryPath) !\($0)" } ?? repositoryPath
        return modifier(BoardCardInteraction(gitLabURL: gitLabURL, background: background, backgroundOpacity: backgroundOpacity,
            actionLabel: actionLabel ?? .Board.boardDetailsFor(title, reference), onActivate: onActivate))
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
