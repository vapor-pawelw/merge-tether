import Foundation

struct MRAutomationScope: Codable, Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable { case all, selected }

    enum Choice: String, CaseIterable, Codable, Sendable {
        case inherit, active, paused, forceOn
    }

    enum Source: Sendable { case global, repository, mergeRequest, draft }

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
    var pauseDraftsByDefault = true
    /// Runtime-only global killswitch. It is never encoded, so stored overrides and presets stay unchanged.
    var isGloballySuspended = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, overrides, managedTargets, repositoryLabels, pauseDraftsByDefault
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .all
        overrides = try values.decodeIfPresent([Target: Choice].self, forKey: .overrides) ?? [:]
        managedTargets = try values.decodeIfPresent(Set<Target>.self, forKey: .managedTargets)
        repositoryLabels = try values.decodeIfPresent([Target: String].self, forKey: .repositoryLabels)
        pauseDraftsByDefault = try values.decodeIfPresent(Bool.self, forKey: .pauseDraftsByDefault) ?? true
    }

    func manualChoice(for target: Target) -> Choice {
        self[target] == .active ? .inherit : self[target]
    }

    mutating func setManualChoice(_ choice: Choice, for target: Target) {
        self[target] = choice == .active ? .forceOn : choice
    }

    subscript(target: Target) -> Choice {
        get { overrides[target] ?? .inherit }
        set {
            if newValue == .active || newValue == .forceOn || overrides[target] == .active || overrides[target] == .forceOn {
                rememberManaged(target)
            }
            overrides[target] = newValue == .inherit ? nil : newValue
        }
    }

    func resolve(_ target: Target) -> (active: Bool, source: Source) {
        if isGloballySuspended { return (false, .global) }
        if target.iid != nil, self[target] != .inherit {
            return (self[target] == .active || self[target] == .forceOn, .mergeRequest)
        }
        if self[target.repository] != .inherit {
            return (self[target.repository] == .active || self[target.repository] == .forceOn, .repository)
        }
        return (mode == .all, .global)
    }

    mutating func setEnabled(_ enabled: Bool, for target: Target) {
        if target.iid != nil {
            setManualChoice(enabled ? .forceOn : .paused, for: target)
            return
        }
        if enabled { rememberManaged(target) }
        let parentIsActive = target.iid == nil ? mode == .all : resolve(target.repository).active
        self[target] = parentIsActive == enabled ? .inherit : enabled ? .active : .paused
    }

    func resolve(_ target: Target, isDraft: Bool) -> (active: Bool, source: Source) {
        let ordinary = resolve(target)
        guard ordinary.active, isDraft, pauseDraftsByDefault, self[target] != .forceOn else { return ordinary }
        return (false, .draft)
    }

    mutating func setEnabled(_ enabled: Bool, for target: Target, isDraft: Bool) {
        setEnabled(enabled, for: target)
    }

    func allowsDraftAutomation(for target: Target) -> Bool {
        target.iid != nil && resolve(target, isDraft: true).active
    }

    /// A transient revocation view for legacy cancellation consumers; never persist it as user policy.
    func cancellationScope(for requests: [GitLabMergeRequest], host: String, username: String) -> Self {
        var result = self
        for request in requests where (request.draft == nil || request.draft == true || request.detailedMergeStatus == "draft_status"
            || request.state == "merged" || request.state == "closed")
            && request.webURL.isGitLabMergeRequest(host: host, iid: request.iid)
            && !permits(request, host: host, username: username) {
            result[.init(host: host, username: username, projectID: request.projectID, iid: request.iid)] = .paused
        }
        return result
    }

    func permits(_ request: GitLabMergeRequest, host: String, username: String) -> Bool {
        guard request.state == "opened", let draft = request.draft else { return false }
        let target = Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return resolve(target, isDraft: draft || request.detailedMergeStatus == "draft_status").active
    }

    func individualOverrides(host: String, username: String) -> [Target] {
        overrides.keys.filter { $0.host == host && $0.username == username && $0.iid != nil }
    }

    func isManaged(_ target: Target) -> Bool {
        target.iid != nil && (managedTargets?.contains(target) == true || self[target] == .active || self[target] == .forceOn)
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
