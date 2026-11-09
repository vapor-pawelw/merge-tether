import SwiftUI

struct BoardMRCompletionCard: View {
    let completion: MergeRequestLifecycleLedger.CompletionReceipt
    let monitor: TodoMonitorService
    @State private var showingDetails = false

    private var state: MergeRequestFinishedState {
        completion.kind == .merged ? .merged : .closed
    }

    private var isCurrentAccount: Bool {
        monitor.glab.resolvedHost == completion.target.host
            && monitor.glab.currentUsername == completion.target.username
    }

    private var canAcknowledge: Bool {
        isCurrentAccount && monitor.lifecycleCompletions.contains { $0.id == completion.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadata
            VStack(alignment: .leading, spacing: 3) {
                Button(action: openDetails) {
                    BoardCardTitle(title: completion.title, repositoryPath: completion.url.gitLabProjectPath)
                }
                .buttonStyle(.plain)
                if let iid = completion.target.iid {
                    BoardMRReferenceLine(iid: iid, projectID: completion.target.projectID)
                }
            }
            HStack(spacing: 8) {
                Text(completion.kind == .merged ? .MRLifecycle.completionMerged : .MRLifecycle.completionClosed)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                seenButton
            }
            .font(.caption)
        }
        .controlSize(.small)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.12), lineWidth: 0.5))
        .boardCardInteraction(onDetails: openDetails)
        .contextMenu { menuItems }
        .onChange(of: isCurrentAccount) { _, current in
            if !current { showingDetails = false }
        }
        .sheet(isPresented: $showingDetails) {
            if isCurrentAccount {
                BoardItemDetailSheet {
                    metadata
                    Text(verbatim: completion.title).font(.title3).textSelection(.enabled)
                    if let iid = completion.target.iid {
                        BoardMRReferenceLine(iid: iid, projectID: completion.target.projectID)
                    }
                    Text(verbatim: completion.url.gitLabProjectPath).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(completion.kind == .merged ? .MRLifecycle.completionMerged : .MRLifecycle.completionClosed)
                    HStack {
                        Text(.MRLifecycle.completionObserved)
                        Text(completion.observedAt, format: .dateTime).textSelection(.enabled)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Link(destination: completion.url) {
                        Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
                    }
                    seenButton
                    MRAutomationEventLogView(target: completion.target, monitor: monitor, readOnly: true)
                }
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let author = completion.author { BoardCardAuthor(author: author) }
            Spacer(minLength: 4)
            FinishedMergeRequestBadge(state: state)
            moreMenu
        }
    }

    private func openDetails() {
        guard isCurrentAccount else { return }
        showingDetails = true
    }

    private var seenButton: some View {
        Button {
            guard isCurrentAccount else { return }
            if monitor.acknowledgeLifecycleCompletion(id: completion.id) { showingDetails = false }
        } label: { Text(.MRLifecycle.seen) }
        .buttonStyle(.bordered)
        .help(Text(.MRLifecycle.completionSeenHelp))
        .disabled(!canAcknowledge)
    }

    private var moreMenu: some View {
        BoardActionsMenu { menuItems }
    }

    @ViewBuilder private var menuItems: some View {
        Button(action: openDetails) {
            Label { Text(.Board.boardDetails) } icon: { Image(systemName: "rectangle.expand.vertical") }
        }
        Link(destination: completion.url) {
            Label { Text(.CommandCenter.commandCenterOpenGitLab) } icon: { Image(systemName: "arrow.up.right.square") }
        }
        AssistantContextMenu(mergeRequestURL: completion.url, title: completion.title,
            settings: monitor.settings)
        Divider()
        Button {
            guard canAcknowledge else { return }
            _ = monitor.acknowledgeLifecycleCompletion(id: completion.id)
        } label: {
            Label { Text(.MRLifecycle.seen) } icon: { Image(systemName: "checkmark") }
        }
        .disabled(!canAcknowledge)
    }

}
