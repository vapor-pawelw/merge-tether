import Foundation
import SwiftUI

/// Conversation context with optional draft selection. Publication stays in the confirmation controls.
struct MRDiscussionThreadsView: View {
    let snapshot: MRDiscussionSnapshot
    let mergeRequestURL: URL
    let currentUsername: String?
    let isLoading: Bool
    let hasError: Bool
    let hasLoaded: Bool
    var expandPendingDrafts = false
    var selection: Binding<DraftPublicationSelection>? = nil
    var selectionDisabled = false
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    var title: LocalizedStringResource = .MRDiscussions.mrDiscussionsTitle
    var draftsFirst = false
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(Text(.MRDiscussions.mrDiscussionsAiLegend))
                    .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsAiLegend))
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(action: onRefresh) {
                    Label { Text(.MRDiscussions.mrDiscussionsRefresh) } icon: { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless).disabled(isLoading)
                .foregroundStyle(isLoading ? Color.secondary : Color.accentColor)
            }
            if hasError {
                Label { Text(.MRDiscussions.mrDiscussionsFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.callout).foregroundStyle(.orange)
            } else if !hasLoaded {
                Text(isLoading ? .MRDiscussions.mrDiscussionsLoading : .MRDiscussions.mrDiscussionsUnavailable)
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot.threads) { thread in
                    if thread.id != snapshot.threads.first?.id { Divider() }
                    threadView(thread)
                }
                ForEach(Array(snapshot.standaloneDrafts.enumerated()), id: \.offset) { index, draft in
                    if index > 0 || !snapshot.threads.isEmpty { Divider() }
                    VStack(alignment: .leading, spacing: 9) {
                        Text(draft.discussionID == nil ? .MRDiscussions.mrDiscussionsNewComment
                             : hasLoaded || hasError ? .MRDiscussions.mrDiscussionsUnmatchedReply
                             : .MRDiscussions.mrDiscussionsReplyDraft)
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        MRDiscussionDraftView(draft: draft, username: currentUsername,
                            selection: selection, selectionDisabled: selectionDisabled, onDelete: onDelete)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background {
                if !snapshot.threads.isEmpty || !snapshot.standaloneDrafts.isEmpty {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.035))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5) }
                }
            }
            if hasLoaded && !isLoading && snapshot.threads.isEmpty && snapshot.standaloneDrafts.isEmpty {
                Text(.MRDiscussions.mrDiscussionsEmpty).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func threadView(_ thread: MRDiscussionSnapshot.Thread) -> some View {
        MRDiscussionThreadView(thread: thread, mergeRequestURL: mergeRequestURL,
                               currentUsername: currentUsername, initiallyExpanded: expandPendingDrafts && !thread.drafts.isEmpty,
                               selection: selection, selectionDisabled: selectionDisabled, draftsFirst: draftsFirst, onDelete: onDelete)
    }
}

private struct MRDiscussionThreadView: View {
    let thread: MRDiscussionSnapshot.Thread
    let mergeRequestURL: URL
    let currentUsername: String?
    let initiallyExpanded: Bool
    let selection: Binding<DraftPublicationSelection>?
    let selectionDisabled: Bool
    let draftsFirst: Bool
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    @State private var isExpanded = false

    private var stateLabel: LocalizedStringResource {
        switch thread.state {
        case .open: .MRDiscussions.mrDiscussionsOpen
        case .resolved: .MRDiscussions.mrDiscussionsResolved
        case .general: .MRDiscussions.mrDiscussionsGeneral
        }
    }
    private var stateColor: Color {
        switch thread.state {
        case .open: .primary
        case .resolved: .secondary
        case .general: .purple
        }
    }

    var body: some View {
        let comments = thread.notes.filter { $0.system != true }
        let summary = thread.replySummary(currentUsername: currentUsername)
        let originBadge = thread.originBadge
        return VStack(alignment: .leading, spacing: 12) {
            if draftsFirst { draftRows }
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(comments.enumerated()), id: \.offset) { index, note in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            MRDiscussionNoteView(note: note, origin: note.id.flatMap { thread.origins[$0] },
                                                 mergeRequestURL: mergeRequestURL, threadLocation: thread.location)
                        }
                        if !draftsFirst { draftRows }
                    }
                    .padding(.top, 10)
                }
            } label: {
                threadHeader(firstComment: comments.first, summary: summary, originBadge: originBadge)
            }
            .disclosureGroupStyle(MRDiscussionDisclosureStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if initiallyExpanded { isExpanded = true } }
    }

    private func threadHeader(firstComment: GitLabMergeRequestDiscussion.Note?,
                              summary: MRDiscussionSnapshot.Thread.ReplySummary,
                              originBadge: MRDiscussionSnapshot.OriginBadge?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    if thread.state == .resolved { Image(systemName: "checkmark") }
                    Text(stateLabel)
                }
                .font(.caption.weight(thread.state == .open ? .semibold : .regular)).foregroundStyle(stateColor)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(stateColor.opacity(thread.state == .open ? 0.055 : 0.08), in: Capsule())
                if let location = thread.location {
                    MRDiscussionLocationLabel(location: .init(full: location))
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                if let posted = firstComment?.createdAt {
                    Text(verbatim: MRDiscussionTimestamp.display(posted))
                        .font(.caption).foregroundStyle(.secondary).help(posted)
                        .lineLimit(1)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    threadAuthor(firstComment?.author, badge: originBadge)
                    replyStatus(summary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    threadAuthor(firstComment?.author, badge: originBadge)
                    replyStatus(summary)
                }
            }
            if !isExpanded, let body = firstComment?.body {
                Text(verbatim: body).font(.callout)
                    .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary).lineLimit(2)
                    .padding(.top, 1)
            }
        }
    }

    private func threadAuthor(_ author: GitLabWorkflowUser?, badge: MRDiscussionSnapshot.OriginBadge?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MRDiscussionAuthorView(author: author)
                .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary)
            if let badge { MRDiscussionOriginBadge(badge: badge) }
        }
    }

    @ViewBuilder
    private func replyStatus(_ summary: MRDiscussionSnapshot.Thread.ReplySummary) -> some View {
        MRDiscussionReplyBadge(state: summary.publishedReply)
        if summary.draftCount > 0 {
            Label { Text(.MRDiscussions.mrDiscussionsDraftCount(summary.draftCount)) } icon: {
                Image(systemName: "square.and.pencil")
            }
            .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
        }
    }

    private var draftRows: some View {
        ForEach(Array(thread.drafts.enumerated()), id: \.offset) { _, draft in
            MRDiscussionDraftView(draft: draft, username: currentUsername, threadLocation: thread.location,
                selection: selection, selectionDisabled: selectionDisabled, onDelete: onDelete)
        }
    }
}

private struct MRDiscussionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 14)
                        .accessibilityHidden(true)
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(configuration.isExpanded
                ? .MRDiscussions.mrDiscussionsExpanded : .MRDiscussions.mrDiscussionsCollapsed))
            if configuration.isExpanded {
                configuration.content.padding(.leading, 24)
            }
        }
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
                MRDiscussionAuthorView(author: note.author)
                if let origin { MRDiscussionOriginBadge(badge: origin.badge, origin: origin) }
                Spacer(minLength: 4)
                if let posted = note.createdAt {
                    Text(verbatim: MRDiscussionTimestamp.display(posted)).font(.caption).foregroundStyle(.secondary).help(posted)
                }
                if let id = note.id, id > 0, let url = discussionNoteURL(mergeRequestURL, id: id) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                        .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                }
            }
            .font(.callout)
            if let location = MRDiscussionLocation(position: note.position), location.full != threadLocation {
                MRDiscussionLocationLabel(location: location).textSelection(.enabled)
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
    var selection: Binding<DraftPublicationSelection>? = nil
    var selectionDisabled = false
    var onDelete: ((GitLabDraftNote) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let selection {
                    DraftPublicationCheckbox(draft: draft, selection: selection, disabled: selectionDisabled)
                }
                if let username { Text(verbatim: "@\(username)").fontWeight(.medium) }
                else { Text(.MRDiscussions.mrDiscussionsYou).fontWeight(.medium) }
                Text(.MRDiscussions.mrDiscussionsPrivateDraft).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                if let onDelete { DraftDeleteButton(draft: draft, disabled: selectionDisabled, onDelete: onDelete) }
            }
            .font(.callout)
            if let location = MRDiscussionLocation(position: draft.position), location.full != threadLocation {
                MRDiscussionLocationLabel(location: location).textSelection(.enabled)
            }
            MRDiscussionBody(source: draft.note)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: 2) }
    }
}

private struct MRDiscussionOriginBadge: View {
    let badge: MRDiscussionSnapshot.OriginBadge
    var origin: MRDiscussionSnapshot.Origin? = nil

    private var title: LocalizedStringResource {
        switch badge {
        case .ai: .MRDiscussions.mrDiscussionsAi
        case .uncertain: .MRDiscussions.mrDiscussionsAiUncertain
        case .human: .MRDiscussions.mrDiscussionsHuman
        }
    }
    private var color: Color {
        switch badge {
        case .ai: .purple
        case .uncertain: .orange
        case .human: .teal
        }
    }
    private var symbol: String {
        switch badge {
        case .ai: "sparkles"
        case .uncertain: "questionmark"
        case .human: "person.fill"
        }
    }
    private var explanation: Text {
        switch origin {
        case .verifiedAssistant: Text(.MRDiscussions.mrDiscussionsAiVerified)
        case .assessed(let evidence): Text(.MRDiscussions.mrDiscussionsAiAssessed) + Text(verbatim: "\n" + evidence)
        case .uncertain(let evidence): Text(.MRDiscussions.mrDiscussionsAiUncertainHelp) + Text(verbatim: "\n" + evidence)
        case .humanLikely(let evidence): Text(.MRDiscussions.mrDiscussionsHumanHelp) + Text(verbatim: "\n" + evidence)
        case nil:
            switch badge {
            case .ai: Text(.MRDiscussions.mrDiscussionsThreadAiHelp)
            case .uncertain: Text(.MRDiscussions.mrDiscussionsThreadUncertainHelp)
            case .human: Text(.MRDiscussions.mrDiscussionsThreadHumanHelp)
            }
        }
    }
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol) }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .help(explanation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityHint(explanation)
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
        .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MRDiscussionLocationLabel: View {
    let location: MRDiscussionLocation

    var body: some View {
        Label { Text(verbatim: location.compact) } icon: { Image(systemName: "doc.text") }
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(Text(verbatim: location.full))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: location.full))
    }
}

private struct MRDiscussionAuthorView: View {
    let author: GitLabWorkflowUser?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let name = author?.name, !name.isEmpty, name != author?.username {
                Text(verbatim: name).fontWeight(.semibold)
                if let username = author?.username, !username.isEmpty {
                    Text(verbatim: "@\(username)").foregroundStyle(.secondary)
                }
            } else if let username = author?.username, !username.isEmpty {
                Text(verbatim: "@\(username)").fontWeight(.semibold)
            } else {
                Text(.MRDiscussions.mrDiscussionsUnknownAuthor).foregroundStyle(.secondary)
            }
        }
        .font(.callout).lineLimit(1).truncationMode(.middle)
    }
}

private struct MRDiscussionReplyBadge: View {
    let state: MRDiscussionSnapshot.Thread.ReplySummary.PublishedReply

    private var label: LocalizedStringResource {
        switch state {
        case .none: .MRDiscussions.mrDiscussionsNoOwnReply
        case .published: .MRDiscussions.mrDiscussionsPublishedReply
        case .earlier: .MRDiscussions.mrDiscussionsEarlierReply
        case .unknown: .MRDiscussions.mrDiscussionsReplyUnknown
        case .unavailable: .MRDiscussions.mrDiscussionsReplyUnavailable
        }
    }
    private var explanation: LocalizedStringResource {
        switch state {
        case .none: .MRDiscussions.mrDiscussionsNoOwnReplyHelp
        case .published: .MRDiscussions.mrDiscussionsPublishedReplyHelp
        case .earlier: .MRDiscussions.mrDiscussionsEarlierReplyHelp
        case .unknown: .MRDiscussions.mrDiscussionsReplyUnknownHelp
        case .unavailable: .MRDiscussions.mrDiscussionsReplyUnavailableHelp
        }
    }
    private var symbol: String {
        switch state {
        case .published, .earlier: "arrowshape.turn.up.left"
        case .none: "bubble.left"
        case .unknown, .unavailable: "questionmark.bubble"
        }
    }

    var body: some View {
        Label { Text(label) } icon: { Image(systemName: symbol) }
            .font(.caption).foregroundStyle(.secondary)
            .help(Text(explanation)).accessibilityHint(Text(explanation))
    }
}


private func discussionNoteURL(_ url: URL, id: Int) -> URL? {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = "note_\(id)"
    return components?.url
}
