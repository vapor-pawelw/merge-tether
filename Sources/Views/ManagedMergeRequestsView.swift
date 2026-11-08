import SwiftUI

struct ManagedMergeRequestsView: View {
    let monitor: TodoMonitorService
    @State private var showingAdd = false
    @State private var address = ""
    @State private var isAdding = false
    @State private var addFailed = false

    var body: some View {
        let scope = monitor.settings.automation.scope
        let rows = monitor.attention.currentOpenItems.compactMap { item -> Row? in
            guard let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url),
                  scope.isManaged(target) || scope.resolve(target).active || scope[target] != .inherit || scope[target.repository] != .inherit
            else { return nil }
            return Row(item: item, target: target)
        }
        let repositories = repositoryTargets(scope)
        let missing = individualTargets(scope).filter { target in !rows.contains { $0.target == target } }
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    address = ""
                    addFailed = false
                    showingAdd = true
                } label: {
                    Label { Text(.Menu.menuScopeAdd) } icon: { Image(systemName: "plus") }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            if showingAdd { addForm }
            list(rows, repositories: repositories, missing: missing, scope: scope)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.Menu.menuScopeAddHelp).foregroundStyle(.secondary)
            TextField(text: $address) { Text(.Menu.menuScopeUrl) }
                .textFieldStyle(.roundedBorder)
                .disabled(isAdding)
            if addFailed { Text(.Menu.menuScopeAddFailed).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(role: .cancel) { showingAdd = false } label: { Text(.Menu.menuScopeCancel) }
                    .disabled(isAdding)
                Button {
                    isAdding = true
                    addFailed = false
                    Task {
                        defer { isAdding = false }
                        do {
                            try await monitor.addAutomationTarget(from: address)
                            showingAdd = false
                        } catch {
                            addFailed = true
                        }
                    }
                } label: {
                    if isAdding { ProgressView().controlSize(.small) }
                    else { Text(.Menu.menuScopeAddConfirm) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func repositoryTargets(_ scope: MRAutomationScope) -> [MRAutomationScope.Target] {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return [] }
        return scope.repositoryOverrides(host: host, username: username).sorted {
            (scope.repositoryLabel(for: $0) ?? "", $0.projectID) < (scope.repositoryLabel(for: $1) ?? "", $1.projectID)
        }
    }

    private func individualTargets(_ scope: MRAutomationScope) -> [MRAutomationScope.Target] {
        guard let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername else { return [] }
        return scope.individualTargets(host: host, username: username).sorted {
            (scope.repositoryLabel(for: $0) ?? "", $0.projectID, $0.iid ?? 0)
                < (scope.repositoryLabel(for: $1) ?? "", $1.projectID, $1.iid ?? 0)
        }
    }

    @ViewBuilder
    private func list(_ rows: [Row], repositories: [MRAutomationScope.Target], missing: [MRAutomationScope.Target], scope: MRAutomationScope) -> some View {
        if rows.isEmpty && repositories.isEmpty && missing.isEmpty {
            ContentUnavailableView {
                Label { Text(.Menu.menuScopeEmpty) } icon: { Image(systemName: "bolt.circle") }
            } description: {
                Text(.Menu.menuScopeEmptyHelp)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(repositories, id: \.self) { target in
                        HStack {
                            if let label = scope.repositoryLabel(for: target) {
                                Label { RepositoryPathText(label) } icon: { Image(systemName: "folder") }
                            } else {
                                Text(.Menu.menuAuthoredProject(target.projectID))
                            }
                            Spacer()
                            MRAutomationScopeMenu(settings: monitor.settings, target: target)
                        }
                        .font(.caption)
                        .mrRowContentPadding()
                        Divider()
                    }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Link(destination: row.item.url) {
                                MergeRequestTitle(title: "!\(row.item.id.iid) · \(row.item.title)",
                                                  isDraft: row.item.section == .draftMergeRequests,
                                                  lineLimit: nil, titleColor: .accentColor)
                            }
                            RepositoryPathText(row.item.url.gitLabProjectPath).font(.caption).foregroundStyle(.secondary)
                            if row.item.draftCount > 0 { Text(.Menu.menuAttentionDrafts(row.item.draftCount)).font(.caption) }
                            if row.item.reReviewRequested { Text(.Menu.menuScopeReReviewRequested).font(.caption) }
                            if row.item.reReviewUnconfirmed { Text(.Menu.menuAttentionReReviewUnconfirmed).font(.caption) }
                            if row.item.needsDiscussion || !row.item.feedback.isEmpty {
                                Text(.Menu.menuAttentionDiscussions).font(.caption)
                            }
                            if row.item.failedPipeline { Text(.Menu.menuAttentionPipeline).font(.caption) }
                            if row.item.hasConflict { Text(.Menu.menuAttentionConflict).font(.caption) }
                            if row.item.needsChanges { Text(.Menu.menuAttentionChanges).font(.caption) }
                            if let event = monitor.authoredMergeRequests.workflow.entries.first(where: {
                                $0.event.mergeRequest.projectID == row.item.id.projectID && $0.event.mergeRequest.iid == row.item.id.iid
                            }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(.Menu.menuScopeLatestRecordedEvent)
                                        Text(event.event.kind.displayLabel)
                                    }
                                    Text(event.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                MRAutomationScopeMenu(settings: monitor.settings, target: row.target,
                                                      projectPath: row.item.url.gitLabProjectPath,
                                                      isDraft: row.item.section == .draftMergeRequests)
                                if !row.item.isAuthored, row.item.mergeRequest != nil,
                                   monitor.settings.automation.hasEnabledAutomation, monitor.settings.automation.autoApproveEnabled {
                                    Toggle(isOn: autoApproveBinding(row.target)) {
                                        Text(.Menu.menuScopeAutoApprove)
                                    }
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                                    .help(Text(.Menu.menuScopeAutoApproveHelp))
                                }
                                Spacer()
                                if let chat = monitor.existingCodexChat(for: row.target) {
                                    Link(destination: chat) {
                                        Text(monitor.settings.automation.assistant == .claude
                                             ? .Menu.menuScopeOpenClaudeSession : .Menu.menuScopeOpenChat)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                        .mrRowContentPadding()
                        Divider()
                    }
                    ForEach(missing, id: \.self) { target in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "!\(target.iid ?? 0)").font(.subheadline.weight(.semibold))
                            if let label = scope.repositoryLabel(for: target) {
                                RepositoryPathText(label)
                            } else {
                                Text(.Menu.menuAuthoredProject(target.projectID))
                            }
                            Text(.Menu.menuScopeNotOpen).foregroundStyle(.secondary)
                            MRAutomationScopeMenu(settings: monitor.settings, target: target)
                        }
                        .font(.caption).mrRowContentPadding()
                        Divider()
                    }
                }
            }
        }
    }

    private func autoApproveBinding(_ target: MRAutomationScope.Target) -> Binding<Bool> {
        Binding(
            get: { !monitor.settings.autoApproveOptOuts.contains(target) },
            set: { enabled in
                if enabled {
                    monitor.settings.autoApproveOptOuts.remove(target)
                } else {
                    monitor.settings.autoApproveOptOuts.insert(target)
                }
                monitor.settings.save()
            }
        )
    }

    private struct Row: Identifiable {
        let item: MergeRequestAttentionMonitor.Item
        let target: MRAutomationScope.Target
        var id: MergeRequestAttentionMonitor.Item.ID { item.id }
    }
}
