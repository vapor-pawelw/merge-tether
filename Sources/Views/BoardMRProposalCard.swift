import AppKit
import SwiftUI

struct BoardMRProposalCard: View {
    let proposal: MergeRequestBoardSnapshot.Proposal
    let monitor: TodoMonitorService
    @State private var isWorking = false
    @State private var failed = false
    @State private var confirmIgnore = false
    @State private var showingDetails = false
    @State private var authorLoader: ProposalAuthorLoader

    init(proposal: MergeRequestBoardSnapshot.Proposal, monitor: TodoMonitorService) {
        self.proposal = proposal
        self.monitor = monitor
        _authorLoader = State(initialValue: ProposalAuthorLoader(glab: monitor.glab) { request, target, url, revision, startedAt in
            monitor.recordBoardDisplayRequest(request, for: target, url: url, accountRevision: revision, readStartedAt: startedAt)
        })
    }

    private var currentRequest: GitLabMergeRequest? {
        monitor.boardDisplayRequest(for: proposal.target, url: proposal.url) ?? proposal.item?.mergeRequest
    }
    private var finishedState: MergeRequestFinishedState? { .init(currentRequest) }
    private var isMuted: Bool {
        monitor.boardActivity(projectID: proposal.target.projectID, iid: proposal.target.iid ?? 0,
            url: proposal.url, isDraft: isDraft, isFinished: finishedState != nil).isMuted
    }
    private var finishedItem: MergeRequestAttentionMonitor.Item? {
        guard monitor.glab.resolvedHost == proposal.target.host,
              monitor.glab.currentUsername == proposal.target.username,
              let request = currentRequest, finishedState != nil,
              request.projectID == proposal.target.projectID, request.iid == proposal.target.iid,
              request.webURL == proposal.url else { return nil }
        var item = proposal.item ?? .init(id: .init(projectID: request.projectID, iid: request.iid),
            title: request.title, url: request.webURL)
        item.mergeRequest = request
        item.isAuthored = request.author.username == proposal.target.username
        item.lifecycleCompletionID = monitor.settings.mrLifecycleLedger.completionID(for: proposal.target)
        return item
    }

    private var context: ProposalMRContext {
        ProposalMRContext(proposal: proposal, fetchedRequest: currentRequest)
    }

    private var authorTaskID: String {
        "\(proposal.target.host)/\(proposal.target.username)/\(proposal.target.projectID)/\(proposal.target.iid ?? 0)/\(proposal.url)|\(monitor.glab.resolvedHost ?? "")/\(monitor.glab.currentUsername ?? "")/\(monitor.glab.accountRevision)"
    }

    private var isDraft: Bool {
        if let draft = currentRequest?.draft { return draft }
        if let item = proposal.item { return item.section == .draftMergeRequests }
        return proposal.todos.contains(where: \.isDraft)
            || proposal.intents.contains {
                $0.target == proposal.target && ProposalMRContext.matches($0.request, proposal: proposal)
                    && $0.request.draft == true
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            VStack(alignment: .leading, spacing: 3) {
                Button { showingDetails = true } label: {
                    BoardCardTitle(title: proposal.title, repositoryPath: proposal.url.gitLabProjectPath,
                        titleColor: isMuted ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                if let iid = proposal.target.iid {
                    BoardMRReferenceLine(iid: iid, projectID: proposal.target.projectID, dependencies: proposal.item?.dependencies)
                }
            }
            if let finishedItem {
                FinishedMergeRequestStatus(item: finishedItem, monitor: monitor)
            } else {
                reasons
                if failed {
                    BoardStatusChip(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle", tint: isMuted ? .secondary : .orange)
                        .help(Text(.Menu.menuMrAddFailed))
                }
                runResult
                HStack {
                    Button {
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            if let todo = proposal.todos.first {
                                await monitor.adoptMRTodoProposal(todo)
                            } else {
                                do {
                                    _ = try await monitor.addManagedMergeRequest(from: proposal.url.absoluteString)
                                    for intent in proposal.intents where intent.state == .pending || intent.state == .failed {
                                        await monitor.runMRTodoIntent(id: intent.id)
                                    }
                                } catch { failed = true }
                            }
                        }
                    } label: { Text(.Board.boardProposalAddAndHandle) }
                    .buttonStyle(.bordered).help(Text(.Board.boardProposalDescription))
                    Button { confirmIgnore = true } label: { Text(.Board.boardProposalIgnore) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                .disabled(isWorking)
            }
        }
        .confirmationDialog(Text(.Board.boardProposalIgnore), isPresented: $confirmIgnore, titleVisibility: .visible) {
            Button(role: .destructive) {
                isWorking = true
                Task {
                    defer { isWorking = false }
                    await monitor.ignoreMergeRequestProposal(projectID: proposal.target.projectID,
                        iid: proposal.target.iid ?? 0, url: proposal.url)
                }
            } label: { Text(.Board.boardProposalIgnore) }
        } message: { Text(.Board.boardProposalIgnoreExplanation) }
        .controlSize(.small)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.12), lineWidth: 0.5))
        .boardCardInteraction { showingDetails = true }
        .contextMenu { menuItems }
        .task(id: authorTaskID) { await authorLoader.load(proposal, displayMetadata: true) }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                Text(verbatim: proposal.title).font(.title3).textSelection(.enabled)
                if let iid = proposal.target.iid {
                    BoardMRReferenceLine(iid: iid, projectID: proposal.target.projectID, dependencies: proposal.item?.dependencies)
                }
                Text(verbatim: proposal.url.gitLabProjectPath).foregroundStyle(.secondary)
                ForEach(context.reasons) { value in
                    VStack(alignment: .leading, spacing: 6) {
                        reason(value)
                        if case .event(let todo) = value {
                            if !todo.body.isEmpty { Text(verbatim: todo.body).textSelection(.enabled) }
                            Text(todo.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Link(destination: proposal.url) {
                    Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
                }
                if let finishedItem { FinishedMergeRequestStatus(item: finishedItem, monitor: monitor) }
                if let job = proposal.latestJob { AssistantJobRow(handoff: job, monitor: monitor, readOnly: finishedState != nil) }
                if finishedState == nil {
                    MRAutomationScopeMenu(monitor: monitor, target: proposal.target,
                        projectPath: proposal.url.gitLabProjectPath, isDraft: isDraft)
                }
            }
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            author
            Spacer(minLength: 4)
            if let finishedState { FinishedMergeRequestBadge(state: finishedState) }
            else {
                BoardStatusChip(title: .Board.boardCompactProposal, symbol: "plus.circle")
                if isDraft { BoardDraftBadge() }
            }
            HStack(spacing: 0) {
                if finishedState == nil {
                    BoardAutomationToggle(settings: monitor.settings, target: proposal.target,
                        projectPath: proposal.url.gitLabProjectPath, isDraft: isDraft)
                }
                BoardPinButton(pin: .mergeRequest(host: proposal.target.host, username: proposal.target.username,
                    projectID: proposal.target.projectID, iid: proposal.target.iid ?? 0), settings: monitor.settings)
                moreMenu
            }
        }
    }

    private var moreMenu: some View {
        BoardActionsMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button { showingDetails = true } label: {
            Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
        }
        Link(destination: proposal.url) {
            Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
        }
        GitLabRefreshButton(monitor: monitor,
            itemID: proposal.target.iid.map { .init(projectID: proposal.target.projectID, iid: $0) }) {
            await authorLoader.load(proposal, force: true)
        }
        AssistantContextMenu(mergeRequestURL: proposal.url, title: proposal.title,
            settings: monitor.settings)
        if finishedState == nil {
            Divider()
            MRAutomationScopeMenu(monitor: monitor, target: proposal.target,
                projectPath: proposal.url.gitLabProjectPath, isDraft: isDraft)
        }
    }

    @ViewBuilder
    private var author: some View {
        if let author = context.author {
            BoardCardAuthor(author: author)
        } else {
            HStack(spacing: 5) {
                if authorLoader.isLoading(proposal) { ProgressView().controlSize(.mini) }
                Text(authorLoader.isLoading(proposal) ? .Proposal.proposalAuthorLoading : .Proposal.proposalAuthorUnknown)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runResult: some View {
        if let job = proposal.latestJob {
            BoardJobStatusActions(handoff: job, monitor: monitor, muted: isMuted)
            Button { showingDetails = true } label: {
                Text(.MRHumanAction.mrHumanActionActionReviewRun)
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var reasons: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let first = context.reasons.first { reason(first).lineLimit(2) }
            if context.reasons.count > 1 {
                Menu {
                    ForEach(context.reasons) { reason($0) }
                } label: { Text(.Proposal.proposalMoreReasons(context.reasons.count - 1)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(Text(.Proposal.proposalMoreReasonsHelp))
            }
        }
        .font(.callout).foregroundStyle(isMuted ? Color.secondary : Color.primary)
    }

    @ViewBuilder
    private func reason(_ reason: ProposalMRContext.Reason) -> some View {
        switch reason {
        case .event(let todo):
            ActionDescriptionText(todo: todo, currentUsername: proposal.target.username)
        case .intent(let kind):
            switch kind {
            case .review: Text(.Proposal.proposalReasonReview)
            case .followUp: Text(.Proposal.proposalReasonFollowUp)
            case .pipeline: Text(.Proposal.proposalReasonPipeline)
            case .conflict: Text(.Proposal.proposalReasonConflict)
            case .refresh: Text(.Proposal.proposalReasonRefresh)
            }
        case .pipeline: Text(.Proposal.proposalReasonPipeline)
        case .conflict: Text(.Proposal.proposalReasonConflict)
        case .feedback: Text(.Proposal.proposalReasonFeedback)
        case .merge: Text(.Proposal.proposalReasonMerge)
        case .drafts: Text(.Proposal.proposalReasonDrafts)
        case .unmanaged: Text(.Proposal.proposalReasonUnmanaged)
        }
    }
}
