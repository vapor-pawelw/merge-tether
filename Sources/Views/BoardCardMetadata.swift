import SwiftUI

struct BoardCardTitle: View {
    let title: String
    let repositoryPath: String
    var font: Font = .callout.weight(.semibold)
    var titleColor: Color = .primary

    var body: some View {
        Text(verbatim: title)
            .font(font).foregroundStyle(titleColor)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: "\(title)\n\(repositoryPath)"))
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

struct BoardMRReferenceLine: View {
    let iid: Int?
    let projectID: Int
    var repositoryPath = ""
    var dependencies: MergeRequestDependencySummary?

    var body: some View {
        MRDependencyRow(summary: dependencies, projectID: projectID, iid: iid, repositoryPath: repositoryPath)
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
        let identity = Text(verbatim: author.person.accessibilityName ?? author.username)
        guard let roleLabel else { return identity }
        return Text(roleLabel) + Text(verbatim: ": ") + identity
    }

    var body: some View {
        PersonLabel(person: author.person)
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// One wrapping line keeps the repository, MR number and predecessor links together.
struct MRDependencyRow: View {
    let summary: MergeRequestDependencySummary?
    let projectID: Int
    var iid: Int? = nil
    var repositoryPath = ""

    private var repositoryName: String {
        repositoryPath.split(separator: "/").last.map(String.init) ?? repositoryPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let iid, summary?.predecessors.isEmpty != false {
                let numberLabel = Text(.Board.boardMergeRequestNumber(iid))
                referenceLine(Text(verbatim: "!\(iid)"))
                    .accessibilityLabel(repositoryPath.isEmpty ? numberLabel : Text("\(repositoryPath), \(numberLabel)"))
            } else {
                let description = description
                if !description.characters.isEmpty || !repositoryName.isEmpty {
                    referenceLine(Text(description), hasReference: !description.characters.isEmpty)
                }
            }
            if let notice = summary?.notice {
                Text(verbatim: notice).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func referenceLine(_ reference: Text, hasReference: Bool = true) -> some View {
        let repository = Text(verbatim: repositoryName).foregroundStyle(Color.accentColor)
        let separator = Text(verbatim: repositoryName.isEmpty || !hasReference ? "" : " ")
        let reference = reference.monospacedDigit().foregroundStyle(.secondary)
        return Text("\(repository)\(separator)\(reference)")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .help(tooltip)
    }

    private var tooltip: Text {
        let references = summary?.predecessors.map { "\($0.title)\n\($0.url.gitLabProjectPath)" } ?? []
        let paths = ([repositoryPath].filter { !$0.isEmpty } + references).joined(separator: "\n")
        if let position = summary?.stackPosition {
            let positionLabel = Text(.MRDependencies.mrDependenciesStackPosition(position))
            let positionHelp = Text(.MRDependencies.mrDependenciesPositionHelp)
            let pathsLabel = Text(verbatim: paths.isEmpty ? "" : "\n" + paths)
            return Text("\(positionLabel)\n\(positionHelp)\(pathsLabel)")
        }
        return Text(verbatim: paths)
    }

    private var description: AttributedString {
        var text = AttributedString()
        guard let summary else { return text }
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
