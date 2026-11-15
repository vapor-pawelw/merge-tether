import SwiftUI

/// A GitLab person as the UI shows them: display name first, the @username only on request.
struct PersonIdentity: Equatable, Hashable, Sendable {
    var name: String?
    var username: String?
    var avatarURL: URL?

    init(name: String?, username: String?, avatarURL: URL? = nil) {
        self.name = name; self.username = username; self.avatarURL = avatarURL
    }

    private var trimmedName: String? {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// The GitLab username without a leading `@`.
    var normalizedUsername: String? {
        let value = String((username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }))
        return value.isEmpty ? nil : value
    }

    /// Falls back to the bare username when GitLab returned no display name.
    var displayName: String? { trimmedName ?? normalizedUsername }
    var handle: String? { normalizedUsername.map { "@" + $0 } }

    /// The display name followed by the handle, so assistive technologies keep both.
    var accessibilityName: String? {
        guard let displayName else { return handle }
        guard let handle, trimmedName != nil else { return displayName }
        return displayName + ", " + handle
    }

    var hasAvatar: Bool { avatarURL.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
}

/// Avatar and display name. macOS reveals the @username on hover; iOS on tap, styled as a link.
struct PersonLabel: View {
    let person: PersonIdentity
    var avatarSize: CGFloat = 16
    var showsAvatar = true
    /// Shown when GitLab returned neither a name nor a username.
    var fallback: Text? = nil

    #if os(iOS)
    @State private var showsHandle = false
    #endif

    var body: some View {
        if let name = person.displayName {
            labeled(name)
        } else if let fallback {
            HStack(spacing: 5) {
                if showsAvatar { PersonAvatar(url: nil, size: avatarSize).accessibilityHidden(true) }
                fallback
            }
        }
    }

    private func content(_ name: String) -> some View {
        HStack(spacing: 5) {
            if showsAvatar { PersonAvatar(url: person.avatarURL, size: avatarSize).accessibilityHidden(true) }
            Text(verbatim: name).lineLimit(1)
        }
    }

    @ViewBuilder private func labeled(_ name: String) -> some View {
        #if os(macOS)
        content(name)
            .help(Text(verbatim: person.handle ?? name))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
        #else
        if let handle = person.handle {
            Button { showsHandle = true } label: {
                HStack(spacing: 5) {
                    if showsAvatar { PersonAvatar(url: person.avatarURL, size: avatarSize).accessibilityHidden(true) }
                    Text(verbatim: name).lineLimit(1)
                        .foregroundStyle(.tint)
                        .underline(pattern: .dot)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
            .accessibilityHint(Text(.Board.boardPersonUsernameHint))
            .popover(isPresented: $showsHandle) {
                HStack(spacing: 10) {
                    PersonAvatar(url: person.avatarURL, size: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name).font(.headline)
                        Text(verbatim: handle).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        } else {
            content(name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: name))
        }
        #endif
    }
}

/// Circular avatar with a neutral placeholder for missing or unreachable images.
struct PersonAvatar: View {
    let url: URL?
    var size: CGFloat = 16

    var body: some View {
        #if os(macOS)
        AvatarView(url: url, size: size)
        #else
        AsyncImage(url: PersonIdentity(name: nil, username: nil, avatarURL: url).hasAvatar ? url : nil) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            // A concrete color, so the placeholder stays gray inside the tinted name button.
            else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Color.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        #endif
    }
}
