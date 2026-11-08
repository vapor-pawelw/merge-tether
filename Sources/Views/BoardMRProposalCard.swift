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
        _authorLoader = State(initialValue: ProposalAuthorLoader(glab: monitor.glab))
    }

    private var currentRequest: GitLabMergeRequest? {
        authorLoader.request(for: proposal) ?? proposal.item?.mergeRequest
            ?? monitor.settings.mrLifecycleLedger.request(for: proposal.target)
    }
    private var finishedState: MergeRequestFinishedState? { .init(currentRequest) }
    private var finishedItem: MergeRequestAttentionMonitor.Item? {
        guard let request = currentRequest, finishedState != nil else { return nil }
        var item = proposal.item ?? .init(id: .init(projectID: request.projectID, iid: request.iid),
            title: request.title, url: request.webURL)
        item.mergeRequest = request
        item.isAuthored = request.author.username == proposal.target.username
        return item
    }

    private var context: ProposalMRContext {
        ProposalMRContext(proposal: proposal, fetchedRequest: authorLoader.request(for: proposal))
    }

    @ViewBuilder private var dependencyRow: some View {
        if let dependencies = proposal.item?.dependencies, dependencies.hasPresentation {
            MRDependencyRow(summary: dependencies, projectID: proposal.target.projectID).transition(.opacity)
        }
    }

    private var authorTaskID: String {
        "\(proposal.target.host)/\(proposal.target.username)/\(proposal.target.projectID)/\(proposal.target.iid ?? 0)/\(proposal.url)|\(monitor.glab.resolvedHost ?? "")/\(monitor.glab.currentUsername ?? "")"
    }

    private var isDraft: Bool {
        if let item = proposal.item { return item.section == .draftMergeRequests }
        if let draft = authorLoader.request(for: proposal)?.draft { return draft }
        return proposal.todos.contains(where: \.isDraft)
            || proposal.intents.contains {
                $0.target == proposal.target && ProposalMRContext.matches($0.request, proposal: proposal)
                    && $0.request.draft == true
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            HStack(alignment: .top) {
                Button { showingDetails = true } label: {
                    BoardCardTitle(title: proposal.title, repositoryPath: proposal.url.gitLabProjectPath,
                        titleColor: isDraft ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                moreMenu
            }
            if let finishedItem {
                FinishedMergeRequestStatus(item: finishedItem, monitor: monitor)
            } else {
                dependencyRow
                reasons
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
                if failed {
                    BoardStatusChip(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle", tint: isDraft ? .secondary : .orange)
                        .help(Text(.Menu.menuMrAddFailed))
                }
                runResult
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
        .task(id: authorTaskID) { await authorLoader.load(proposal) }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                Text(verbatim: proposal.title).font(.title3).textSelection(.enabled)
                dependencyRow
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
                    MRAutomationScopeMenu(settings: monitor.settings, target: proposal.target,
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
            if let iid = proposal.target.iid { BoardMRIdentifier(iid: iid) }
            if finishedState == nil {
                BoardAutomationToggle(settings: monitor.settings, target: proposal.target,
                    projectPath: proposal.url.gitLabProjectPath, isDraft: isDraft)
            }
            BoardPinButton(pin: .mergeRequest(host: proposal.target.host, username: proposal.target.username,
                projectID: proposal.target.projectID, iid: proposal.target.iid ?? 0), settings: monitor.settings)
        }
    }

    private var moreMenu: some View {
        Menu {
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
                workspace: monitor.settings.automation.assistantWorkspace)
            if finishedState == nil {
                Divider()
                MRAutomationScopeMenu(settings: monitor.settings, target: proposal.target,
                    projectPath: proposal.url.gitLabProjectPath, isDraft: isDraft)
            }
        } label: { BoardCardActionIcon(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 24, height: 24)
        .accessibilityLabel(Text(.CommandCenter.commandCenterActions))
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
            BoardJobStatusActions(handoff: job, monitor: monitor, muted: isDraft)
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
        .font(.callout).foregroundStyle(isDraft ? Color.secondary : Color.primary)
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
