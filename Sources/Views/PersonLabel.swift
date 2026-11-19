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

    var initials: String? {
        guard let displayName else { return nil }
        let words = displayName.split(whereSeparator: \.isWhitespace)
        let letters = words.count > 1 ? [words.first?.first, words.last?.first].compactMap { $0 } : Array(displayName.prefix(2))
        return String(letters).uppercased()
    }
}

/// Avatar and display name. macOS reveals the @username on hover; iOS on tap, styled as a link.
struct PersonLabel: View {
    let person: PersonIdentity
    var avatarSize: CGFloat = 16
    var showsAvatar = true
    /// Shown when GitLab returned neither a name nor a username.
    var fallback: Text? = nil

    @State private var showsHandle = false

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
            if showsAvatar { PersonAvatar(url: person.avatarURL, size: avatarSize, initials: person.initials).accessibilityHidden(true) }
            Text(verbatim: name).lineLimit(1)
        }
    }

    @ViewBuilder private func labeled(_ name: String) -> some View {
        #if os(macOS)
        content(name)
            .contentShape(Rectangle())
            .onHover { showsHandle = $0 && person.handle != nil }
            .popover(isPresented: $showsHandle, arrowEdge: .bottom) {
                if let handle = person.handle { handlePopover(name, handle: handle) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
        #else
        if let handle = person.handle {
            Button { showsHandle = true } label: {
                HStack(spacing: 5) {
                    if showsAvatar { PersonAvatar(url: person.avatarURL, size: avatarSize, initials: person.initials).accessibilityHidden(true) }
                    Text(verbatim: name).lineLimit(1)
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
            .accessibilityHint(Text(.Board.boardPersonUsernameHint))
            .popover(isPresented: $showsHandle) {
                handlePopover(name, handle: handle)
                .presentationCompactAdaptation(.popover)
            }
        } else {
            content(name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: name))
        }
        #endif
    }

    private func handlePopover(_ name: String, handle: String) -> some View {
        HStack(spacing: 10) {
            PersonAvatar(url: person.avatarURL, size: 36, initials: person.initials).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.headline)
                Text(verbatim: handle).font(.callout.monospaced()).foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(Color.primary)
        .padding(14)
    }
}

struct ThreadResolutionWaitLabel: View {
    let people: [PersonIdentity]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 14)
                .accessibilityHidden(true)
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.AuthorFeedback.authorFeedbackThreadResolutionWait)
                .fixedSize(horizontal: false, vertical: true)
            StatusFlowLayout(spacing: 6) {
                ForEach(people.prefix(3), id: \.self) { person in
                    PersonLabel(person: person, avatarSize: 14)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
                if people.count > 3 {
                    Text(.AuthorFeedback.authorFeedbackThreadResolutionPeopleMore(people.count - 3))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Circular avatar with a neutral placeholder for missing or unreachable images.
struct PersonAvatar: View {
    let url: URL?
    var size: CGFloat = 16
    var initials: String? = nil
    #if os(iOS)
    @Environment(\.remoteAvatarThumbnails) private var remoteThumbnails
    private var remoteThumbnail: UIImage? {
        guard let url, let data = remoteThumbnails[url] else { return nil }
        return UIImage(data: data)
    }
    #endif

    var body: some View {
        #if os(macOS)
        AvatarView(url: url, size: size)
        #else
        let thumbnail = remoteThumbnail
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else if let initials {
                Text(verbatim: initials).font(.system(size: size * 0.42, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.14))
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        #endif
    }
}

#if os(iOS)
private struct RemoteAvatarThumbnailsKey: EnvironmentKey {
    static let defaultValue: [URL: Data] = [:]
}

extension EnvironmentValues {
    var remoteAvatarThumbnails: [URL: Data] {
        get { self[RemoteAvatarThumbnailsKey.self] }
        set { self[RemoteAvatarThumbnailsKey.self] = newValue }
    }
}
#endif
