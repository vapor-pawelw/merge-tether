import Foundation

struct AssistantAutomaticRetryTarget: Codable, Hashable, Sendable {
    let host: String
    let username: String
    let projectID: Int
    let iid: Int
    var isValid: Bool { !host.isEmpty && !username.isEmpty && projectID > 0 && iid > 0 }
}

struct AssistantAutomaticRetryIdentity: Codable, Equatable, Sendable {
    let rootID: UUID
    let reservationID: UUID
    let attempt: Int
}

struct AssistantAutomaticRetryAttempt: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case reserved, started, failed, obsolete }
    let id: UUID
    let rootID: UUID
    let parentJobID: UUID
    let target: AssistantAutomaticRetryTarget
    let family: String
    let attempt: Int
    let reservedAt: Date
    var state: State = .reserved
    var finishedAt: Date? = nil
    var replacementJobID: UUID? = nil
    var failure: String? = nil
    /// A recorded replacement stopped at the disk gate before launching, so it does not spend an attempt.
    var diskDeferred: Bool? = nil
    var identity: AssistantAutomaticRetryIdentity { .init(rootID: rootID, reservationID: id, attempt: attempt) }
}

/// Scheduling facts do not authorize a workflow or a GitLab write. Admission remains live and workflow-specific.
enum AssistantAutomaticRetryPolicy {
    static let maximumRetries = 3
    static let delays: [TimeInterval] = [15, 60, 300]

    struct Candidate: Sendable {
        let id: UUID
        var target: AssistantAutomaticRetryTarget
        var family: String
        var createdAt: Date
        var state: AssistantJobExecution.State
        var finishedAt: Date?
        var cancellationOrigin: AssistantJobExecution.CancellationOrigin? = nil
        var automaticRetryIdentity: AssistantAutomaticRetryIdentity? = nil
        var retryOf: UUID? = nil
        var isExecutable = true
        var delegatesRecovery = false
        var isObsolete = false
    }

    struct Plan: Equatable, Sendable, Identifiable {
        let parentJobID: UUID
        let rootID: UUID
        let target: AssistantAutomaticRetryTarget
        let family: String
        let attempt: Int
        var dueAt: Date
        var id: String { "\(rootID.uuidString)/\(attempt)" }

        func reservation(id: UUID = UUID(), at date: Date) -> AssistantAutomaticRetryAttempt {
            .init(id: id, rootID: rootID, parentJobID: parentJobID, target: target,
                family: family, attempt: attempt, reservedAt: date)
        }
    }

    enum Assessment: Equatable, Sendable {
        case planned(Plan)
        case exhausted(parentJobID: UUID, rootID: UUID)
    }

    private struct Family: Hashable { let target: AssistantAutomaticRetryTarget; let name: String }

    static func assess(_ jobs: [Candidate], attempts: [AssistantAutomaticRetryAttempt]) -> [Assessment] {
        guard Set(attempts.map(\.id)).count == attempts.count else { return [] }
        let active = Set(jobs.filter { !$0.isObsolete && $0.state.isActive }.map(\.target))
        var leaves: [Family: Candidate] = [:]
        for job in jobs where !job.isObsolete && job.target.isValid {
            let family = Family(target: job.target, name: job.family)
            if let current = leaves[family], current.createdAt > job.createdAt
                || current.createdAt == job.createdAt && current.id.uuidString > job.id.uuidString { continue }
            leaves[family] = job
        }
        return leaves.values.compactMap { job in
            guard !active.contains(job.target), !job.delegatesRecovery, job.isExecutable,
                  job.cancellationOrigin != .user,
                  job.state == .failed || job.state == .interrupted
                    || job.state == .cancelled && job.cancellationOrigin == .policy,
                  let finishedAt = job.finishedAt, finishedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return assess(job, finishedAt: finishedAt, attempts: attempts)
        }.sorted { left, right in
            switch (left, right) {
            case (.planned(let a), .planned(let b)): a.dueAt == b.dueAt ? a.id < b.id : a.dueAt < b.dueAt
            case (.planned, .exhausted): true
            case (.exhausted, .planned): false
            case (.exhausted(let a, _), .exhausted(let b, _)): a.uuidString < b.uuidString
            }
        }
    }

    private static func assess(_ job: Candidate, finishedAt: Date,
                               attempts: [AssistantAutomaticRetryAttempt]) -> Assessment? {
        let adopted = attempts.first { $0.replacementJobID == job.id && $0.state == .started }
        let root = job.automaticRetryIdentity?.rootID ?? adopted?.rootID ?? job.id
        let lineage = attempts.filter { $0.rootID == root }
        let spent = lineage.filter { $0.diskDeferred != true }
        guard lineage.allSatisfy({ $0.target == job.target && $0.family == job.family
            && (1...maximumRetries).contains($0.attempt) && $0.reservedAt.timeIntervalSinceReferenceDate.isFinite
            && ($0.finishedAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
            && ($0.state == .started ? $0.replacementJobID != nil : $0.replacementJobID == nil)
            && ($0.diskDeferred != true || $0.state == .started)
        }), Set(spent.map(\.attempt)).count == spent.count,
              Set(spent.map(\.attempt)) == Set(1...max(1, spent.count)) || spent.isEmpty else { return nil }
        if let identity = job.automaticRetryIdentity {
            guard lineage.contains(where: { record in
                guard record.identity == identity else { return false }
                if identity.rootID == job.id { return record.parentJobID == job.id }
                return record.state == .started && record.replacementJobID == job.id && record.parentJobID == job.retryOf
            }) else { return nil }
        } else if let adopted, adopted.parentJobID != job.retryOf { return nil }
        guard !lineage.contains(where: { $0.state == .obsolete || $0.state == .reserved
            || $0.state == .started && $0.parentJobID == job.id }) else { return nil }
        let number = spent.count + 1
        guard number <= maximumRetries else { return .exhausted(parentJobID: job.id, rootID: root) }
        let base = lineage.filter { $0.parentJobID == job.id && $0.state == .failed }
            .map { max($0.reservedAt, $0.finishedAt ?? $0.reservedAt) }.reduce(finishedAt, max)
        return .planned(.init(parentJobID: job.id, rootID: root, target: job.target,
            family: job.family, attempt: number, dueAt: base.addingTimeInterval(delays[number - 1])))
    }
}
