import SwiftUI

struct CommandCenterAddMergeRequestView: View {
    let monitor: TodoMonitorService
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var selectedProjectID: Int?
    @State private var isAdding = false
    @State private var addFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.CommandCenter.commandCenterAdd).font(.title2.weight(.semibold))
            Text(.CommandCenter.commandCenterAddDescription).foregroundStyle(.secondary)
            TextField(text: $address) { Text(.Menu.menuMrAddress) }
                .textFieldStyle(.roundedBorder).disabled(isAdding)
            if usesNumericAddress {
                Picker(selection: $selectedProjectID) {
                    Text(.Menu.menuMrNoRepository).tag(Int?.none)
                    ForEach(repositories) { repository in
                        Text(verbatim: repository.name).tag(Optional(repository.id))
                    }
                } label: { Text(.Menu.menuMrRepository) }
                .disabled(isAdding)
            }
            if addFailed { Text(.Menu.menuMrAddFailed).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { Text(.Menu.menuScopeCancel) }
                    .keyboardShortcut(.cancelAction).disabled(isAdding)
                Button {
                    isAdding = true
                    Task {
                        defer { isAdding = false }
                        do {
                            _ = try await monitor.addManagedMergeRequest(from: address,
                                projectID: usesNumericAddress ? selectedProjectID : nil)
                            dismiss()
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
        .padding(24).frame(width: 480)
        .onAppear { if repositories.count == 1 { selectedProjectID = repositories.first?.id } }
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
