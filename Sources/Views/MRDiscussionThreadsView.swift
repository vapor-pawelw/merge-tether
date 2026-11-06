import Foundation
import SwiftUI

/// Read-only conversation context. Publication stays in the existing confirmation controls.
struct MRDiscussionThreadsView: View {
    let snapshot: MRDiscussionSnapshot
    let mergeRequestURL: URL
    let currentUsername: String?
    let isLoading: Bool
    let hasError: Bool
    let hasLoaded: Bool
    var expandPendingDrafts = false
    let onRefresh: () -> Void

    private var pendingThreads: [MRDiscussionSnapshot.Thread] { snapshot.threads.filter { !$0.drafts.isEmpty } }
    private var otherThreads: [MRDiscussionSnapshot.Thread] { snapshot.threads.filter { $0.drafts.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(.MRDiscussions.mrDiscussionsTitle).font(.headline)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(Text(.MRDiscussions.mrDiscussionsAiLegend))
                    .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsAiLegend))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(action: onRefresh) { Text(.MRDiscussions.mrDiscussionsRefresh) }
                    .buttonStyle(.borderless).disabled(isLoading)
            }
            if hasError {
                Label { Text(.MRDiscussions.mrDiscussionsFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption).foregroundStyle(.orange)
            } else if !hasLoaded {
                Text(isLoading ? .MRDiscussions.mrDiscussionsLoading : .MRDiscussions.mrDiscussionsUnavailable)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pendingThreads) { thread in threadView(thread) }
            ForEach(Array(snapshot.standaloneDrafts.enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 9) {
                    Text(draft.discussionID == nil ? .MRDiscussions.mrDiscussionsNewComment
                         : hasLoaded || hasError ? .MRDiscussions.mrDiscussionsUnmatchedReply
                         : .MRDiscussions.mrDiscussionsReplyDraft)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    MRDiscussionDraftView(draft: draft, username: currentUsername)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(otherThreads) { thread in threadView(thread) }
            if hasLoaded && !isLoading && snapshot.threads.isEmpty && snapshot.standaloneDrafts.isEmpty {
                Text(.MRDiscussions.mrDiscussionsEmpty).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func threadView(_ thread: MRDiscussionSnapshot.Thread) -> some View {
        MRDiscussionThreadView(thread: thread, mergeRequestURL: mergeRequestURL,
                               currentUsername: currentUsername, initiallyExpanded: expandPendingDrafts && !thread.drafts.isEmpty)
    }
}

private struct MRDiscussionThreadView: View {
    let thread: MRDiscussionSnapshot.Thread
    let mergeRequestURL: URL
    let currentUsername: String?
    let initiallyExpanded: Bool
    @State private var isExpanded = false

    private var comments: [GitLabMergeRequestDiscussion.Note] { thread.notes.filter { $0.system != true } }
    private var stateLabel: LocalizedStringResource {
        switch thread.state {
        case .open: .MRDiscussions.mrDiscussionsOpen
        case .resolved: .MRDiscussions.mrDiscussionsResolved
        case .general: .MRDiscussions.mrDiscussionsGeneral
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, note in
                    MRDiscussionNoteView(note: note, origin: note.id.flatMap { thread.origins[$0] },
                                         mergeRequestURL: mergeRequestURL, threadLocation: thread.location)
                }
                ForEach(Array(thread.drafts.enumerated()), id: \.offset) { _, draft in
                    MRDiscussionDraftView(draft: draft, username: currentUsername, threadLocation: thread.location)
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: discussionAuthor(comments.first?.author)).fontWeight(.medium)
                    Text(stateLabel).foregroundStyle(thread.state == .resolved ? .green : .secondary)
                    Spacer(minLength: 4)
                    if !thread.drafts.isEmpty {
                        Text(.MRDiscussions.mrDiscussionsDraftCount(thread.drafts.count)).foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                if let location = thread.location {
                    Text(verbatim: location).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !isExpanded, let body = comments.first?.body {
                    Text(verbatim: body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { if initiallyExpanded { isExpanded = true } }
    }
}

private struct MRDiscussionNoteView: View {
    let note: GitLabMergeRequestDiscussion.Note
    let origin: MRDiscussionSnapshot.Origin?
    let mergeRequestURL: URL
    let threadLocation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: discussionAuthor(note.author)).fontWeight(.medium)
                if let origin { MRDiscussionAIBadge(origin: origin) }
                Spacer(minLength: 4)
                if let posted = note.createdAt {
                    Text(verbatim: discussionTimestamp(posted)).foregroundStyle(.secondary).help(posted)
                }
                if let id = note.id, id > 0, let url = discussionNoteURL(mergeRequestURL, id: id) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                        .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                }
            }
            .font(.caption)
            if let location = discussionLocation(note.position), location != threadLocation {
                Text(verbatim: location).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            MRDiscussionBody(source: note.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MRDiscussionDraftView: View {
    let draft: GitLabDraftNote
    let username: String?
    var threadLocation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let username { Text(verbatim: "@\(username)").fontWeight(.medium) }
                else { Text(.MRDiscussions.mrDiscussionsYou).fontWeight(.medium) }
                Text(.MRDiscussions.mrDiscussionsPrivateDraft).foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            if let location = discussionLocation(draft.position), location != threadLocation {
                Text(verbatim: location).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            MRDiscussionBody(source: draft.note)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: 2) }
    }
}

private struct MRDiscussionAIBadge: View {
    let origin: MRDiscussionSnapshot.Origin
    private var explanation: Text {
        switch origin {
        case .verifiedAssistant: Text(.MRDiscussions.mrDiscussionsAiVerified)
        case .assessed(let evidence): Text(.MRDiscussions.mrDiscussionsAiAssessed) + Text(verbatim: "\n" + evidence)
        }
    }
    var body: some View {
        Text(.MRDiscussions.mrDiscussionsAi).font(.caption2.weight(.semibold))
            .foregroundStyle(.blue).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.blue.opacity(0.09), in: Capsule()).help(explanation)
    }
}

/// Native inline Markdown preserves multiline text and never loads HTML or remote images.
private struct MRDiscussionBody: View {
    let source: String?
    private var rendered: AttributedString? {
        guard let body = source else { return nil }
        guard var text = try? AttributedString(markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return nil }
        let unsafeLinks = text.runs.filter { run in
            guard let link = run.link else { return false }
            return !["http", "https"].contains(link.scheme?.lowercased() ?? "")
        }.map(\.range)
        for range in unsafeLinks { text[range].link = nil }
        let imageRanges = text.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in imageRanges { text[range].imageURL = nil }
        return text
    }
    var body: some View {
        Group {
            if let rendered { Text(rendered) }
            else if let source { Text(verbatim: source) }
            else { Text(.MRDiscussions.mrDiscussionsBodyUnavailable).foregroundStyle(.secondary) }
        }
        .font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func discussionAuthor(_ author: GitLabWorkflowUser?) -> String {
    if let username = author?.username, !username.isEmpty {
        if let name = author?.name, !name.isEmpty, name != username { return "\(name) (@\(username))" }
        return "@\(username)"
    }
    return author?.name ?? String(localized: .MRDiscussions.mrDiscussionsUnknownAuthor)
}

private func discussionTimestamp(_ raw: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? raw
}

private func discussionLocation(_ position: GitLabDraftNote.Position?) -> String? {
    guard let path = position?.newPath ?? position?.oldPath else { return nil }
    let line = position?.newLine ?? position?.oldLine
    return line.map { "\(path):\($0)" } ?? path
}

private func discussionNoteURL(_ url: URL, id: Int) -> URL? {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = "note_\(id)"
    return components?.url
}
