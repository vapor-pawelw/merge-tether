import Foundation

struct MRAutomationScope: Codable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable { case all, selected }

    enum Choice: String, CaseIterable, Codable, Sendable {
        case inherit, active, paused
    }

    enum Source: Sendable { case global, repository, mergeRequest }

    struct Target: Codable, Hashable, Sendable {
        let host: String
        let username: String
        let projectID: Int
        let iid: Int?

        var repository: Self {
            .init(host: host, username: username, projectID: projectID, iid: nil)
        }
    }

    var mode: Mode = .all
    private var overrides: [Target: Choice] = [:]
    private var managedTargets: Set<Target>?
    private var repositoryLabels: [Target: String]?

    subscript(target: Target) -> Choice {
        get { overrides[target] ?? .inherit }
        set {
            if newValue == .active || overrides[target] == .active { rememberManaged(target) }
            overrides[target] = newValue == .inherit ? nil : newValue
        }
    }

    func resolve(_ target: Target) -> (active: Bool, source: Source) {
        if target.iid != nil, self[target] != .inherit {
            return (self[target] == .active, .mergeRequest)
        }
        if self[target.repository] != .inherit {
            return (self[target.repository] == .active, .repository)
        }
        return (mode == .all, .global)
    }

    mutating func setEnabled(_ enabled: Bool, for target: Target) {
        if enabled { rememberManaged(target) }
        let parentIsActive = target.iid == nil ? mode == .all : resolve(target.repository).active
        self[target] = parentIsActive == enabled ? .inherit : enabled ? .active : .paused
    }

    func permits(_ request: GitLabMergeRequest, host: String, username: String) -> Bool {
        resolve(.init(host: host, username: username, projectID: request.projectID, iid: request.iid)).active
    }

    func individualOverrides(host: String, username: String) -> [Target] {
        overrides.keys.filter { $0.host == host && $0.username == username && $0.iid != nil }
    }

    func isManaged(_ target: Target) -> Bool {
        target.iid != nil && (managedTargets?.contains(target) == true || self[target] == .active)
    }

    func individualTargets(host: String, username: String) -> [Target] {
        let managed = managedTargets?.filter { $0.host == host && $0.username == username && $0.iid != nil } ?? []
        return Array(Set(individualOverrides(host: host, username: username)).union(managed))
    }

    mutating func forgetManaged(_ target: Target) {
        managedTargets?.remove(target)
        if managedTargets?.isEmpty == true { managedTargets = nil }
    }

    private mutating func rememberManaged(_ target: Target) {
        guard target.iid != nil else { return }
        if managedTargets == nil { managedTargets = [] }
        managedTargets?.insert(target)
    }

    func repositoryOverrides(host: String, username: String) -> [Target] {
        overrides.keys.filter { $0.host == host && $0.username == username && $0.iid == nil }
    }

    func repositoryLabel(for target: Target) -> String? {
        repositoryLabels?[target.repository]
    }

    mutating func rememberRepository(_ name: String, for target: Target) {
        if repositoryLabels == nil { repositoryLabels = [:] }
        repositoryLabels?[target.repository] = name
    }
}
