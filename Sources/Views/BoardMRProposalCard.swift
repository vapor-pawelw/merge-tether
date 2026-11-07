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

    private var context: ProposalMRContext {
        ProposalMRContext(proposal: proposal, fetchedRequest: authorLoader.request(for: proposal))
    }

    private var authorTaskID: String {
        "\(proposal.target.host)/\(proposal.target.username)/\(proposal.target.projectID)/\(proposal.target.iid ?? 0)/\(proposal.url)|\(monitor.glab.resolvedHost ?? "")/\(monitor.glab.currentUsername ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadataHeader
            HStack(alignment: .top) {
                Button { showingDetails = true } label: {
                    BoardCardTitle(title: proposal.title, repositoryPath: proposal.url.gitLabProjectPath)
                }
                .buttonStyle(.plain)
                moreMenu
            }
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
                BoardStatusChip(title: .Board.boardCompactBlocked, symbol: "exclamationmark.circle", tint: .orange)
                    .help(Text(.Menu.menuMrAddFailed))
            }
            runResult
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
        .boardCardInteraction { showingDetails = true }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.12), lineWidth: 0.5))
        .task(id: authorTaskID) { await authorLoader.load(proposal) }
        .sheet(isPresented: $showingDetails) {
            BoardItemDetailSheet {
                metadataHeader
                Text(verbatim: proposal.title).font(.title3).textSelection(.enabled)
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
                if let job = proposal.latestJob { AssistantJobRow(handoff: job, monitor: monitor) }
            }
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 6) {
            author
            Spacer(minLength: 4)
            BoardStatusChip(title: .Board.boardCompactProposal, symbol: "plus.circle")
            if proposal.item?.section == .draftMergeRequests || proposal.todos.contains(where: \.isDraft) {
                BoardDraftBadge()
            }
            if let iid = proposal.target.iid { BoardMRIdentifier(iid: iid) }
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
            AssistantContextMenu(mergeRequestURL: proposal.url, title: proposal.title,
                workspace: monitor.settings.automation.assistantWorkspace)
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
            BoardJobStatusActions(handoff: job, monitor: monitor)
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
        .font(.callout).foregroundStyle(.primary)
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
