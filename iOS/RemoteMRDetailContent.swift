import SwiftUI
import MergeTetherRemote

struct RemoteMRDetailContent: View {
    let details: RemoteMRDetails
    let card: RemoteCard
    let account: String
    var personalApproval: RemotePersonalApprovalControl? = nil
    var reviewerEditing: ReviewerEditing? = nil
    var onRefreshActivity: (() -> Void)? = nil
    var canRefreshActivity = false
    /// Present when the Mac accepts comment-origin changes from this phone.
    var onCommentOrigin: ((RemoteCommentOriginRequest) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingApprovals = false
    @State private var reviewerEditor = ReviewerEditorState()
    @State private var discussionsExpanded = true
    @State private var selectedActivityNote: RemoteDetailActivity.Note?
    /// Holds that stop work lead; saved rules sit with the reference data, as on the Mac.
    private var rules: [String] { details.rules ?? [] }
    private var visiblePolicy: [String] { card.visiblePolicy(details.policy.filter { !rules.contains($0) }) }

    var body: some View {
        Group {
            // Same order as the Mac detail: what applies now, then the conversation, then reference data.
            if !visiblePolicy.isEmpty {
                section(.RemoteDetail.remoteDetailPolicy) {
                    ForEach(Array(visiblePolicy.enumerated()), id: \.offset) { _, message in
                        Text(verbatim: message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let dependencies = card.dependencies {
                section(.RemoteDetail.remoteDetailDependencies) {
                    if let position = dependencies.stackPosition { Text(.MRDependencies.mrDependenciesStackPosition(position)).font(.callout) }
                    ForEach(Array(dependencies.predecessors.enumerated()), id: \.offset) { _, predecessor in
                        VStack(alignment: .leading, spacing: 5) {
                            if ["https", "http"].contains(predecessor.url.scheme?.lowercased() ?? ""), predecessor.url.host == card.url?.host {
                                Link(destination: predecessor.url) {
                                    Text(verbatim: predecessor.reference + " · " + predecessor.title)
                                        .frame(minHeight: 44, alignment: .leading)
                                }.font(.callout)
                            } else { Text(verbatim: predecessor.reference + " · " + predecessor.title).font(.callout) }
                            if !predecessor.isCurrent {
                                Text(.MRDependencies.mrDependenciesLastKnown).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let notice = dependencies.notice { Text(verbatim: notice).font(.callout).foregroundStyle(.secondary) }
                }
            }
            section(.RemoteDetail.remoteDetailFeedback) {
                if details.feedback.isEmpty {
                    Text(.RemoteDetail.remoteDetailNoFeedback).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(details.feedback.enumerated()), id: \.offset) { _, field in fieldView(field) }
                }
            }
            .id(RemoteCardCTA.Destination.feedback)
            section(.RemoteDetail.remoteDetailDiscussions,
                    background: colorScheme == .light ? Color(white: 0.96) : sectionBackground,
                    expansion: $discussionsExpanded) {
                if let resume = details.originResume, let onCommentOrigin {
                    RemoteOriginResumeBanner(resume: resume, onCommentOrigin: onCommentOrigin)
                }
                if let threads = details.threads {
                    let proposalIDs = Set(details.proposedSolutionDraftIDs ?? [])
                    if threads.isEmpty {
                        Text(details.truncated ? .RemoteDetail.remoteDetailTruncated : .RemoteDetail.remoteDetailNoDiscussions)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    // Long conversations: only threads near the viewport are built and measured.
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(threads) { thread in
                            RemoteDiscussionCard(thread: thread, mergeRequestURL: card.url,
                                drafts: card.drafts.filter { thread.draftIDs?.contains($0.id) == true },
                                draftContexts: details.draftContexts ?? [:], proposalIDs: proposalIDs,
                                onCommentOrigin: onCommentOrigin)
                        }
                    }
                } else { unavailable }
            }
            .id(RemoteCardCTA.Destination.discussions)
            section(.RemoteDetail.remoteDetailApprovals) {
                if let approvals = details.approvals {
                    RemoteApprovalSummary(details: approvals)
                    Button { showingApprovals = true } label: {
                        Label(.RemoteDetail.remoteDetailPeopleAndRules, systemImage: "person.2")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("remote.details.approvals")
                } else { unavailable }
            }
            .id(RemoteDetailAnchor.approvals)
            section(.RemoteDetail.remoteDetailOverview) {
                ForEach(Array(details.metadata.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }
                if let automation = details.automation {
                    Divider()
                    // Read-only, like the Mac's lightning panel header; switching stays on the Mac.
                    Label { Text(verbatim: automation.summary) } icon: {
                        Image(systemName: automation.active ? "bolt.fill" : "bolt.slash")
                            .foregroundStyle(automation.active ? Color.accentColor : Color.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
                if !rules.isEmpty {
                    if details.automation == nil { Divider() }
                    Text(.RemoteDetail.remoteDetailAutomationRules).font(.subheadline.weight(.medium))
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        Text(verbatim: rule).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !details.reasons.isEmpty {
                    Divider()
                    ForEach(Array(details.reasons.enumerated()), id: \.offset) { _, reason in
                        Label { Text(verbatim: reason) } icon: { Image(systemName: "info.circle") }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            section(.RemoteDetail.remoteDetailActivity) {
                Text(.RemoteDetail.remoteDetailHistoryHelp).font(.caption).foregroundStyle(.secondary)
                if details.activityPartial == true {
                    Label(.RemoteDetail.remoteDetailActivityPartial, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    if let onRefreshActivity {
                        Button(action: onRefreshActivity) {
                            Text(.RemoteDetail.remoteDetailRefresh).frame(minHeight: 44)
                        }
                        .disabled(!canRefreshActivity)
                    }
                } else if details.activity.isEmpty {
                    Text(.RemoteDetail.remoteDetailNoActivity).font(.callout).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 14) { ForEach(details.activity) { activity in
                    let note = activity.note
                    RemoteActivityRow(activity: activity, noteURL: note?.linkURL(card: card, account: account),
                        openDiscussion: note?.matchingThread(in: details.threads) != nil ? { selectedActivityNote = note } : nil)
                    Divider()
                } }
            }
            .id(RemoteCardCTA.Destination.assistantRuns)
            section(.RemoteDetail.remoteDetailUsage) {
                if let usage = details.usage {
                    ForEach(Array(usage.enumerated()), id: \.offset) { _, field in fieldView(field) }
                } else { unavailable }
            }
        }
        .sheet(isPresented: $showingApprovals, onDismiss: {
            reviewerEditor.isEditing = false
            reviewerEditor.finishAdding()
        }) {
            RemoteApprovalDetailsView(details: details.approvals ?? .init(progress: nil), mergeRequestURL: card.url,
                approvedWithOpenFindings: card.presentation?.approvedWithOpenFindings == true,
                personalApproval: personalApproval, reviewerEditing: reviewerEditing,
                automaticApprovalOff: card.presentation?.automaticApprovalOff == true, reviewerEditor: reviewerEditor)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedActivityNote) { note in
            if let thread = activityDiscussion(note) {
                activityDiscussionSheet(thread: thread, note: note)
            }
        }
        .onChange(of: selectedActivityNote.flatMap(activityDiscussion) == nil) { _, unavailable in
            if unavailable { selectedActivityNote = nil }
        }
        .modifier(ReviewerSaveErrorAlert(state: reviewerEditor, editorClosed: !showingApprovals))
    }

    private func activityDiscussion(_ note: RemoteDetailActivity.Note) -> RemoteDetailThread? {
        guard details.activity.contains(where: { $0.note == note }) else { return nil }
        return note.matchingThread(in: details.threads)
    }

    private func activityDiscussionSheet(thread: RemoteDetailThread, note: RemoteDetailActivity.Note) -> some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    RemoteDiscussionCard(thread: thread, mergeRequestURL: card.url, initiallyExpanded: true)
                        .padding(16)
                }
                .task { proxy.scrollTo(String(note.id), anchor: .top) }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(Text(.RemoteDetail.remoteDetailDiscussions))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.Remote.remoteClose) { selectedActivityNote = nil }
                }
            }
        }
    }

    @ViewBuilder private func fieldView(_ field: RemoteDetailField) -> some View {
        // A person names either the label (feedback from a reviewer) or the value (the MR author).
        let person = field.person.map { PersonIdentity(name: $0.name, username: $0.username, avatarURL: $0.avatarURL) }
        let personIsLabel = person.map { $0.displayName == field.label || $0.handle == field.label } ?? false
        VStack(alignment: .leading, spacing: 5) {
            if let person, personIsLabel {
                HStack(spacing: 8) {
                    PersonLabel(person: person, avatarSize: 20).font(.subheadline.weight(.medium))
                    if let url = safeLink(field.url, to: card.url) {
                        Spacer(minLength: 4)
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .accessibilityLabel(Text(verbatim: field.label))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }.frame(minHeight: 44, alignment: .leading)
            } else if let url = safeLink(field.url, to: card.url) {
                Link(destination: url) { Label { Text(verbatim: field.label) } icon: { Image(systemName: "arrow.up.right.square") } }
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44, alignment: .leading)
            } else { Text(verbatim: field.label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
            if let person, !personIsLabel {
                PersonLabel(person: person, avatarSize: 20).font(.callout)
            } else if let message = field.peopleMessage {
                PeopleMessageLabel(message: message).font(.callout)
                if let supportingText = field.supportingText {
                    Text(verbatim: supportingText).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(verbatim: field.value).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var unavailable: some View { Text(.RemoteDetail.remoteDetailUnavailable).font(.callout).foregroundStyle(.secondary) }
    private var sectionBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private func section<Content: View>(_ title: LocalizedStringResource, background: Color? = nil,
                                        expansion: Binding<Bool>? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        let sectionContent = content()
        return VStack(alignment: .leading, spacing: 14) {
            if let expansion {
                DisclosureGroup(isExpanded: expansion) {
                    sectionContent.padding(.top, 8)
                } label: {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { expansion.wrappedValue.toggle() }
                }
                .tint(.secondary)
            } else {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                sectionContent
            }
        }
        .padding(.horizontal, 16).padding(.vertical, expansion?.wrappedValue == false ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background ?? sectionBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RemoteActivityRow: View {
    let activity: RemoteDetailActivity
    let noteURL: URL?
    let openDiscussion: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        if activity.summary != nil || activity.head != nil || noteURL != nil || openDiscussion != nil {
            disclosure
        } else {
            heading
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // Full-width leading stack: without it the disclosure centres short lines.
            VStack(alignment: .leading, spacing: 4) {
                if let summary = activity.summary {
                    Text(verbatim: summary).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
                }
                if let head = activity.head {
                    Text(.RemoteSecurity.remoteSecurityCommit).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: head).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let openDiscussion {
                    Button(action: openDiscussion) {
                        Label(.RemoteDetail.remoteDetailOpenDiscussion, systemImage: "bubble.left")
                            .frame(minHeight: 44)
                    }
                    .tint(.accentColor)
                }
                if let noteURL {
                    Link(destination: noteURL) {
                        Label(.CommandCenter.commandCenterOpenGitLab, systemImage: "arrow.up.right.square")
                            .frame(minHeight: 44)
                    }
                    .tint(.accentColor)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            heading.contentShape(Rectangle()).onTapGesture { withAnimation { expanded.toggle() } }
        }
        // Like the thread disclosures: a neutral chevron instead of link-blue labels.
        .tint(.secondary)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: activity.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            Text(verbatim: activity.status).font(.callout).foregroundStyle(.secondary)
            Text(activity.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

enum RemoteDetailAnchor: Hashable { case approvals }

private struct RemoteDiscussionCard: View {
    let thread: RemoteDetailThread
    let mergeRequestURL: URL?
    var drafts: [RemoteDraft] = []
    var draftContexts: [String: String] = [:]
    var proposalIDs: Set<Int> = []
    var onCommentOrigin: ((RemoteCommentOriginRequest) -> Void)? = nil
    var initiallyExpanded = false
    @State private var expansion: Bool?
    @State private var threadOriginRequest: ThreadOriginRequest?

    private struct ThreadOriginRequest: Identifiable {
        let id = UUID()
        let origin: RemoteDetailNote.Origin?
    }
    private var expanded: Bool { expansion ?? initiallyExpanded }
    private var color: Color {
        switch thread.state { case .open: .orange; case .resolved: .green; case .general: .secondary }
    }
    private var state: LocalizedStringResource {
        switch thread.state {
        case .open: .RemoteDetail.remoteDetailThreadOpen
        case .resolved: .RemoteDetail.remoteDetailThreadResolved
        case .general: .RemoteDetail.remoteDetailThreadGeneral
        }
    }
    var body: some View {
        // Not a DisclosureGroup: its label is one button, which would swallow taps on the origin menus.
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 18) {
                    if thread.truncated { Text(.RemoteDetail.remoteDetailTruncated).font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(thread.notes.enumerated()), id: \.offset) { index, note in
                        VStack(alignment: .leading, spacing: 10) {
                            // The first comment's author line stays in the header, like on the Mac.
                            if index > 0 { noteHeader(note) }
                            noteContent(note)
                        }
                        .id(note.id)
                        if note.id != thread.notes.last?.id { Divider() }
                    }
                }.padding(.top, 12)
            }
            ForEach(drafts) { draft in
                RemoteDraftCard(draft: draft, deleteAction: nil, extraContext: draftContexts[String(draft.id)],
                    proposedSolution: proposalIDs.contains(draft.id), canAct: false, onAction: { _ in })
                    .padding(.top, 12)
                    .accessibilityIdentifier("remote.thread-draft.\(draft.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpansion)
        .alert(threadOriginTitle, isPresented: Binding(get: { threadOriginRequest != nil },
                                                       set: { if !$0 { threadOriginRequest = nil } }),
               presenting: threadOriginRequest) { request in
            Button(role: .cancel) { threadOriginRequest = nil } label: { Text(.RemoteDetail.remoteDetailOriginCancel) }
            Button {
                if !thread.notes.contains(where: { $0.authorKind == .automation }),
                   let change = RemoteCommentOriginRequest.set(request.origin, notes: thread.notes, in: thread.id) {
                    onCommentOrigin?(change)
                }
                threadOriginRequest = nil
            } label: { Text(.RemoteDetail.remoteDetailOriginConfirm) }
        } message: { _ in
            Text(.RemoteDetail.remoteDetailThreadOriginMessage(thread.notes.count))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                StatusFlowLayout {
                    Label(state, systemImage: thread.state == .resolved ? "checkmark.bubble" : "bubble.left")
                        .font(.caption.weight(.medium)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(color.opacity(0.07), in: Capsule())
                    if let feedback = thread.feedback { feedbackBadge(feedback) }
                    if thread.showsPublishedReply {
                        Text(replyTitle).font(.caption).foregroundStyle(Color.blue)
                            .accessibilityHint(Text(.RemoteDetail.remoteDetailReplyPublishedHelp))
                    }
                    if thread.draftCount > 0 {
                        HStack(spacing: 5) {
                            Label(.RemoteDetail.remoteDetailDraft, systemImage: "square.and.pencil")
                            Text(thread.draftCount, format: .number)
                        }.font(.caption).foregroundStyle(.tint)
                    }
                    if let origin = thread.origin ?? (!thread.notes.isEmpty && thread.notes.allSatisfy { $0.authorKind == .automation } ? .ai : nil) {
                        originBadge(origin, manual: thread.notes.allSatisfy { $0.originManual == true }, thread: true,
                            bot: !thread.notes.isEmpty && thread.notes.allSatisfy { $0.authorKind == .automation },
                            locked: thread.notes.contains { $0.authorKind == .automation }) {
                            threadOriginRequest = .init(origin: $0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: toggleExpansion) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel(Text(.RemoteDetail.remoteDetailToggleThread))
                .accessibilityValue(Text(expanded ? .RemoteDetail.remoteDetailShowLess : .RemoteDetail.remoteDetailShowMore))
            }
            if let location = thread.location { RemoteDiscussionLocationLabel(full: location) }
            if let first = thread.notes.first {
                noteHeader(first)
                if !expanded { RemoteMarkdownText(source: first.body).font(.callout).lineLimit(3).foregroundStyle(.secondary) }
            }
        }
    }

    private func toggleExpansion() {
        withAnimation(.snappy) { expansion = !expanded }
    }

    private var threadOriginTitle: Text {
        switch threadOriginRequest?.origin {
        case .ai: Text(.RemoteDetail.remoteDetailThreadOriginAiTitle)
        case .uncertain: Text(.RemoteDetail.remoteDetailThreadOriginUncertainTitle)
        case .human: Text(.RemoteDetail.remoteDetailThreadOriginHumanTitle)
        case nil: Text(.RemoteDetail.remoteDetailThreadOriginAutomaticTitle)
        }
    }

    /// Author and origin on the left (wrapping on narrow screens), date on the right: the same line for every comment.
    private func noteHeader(_ note: RemoteDetailNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusFlowLayout(spacing: note.authorKind == .automation ? 8 : 6) {
                PersonLabel(person: .init(name: note.author, username: note.username, avatarURL: note.avatarURL), avatarSize: 20,
                            fallback: Text(.RemoteDetail.remoteDetailUnknownAuthor))
                    .font(.callout.weight(.medium))
                if let origin = note.displayOrigin {
                    originBadge(origin, manual: note.originManual == true, thread: false,
                                bot: note.authorKind == .automation, locked: note.authorKind == .automation) { choice in
                        if let change = RemoteCommentOriginRequest.set(choice, notes: [note], in: thread.id) { onCommentOrigin?(change) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let date = note.createdAt {
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func noteContent(_ note: RemoteDetailNote) -> some View {
        if let location = note.location, location != thread.location { RemoteDiscussionLocationLabel(full: location) }
        RemoteMarkdownText(source: note.body).font(.callout).lineSpacing(3).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if let extraContext = note.extraContext, !extraContext.isEmpty {
            RemoteExtraContextButton(markdown: extraContext, proposedSolution: note.proposedSolution == true)
        }
        if let url = safeLink(note.url, to: mergeRequestURL) {
            Link(destination: url) { Label(.RemoteDetail.remoteDetailOpenComment, systemImage: "arrow.up.right.square") }
                .font(.caption).frame(minHeight: 44)
        }
    }
    @ViewBuilder private func feedbackBadge(_ feedback: RemoteDetailThread.Feedback) -> some View {
        let badge: (title: LocalizedStringResource, color: Color, symbol: String)? = switch feedback {
        case .addressed: (.RemoteDetail.remoteDetailFeedbackAddressed, .green, "checkmark.seal")
        case .pending: (.RemoteDetail.remoteDetailFeedbackPending, .orange, "exclamationmark.bubble")
        case .informational: (.RemoteDetail.remoteDetailFeedbackInformational, .secondary, "info.circle")
        case .ignored: (.RemoteDetail.remoteDetailFeedbackIgnored, .secondary, "minus.circle")
        case .partlyIgnored: (.RemoteDetail.remoteDetailFeedbackPartlyIgnored, .secondary, "minus.circle")
        case .notApplicable: (.RemoteDetail.remoteDetailFeedbackNotApplicable, .secondary, "info.circle")
        case .needsVerification: nil // Older Mac hosts can still send this value.
        }
        if let badge {
            let explanation: LocalizedStringResource = feedback == .addressed
                ? .RemoteDetail.remoteDetailFeedbackAddressedHelp : .RemoteDetail.remoteDetailFeedbackHelp
            Label(badge.title, systemImage: badge.symbol).font(.caption.weight(.medium)).foregroundStyle(badge.color)
                .padding(.horizontal, 7).padding(.vertical, 3).background(badge.color.opacity(0.08), in: Capsule())
                .accessibilityHint(Text(explanation))
        }
    }
    private var replyTitle: LocalizedStringResource {
        switch thread.reply {
        case .none: .RemoteDetail.remoteDetailReplyNone
        case .published: .RemoteDetail.remoteDetailReplyPublished
        case .earlier: .RemoteDetail.remoteDetailReplyEarlier
        case .unknown, .unavailable: .RemoteDetail.remoteDetailReplyUnknown
        }
    }
    private func originTitle(_ origin: RemoteDetailNote.Origin) -> LocalizedStringResource {
        switch origin {
        case .ai: .RemoteDetail.remoteDetailOriginAI
        case .uncertain: .RemoteDetail.remoteDetailOriginUncertain
        case .human: .RemoteDetail.remoteDetailOriginHuman
        }
    }
    private func originSymbol(_ origin: RemoteDetailNote.Origin) -> String {
        origin == .ai ? "sparkles" : origin == .human ? "person" : "questionmark.circle"
    }

    private func originColor(_ origin: RemoteDetailNote.Origin, bot: Bool) -> Color {
        if bot { return .secondary }
        return switch origin { case .ai: .purple; case .uncertain: .orange; case .human: .teal }
    }

    @ViewBuilder
    private func originBadge(_ origin: RemoteDetailNote.Origin, manual: Bool, thread: Bool,
                             bot: Bool = false, locked: Bool = false,
                             onSelect: @escaping (RemoteDetailNote.Origin?) -> Void) -> some View {
        let color = originColor(origin, bot: bot)
        let title: LocalizedStringResource = bot ? .AuthorFeedback.authorFeedbackBotAuthor : originTitle(origin)
        let capsule = Group {
            if bot {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "gearshape").accessibilityHidden(true)
                    Text(title)
                }
            } else {
                Label {
                    HStack(spacing: 3) {
                        Text(title)
                        if manual { Image(systemName: "hand.raised.fill").imageScale(.small) }
                        if onCommentOrigin != nil && !locked { Image(systemName: "chevron.down").imageScale(.small) }
                    }
                } icon: { Image(systemName: originSymbol(origin)) }
            }
        }
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.08), in: Capsule())
            .fixedSize()
        if onCommentOrigin != nil && !locked {
            Menu {
                Section {
                    ForEach([RemoteDetailNote.Origin.ai, .uncertain, .human], id: \.self) { choice in
                        Button { onSelect(choice) } label: {
                            Label { Text(originTitle(choice)) } icon: {
                                Image(systemName: manual && choice == origin ? "checkmark" : originSymbol(choice))
                            }
                        }
                    }
                } header: {
                    Text(thread ? .RemoteDetail.remoteDetailThreadOriginMenuTitle : .RemoteDetail.remoteDetailOriginMenuTitle)
                }
                if manual || thread {
                    Button { onSelect(nil) } label: {
                        Label { Text(.RemoteDetail.remoteDetailOriginAutomatic) } icon: { Image(systemName: "arrow.uturn.backward") }
                    }
                }
            } label: { capsule.contentShape(Rectangle()) }
                .accessibilityLabel(manual ? Text(originTitle(origin)) + Text(verbatim: ", ") + Text(.RemoteDetail.remoteDetailOriginManual)
                                           : Text(originTitle(origin)))
                .accessibilityHint(Text(thread ? .RemoteDetail.remoteDetailThreadOriginMenuHint : .RemoteDetail.remoteDetailOriginMenuHint))
        } else {
            if bot {
                capsule.accessibilityElement(children: .combine)
                    .accessibilityHint(Text(.RemoteDetail.remoteDetailBotOriginHelp))
            } else {
                capsule.accessibilityElement(children: .combine)
            }
        }
    }
}

/// Shown while an origin change waits before automation publishes drafts; Undo goes back to the Mac.
private struct RemoteOriginResumeBanner: View {
    let resume: RemoteOriginResume
    let onCommentOrigin: (RemoteCommentOriginRequest) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(resume.resumesAt.timeIntervalSince(context.date).rounded(.up))
            if remaining > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text(.RemoteDetail.remoteDetailOriginResume(resume.drafts)).font(.callout.weight(.medium)) } icon: {
                        Image(systemName: "hourglass").foregroundStyle(.orange)
                    }
                    Text(.RemoteDetail.remoteDetailOriginResumeCountdown(remaining))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    HStack(spacing: 12) {
                        Button { onCommentOrigin(.init(operation: .undo, changeID: resume.changeID)) } label: {
                            Text(.RemoteDetail.remoteDetailOriginUndo).frame(minHeight: 32)
                        }.buttonStyle(.borderedProminent)
                        Button { onCommentOrigin(.init(operation: .continueNow, changeID: resume.changeID)) } label: {
                            Text(.RemoteDetail.remoteDetailOriginContinueNow).frame(minHeight: 32)
                        }.buttonStyle(.bordered)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// The same Markdown formatting used by the Mac for GitLab content.
struct RemoteMarkdownText: View {
    let source: String
    @State private var rendered: Rendered?
    private struct Rendered {
        let source: String
        let text: AttributedString?
    }
    var body: some View {
        Group {
            if let rendered, rendered.source == source, let text = rendered.text { Text(text) }
            else { Text(verbatim: source) }
        }
        .task(id: source) {
            let input = source
            let text = await Task.detached(priority: .userInitiated) { SafeMarkdown.render(input) }.value
            guard !Task.isCancelled else { return }
            rendered = Rendered(source: input, text: text)
        }
    }
}

private struct RemoteDiscussionLocationLabel: View {
    let full: String
    @State private var showingFullPath = false

    var body: some View {
        Button { showingFullPath = true } label: {
            Text(verbatim: full.split(separator: "/").last.map(String.init) ?? full)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(.RemoteDetail.remoteDetailShowFullPath))
        .popover(isPresented: $showingFullPath) {
            Text(verbatim: full).font(.callout.monospaced()).textSelection(.enabled)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private func safeLink(_ url: URL?, to mergeRequest: URL?) -> URL? {
    guard let url, let mergeRequest, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host == mergeRequest.host, url.path == mergeRequest.path else { return nil }
    return url
}
