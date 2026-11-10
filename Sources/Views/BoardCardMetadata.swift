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

struct BoardCardActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
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

struct BoardMRReferenceLine: View {
    let iid: Int
    let projectID: Int
    var dependencies: MergeRequestDependencySummary?

    var body: some View {
        if let dependencies {
            MRDependencyRow(summary: dependencies, projectID: projectID, iid: iid)
        } else {
            BoardMRIdentifier(iid: iid)
        }
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
            Text(verbatim: author.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? author.username : author.name).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(Text(verbatim: "\(author.name) (@\(author.username))"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// One wrapping text flow keeps each canonical predecessor link together with its stack position.
struct MRDependencyRow: View {
    let summary: MergeRequestDependencySummary
    let projectID: Int
    var iid: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let iid, summary.predecessors.isEmpty {
                BoardMRIdentifier(iid: iid).help(tooltip)
            } else if !description.characters.isEmpty {
                Text(description).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(tooltip)
            }
            if let notice = summary.notice {
                Text(verbatim: notice).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tooltip: Text {
        let references = summary.predecessors.map { "\($0.title)\n\($0.url.gitLabProjectPath)" }.joined(separator: "\n")
        if let position = summary.stackPosition {
            return Text(.MRDependencies.mrDependenciesStackPosition(position)) + Text(verbatim: "\n")
                + Text(.MRDependencies.mrDependenciesPositionHelp) + Text(verbatim: references.isEmpty ? "" : "\n" + references)
        }
        return Text(verbatim: references)
    }

    private var description: AttributedString {
        var text = AttributedString()
        if let iid {
            text = AttributedString("!\(iid)")
        } else if let position = summary.stackPosition {
            text = AttributedString(String(localized: .MRDependencies.mrDependenciesStackPosition(position)))
        }
        if !summary.predecessors.isEmpty {
            if iid != nil { text += AttributedString(", ") }
            else if summary.stackPosition != nil { text += AttributedString(" · ") }
            text += AttributedString(String(localized: iid == nil ? .MRDependencies.mrDependenciesAfter : .MRDependencies.mrDependenciesAfterInline) + " ")
            for (index, predecessor) in summary.predecessors.enumerated() {
                if index > 0 { text += AttributedString(", ") }
                var reference = predecessor.reference(relativeTo: projectID)
                if !predecessor.isCurrent { reference += " (\(String(localized: .MRDependencies.mrDependenciesLastKnown)))" }
                var link = AttributedString(reference)
                link.link = predecessor.url
                text += link
            }
        }
        return text
    }
}

extension MergeRequestDependencySummary {
    var hasPresentation: Bool { stackPosition != nil || !predecessors.isEmpty || !issues.isEmpty }

    var notice: String? {
        var messages: [LocalizedStringResource] = []
        if issues.contains(.dependenciesUnavailable) { messages.append(.MRDependencies.mrDependenciesUnavailable) }
        else if issues.contains(.hiddenDependency) { messages.append(.MRDependencies.mrDependenciesHidden) }
        if issues.contains(.stackUnavailable), !issues.contains(.dependenciesUnavailable) {
            messages.append(.MRDependencies.mrDependenciesStackUnavailable)
        }
        if issues.contains(.stackAmbiguous) { messages.append(.MRDependencies.mrDependenciesStackAmbiguous) }
        else if issues.contains(.stackIncomplete) { messages.append(.MRDependencies.mrDependenciesStackIncomplete) }
        return messages.isEmpty ? nil : messages.map { String(localized: $0) }.joined(separator: " · ")
    }
}
