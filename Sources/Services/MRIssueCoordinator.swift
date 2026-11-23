import Foundation
import MergeTetherRemote
import Observation

/// Account-bound display metadata. Each source can fail or refresh independently.
@MainActor @Observable
final class MRIssueCoordinator {
    typealias Target = MRAutomationScope.Target
    typealias ClosingRead = (Target) async throws -> [RemoteMRIssue]
    typealias Assessment = (GitLabMergeRequest, Target) async throws -> [RemoteMRIssue]?

    private struct Record: Codable {
        let version: Int
        let target: Target
        let context: String
        var closing: [RemoteMRIssue]?
        var checkedAt: Date?
        var inferred: [RemoteMRIssue]?
    }

    private struct ObservedRequest {
        let request: GitLabMergeRequest
        let context: String
        let revision: UInt64
        let date: Date
    }

    private struct Work: Equatable {
        let target: Target
        let context: String
        let revision: UInt64
    }

    private static let version = 1
    private static let closingInterval: TimeInterval = 600
    private static let retryInterval: TimeInterval = 30
    private let file: URL?
    private let now: () -> Date
    private let isCurrentAccount: (Target, UInt64) -> Bool
    private let readClosing: ClosingRead
    private let assess: Assessment
    private var records: [Target: Record]
    @ObservationIgnored private var observed: [Target: ObservedRequest] = [:]
    @ObservationIgnored private var pendingClosing: [Target: Work] = [:]
    @ObservationIgnored private var pendingAssessment: [Target: Work] = [:]
    @ObservationIgnored private var nativeRetryAfter: [Target: Date] = [:]
    @ObservationIgnored private var assessmentRetryAfter: [Target: Date] = [:]
    @ObservationIgnored private var reading: Work?
    @ObservationIgnored private var assessing: Work?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var assessmentTask: Task<Void, Never>?
    @ObservationIgnored private var accountRevision: UInt64?

    init(file: URL?, now: @escaping () -> Date = Date.init,
         isCurrentAccount: @escaping (Target, UInt64) -> Bool,
         readClosing: @escaping ClosingRead, assess: @escaping Assessment) {
        self.file = file
        self.now = now
        self.isCurrentAccount = isCurrentAccount
        self.readClosing = readClosing
        self.assess = assess
        var entries: [Target: Record] = [:]
        if let file, let data = try? Data(contentsOf: file), data.count <= 8_000_000,
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            for record in saved where record.version == Self.version { entries[record.target] = record }
        }
        records = entries
    }

    func issues(for request: GitLabMergeRequest, target: Target, revision: UInt64) -> [RemoteMRIssue] {
        guard isCurrentAccount(target, revision), let record = records[target] else { return [] }
        let context = Self.context(request)
        guard record.context == context,
              observed[target].map({ $0.revision != revision || $0.context == context }) ?? true else { return [] }
        return Self.combine(closing: record.closing ?? [], inferred: record.inferred ?? [])
    }

    func observe(_ request: GitLabMergeRequest, target: Target, revision: UInt64, at date: Date,
                 assessExternal: Bool = false, refreshClosing: Bool = false) {
        guard isCurrentAccount(target, revision), target.projectID == request.projectID, target.iid == request.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid) else { return }
        if accountRevision != revision {
            accountRevision = revision
            observed.removeAll()
            pendingClosing.removeAll()
            pendingAssessment.removeAll()
            nativeRetryAfter.removeAll()
            assessmentRetryAfter.removeAll()
            closingTask?.cancel()
            assessmentTask?.cancel()
        }
        guard observed[target].map({ date >= $0.date }) ?? true else { return }
        let context = Self.context(request)
        if observed[target]?.context != context {
            pendingClosing.removeValue(forKey: target)
            pendingAssessment.removeValue(forKey: target)
            nativeRetryAfter.removeValue(forKey: target)
            assessmentRetryAfter.removeValue(forKey: target)
        }
        observed[target] = .init(request: request, context: context, revision: revision, date: date)
        guard request.state == "opened" else { return }

        let work = Work(target: target, context: context, revision: revision)
        let record = record(for: work)
        let timestamp = now()
        if work != reading, (nativeRetryAfter[target] ?? .distantPast) <= timestamp,
           refreshClosing || record.checkedAt.map({ timestamp.timeIntervalSince($0) >= Self.closingInterval }) != false {
            pendingClosing[target] = work
        }
        if assessExternal, work != assessing, record.inferred == nil,
           (assessmentRetryAfter[target] ?? .distantPast) <= timestamp {
            pendingAssessment[target] = work
        }
        drain()
    }

    var isWorking: Bool { closingTask != nil || assessmentTask != nil }

    func requestAssessment(for request: GitLabMergeRequest, target: Target, revision: UInt64) {
        let current = observed[target]
        guard current?.revision != revision || current?.context == Self.context(request) else { return }
        observe(request, target: target, revision: revision, at: current?.date ?? .distantPast, assessExternal: true)
    }

    func cancelAssessments() {
        pendingAssessment.removeAll()
        assessmentTask?.cancel()
    }

    private func drain() {
        if closingTask == nil, !pendingClosing.isEmpty {
            closingTask = Task { [weak self] in await self?.drainClosingReads() }
        }
        if assessmentTask == nil, nextAssessment != nil {
            assessmentTask = Task { [weak self] in await self?.drainAssessments() }
        }
    }

    private var nextAssessment: Work? {
        pendingAssessment.values.first { pendingClosing[$0.target] == nil && reading?.target != $0.target }
    }

    private func drainClosingReads() async {
        defer { closingTask = nil; drain() }
        while !Task.isCancelled, let work = pendingClosing.values.first {
            pendingClosing.removeValue(forKey: work.target)
            guard currentRequest(for: work) != nil else { continue }
            reading = work
            do {
                let found = try await readClosing(work.target)
                if currentRequest(for: work) != nil {
                    var updated = record(for: work)
                    updated.closing = found
                    updated.checkedAt = now()
                    save(updated)
                }
            } catch {
                if currentRequest(for: work) != nil { nativeRetryAfter[work.target] = now().addingTimeInterval(Self.retryInterval) }
            }
            reading = nil
            drain()
        }
    }

    private func drainAssessments() async {
        defer { assessmentTask = nil; drain() }
        while !Task.isCancelled, let work = nextAssessment {
            pendingAssessment.removeValue(forKey: work.target)
            guard let request = currentRequest(for: work) else { continue }
            let record = record(for: work)
            if record.closing?.isEmpty != true, !MRIssueAssessor.Input(request: request, host: work.target.host).hasExternalReference {
                continue
            }
            assessing = work
            do {
                if let found = try await assess(request, work.target), currentRequest(for: work) != nil {
                    var updated = self.record(for: work)
                    updated.inferred = found
                    save(updated)
                }
            } catch {
                if currentRequest(for: work) != nil { assessmentRetryAfter[work.target] = now().addingTimeInterval(Self.retryInterval) }
            }
            assessing = nil
        }
    }

    private func currentRequest(for work: Work) -> GitLabMergeRequest? {
        guard !Task.isCancelled, isCurrentAccount(work.target, work.revision), let current = observed[work.target],
              current.context == work.context, current.revision == work.revision, current.request.state == "opened" else { return nil }
        return current.request
    }

    private func record(for work: Work) -> Record {
        if let record = records[work.target], record.context == work.context { return record }
        return .init(version: Self.version, target: work.target, context: work.context)
    }

    private func save(_ record: Record) {
        let previous = records.updateValue(record, forKey: record.target)
        guard let file, previous?.context != record.context || previous?.closing != record.closing
                || previous?.inferred != record.inferred else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Array(records.values))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.monitor.error("Could not save merge request issue cache")
        }
    }

    private static func context(_ request: GitLabMergeRequest) -> String {
        let fields = [request.semanticContextFingerprint, request.sha ?? "", request.webURL.absoluteString,
                      request.sourceBranch, request.targetBranch, String(request.sourceProjectID ?? 0),
                      String(request.targetProjectID ?? 0)]
        return UserAttentionSnapshot.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    private static func combine(closing: [RemoteMRIssue], inferred: [RemoteMRIssue]) -> [RemoteMRIssue] {
        var result: [RemoteMRIssue] = []
        for issue in closing + inferred {
            if let index = result.firstIndex(where: {
                if let url = issue.linkURL, let known = $0.linkURL { return url == known }
                return $0.reference == issue.reference
            }) {
                if result[index].linkURL == nil, let url = issue.linkURL {
                    result[index] = .init(reference: result[index].reference, title: result[index].title ?? issue.title, url: url)
                }
            } else {
                result.append(issue)
            }
        }
        return result
    }
}
