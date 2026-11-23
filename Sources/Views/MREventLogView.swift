import SwiftUI

struct MREventLogView: View {
    struct Discussions {
        let entries: [MRGitLabActivity]
        let isLoading: Bool
        let hasError: Bool
    }

    let target: MRAutomationScope.Target?
    let discussionTarget: MRDiscussionTarget?
    let discussions: Discussions?
    let monitor: TodoMonitorService
    let initiallyExpandedJobID: UUID?
    let readOnly: Bool
    let openDiscussion: ((Int, String?) -> Bool)?
    @State private var expanded: Bool
    @State private var showAll: Bool
    @State private var resourceActivity = MRGitLabActivityStore()
    @State private var refreshID = UUID()

    init(target: MRAutomationScope.Target?, discussionTarget: MRDiscussionTarget?,
         discussions: Discussions? = nil, monitor: TodoMonitorService, initiallyExpanded: Bool = false,
         initiallyExpandedJobID: UUID? = nil, readOnly: Bool = false,
         openDiscussion: ((Int, String?) -> Bool)? = nil) {
        self.target = target
        self.discussionTarget = discussionTarget
        self.discussions = discussions
        self.monitor = monitor
        self.initiallyExpandedJobID = initiallyExpandedJobID
        self.readOnly = readOnly
        self.openDiscussion = openDiscussion
        _expanded = State(initialValue: initiallyExpanded || initiallyExpandedJobID != nil)
        _showAll = State(initialValue: initiallyExpandedJobID != nil)
    }

    private struct Refresh: Equatable {
        let target: MRDiscussionTarget
        let revision: UInt64
        let request: UUID
    }

    private var refresh: Refresh? {
        guard expanded, let discussionTarget else { return nil }
        return .init(target: discussionTarget, revision: monitor.glab.accountRevision, request: refreshID)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { timeline.padding(.top, 8) }
        } label: { Text(.AutomationHistory.automationHistoryTitle).font(.headline) }
        .task(id: refresh) {
            guard let target = refresh?.target else { return }
            while !Task.isCancelled {
                await resourceActivity.refresh(target: target, glab: monitor.glab, includesDiscussions: discussions == nil)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var timeline: some View {
        let resource = discussionTarget.map { resourceActivity.snapshot(target: $0, revision: monitor.glab.accountRevision) }
        let gitLab = (resource?.entries ?? []) + (discussions?.entries ?? [])
        let history = target.map { target -> MRAutomationHistory in
            let workflows = monitor.authoredMergeRequests.workflow.entries
            return MRAutomationHistory(target: target, handoffs: monitor.assistantHandoffs, workflows: workflows,
                events: monitor.settings.automationEvents, gitLab: gitLab)
        }
        let entries = history?.entries ?? []
        let limit = 20
        let hasError = resource?.hasError == true || discussions?.hasError == true
        let isLoading = resource?.isLoading == true || discussions?.isLoading == true
        return VStack(alignment: .leading, spacing: 6) {
            if hasError {
                HStack {
                    Label(.AutomationHistory.automationHistoryPartial, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if resource?.hasError == true {
                        Button { refreshID = UUID() } label: { Text(.CommandCenter.commandCenterRefresh) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
            if entries.isEmpty && !hasError && !isLoading {
                Text(.AutomationHistory.automationHistoryEmpty).font(.callout).foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel(Text(.AutomationHistory.automationHistoryLoading))
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? entries : Array(entries.prefix(limit))) { entry in
                    if entry.id != entries.first?.id { Divider() }
                    row(entry, history: history).id(entry.id)
                }
            }
            if entries.count > limit {
                Button { showAll.toggle() } label: {
                    Text(showAll ? .CommandCenter.commandCenterShowLess : .CommandCenter.commandCenterShowAll)
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder private func row(_ entry: MRAutomationHistory.Entry, history: MRAutomationHistory?) -> some View {
        switch entry.source {
        case .gitLab(let event, let appEvent):
            if let url = discussionTarget?.url {
                MREventLogGitLabRow(event: event, appEvent: appEvent, mergeRequestURL: url, openDiscussion: openDiscussion)
            }
        case .job, .event, .workflow:
            MRAutomationEventLogRow(entry: entry, runs: history?.associatedRuns(for: entry) ?? [],
                monitor: monitor, initiallyExpandedJobID: initiallyExpandedJobID, readOnly: readOnly)
        }
    }
}
