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
        let userID: Int?

        init(host: String, username: String, projectID: Int, iid: Int?, userID: Int? = nil) {
            self.host = host
            self.username = username
            self.projectID = projectID
            self.iid = iid
            self.userID = userID
        }

        var account: GitLabAccountIdentity { .init(host: host, username: username, userID: userID) }

        func forAccount(_ account: GitLabAccountIdentity) -> Self {
            .init(host: account.host, username: account.username, projectID: projectID, iid: iid, userID: account.userID)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.account == rhs.account && lhs.projectID == rhs.projectID && lhs.iid == rhs.iid
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(account)
            hasher.combine(projectID)
            hasher.combine(iid)
        }

        static func mergeRequest(host: String, username: String, projectID: Int, iid: Int) -> Self {
            .init(host: host, username: username, projectID: projectID, iid: iid)
        }

        static func repository(host: String, username: String, projectID: Int) -> Self {
            .init(host: host, username: username, projectID: projectID, iid: nil)
        }

        var mergeRequestID: GitLabMergeRequestID? {
            iid.map { .init(projectID: projectID, iid: $0) }
        }

        var repository: Self {
            .init(host: host, username: username, projectID: projectID, iid: nil, userID: userID)
        }
    }

    var mode: Mode = .all
    private var overrides: [Target: Choice] = [:]
    private var managedTargets: Set<Target>?
    private var repositoryLabels: [Target: String]?
    private var targetsFollowingActionDefaults: Set<Target>?
    var pauseDraftsByDefault = true
    var assignedOwnershipConfirmation: Bool? = true
    private var claimedAssignments: Set<Target>?
    var requiresAssignmentClaim: Bool {
        get { assignedOwnershipConfirmation ?? true }
        set { assignedOwnershipConfirmation = newValue }
    }
    // Runtime mirror of the separate MR ownership preference.
    var treatsAssignedRequestsAsOwn = true
    /// Runtime-only global killswitch. It is never encoded, so stored overrides and presets stay unchanged.
    var isGloballySuspended = false

    mutating func mapAccountTargets(pausedTarget: ((Target) -> Target?)? = nil, _ transform: (Target) -> Target?) {
        overrides = Dictionary(overrides.compactMap { target, choice in
            let mapped = if choice == .paused, let pausedTarget { pausedTarget(target) } else { transform(target) }
            return mapped.map { ($0, choice) }
        },
            uniquingKeysWith: { first, second in first == .paused || second == .paused ? .paused : first })
        managedTargets = managedTargets.map { Set($0.compactMap(transform)) }
        repositoryLabels = repositoryLabels.map {
            Dictionary($0.compactMap { target, label in transform(target).map { ($0, label) } },
                uniquingKeysWith: { first, _ in first })
        }
        targetsFollowingActionDefaults = targetsFollowingActionDefaults.map { Set($0.compactMap(transform)) }
        claimedAssignments = claimedAssignments.map { Set($0.compactMap(transform)) }
    }

    mutating func retainAccountTargets(from other: Self) {
        overrides.merge(other.overrides) { current, _ in current }
        if let targets = other.managedTargets { managedTargets = (managedTargets ?? []).union(targets) }
        if let labels = other.repositoryLabels {
            repositoryLabels = (repositoryLabels ?? [:]).merging(labels) { current, _ in current }
        }
        if let targets = other.targetsFollowingActionDefaults {
            targetsFollowingActionDefaults = (targetsFollowingActionDefaults ?? []).union(targets)
        }
        if let claims = other.claimedAssignments { claimedAssignments = (claimedAssignments ?? []).union(claims) }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, overrides, managedTargets, repositoryLabels, pauseDraftsByDefault, targetsFollowingActionDefaults
        case assignedOwnershipConfirmation, claimedAssignments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .all
        overrides = try values.decodeIfPresent([Target: Choice].self, forKey: .overrides) ?? [:]
        managedTargets = try values.decodeIfPresent(Set<Target>.self, forKey: .managedTargets)
        repositoryLabels = try values.decodeIfPresent([Target: String].self, forKey: .repositoryLabels)
        targetsFollowingActionDefaults = try values.decodeIfPresent(Set<Target>.self, forKey: .targetsFollowingActionDefaults)
        pauseDraftsByDefault = try values.decodeIfPresent(Bool.self, forKey: .pauseDraftsByDefault) ?? true
        assignedOwnershipConfirmation = try values.decodeIfPresent(Bool.self, forKey: .assignedOwnershipConfirmation)
        claimedAssignments = try values.decodeIfPresent(Set<Target>.self, forKey: .claimedAssignments)
    }

    func manualChoice(for target: Target) -> Choice {
        self[target] == .active ? .inherit : self[target]
    }

    mutating func setManualChoice(_ choice: Choice, for target: Target) {
        self[target] = choice == .active ? .forceOn : choice
        if target.iid != nil, choice == .inherit {
            if targetsFollowingActionDefaults == nil { targetsFollowingActionDefaults = [] }
            targetsFollowingActionDefaults?.insert(target)
        }
    }

    /// Older installations could inherit scope and still override individual actions.
    func followsActionDefaults(for target: Target) -> Bool {
        self[target] == .inherit && targetsFollowingActionDefaults?.contains(target) == true
    }

    /// Track an eligible MR while leaving its automation choice to the user.
    mutating func adoptAutomatically(_ target: Target) {
        rememberManaged(target)
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
        for request in requests where request.webURL.isGitLabMergeRequest(host: host, iid: request.iid) {
            let target = Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
            let needsRuntimeCheck = request.draft == nil || request.isDraft || !request.isOpen
                || awaitsAssignmentClaim(request, target: target)
            if needsRuntimeCheck && !permits(request, host: host, username: username) { result[target] = .paused }
        }
        return result
    }

    func permits(_ request: GitLabMergeRequest, host: String, username: String) -> Bool {
        guard request.isOpen, request.draft != nil else { return false }
        let target = Target.mergeRequest(host: host, username: username, projectID: request.projectID, iid: request.iid)
        return resolve(target, isDraft: request.isDraft).active && !awaitsAssignmentClaim(request, target: target)
    }

    func assignmentClaimRequired(for target: Target) -> Bool {
        treatsAssignedRequestsAsOwn && requiresAssignmentClaim && claimedAssignments?.contains(target) != true
    }

    func awaitsAssignmentClaim(_ request: GitLabMergeRequest, target: Target) -> Bool {
        assignmentClaimRequired(for: target) && request.isOpen
            && request.author.username != target.username && request.isOwned(by: target.username, includingAssignee: true)
            && request.projectID == target.projectID && request.iid == target.iid
            && request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid)
    }

    mutating func claimAssignment(for target: Target) {
        if claimedAssignments == nil { claimedAssignments = [] }
        claimedAssignments?.insert(target)
    }

    func individualOverrides(host: String, username: String) -> [Target] {
        overrides.keys.filter { $0.account == .init(host: host, username: username) && $0.iid != nil }
    }

    func isManaged(_ target: Target) -> Bool {
        target.iid != nil && (managedTargets?.contains(target) == true || self[target] == .active || self[target] == .forceOn)
    }

    func individualTargets(host: String, username: String) -> [Target] {
        let managed = managedTargets?.filter { $0.account == .init(host: host, username: username) && $0.iid != nil } ?? []
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
        overrides.keys.filter { $0.account == .init(host: host, username: username) && $0.iid == nil }
    }

    func repositoryLabel(for target: Target) -> String? {
        repositoryLabels?[target.repository]
    }

    mutating func rememberRepository(_ name: String, for target: Target) {
        if repositoryLabels == nil { repositoryLabels = [:] }
        repositoryLabels?[target.repository] = name
    }
}
