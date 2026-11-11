import SwiftUI

struct WorkerExecutionTimeoutSettingsView: View {
    @Binding var policy: WorkerExecutionTimeout
    let repositories: [PublicationIdentity]

    var body: some View {
        Section {
            LabeledContent {
                timeoutField($policy.defaultLimit)
            } label: { Text(.WorkerTimeout.defaultLimit) }
            Text(.WorkerTimeout.help).font(.caption).foregroundStyle(.secondary)
            ForEach($policy.projectOverrides) { $entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if let path = repositories.first(where: {
                                $0.host == entry.host && $0.entityID == entry.projectID
                            })?.label ?? entry.projectPath {
                                RepositoryPathText(path)
                            } else {
                                Text(.WorkerTimeout.savedRepository)
                            }
                            Text(verbatim: entry.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        timeoutField($entry.limit)
                        Button {
                            let id = entry.id
                            policy.projectOverrides.removeAll { $0.id == id }
                        } label: {
                            Label { Text(.WorkerTimeout.removeOverride) } icon: { Image(systemName: "minus.circle") }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            Menu {
                ForEach(availableRepositories) { repository in
                    Button {
                        policy.projectOverrides.append(.init(host: repository.host, projectID: repository.entityID,
                            projectPath: repository.label, limit: policy.defaultLimit))
                    } label: {
                        Text(verbatim: "\(repository.label) · \(repository.host)")
                    }
                }
            } label: {
                Label { Text(.WorkerTimeout.addOverride) } icon: { Image(systemName: "plus") }
            }
            .disabled(availableRepositories.isEmpty)
            Text(.WorkerTimeout.overridesHelp).font(.caption).foregroundStyle(.secondary)
            if repositories.isEmpty {
                Text(.WorkerTimeout.noRepositories).font(.caption).foregroundStyle(.secondary)
            }
            if policy.hasInvalidOverrides {
                Text(.WorkerTimeout.invalidOverrides).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(.WorkerTimeout.title)
        } footer: {
            Text(.WorkerTimeout.runHelp).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func repositoryChoice(projectID: Int, url: URL) -> PublicationIdentity? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let hostname = components.host, !hostname.isEmpty else { return nil }
        let hostnameAuthority = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        let authority = hostnameAuthority + (components.port.map { ":\($0)" } ?? "")
        guard let key = WorkerExecutionTimeout.ProjectKey(host: authority, projectID: projectID),
              !url.gitLabProjectPath.isEmpty else { return nil }
        return .init(host: key.host, entityID: key.projectID, label: url.gitLabProjectPath)
    }

    var availableRepositories: [PublicationIdentity] {
        repositories.filter { repository in
            guard let key = WorkerExecutionTimeout.ProjectKey(host: repository.host, projectID: repository.entityID) else { return false }
            return !policy.projectOverrides.contains { $0.key == key }
        }
    }

    private func timeoutField(_ limit: Binding<WorkerExecutionTimeout.Limit>) -> some View {
        let minutes = Binding(get: { limit.wrappedValue.minutes }, set: { limit.wrappedValue = .init(minutes: $0) })
        return HStack(spacing: 6) {
            TextField(value: minutes, format: .number.grouping(.never)) {
                Text(.WorkerTimeout.minutes)
            }
            .labelsHidden()
            .frame(width: 64)
            Text(.WorkerTimeout.minutes).foregroundStyle(.secondary)
            Stepper(value: minutes, in: WorkerExecutionTimeout.Limit.validMinutes) {
                Text(.WorkerTimeout.minutes)
            }
            .labelsHidden()
        }
        .fixedSize()
    }
}
