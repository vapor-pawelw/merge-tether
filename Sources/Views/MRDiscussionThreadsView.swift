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
    /// Present when the user may change comment origins; `nil` classification returns to automatic assessment.
    var onSetOrigin: MRDiscussionOriginAction? = nil
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
                        MRDiscussionDraftView(draft: draft, author: currentUser,
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

    /// Your drafts show your GitLab name and avatar when any loaded note carries them.
    private var currentUser: PersonIdentity? {
        guard let username = currentUsername?.lowercased() else { return nil }
        let known = snapshot.threads.lazy.flatMap(\.notes).compactMap(\.author)
            .first { $0.username?.lowercased() == username }
        return known?.person ?? .init(name: nil, username: currentUsername)
    }

    private func threadView(_ thread: MRDiscussionSnapshot.Thread) -> some View {
        MRDiscussionThreadView(thread: thread, mergeRequestURL: mergeRequestURL,
                               currentUsername: currentUsername, currentUser: currentUser, initiallyExpanded: expandPendingDrafts && !thread.drafts.isEmpty,
                               selection: selection, selectionDisabled: selectionDisabled, draftsFirst: draftsFirst, onDelete: onDelete,
                               onSetOrigin: onSetOrigin)
    }
}

typealias MRDiscussionOriginAction = (AICommentOriginOverride.Classification?, [GitLabMergeRequestDiscussion.Note]) -> Void

private struct MRDiscussionThreadView: View {
    let thread: MRDiscussionSnapshot.Thread
    let mergeRequestURL: URL
    let currentUsername: String?
    let currentUser: PersonIdentity?
    let initiallyExpanded: Bool
    let selection: Binding<DraftPublicationSelection>?
    let selectionDisabled: Bool
    let draftsFirst: Bool
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    var onSetOrigin: MRDiscussionOriginAction? = nil
    @State private var isExpanded = false
    @State private var threadOriginRequest: ThreadOriginRequest?

    private struct ThreadOriginRequest: Identifiable {
        let id = UUID()
        let classification: AICommentOriginOverride.Classification?
    }

    private var stateLabel: LocalizedStringResource {
        switch thread.state {
        case .open: .MRDiscussions.mrDiscussionsOpen
        case .resolved: .MRDiscussions.mrDiscussionsResolved
        case .general: .MRDiscussions.mrDiscussionsGeneral
        }
    }
    private var stateColor: Color {
        switch thread.state {
        case .open: .orange
        case .resolved: .green
        case .general: .secondary
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
                        // The first comment's author line stays in the header; its body continues here.
                        if let first = comments.first {
                            MRDiscussionNoteContent(note: first, threadLocation: thread.location)
                        }
                        ForEach(Array(comments.dropFirst().enumerated()), id: \.offset) { _, note in
                            Divider().padding(.vertical, 2)
                            MRDiscussionNoteView(note: note, origin: note.id.flatMap { thread.origins[$0] },
                                                 authorKind: (note.author?.id).flatMap { thread.authorKinds[$0] },
                                                 mergeRequestURL: mergeRequestURL, threadLocation: thread.location,
                                                 onSetOrigin: noteOriginAction(note))
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
        .alert(threadOriginTitle, isPresented: Binding(get: { threadOriginRequest != nil },
                                                       set: { if !$0 { threadOriginRequest = nil } }),
               presenting: threadOriginRequest) { request in
            Button(role: .cancel) { threadOriginRequest = nil } label: { Text(.MRDiscussions.mrDiscussionsOriginCancel) }
            Button { onSetOrigin?(request.classification, comments); threadOriginRequest = nil } label: {
                Text(.MRDiscussions.mrDiscussionsOriginConfirm)
            }
        } message: { _ in
            Text(.MRDiscussions.mrDiscussionsThreadOriginMessage(comments.count))
        }
    }

    private var threadOriginTitle: Text {
        switch threadOriginRequest?.classification {
        case .ai: Text(.MRDiscussions.mrDiscussionsThreadOriginAiTitle)
        case .uncertain: Text(.MRDiscussions.mrDiscussionsThreadOriginUncertainTitle)
        case .human: Text(.MRDiscussions.mrDiscussionsThreadOriginHumanTitle)
        case nil: Text(.MRDiscussions.mrDiscussionsThreadOriginAutomaticTitle)
        }
    }

    private func noteOriginAction(_ note: GitLabMergeRequestDiscussion.Note) -> ((AICommentOriginOverride.Classification?) -> Void)? {
        guard let onSetOrigin else { return nil }
        return { onSetOrigin($0, [note]) }
    }

    private func threadHeader(firstComment: GitLabMergeRequestDiscussion.Note?,
                              summary: MRDiscussionSnapshot.Thread.ReplySummary,
                              originBadge: MRDiscussionSnapshot.OriginBadge?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            StatusFlowLayout {
                HStack(spacing: 4) {
                    if thread.state == .resolved { Image(systemName: "checkmark") }
                    Text(stateLabel)
                }
                .font(.caption.weight(thread.state == .open ? .semibold : .regular)).foregroundStyle(stateColor)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(stateColor.opacity(thread.state == .open ? 0.055 : 0.08), in: Capsule())
                MRDiscussionFeedbackBadge(state: thread.feedback)
                replyStatus(summary)
                if let originBadge {
                    MRDiscussionOriginBadge(badge: originBadge,
                        isManual: !thread.origins.isEmpty && thread.origins.values.allSatisfy(\.isManual),
                        scope: .thread,
                        onSelect: onSetOrigin == nil ? nil : { threadOriginRequest = .init(classification: $0) })
                }
            }
            if let location = thread.location {
                MRDiscussionLocationLabel(location: .init(full: location))
            }
            if let firstComment {
                MRDiscussionNoteHeader(note: firstComment, origin: firstComment.id.flatMap { thread.origins[$0] },
                    authorKind: (firstComment.author?.id).flatMap { thread.authorKinds[$0] },
                    mergeRequestURL: mergeRequestURL, onSetOrigin: noteOriginAction(firstComment))
                    .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary)
                if !isExpanded, let body = firstComment.body {
                    Text(verbatim: body).font(.callout)
                        .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary).lineLimit(2)
                        .padding(.top, 1)
                }
            }
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
            MRDiscussionDraftView(draft: draft, author: currentUser, threadLocation: thread.location,
                selection: selection, selectionDisabled: selectionDisabled, onDelete: onDelete)
        }
    }
}

/// The header is not one big button, so origin menus and links inside it stay clickable.
private struct MRDiscussionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    configuration.isExpanded.toggle()
                } label: {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsToggleThread))
                .accessibilityValue(Text(configuration.isExpanded
                    ? .MRDiscussions.mrDiscussionsExpanded : .MRDiscussions.mrDiscussionsCollapsed))
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { configuration.isExpanded.toggle() }
            }
            if configuration.isExpanded {
                configuration.content.padding(.leading, 24)
            }
        }
    }
}

private struct MRDiscussionNoteView: View {
    let note: GitLabMergeRequestDiscussion.Note
    let origin: MRDiscussionSnapshot.Origin?
    let authorKind: AuthorFeedbackPolicy.AccountKind?
    let mergeRequestURL: URL
    let threadLocation: String?
    var onSetOrigin: ((AICommentOriginOverride.Classification?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MRDiscussionNoteHeader(note: note, origin: origin, authorKind: authorKind,
                                   mergeRequestURL: mergeRequestURL, onSetOrigin: onSetOrigin)
            MRDiscussionNoteContent(note: note, threadLocation: threadLocation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line for every comment, the thread's first included: author, origin, then date and link on the right.
private struct MRDiscussionNoteHeader: View {
    let note: GitLabMergeRequestDiscussion.Note
    let origin: MRDiscussionSnapshot.Origin?
    let authorKind: AuthorFeedbackPolicy.AccountKind?
    let mergeRequestURL: URL
    var onSetOrigin: ((AICommentOriginOverride.Classification?) -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MRDiscussionAuthorView(author: note.author, accountKind: authorKind)
                .layoutPriority(1)
            if let origin {
                MRDiscussionOriginBadge(badge: origin.badge, origin: origin, isManual: origin.isManual,
                                        scope: .comment, onSelect: onSetOrigin)
            }
            Spacer(minLength: 4)
            if let posted = note.createdAt {
                Text(verbatim: MRDiscussionTimestamp.display(posted)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().help(posted)
            }
            if let id = note.id, id > 0, let url = discussionNoteURL(mergeRequestURL, id: id) {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
                    .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsOpenInGitLab))
            }
        }
        .font(.callout)
    }
}

private struct MRDiscussionNoteContent: View {
    let note: GitLabMergeRequestDiscussion.Note
    let threadLocation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
    let author: PersonIdentity?
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
                PersonLabel(person: author ?? .init(name: nil, username: nil), avatarSize: 18,
                            fallback: Text(.MRDiscussions.mrDiscussionsYou))
                    .fontWeight(.medium)
                Text(.MRDiscussions.mrDiscussionsPrivateDraft).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                if let onDelete { DraftDeleteButton(draft: draft, disabled: selectionDisabled, onDelete: onDelete) }
            }
            .font(.callout)
            if let location = MRDiscussionLocation(position: draft.position), location.full != threadLocation {
                MRDiscussionLocationLabel(location: location).textSelection(.enabled)
            }
            MRDiscussionBody(source: draft.note)
            DraftPublicationWarnings(drafts: [draft])
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: 2) }
    }
}

private struct MRDiscussionOriginBadge: View {
    enum Scope { case comment, thread }
    let badge: MRDiscussionSnapshot.OriginBadge
    var origin: MRDiscussionSnapshot.Origin? = nil
    var isManual = false
    var scope: Scope = .comment
    /// Present when the user may change the classification; `nil` returns to automatic assessment.
    var onSelect: ((AICommentOriginOverride.Classification?) -> Void)? = nil

    private var title: LocalizedStringResource {
        if origin == .appGenerated { return .MRDiscussions.mrDiscussionsAiMergeTether }
        return switch badge {
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
        if origin == .appGenerated { return "wand.and.stars" }
        return switch badge {
        case .ai: "sparkles"
        case .uncertain: "questionmark"
        case .human: "person.fill"
        }
    }
    private var explanation: Text {
        var text: Text = switch origin {
        case .verifiedAssistant: Text(.MRDiscussions.mrDiscussionsAiVerified)
        case .appGenerated: Text(.MRDiscussions.mrDiscussionsAiAppGenerated)
        case .assessed(let evidence): Text(.MRDiscussions.mrDiscussionsAiAssessed) + Text(verbatim: "\n" + evidence)
        case .uncertain(let evidence): Text(.MRDiscussions.mrDiscussionsAiUncertainHelp) + Text(verbatim: "\n" + evidence)
        case .humanLikely(let evidence): Text(.MRDiscussions.mrDiscussionsHumanHelp) + Text(verbatim: "\n" + evidence)
        case .manual: Text(.MRDiscussions.mrDiscussionsManualHelp)
        case nil:
            switch badge {
            case .ai: Text(.MRDiscussions.mrDiscussionsThreadAiHelp)
            case .uncertain: Text(.MRDiscussions.mrDiscussionsThreadUncertainHelp)
            case .human: Text(.MRDiscussions.mrDiscussionsThreadHumanHelp)
            }
        }
        if onSelect != nil {
            text = text + Text(verbatim: "\n\n") + Text(scope == .thread
                ? .MRDiscussions.mrDiscussionsThreadOriginMenuHelp : .MRDiscussions.mrDiscussionsOriginMenuHelp)
        }
        return text
    }
    private var current: AICommentOriginOverride.Classification? {
        guard isManual else { return nil }
        return switch badge { case .ai: .ai; case .uncertain: .uncertain; case .human: .human }
    }

    private var capsule: some View {
        Label {
            HStack(spacing: 3) {
                Text(title)
                if isManual { Image(systemName: "hand.raised.fill").imageScale(.small).accessibilityHidden(true) }
                if onSelect != nil { Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true) }
            }
        } icon: { Image(systemName: symbol) }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        if let onSelect {
            Menu {
                Section {
                    option(.ai, title: .MRDiscussions.mrDiscussionsAi, symbol: "sparkles", onSelect: onSelect)
                    option(.uncertain, title: .MRDiscussions.mrDiscussionsAiUncertain, symbol: "questionmark", onSelect: onSelect)
                    option(.human, title: .MRDiscussions.mrDiscussionsHuman, symbol: "person.fill", onSelect: onSelect)
                } header: {
                    Text(scope == .thread ? .MRDiscussions.mrDiscussionsThreadOriginMenuTitle : .MRDiscussions.mrDiscussionsOriginMenuTitle)
                }
                if isManual || scope == .thread {
                    Divider()
                    Button { onSelect(nil) } label: {
                        Label { Text(.MRDiscussions.mrDiscussionsOriginAutomatic) } icon: { Image(systemName: "arrow.uturn.backward") }
                    }
                }
            } label: { capsule }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(explanation)
                .accessibilityLabel(Text(title))
                .accessibilityHint(explanation)
        } else {
            capsule
                .help(explanation)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityHint(explanation)
        }
    }

    @ViewBuilder
    private func option(_ value: AICommentOriginOverride.Classification, title: LocalizedStringResource, symbol: String,
                        onSelect: @escaping (AICommentOriginOverride.Classification?) -> Void) -> some View {
        Button { onSelect(value) } label: {
            Label { Text(title) } icon: { Image(systemName: current == value ? "checkmark" : symbol) }
        }
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
    var accountKind: AuthorFeedbackPolicy.AccountKind? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            PersonLabel(person: author?.person ?? .init(name: nil, username: nil), avatarSize: 18,
                        fallback: Text(.MRDiscussions.mrDiscussionsUnknownAuthor).foregroundStyle(.secondary))
                .fontWeight(.semibold)
            if accountKind == .automation {
                Label(.AuthorFeedback.authorFeedbackBotAuthor, systemImage: "gearshape")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .help(Text(.AuthorFeedback.authorFeedbackBotAuthorHelp))
            }
        }
        .font(.callout).lineLimit(1).truncationMode(.middle)
    }
}

private struct MRDiscussionFeedbackBadge: View {
    let state: MRDiscussionSnapshot.Feedback

    private var title: LocalizedStringResource {
        switch state {
        case .addressed: .MRDiscussions.mrDiscussionsFeedbackAddressed
        case .pending: .MRDiscussions.mrDiscussionsFeedbackPending
        case .needsVerification: .MRDiscussions.mrDiscussionsFeedbackNeedsVerification
        case .informational: .MRDiscussions.mrDiscussionsFeedbackInformational
        case .ignored: .MRDiscussions.mrDiscussionsFeedbackIgnored
        case .partlyIgnored: .MRDiscussions.mrDiscussionsFeedbackPartlyIgnored
        case .notApplicable: .MRDiscussions.mrDiscussionsFeedbackNotApplicable
        }
    }
    private var color: Color {
        switch state {
        case .addressed: .green
        case .pending, .needsVerification: .orange
        case .informational, .ignored, .partlyIgnored, .notApplicable: .secondary
        }
    }
    private var symbol: String {
        switch state {
        case .addressed: "checkmark.seal"
        case .pending: "exclamationmark.bubble"
        case .needsVerification: "questionmark.circle"
        case .informational, .notApplicable: "info.circle"
        case .ignored, .partlyIgnored: "minus.circle"
        }
    }
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: Capsule())
            .help(Text(.MRDiscussions.mrDiscussionsFeedbackHelp))
            .accessibilityHint(Text(.MRDiscussions.mrDiscussionsFeedbackHelp))
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
            .font(.caption).foregroundStyle(state == .published || state == .earlier ? Color.blue : Color.secondary)
            .help(Text(explanation)).accessibilityHint(Text(explanation))
    }
}


private func discussionNoteURL(_ url: URL, id: Int) -> URL? {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = "note_\(id)"
    return components?.url
}
