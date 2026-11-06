import SwiftUI

/// A single text flow lets the title keep its width while repository context wraps with it.
struct BoardCardTitle: View {
    let title: String
    let repositoryPath: String
    var font: Font = .callout.weight(.semibold)
    var titleColor: Color = .primary

    private var repositoryName: String {
        repositoryPath.split(separator: "/").last.map(String.init) ?? repositoryPath
    }

    var body: some View {
        let titleText = Text(verbatim: title).font(font).foregroundStyle(titleColor)
        let repositoryText = Text(verbatim: repositoryName).font(.caption).foregroundStyle(Color.accentColor)
        (titleText + Text(verbatim: repositoryName.isEmpty ? "" : "  ") + repositoryText)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: "\(title)\n\(repositoryPath)"))
            .accessibilityLabel(Text(verbatim: "\(title), \(repositoryPath)"))
    }
}

struct BoardRepositoryFooter: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(Text(verbatim: path))
    }
}

struct BoardMRIdentifier: View {
    let iid: Int

    var body: some View {
        Text(verbatim: "!\(iid)")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            .accessibilityLabel(Text(.Board.boardMergeRequestNumber(iid)))
    }
}

struct BoardDraftBadge: View {
    var body: some View {
        Text(.Menu.menuMrDraftBadge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.secondary.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

struct BoardCardAuthor: View {
    let author: Todo.Author
    var roleLabel: LocalizedStringResource? = .ReviewingContext.reviewingAuthorLabel

    private var accessibilityLabel: Text {
        let identity = Text(verbatim: "\(author.name) (@\(author.username))")
        guard let roleLabel else { return identity }
        return Text(roleLabel) + Text(verbatim: ": ") + identity
    }

    var body: some View {
        HStack(spacing: 4) {
            AvatarView(url: author.avatarURL, size: 16).accessibilityHidden(true)
            Text(verbatim: "@\(author.username)").lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(Text(verbatim: "\(author.name) (@\(author.username))"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
