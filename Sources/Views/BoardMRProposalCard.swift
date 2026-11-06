import AppKit
import SwiftUI

struct BoardMRProposalCard: View {
    let proposal: MergeRequestBoardSnapshot.Proposal
    let monitor: TodoMonitorService
    @State private var isWorking = false
    @State private var failed = false
    @State private var confirmIgnore = false
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
            BoardStatusChip(title: .Board.boardCompactProposal, symbol: "plus.circle")
            HStack(alignment: .top) {
                Link(destination: proposal.url) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: "!\(proposal.target.iid ?? 0) · \(proposal.title)").font(.callout.weight(.semibold)).lineLimit(2)
                        RepositoryPathText(proposal.url.gitLabProjectPath).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                AssistantContextMenu(mergeRequestURL: proposal.url, title: proposal.title,
                                     workspace: monitor.settings.automation.assistantWorkspace)
                    .labelStyle(.iconOnly)
            }
            author
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.12), lineWidth: 0.5))
        .task(id: authorTaskID) { await authorLoader.load(proposal) }
    }

    @ViewBuilder
    private var author: some View {
        if let author = context.author {
            HStack(spacing: 5) {
                AvatarView(url: author.avatarURL, size: 18)
                    .accessibilityHidden(true)
                if !author.name.isEmpty && author.name != author.username { Text(verbatim: author.name) }
                Text(verbatim: "@\(author.username)").foregroundStyle(.secondary)
            }
            .font(.caption).lineLimit(1)
            .help(Text(verbatim: "\(author.name) (@\(author.username))"))
            .accessibilityLabel(Text(.Proposal.proposalAuthorLabel))
            .accessibilityValue(Text(verbatim: "\(author.name) (@\(author.username))"))
        } else {
            HStack(spacing: 5) {
                if authorLoader.isLoading(proposal) { ProgressView().controlSize(.mini) }
                Text(authorLoader.isLoading(proposal) ? .Proposal.proposalAuthorLoading : .Proposal.proposalAuthorUnknown)
            }
            .font(.caption).foregroundStyle(.secondary)
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
        .font(.caption).foregroundStyle(.secondary)
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
