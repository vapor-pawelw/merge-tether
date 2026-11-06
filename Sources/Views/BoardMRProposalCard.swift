import AppKit
import SwiftUI

struct BoardMRProposalCard: View {
    let proposal: MergeRequestBoardSnapshot.Proposal
    let monitor: TodoMonitorService
    @State private var isWorking = false
    @State private var failed = false
    @State private var confirmIgnore = false

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
    }
}
