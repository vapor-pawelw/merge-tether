import SwiftUI

struct CommandCenterMRBrowser: View {
    let monitor: TodoMonitorService
    let own: Bool
    var onAdded: ((Bool) -> Void)? = nil
    @State private var selectedID: MergeRequestAttentionMonitor.Item.ID?
    @State private var search = ""
    @State private var showingAdd = false
    @State private var address = ""
    @State private var selectedProjectID: Int?
    @State private var isAdding = false
    @State private var addFailed = false

    private var allItems: [MergeRequestAttentionMonitor.Item] {
        own ? monitor.ownMergeRequestItems : monitor.reviewedMergeRequestItems
    }

    private var items: [MergeRequestAttentionMonitor.Item] {
        allItems.filter { CommandCenterSearch.matches(search, title: $0.title, repository: $0.url.gitLabProjectPath, iid: $0.id.iid) }
    }

    private var selectedItem: MergeRequestAttentionMonitor.Item? {
        items.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                listHeader
                if monitor.attention.hasError || (own && monitor.authoredMergeRequests.hasError) {
                    Label { Text(.CommandCenter.commandCenterStale) } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                }
                list
            }
            .frame(minWidth: 310, idealWidth: 360, maxWidth: 500)
            Group {
                if let selectedItem {
                    CommandCenterMRDetail(item: selectedItem, monitor: monitor)
                        .id(selectedItem.id)
                } else {
                    ContentUnavailableView {
                        Label { Text(.CommandCenter.commandCenterSelectTitle) } icon: {
                            Image(systemName: "arrow.triangle.pull")
                        }
                    } description: {
                        Text(.CommandCenter.commandCenterSelectDescription)
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingAdd) { addForm }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            TextField(text: $search) { Text(.CommandCenter.commandCenterSearch) }
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text(.CommandCenter.commandCenterSearch))
            Button {
                address = ""
                selectedProjectID = repositories.count == 1 ? repositories.first?.id : nil
                addFailed = false
                showingAdd = true
            } label: { Image(systemName: "plus") }
                .help(Text(.CommandCenter.commandCenterAdd))
                .accessibilityLabel(Text(.CommandCenter.commandCenterAdd))
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            if monitor.attention.isLoading || (own && monitor.authoredMergeRequests.isLoading) {
                ProgressView { Text(.Menu.menuAuthoredLoading) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(search.isEmpty ? (own ? .Menu.menuMrNoOwn : .Menu.menuMrNoReviewed)
                             : .CommandCenter.commandCenterEmptySearchTitle)
                    } icon: { Image(systemName: "tray") }
                } description: {
                    if !search.isEmpty { Text(.CommandCenter.commandCenterEmptySearchDescription) }
                }
            }
        } else {
            List(items, selection: $selectedID) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(verbatim: "!\(item.id.iid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        if item.section == .draftMergeRequests {
                            Text(.CommandCenter.commandCenterStatusDraft).font(.caption).foregroundStyle(.secondary)
                        } else if item.needsAttention {
                            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                                .accessibilityLabel(Text(.CommandCenter.commandCenterStatusAttention))
                        }
                    }
                    Text(verbatim: item.title).font(.body.weight(.medium)).lineLimit(3)
                    Text(verbatim: item.url.gitLabProjectPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if item.draftCount > 0 {
                        Label { Text(.Menu.menuAttentionDrafts(item.draftCount)) } icon: {
                            Image(systemName: "text.bubble")
                        }
                        .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 7)
                .tag(item.id)
            }
            .listStyle(.inset)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.CommandCenter.commandCenterAdd).font(.title2.weight(.semibold))
            Text(.CommandCenter.commandCenterAddDescription).foregroundStyle(.secondary)
            TextField(text: $address) { Text(.Menu.menuScopeUrl) }
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
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Button {
                    isAdding = true
                    Task {
                        defer { isAdding = false }
                        do {
                            let request = try await monitor.addManagedMergeRequest(from: address,
                                projectID: usesNumericAddress ? selectedProjectID : nil)
                            let isOwn = request.author.username == monitor.glab.currentUsername
                            if isOwn == own {
                                search = ""
                                selectedID = .init(projectID: request.projectID, iid: request.iid)
                            }
                            showingAdd = false
                            if isOwn != own { onAdded?(isOwn) }
                        } catch { addFailed = true }
                    }
                } label: {
                    if isAdding { ProgressView().controlSize(.small) }
                    else { Text(.Menu.menuScopeAddConfirm) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (usesNumericAddress && selectedProjectID == nil))
            }
        }
        .padding(24)
        .frame(width: 480)
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
        for item in monitor.attention.currentOpenItems { names[item.id.projectID] = item.url.gitLabProjectPath }
        if let host = monitor.glab.resolvedHost, let username = monitor.glab.currentUsername {
            let scope = monitor.settings.automation.scope
            for target in scope.repositoryOverrides(host: host, username: username) where names[target.projectID] == nil {
                names[target.projectID] = scope.repositoryLabel(for: target)
                    ?? String(localized: .Menu.menuAuthoredProject(target.projectID))
            }
        }
        return names.map { RepositoryChoice(id: $0.key, name: $0.value) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

}
