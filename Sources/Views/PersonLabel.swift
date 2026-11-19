import SwiftUI
#if os(iOS)
import ImageIO
#endif

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
                        .underline(pattern: .dot)
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
    @State private var loaded: (url: URL, image: UIImage)?
    #endif

    var body: some View {
        #if os(macOS)
        AvatarView(url: url, size: size)
        #else
        Group {
            if let loaded, loaded.url == url {
                Image(uiImage: loaded.image).resizable().scaledToFill()
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
        .task(id: url) {
            guard let url, PersonIdentity(name: nil, username: nil, avatarURL: url).hasAvatar else {
                loaded = nil; return
            }
            let image = await PhoneAvatarCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loaded = image.map { (url, $0) }
        }
        #endif
    }
}

#if os(iOS)
@MainActor private final class PhoneAvatarCache {
    static let shared = PhoneAvatarCache()
    private let images = NSCache<NSURL, UIImage>()
    private let failures = NSCache<NSURL, NSDate>()
    private var requests: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        images.countLimit = 256
        failures.countLimit = 256
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url as NSURL
        if let image = images.object(forKey: key) { return image }
        if let until = failures.object(forKey: key) as Date?, until > .now { return nil }
        if let request = requests[url] { return await request.value }

        let request = Task { [session] () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= 4 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 120
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
        requests[url] = request
        let image = await request.value
        requests[url] = nil
        if let image { images.setObject(image, forKey: key) }
        else { failures.setObject(Date.now.addingTimeInterval(60) as NSDate, forKey: key) }
        return image
    }
}
#endif
