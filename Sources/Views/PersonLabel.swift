import SwiftUI
import MergeTetherRemote

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
    var messageName: String? { trimmedName ?? handle }

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

private struct GitLabPersonSourceURLKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var gitLabPersonSourceURL: URL? {
        get { self[GitLabPersonSourceURLKey.self] }
        set { self[GitLabPersonSourceURLKey.self] = newValue }
    }
}

/// Avatar and display name with GitLab identity details on hover or tap.
struct PersonLabel: View {
    let person: PersonIdentity
    var avatarSize: CGFloat = 16
    var showsAvatar = true
    var showsHandleWhenUnnamed = false
    /// Shown when GitLab returned neither a name nor a username.
    var fallback: Text? = nil
    var contentOpacity = 1.0

    @Environment(\.gitLabPersonSourceURL) private var sourceURL
    @State private var showsHandle = false

    private var profileURL: URL? {
        RemotePerson(name: person.name, username: person.username).profileURL(on: sourceURL)
    }

    var body: some View {
        if let name = person.displayName {
            labeled(name)
        } else if let fallback {
            HStack(spacing: 5) {
                if showsAvatar { PersonAvatar(url: nil, size: avatarSize).accessibilityHidden(true) }
                fallback
            }
            .opacity(contentOpacity)
        }
    }

    private func content(_ name: String) -> some View {
        HStack(spacing: 5) {
            if showsAvatar { PersonAvatar(url: person.avatarURL, size: avatarSize, initials: person.initials).accessibilityHidden(true) }
            Text(verbatim: showsHandleWhenUnnamed ? person.messageName ?? name : name).lineLimit(1)
        }
        .opacity(contentOpacity)
    }

    @ViewBuilder private func labeled(_ name: String) -> some View {
        #if os(macOS)
        Group {
            if let profileURL {
                Link(destination: profileURL) { content(name).foregroundStyle(Color.accentColor) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
                    .accessibilityHint(Text(.Board.boardPersonOpenProfile))
            } else {
                content(name)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: person.accessibilityName ?? name))
            }
        }
            .contentShape(Rectangle())
            .onHover { showsHandle = $0 && person.handle != nil }
            .popover(isPresented: $showsHandle, arrowEdge: .bottom) {
                if let handle = person.handle { handlePopover(name, handle: handle) }
            }
        #else
        if let handle = person.handle {
            Button { showsHandle = true } label: {
                content(name).foregroundStyle(Color.accentColor)
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
                #if os(iOS)
                if let profileURL {
                    Link(destination: profileURL) {
                        Label { Text(verbatim: handle) } icon: { Image(systemName: "arrow.up.right.square") }
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 44)
                    }
                    .font(.callout.monospaced())
                    .accessibilityHint(Text(.Board.boardPersonOpenProfile))
                } else {
                    handleText(handle)
                }
                #else
                handleText(handle)
                #endif
            }
        }
        .foregroundStyle(Color.primary)
        .padding(14)
    }

    private func handleText(_ handle: String) -> some View {
        Text(verbatim: handle).font(.callout.monospaced()).foregroundStyle(Color.secondary)
            .textSelection(.enabled)
    }
}

extension PersonIdentity {
    init(_ remote: RemotePerson) {
        self.init(name: remote.name, username: remote.username, avatarURL: remote.avatarURL)
    }
}

extension RemotePeopleMessage {
    init?(_ prefix: LocalizedStringResource, people: [PersonIdentity]) {
        guard !people.isEmpty else { return nil }
        self.init(prefix: String(localized: prefix),
                  people: people.prefix(2).map { .init(name: $0.name, username: $0.normalizedUsername, avatarURL: $0.avatarURL) },
                  remainingCount: max(0, people.count - 2))
    }

    fileprivate var conjunction: String { String(localized: .Board.boardPeopleAnd) }
    fileprivate var others: String { String(localized: .Board.boardPeopleOthers(remainingCount)) }

    var resource: LocalizedStringResource {
        let names = people.prefix(2).compactMap { PersonIdentity($0).messageName }
        let list = if remainingCount > 0 { names.joined(separator: ", ") + " " + others }
            else { names.joined(separator: " " + conjunction + " ") }
        return .Board.boardPeopleMessage(prefix, list)
    }

    var text: String { String(localized: resource) }
}

struct PeopleMessageLabel: View {
    let message: RemotePeopleMessage

    var body: some View {
        StatusFlowLayout(spacing: 4) {
            Text(verbatim: message.prefix).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(message.people.prefix(2).enumerated()), id: \.offset) { index, person in
                HStack(spacing: index == 0 ? 0 : 4) {
                    if index == 1, message.remainingCount == 0 { Text(verbatim: message.conjunction) }
                    PersonLabel(person: .init(person), showsAvatar: false, showsHandleWhenUnnamed: true)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                    if index == 0, message.remainingCount > 0 { Text(verbatim: ",") }
                }
            }
            if message.remainingCount > 0 { Text(verbatim: message.others) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct WaitingPeopleLabel: View {
    let message: RemotePeopleMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 14)
                .accessibilityHidden(true)
            PeopleMessageLabel(message: message)
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
