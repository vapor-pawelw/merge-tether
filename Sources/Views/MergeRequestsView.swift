import SwiftUI

/// Read-only MR browsing; adding an MR explicitly opts that MR into automation.
struct MergeRequestsView: View {
    let monitor: TodoMonitorService
    @State private var selection: Tab = .own
    @State private var showingAdd = false
    @State private var address = ""
    @State private var selectedProjectID: Int?
    @State private var isAdding = false
    @State private var addFailed = false

    private enum Tab { case own, reviewed, activity }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(selection: $selection) {
                    Text(.Menu.menuMrTabOwn).tag(Tab.own)
                    Text(.Menu.menuMrTabReviewed).tag(Tab.reviewed)
                    Text(.Menu.menuWorkflowActivityTabShort).tag(Tab.activity)
                } label: { Text(.Menu.menuMrTabOwn) }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer(minLength: 8)
                Button {
                    address = ""
                    addFailed = false
                    selectedProjectID = repositories.count == 1 ? repositories.first?.id : nil
                    showingAdd.toggle()
                } label: {
                    Label { Text(.Menu.menuMrAdd) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAdding || selection != .reviewed)
                // Reserve the same space on every tab so the segmented control never moves.
                .opacity(selection == .reviewed ? 1 : 0)
                .allowsHitTesting(selection == .reviewed)
                .accessibilityHidden(selection != .reviewed)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if selection == .activity {
                // What automation did on its own, so the autopilot is never a black box.
                MergeWorkflowActivityView(entries: monitor.authoredMergeRequests.workflow.entries,
                                          onHandoff: monitor.authoredMergeRequests.workflow.confirmPipelineHandoff)
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            if showingAdd && selection == .reviewed { addForm }
            if hasError { staleBanner }
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // Dynamic MR/history heights can trap lazy layout in a measurement loop on macOS.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            requestRow(item)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MRRowLayout.listInset)
                }
            }
        }
    }

    private var items: [MergeRequestAttentionMonitor.Item] {
        selection == .own ? monitor.ownMergeRequestItems : monitor.reviewedMergeRequestItems
    }

    private var hasError: Bool {
        monitor.attention.hasError || (selection == .own && monitor.authoredMergeRequests.hasError)
    }

    private var isLoading: Bool {
        monitor.attention.isLoading || (selection == .own && monitor.authoredMergeRequests.isLoading)
    }

    private var staleBanner: some View {
        Label { Text(.Menu.menuMrStale) } icon: { Image(systemName: "exclamationmark.triangle") }
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.10))
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading {
            ProgressView { Text(.Menu.menuAuthoredLoading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label {
                    Text(hasError ? .Menu.menuAuthoredError
                         : selection == .own ? .Menu.menuMrNoOwn : .Menu.menuMrNoReviewed)
                } icon: { Image(systemName: hasError ? "exclamationmark.triangle" : "arrow.triangle.merge") }
            }
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.Menu.menuMrAddHelp).font(.caption).foregroundStyle(.secondary)
            TextField(text: $address) { Text(.Menu.menuMrAddress) }
                .textFieldStyle(.roundedBorder)
                .disabled(isAdding)
            if usesNumericAddress {
                Picker(selection: $selectedProjectID) {
                    Text(.Menu.menuMrNoRepository).tag(Int?.none)
                    ForEach(repositories) { repository in
                        Text(verbatim: repository.name).tag(Optional(repository.id))
                    }
                } label: { Text(.Menu.menuMrRepository) }
                .disabled(isAdding)
            }
            if addFailed { Text(.Menu.menuMrAddFailed).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(role: .cancel) { showingAdd = false } label: { Text(.Menu.menuScopeCancel) }
                    .disabled(isAdding)
                Button(action: addMergeRequest) {
                    if isAdding { ProgressView().controlSize(.small) }
                    else { Text(.Menu.menuScopeAddConfirm) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (usesNumericAddress && selectedProjectID == nil))
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var usesNumericAddress: Bool {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = input.hasPrefix("!") ? String(input.dropFirst()) : input
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private struct RepositoryChoice: Identifiable {
        let id: Int
        let name: String
    }

    private var repositories: [RepositoryChoice] {
        var names: [Int: String] = [:]
        for item in monitor.attention.currentOpenItems {
            names[item.id.projectID] = item.url.gitLabProjectPath
        }
        if let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername {
            let scope = monitor.settings.automation.scope
            for target in scope.repositoryOverrides(host: host, username: username) where names[target.projectID] == nil {
                names[target.projectID] = scope.repositoryLabel(for: target)
                    ?? String(localized: .Menu.menuAuthoredProject(target.projectID))
            }
        }
        return names.map { RepositoryChoice(id: $0.key, name: $0.value) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func addMergeRequest() {
        guard !isAdding else { return }
        isAdding = true
        addFailed = false
        Task {
            defer { isAdding = false }
            do {
                let request = try await monitor.addManagedMergeRequest(from: address,
                    projectID: usesNumericAddress ? selectedProjectID : nil)
                showingAdd = false
                address = ""
                if request.author.username == monitor.glab.currentUsername { selection = .own }
            } catch {
                addFailed = true
            }
        }
    }

    @ViewBuilder
    private func requestRow(_ item: MergeRequestAttentionMonitor.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if selection == .own, let status = monitor.authoredMergeRequests.requests.first(where: {
                $0.request.projectID == item.id.projectID && $0.request.iid == item.id.iid
                    && $0.request.webURL.host == item.url.host && $0.request.webURL.port == item.url.port
                    && $0.request.sha == item.mergeRequest?.sha
            }), (!status.blockers.isEmpty || item.canOfferMerge(using: status)) {
                AuthoredMergeRequestRow(status: status)
                if item.draftCount > 0 {
                    Text(.Menu.menuAttentionDrafts(item.draftCount))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                if item.reReviewUnconfirmed {
                    Text(.Menu.menuAttentionReReviewUnconfirmed)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            } else {
                MergeRequestSummary(item: item)
            }
            ReReviewControls(item: item, monitor: monitor.attention)
                .padding(.horizontal, 12)
                .padding(.bottom, item.reReviewReadiness == nil ? 0 : 10)
            assistantDetails(item)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            if selection == .reviewed, let target = autoApproveTarget(for: item) {
                Toggle(isOn: autoApproveBinding(target)) { Text(.Menu.menuScopeAutoApprove) }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help(Text(.Menu.menuScopeAutoApproveHelp))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    /// Per-MR opt-out from automatic approval, shown where the MR is, not only in Settings.
    private func autoApproveTarget(for item: MergeRequestAttentionMonitor.Item) -> MRAutomationScope.Target? {
        guard monitor.settings.automation.autoApproveEnabled, let request = item.mergeRequest,
              let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername,
              request.author.username != username,
              monitor.settings.automation.scope.permits(request, host: host, username: username) else { return nil }
        return MRAutomationScope.Target(host: host, username: username, projectID: item.id.projectID, iid: item.id.iid)
    }

    private func autoApproveBinding(_ target: MRAutomationScope.Target) -> Binding<Bool> {
        Binding(
            get: { !monitor.settings.autoApproveOptOuts.contains(target) },
            set: { enabled in
                if enabled { monitor.settings.autoApproveOptOuts.remove(target) }
                else { monitor.settings.autoApproveOptOuts.insert(target) }
                monitor.settings.save()
            }
        )
    }

    private func assistantDetails(_ item: MergeRequestAttentionMonitor.Item) -> some View {
        let links = monitor.assistantChatLinks(for: item)
        let group = monitor.assistantGroups.first {
            $0.id.host == monitor.glab.resolvedHost && $0.id.projectID == item.id.projectID && $0.id.iid == item.id.iid
        }
        return VStack(alignment: .leading, spacing: 8) {
            if let target = monitor.scopeTarget(projectID: item.id.projectID, iid: item.id.iid, url: item.url) {
                let active = monitor.settings.automation.scope.resolve(target).active
                assistantStatus(active ? .Menu.menuMrAutomationActive : .Menu.menuMrAutomationPaused,
                                icon: active ? "bolt.circle.fill" : "pause.circle.fill",
                                color: active ? .green : .orange)
            }
            if links.isEmpty {
                assistantStatus(.Menu.menuMrNoChat, icon: "bubble.left.and.exclamationmark.bubble.right",
                                color: .orange)
            } else {
                HStack(spacing: 12) {
                    ForEach(links, id: \.id) { link in
                        Link(destination: link.url) {
                            Label {
                                Text(link.assistant == .codex ? .Menu.menuMrChatCodex : .Menu.menuMrChatClaude)
                            } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                        }
                        .foregroundStyle(.tint)
                    }
                }
            }
            if let group {
                if group.pendingCount > 0 {
                    assistantStatus(.Menu.menuMrPendingEvents(group.pendingCount), icon: "clock.fill", color: .orange)
                } else if group.deliveredCount > 0 {
                    assistantStatus(.Menu.menuMrDelivered, icon: "checkmark.circle.fill", color: .green)
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.handoffs) { handoff in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: handoff.title).lineLimit(2)
                                HStack {
                                    Text(handoff.relayComplete == true ? .Menu.menuMrDelivered : .Menu.menuMrPendingEvents(1))
                                    Spacer()
                                    Text(RelativeTime.string(from: handoff.createdAt))
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 5)
                } label: { Text(.Menu.menuMrHistory) }
                .font(.caption)
                .fontWeight(.regular)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func assistantStatus(_ title: LocalizedStringResource, icon: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MergeRequestSummary: View {
    let item: MergeRequestAttentionMonitor.Item

    var body: some View {
        Link(destination: item.url) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 10) {
                    MergeRequestTitle(title: "!\(item.id.iid) · \(item.title)",
                                      isDraft: item.section == .draftMergeRequests, lineLimit: 3)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                        .mrRowAccessoryFrame()
                        .accessibilityHidden(true)
                }
                RepositoryPathText(item.url.gitLabProjectPath)
                if let pipeline = item.mergeRequest?.headPipeline {
                    Text(.Menu.menuAuthoredPipeline(pipeline.status.replacingOccurrences(of: "_", with: " ")))
                        .foregroundStyle(pipeline.status == "success" ? Color.green : pipeline.status == "failed" ? .red : .secondary)
                }
                if let status = item.mergeRequest?.detailedMergeStatus {
                    Text(.Menu.menuAuthoredMergeCheck(status.replacingOccurrences(of: "_", with: " ")))
                        .foregroundStyle(.secondary)
                }
                if item.draftCount > 0 { Text(.Menu.menuAttentionDrafts(item.draftCount)).foregroundStyle(.orange) }
                if item.needsDiscussion || item.mergeRequest?.blockingDiscussionsResolved == false {
                    Text(.Menu.menuAttentionDiscussions).foregroundStyle(.orange)
                }
                if item.hasConflict || item.mergeRequest?.hasMergeConflict == true {
                    Text(.Menu.menuAttentionConflict).foregroundStyle(.orange)
                }
                if item.needsChanges { Text(.Menu.menuAttentionChanges).foregroundStyle(.orange) }
                if item.reReviewRequested { Text(.Menu.menuScopeReReviewRequested).foregroundStyle(.secondary) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mrRowContentPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(.Menu.menuActionOpenInBrowser))
    }
}
