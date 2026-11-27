import Foundation
import MergeTetherRemote
import SwiftUI

struct MRDiscussionNavigation: Equatable {
    struct Anchor: Hashable { let threadID: String }
    let anchor: Anchor
    private let requestID = UUID()
}

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
    var onRegenerate: ((GitLabDraftNote) -> Void)? = nil
    var aiReplyControls: AIReplyControls? = nil
    var title: LocalizedStringResource = .MRDiscussions.mrDiscussionsTitle
    var codeContext: MRDiscussionCodeContext? = nil
    /// Present when the user may change comment origins; `nil` classification returns to automatic assessment.
    var onSetOrigin: MRDiscussionOriginAction? = nil
    var extraContexts: AICommentProvenanceStore.ExtraContexts = .empty
    var currentUserIdentity: PersonIdentity? = nil
    var replyRecipients: [String: [PersonIdentity]] = [:]
    var navigation: MRDiscussionNavigation? = nil
    var expansion: Binding<Bool>? = nil
    let onRefresh: () -> Void
    @State private var markdownCache = MRDiscussionMarkdownCache()

    var body: some View {
        let currentUser = self.currentUser
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let expansion {
                    MRDetailDisclosureButton(isExpanded: expansion) { heading }
                } else {
                    heading
                    Spacer()
                }
                Button(action: onRefresh) {
                    Label { Text(.MRDiscussions.mrDiscussionsRefresh) } icon: { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless).disabled(isLoading)
                .foregroundStyle(isLoading ? Color.secondary : Color.accentColor)
            }
            if expansion?.wrappedValue != false { discussionContent(currentUser: currentUser) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        HStack {
            Text(title).font(.headline)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(Text(.MRDiscussions.mrDiscussionsAiLegend))
                .accessibilityLabel(Text(.MRDiscussions.mrDiscussionsAiLegend))
        }
    }

    @ViewBuilder
    private func discussionContent(currentUser: PersonIdentity?) -> some View {
        if hasError {
            Label { Text(.MRDiscussions.mrDiscussionsFailed) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.callout).foregroundStyle(.orange)
        } else if !hasLoaded && !isLoading {
            Text(.MRDiscussions.mrDiscussionsUnavailable)
                .font(.callout).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.threads) { thread in
                if thread.id != snapshot.threads.first?.id { Divider() }
                threadView(thread, currentUser: currentUser)
            }
            ForEach(StableRowKey.rows(snapshot.standaloneDrafts, id: \.id)) { row in
                let index = row.index, draft = row.element
                if index > 0 || !snapshot.threads.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 9) {
                    Text(draft.discussionID == nil
                         ? draft.position?.isAnchored == true ? .MRDiscussions.mrDiscussionsNewCodeComment : .MRDiscussions.mrDiscussionsNewComment
                         : hasLoaded || hasError ? .MRDiscussions.mrDiscussionsUnmatchedReply
                         : .MRDiscussions.mrDiscussionsReplyDraft)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    MRDiscussionDraftView(draft: draft, author: currentUser, markdownCache: markdownCache,
                        replyTo: draft.discussionID.flatMap(replyMessage),
                        mergeRequestURL: mergeRequestURL, codeContext: codeContext,
                        extraContext: extraContexts.forDraft(draft),
                        selection: selection, selectionDisabled: selectionDisabled,
                        onDelete: onDelete, onRegenerate: onRegenerate, aiReplyControls: aiReplyControls)
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

    private var currentUser: PersonIdentity? {
        guard let username = currentUsername else { return nil }
        var directory = PersonDirectory(currentUserIdentity.map { [$0] } ?? [])
        for note in snapshot.threads.flatMap(\.notes) {
            if let person = note.author?.person { directory.insert(person) }
        }
        return directory.person(username: username)
    }

    private func threadView(_ thread: MRDiscussionSnapshot.Thread, currentUser: PersonIdentity?) -> some View {
        let anchor = MRDiscussionNavigation.Anchor(threadID: thread.id)
        let expansion = navigation?.anchor == anchor ? navigation : nil
        return MRDiscussionThreadView(thread: thread, mergeRequestURL: mergeRequestURL,
                               currentUsername: currentUsername, currentUser: currentUser, markdownCache: markdownCache, initiallyExpanded: expandPendingDrafts && !thread.drafts.isEmpty,
                               selection: selection, selectionDisabled: selectionDisabled,
                               extraContexts: extraContexts, replyTo: replyMessage(thread.id),
                               onDelete: onDelete, onRegenerate: onRegenerate, aiReplyControls: aiReplyControls,
                               onSetOrigin: onSetOrigin,
                               navigation: expansion)
            .id(anchor)
    }

    private func replyMessage(_ discussionID: String) -> RemotePeopleMessage? {
        .init(.Board.boardReplyTo, people: replyRecipients[discussionID] ?? [])
    }
}

struct AIReplyControls {
    let decisions: [Int: [MergeRequestAttentionMonitor.AIReplyDecision]]
    let choose: (MergeRequestAttentionMonitor.AIReplyChoice, MergeRequestAttentionMonitor.AIReplyDecision, GitLabDraftNote) -> Void
}

typealias MRDiscussionOriginAction = (AICommentOriginOverride.Classification?, [GitLabMergeRequestDiscussion.Note]) -> Void

private struct MRDiscussionThreadView: View {
    let thread: MRDiscussionSnapshot.Thread
    let mergeRequestURL: URL
    let currentUsername: String?
    let currentUser: PersonIdentity?
    let markdownCache: MRDiscussionMarkdownCache
    let initiallyExpanded: Bool
    let selection: Binding<DraftPublicationSelection>?
    let selectionDisabled: Bool
    var extraContexts: AICommentProvenanceStore.ExtraContexts = .empty
    var replyTo: RemotePeopleMessage? = nil
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    var onRegenerate: ((GitLabDraftNote) -> Void)? = nil
    var aiReplyControls: AIReplyControls? = nil
    var onSetOrigin: MRDiscussionOriginAction? = nil
    let navigation: MRDiscussionNavigation?
    @State private var isExpanded = false
    @State private var appliedInitialExpansion = false
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
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 12) {
                        // The first comment's author line stays in the header; its body continues here.
                        if let first = comments.first {
                            MRDiscussionNoteContent(note: first, threadLocation: thread.location, markdownCache: markdownCache)
                        }
                        ForEach(StableRowKey.rows(Array(comments.dropFirst()), id: \.id)) { row in
                            let note = row.element
                            Divider().padding(.vertical, 2)
                            MRDiscussionNoteView(note: note, origin: note.id.flatMap { thread.origins[$0] },
                                                 authorKind: (note.author?.id).flatMap { thread.authorKinds[$0] },
                                                 mergeRequestURL: mergeRequestURL, threadLocation: thread.location,
                                                 markdownCache: markdownCache, onSetOrigin: noteOriginAction(note), extraContext: extraContexts.forNote(note.id))
                        }
                        if selection == nil { draftRows }
                    }
                    .padding(.top, 10)
                }
            } label: {
                threadHeader(firstComment: comments.first, summary: summary, originBadge: originBadge)
            }
            .disclosureGroupStyle(MRDiscussionDisclosureStyle())
            if selection != nil { draftRows }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !appliedInitialExpansion else { return }
            appliedInitialExpansion = true
            if initiallyExpanded { isExpanded = true }
        }
        .onChange(of: navigation, initial: true) { _, request in
            if request != nil { isExpanded = true }
        }
        .alert(threadOriginTitle, isPresented: Binding(get: { threadOriginRequest != nil },
                                                       set: { if !$0 { threadOriginRequest = nil } }),
               presenting: threadOriginRequest) { request in
            Button(role: .cancel) { threadOriginRequest = nil } label: { Text(.MRDiscussions.mrDiscussionsOriginCancel) }
            Button { onSetOrigin?(request.classification, comments); threadOriginRequest = nil } label: {
                Text(.MRDiscussions.mrDiscussionsOriginConfirm)
            }
            .disabled(containsBotComment)
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
        guard let onSetOrigin, note.id.flatMap({ thread.origins[$0] }) != .botAccount else { return nil }
        return { onSetOrigin($0, [note]) }
    }

    private var containsBotComment: Bool {
        thread.notes.contains { $0.system != true && $0.id.flatMap { thread.origins[$0] } == .botAccount }
    }

    private var containsOnlyBotComments: Bool {
        let comments = thread.notes.filter { $0.system != true }
        return !comments.isEmpty && comments.allSatisfy { $0.id.flatMap { thread.origins[$0] } == .botAccount }
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
                if let feedback = thread.feedback { MRDiscussionFeedbackBadge(state: feedback) }
                replyStatus(summary)
                if let originBadge {
                    MRDiscussionOriginBadge(badge: originBadge, origin: containsOnlyBotComments ? .botAccount : nil,
                        isManual: !thread.origins.isEmpty && thread.origins.values.allSatisfy(\.isManual),
                        scope: .thread,
                        onSelect: onSetOrigin == nil || containsBotComment ? nil : { threadOriginRequest = .init(classification: $0) })
                }
            }
            if let location = thread.location {
                MRDiscussionLocationLabel(location: .init(full: location))
            }
            if let firstComment {
                MRDiscussionNoteHeader(note: firstComment, origin: firstComment.id.flatMap { thread.origins[$0] },
                    authorKind: (firstComment.author?.id).flatMap { thread.authorKinds[$0] },
                    mergeRequestURL: mergeRequestURL, onSetOrigin: noteOriginAction(firstComment),
                    extraContext: extraContexts.forNote(firstComment.id))
                    .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary)
                if !isExpanded, let body = firstComment.body {
                    Text(markdownCache.render(body) ?? AttributedString(body)).font(.callout)
                        .foregroundStyle(thread.state == .resolved ? Color.secondary : Color.primary).lineLimit(2)
                        .padding(.top, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func replyStatus(_ summary: MRDiscussionSnapshot.Thread.ReplySummary) -> some View {
        if summary.showsPublishedReply {
            MRDiscussionReplyBadge(state: summary.publishedReply)
        }
        if summary.draftCount > 0 {
            Label { Text(.MRDiscussions.mrDiscussionsDraftCount(summary.draftCount)) } icon: {
                Image(systemName: "square.and.pencil")
            }
            .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
        }
    }

    private var draftRows: some View {
        ForEach(StableRowKey.rows(thread.drafts, id: \.id)) { row in
            let draft = row.element
            MRDiscussionDraftView(draft: draft, author: currentUser, markdownCache: markdownCache,
                                  replyTo: replyTo, threadLocation: thread.location,
                extraContext: extraContexts.forDraft(draft),
                selection: selection, selectionDisabled: selectionDisabled, onDelete: onDelete, onRegenerate: onRegenerate, aiReplyControls: aiReplyControls)
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
    let markdownCache: MRDiscussionMarkdownCache
    var onSetOrigin: ((AICommentOriginOverride.Classification?) -> Void)? = nil
    var extraContext: AICommentProvenanceStore.ExtraContexts.Entry? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MRDiscussionNoteHeader(note: note, origin: origin, authorKind: authorKind,
                                   mergeRequestURL: mergeRequestURL, onSetOrigin: onSetOrigin,
                                   extraContext: extraContext)
            MRDiscussionNoteContent(note: note, threadLocation: threadLocation, markdownCache: markdownCache)
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
    var extraContext: AICommentProvenanceStore.ExtraContexts.Entry? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MRDiscussionAuthorView(author: note.author, accountKind: origin == .botAccount ? nil : authorKind)
                .layoutPriority(1)
            if let origin {
                MRDiscussionOriginBadge(badge: origin.badge, origin: origin, isManual: origin.isManual,
                                        scope: .comment, onSelect: onSetOrigin)
            }
            Spacer(minLength: 4)
            if let extraContext { ExtraContextButton(context: extraContext) }
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
    let markdownCache: MRDiscussionMarkdownCache

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let location = MRDiscussionLocation(position: note.position), location.full != threadLocation {
                MRDiscussionLocationLabel(location: location).textSelection(.enabled)
            }
            MRDiscussionBody(source: note.body, markdownCache: markdownCache)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MRDiscussionDraftView: View {
    let draft: GitLabDraftNote
    let author: PersonIdentity?
    let markdownCache: MRDiscussionMarkdownCache
    var replyTo: RemotePeopleMessage? = nil
    var threadLocation: String? = nil
    var mergeRequestURL: URL? = nil
    var codeContext: MRDiscussionCodeContext? = nil
    var extraContext: AICommentProvenanceStore.ExtraContexts.Entry? = nil
    var selection: Binding<DraftPublicationSelection>? = nil
    var selectionDisabled = false
    var onDelete: ((GitLabDraftNote) -> Void)? = nil
    var onRegenerate: ((GitLabDraftNote) -> Void)? = nil
    var aiReplyControls: AIReplyControls? = nil

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
                if let extraContext { ExtraContextButton(context: extraContext) }
                if let onRegenerate, let id = draft.id, DraftPublicationSelection.canSelect(draft) {
                    Button { onRegenerate(draft) } label: { CodingProviderIcon() }
                        .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                        .disabled(selectionDisabled)
                        .help(Text(.DraftRegeneration.draftRegenerationOneAction))
                        .accessibilityLabel(Text(.DraftRegeneration.draftRegenerationOneAction))
                        .accessibilityIdentifier("draft-regeneration.draft.\(id)")
                }
                if let onDelete { DraftDeleteButton(draft: draft, disabled: selectionDisabled, onDelete: onDelete) }
            }
            .font(.callout)
            if let replyTo {
                Label { PeopleMessageLabel(message: replyTo) } icon: { Image(systemName: "arrowshape.turn.up.left") }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let location = MRDiscussionLocation(position: draft.position), location.full != threadLocation {
                MRDiscussionLocationLabel(location: location).textSelection(.enabled)
            }
            if let mergeRequestURL, let position = draft.position,
               position.newLine != nil || position.oldLine != nil {
                let request = codeContext?.request(for: position)
                MRDiscussionCodePreview(request: request, codeContext: codeContext,
                    changesURL: MRDiscussionCodeAnchor.changesURL(for: position, mergeRequestURL: mergeRequestURL))
                    .id(request)
            }
            MRDiscussionBody(source: draft.note, markdownCache: markdownCache)
            DraftPublicationWarnings(drafts: [draft])
            if let aiReplyControls, let id = draft.id {
                ForEach(aiReplyControls.decisions[id] ?? []) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(.CommentReview.commentReviewUnconfirmedAI(source.authorLabel))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: source.excerpt).font(.caption).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Button { aiReplyControls.choose(.reply, source, draft) } label: {
                            Text(.CommentReview.commentReviewReplyAI)
                        }
                        Button { aiReplyControls.choose(.human, source, draft) } label: {
                            Text(.CommentReview.commentReviewMarkHuman)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(selectionDisabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.45)).frame(width: 2) }
    }
}

struct MRDiscussionCodeContext {
    let target: MRDiscussionTarget
    let accountRevision: UInt64
    let sourceProjectID: Int?
    let targetProjectID: Int?
    let glab: GlabService

    struct Request: Hashable {
        let target: MRDiscussionTarget
        let accountRevision: UInt64
        let projectID: Int
        let anchor: MRDiscussionCodeAnchor
    }

    func request(for position: GitLabDraftNote.Position) -> Request? {
        guard let anchor = MRDiscussionCodeAnchor(position) else { return nil }
        let projectID = anchor.side == .new ? sourceProjectID : targetProjectID
        return .init(target: target, accountRevision: accountRevision, projectID: projectID ?? target.projectID, anchor: anchor)
    }
}

private struct MRDiscussionCodePreview: View {
    let request: MRDiscussionCodeContext.Request?
    let codeContext: MRDiscussionCodeContext?
    let changesURL: URL
    @State private var lines: [MRDiscussionCodeAnchor.Line]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lines, !lines.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                        ForEach(lines) { line in
                            let highlighted = line.number == request?.anchor.line
                            GridRow {
                                Text(verbatim: String(line.number)).foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(verbatim: line.text).fixedSize(horizontal: true, vertical: false)
                            }
                            .fontWeight(highlighted ? .semibold : .regular)
                            .background(highlighted ? Color.accentColor.opacity(0.15) : .clear)
                        }
                    }
                    .padding(8)
                    .font(.caption.monospaced()).textSelection(.enabled)
                }
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } else if request == nil || lines != nil {
                Text(.MRDiscussions.mrDiscussionsCodeUnavailable).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(.MRDiscussions.mrDiscussionsCodeLoading).foregroundStyle(.secondary)
                }
            }
            Link(destination: changesURL) {
                Label(.MRDiscussions.mrDiscussionsOpenChanges, systemImage: "arrow.up.right.square")
            }
        }
        .font(.caption)
        .task {
            guard lines == nil, let request, let glab = codeContext?.glab,
                  request.accountRevision == glab.accountRevision else { return }
            let result = try? await glab.fetchDiscussionCode(request.anchor, in: request.projectID, for: request.target)
            guard !Task.isCancelled, request.accountRevision == glab.accountRevision else { return }
            lines = result ?? []
        }
    }
}

/// App-only agent explanation. It is local display data and never part of the published comment.
private struct ExtraContextButton: View {
    let context: AICommentProvenanceStore.ExtraContexts.Entry
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            if context.proposedSolution {
                Text(.MRDiscussions.mrDiscussionsProposedSolution).font(.caption)
            } else {
                Label(.MRDiscussions.mrDiscussionsExtraContext, systemImage: "lightbulb")
                    .font(.caption.weight(.medium))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(context.proposedSolution ? Color.secondary : Color.accentColor)
        .help(Text(.MRDiscussions.mrDiscussionsExtraContextHelp))
        .accessibilityHint(Text(.MRDiscussions.mrDiscussionsExtraContextHelp))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label { Text(.MRDiscussions.mrDiscussionsExtraContextHelp) } icon: { Image(systemName: "lock") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ExtraContextMarkdown(source: context.markdown).font(.callout)
                }
                .padding(16)
            }
            .frame(width: 440)
            .frame(maxHeight: 520)
        }
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
        if origin == .botAccount { return .AuthorFeedback.authorFeedbackBotAuthor }
        if origin == .appGenerated { return .MRDiscussions.mrDiscussionsAiMergeTether }
        return switch badge {
        case .ai: .MRDiscussions.mrDiscussionsAi
        case .uncertain: .MRDiscussions.mrDiscussionsAiUncertain
        case .human: .MRDiscussions.mrDiscussionsHuman
        }
    }
    private var color: Color {
        if origin == .botAccount { return .secondary }
        return switch badge {
        case .ai: .purple
        case .uncertain: .orange
        case .human: .teal
        }
    }
    private var symbol: String {
        if origin == .botAccount { return "gearshape" }
        if origin == .appGenerated { return "wand.and.stars" }
        return switch badge {
        case .ai: "sparkles"
        case .uncertain: "questionmark"
        case .human: "person.fill"
        }
    }
    private var explanation: Text {
        var text: Text = switch origin {
        case .botAccount: Text(.MRDiscussions.mrDiscussionsBotOriginHelp)
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
        if onSelect != nil && origin != .botAccount {
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
        Group {
            if origin == .botAccount {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape").accessibilityHidden(true)
                    Text(title)
                }
            } else {
                Label {
                    HStack(spacing: 3) {
                        Text(title)
                        if isManual { Image(systemName: "hand.raised.fill").imageScale(.small).accessibilityHidden(true) }
                        if onSelect != nil { Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true) }
                    }
                } icon: { Image(systemName: symbol) }
            }
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        if let onSelect, origin != .botAccount {
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

private struct MRDiscussionBody: View {
    let source: String?
    let markdownCache: MRDiscussionMarkdownCache
    private var rendered: AttributedString? { source.flatMap(markdownCache.render) }
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
        case .informational: .MRDiscussions.mrDiscussionsFeedbackInformational
        case .ignored: .MRDiscussions.mrDiscussionsFeedbackIgnored
        case .partlyIgnored: .MRDiscussions.mrDiscussionsFeedbackPartlyIgnored
        case .notApplicable: .MRDiscussions.mrDiscussionsFeedbackNotApplicable
        }
    }
    private var color: Color {
        switch state {
        case .addressed: .green
        case .pending: .orange
        case .informational, .ignored, .partlyIgnored, .notApplicable: .secondary
        }
    }
    private var symbol: String {
        switch state {
        case .addressed: "checkmark.seal"
        case .pending: "exclamationmark.bubble"
        case .informational, .notApplicable: "info.circle"
        case .ignored, .partlyIgnored: "minus.circle"
        }
    }
    private var explanation: LocalizedStringResource {
        switch state {
        case .addressed: .MRDiscussions.mrDiscussionsFeedbackAddressedHelp
        default: .MRDiscussions.mrDiscussionsFeedbackHelp
        }
    }
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.08), in: Capsule())
            .help(Text(explanation))
            .accessibilityHint(Text(explanation))
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
