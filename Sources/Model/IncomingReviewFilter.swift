import Foundation

struct IncomingReviewFilterSettings: Codable, Equatable, Sendable {
    var enabled = false
    var criteria = ""

    var activeCriteria: String? {
        let text = criteria.trimmingCharacters(in: .whitespacesAndNewlines)
        return enabled && !text.isEmpty ? text : nil
    }
}

enum IncomingReviewFilterNotice: Codable, Equatable, Sendable {
    case unavailable, interrupted, failed, storage, configurationChanged
    case uncertain(String?)

    var localizedMessage: LocalizedStringResource {
        switch self {
        case .unavailable: .ReviewIntake.reviewIntakeNoticeUnavailable
        case .interrupted: .ReviewIntake.reviewIntakeNoticeInterrupted
        case .failed: .ReviewIntake.reviewIntakeNoticeFailed
        case .storage: .ReviewIntake.reviewIntakeNoticeStorage
        case .configurationChanged: .ReviewIntake.reviewIntakeNoticeConfiguration
        case .uncertain(let reason?) where !reason.isEmpty: .ReviewIntake.reviewIntakeNoticeReason(reason)
        case .uncertain: .ReviewIntake.reviewIntakeNoticeUncertain
        }
    }
}

struct IncomingReviewFilterLedger: Codable, Equatable, Sendable {
    typealias Target = MRAutomationScope.Target

    enum Outcome: Codable, Equatable, Sendable {
        case pending, passed
        case bypassed(IncomingReviewFilterNotice)
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: UUID
        let queuedAt: Date
        var title: String
        var url: URL
        var outcome: Outcome
        var todos: [Todo]
    }

    private(set) var entries: [Target: Entry] = [:]
    private var observedInboxTargets: Set<Target> = []

    static func target(for todo: Todo, host: String, username: String) -> Target? {
        guard todo.targetType == .mergeRequest, todo.project.id > 0, let iid = todo.target.iid, iid > 0,
              todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) != nil else { return nil }
        return .init(host: host, username: username, projectID: todo.project.id, iid: iid)
    }

    func suppresses(_ target: Target) -> Bool {
        entries[target]?.outcome == .pending
    }

    func notice(for target: Target) -> IncomingReviewFilterNotice? {
        guard case .bypassed(let reason) = entries[target]?.outcome else { return nil }
        return reason
    }

    mutating func observeInbox(_ todos: [Todo], host: String, username: String, assigned: Set<Target>,
                               enabled: Bool, excluding: Set<Target>) {
        var current: [Target: [Todo]] = [:]
        for todo in todos where MRTodoIntent.kind(for: todo, username: username) == .review
            && todo.targetState != .closed && todo.targetState != .merged {
            guard let target = Self.target(for: todo, host: host, username: username) else { continue }
            current[target, default: []].append(todo)
        }
        for (target, events) in current {
            if entries[target] != nil {
                entries[target]?.todos = events
            } else if enabled, !observedInboxTargets.contains(target), !assigned.contains(target),
                      !excluding.contains(target), let todo = events.first, let iid = target.iid,
                      let url = todo.targetURL.gitLabTodoMergeRequestURL(host: host, iid: iid) {
                enqueue(target, title: todo.displayTitle, url: url, todos: events)
            }
        }
        for target in observedInboxTargets where target.host == host && target.username == username && current[target] == nil {
            entries[target]?.todos = []
        }
        observedInboxTargets = observedInboxTargets.filter { $0.host != host || $0.username != username }
        observedInboxTargets.formUnion(current.keys)
        prune(host: host, username: username, assigned: assigned)
    }

    mutating func observeAssignments(_ requests: [ReviewAssignmentLedger.Entry], host: String, username: String,
                                     previous: Set<Target>, enabled: Bool, excluding: Set<Target>) {
        var assigned = Set<Target>()
        for assignment in requests {
            let request = assignment.request
            let target = Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
            assigned.insert(target)
            if entries[target] != nil {
                // Keep the queued URL immutable so a moved MR fails open.
                entries[target]?.title = request.title
            } else if enabled, assignment.newSince != nil, !previous.contains(target),
                      !observedInboxTargets.contains(target), !excluding.contains(target) {
                enqueue(target, title: request.title, url: request.webURL, todos: [])
            }
        }
        prune(host: host, username: username, assigned: assigned)
    }

    private mutating func enqueue(_ target: Target, title: String, url: URL, todos: [Todo]) {
        entries[target] = .init(id: UUID(), queuedAt: Date(), title: title, url: url, outcome: .pending, todos: todos)
    }

    private mutating func prune(host: String, username: String, assigned: Set<Target>) {
        entries = entries.filter { target, _ in
            target.host != host || target.username != username || assigned.contains(target) || observedInboxTargets.contains(target)
        }
    }

    mutating func settle(_ target: Target, id: UUID, outcome: Outcome) {
        guard entries[target]?.id == id, entries[target]?.outcome == .pending else { return }
        entries[target]?.outcome = outcome
    }

    @discardableResult
    mutating func releasePending(_ notice: IncomingReviewFilterNotice) -> Bool {
        let pending = entries.keys.filter { entries[$0]?.outcome == .pending }
        for target in pending { entries[target]?.outcome = .bypassed(notice) }
        return !pending.isEmpty
    }

    mutating func replacePendingAfterWriteFailure(_ target: Target, id: UUID, hidden: Bool) {
        guard entries[target]?.id == id else { return }
        entries[target]?.outcome = hidden ? .passed : .bypassed(.storage)
    }

    mutating func releaseInterrupted(hidden: Set<Target> = []) -> Bool {
        let heldAndHidden = hidden.filter(suppresses)
        for target in heldAndHidden { entries[target]?.outcome = .passed }
        let released = releasePending(.interrupted)
        return released || !heldAndHidden.isEmpty
    }

    mutating func releaseForManualAdd(_ target: Target) -> Bool {
        guard suppresses(target) else { return false }
        entries[target]?.outcome = .passed
        return true
    }

    func recoveredTodos(host: String, username: String) -> [Todo] {
        entries.filter { target, entry in
            target.host == host && target.username == username && entry.outcome == .bypassed(.interrupted)
        }.values.flatMap(\.todos)
    }
}
