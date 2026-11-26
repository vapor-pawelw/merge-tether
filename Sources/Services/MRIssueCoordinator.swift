import Foundation
import MergeTetherRemote
import Observation

/// Stores only agent-confirmed display metadata for the active account and MR context.
@MainActor @Observable
final class MRIssueCoordinator {
    typealias Target = MRAutomationScope.Target
    typealias CandidateRead = (GitLabMergeRequest, Target) async throws -> [MRIssueCandidate]
    typealias Assessment = ([AssessmentInput]) async throws -> [Target: [RemoteMRIssue]]?

    struct AssessmentInput: Sendable {
        let request: GitLabMergeRequest
        let target: Target
        let evidence: MRIssueAssessor.Input
    }

    private struct Record: Codable, Sendable {
        let version: Int
        let target: Target
        let context: String
        let evidence: String
        var checkedAt: Date
        let issues: [RemoteMRIssue]
    }

    private struct ObservedRequest {
        let request: GitLabMergeRequest
        let context: String
        let generation: UUID
        let revision: UInt64
        let date: Date
    }

    private struct Work {
        let target: Target
        let generation: UUID
        let force: Bool
    }

    private nonisolated static let version = 4
    private static let refreshInterval: TimeInterval = 600
    private static let retryInterval: TimeInterval = 30
    private let file: URL?
    private let now: () -> Date
    private let isCurrentAccount: (Target, UInt64) -> Bool
    private let isEligible: (GitLabMergeRequest, Target) -> Bool
    private let readCandidates: CandidateRead
    private let readReferencedRequests: (GitLabMergeRequest, Target) async throws -> [GitLabMergeRequest]
    private let assess: Assessment
    private var records: [Target: Record] = [:]
    @ObservationIgnored private var observed: [Target: ObservedRequest] = [:]
    @ObservationIgnored private var pendingBoard: [Target: Work] = [:]
    @ObservationIgnored private var pendingSingles: [Target: Work] = [:]
    @ObservationIgnored private var retryAfter: [Target: Date] = [:]
    @ObservationIgnored private var inFlight: [Target: UUID] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cacheLoad: Task<Void, Never>?
    @ObservationIgnored private var accountRevision: UInt64?

    init(file: URL?, now: @escaping () -> Date = Date.init,
         isCurrentAccount: @escaping (Target, UInt64) -> Bool,
         isEligible: @escaping (GitLabMergeRequest, Target) -> Bool = { _, _ in true },
         readCandidates: @escaping CandidateRead,
         readReferencedRequests: @escaping (GitLabMergeRequest, Target) async throws -> [GitLabMergeRequest] = { _, _ in [] },
         assess: @escaping Assessment) {
        self.file = file
        self.now = now
        self.isCurrentAccount = isCurrentAccount
        self.isEligible = isEligible
        self.readCandidates = readCandidates
        self.readReferencedRequests = readReferencedRequests
        self.assess = assess
        if let file {
            cacheLoad = Task(priority: .utility) { [weak self] in
                let saved = await Self.readCache(file)
                guard let self else { return }
                records = saved
                cacheLoad = nil
                drain()
            }
        }
    }

    func issues(for request: GitLabMergeRequest, target: Target, revision: UInt64) -> [RemoteMRIssue] {
        guard isCurrentAccount(target, revision), let record = records[target] else { return [] }
        let context = Self.context(request)
        guard record.context == context,
              observed[target].map({ $0.revision != revision || $0.context == context }) ?? true else { return [] }
        return record.issues
    }

    func observe(_ request: GitLabMergeRequest, target: Target, revision: UInt64, at date: Date) {
        guard isCurrentAccount(target, revision), target.projectID == request.projectID, target.iid == request.iid,
              request.webURL.isGitLabMergeRequest(host: target.host, iid: request.iid) else { return }
        if accountRevision != revision {
            accountRevision = revision
            observed.removeAll()
            retryAfter.removeAll()
            cancelAssessments()
        }
        let previous = observed[target]
        guard previous.map({ date >= $0.date }) ?? true else { return }
        let context = Self.context(request)
        let sameContext = previous?.context == context && previous?.request.state == request.state
        let generation = sameContext ? previous?.generation ?? UUID() : UUID()
        if !sameContext {
            pendingBoard.removeValue(forKey: target)
            pendingSingles.removeValue(forKey: target)
            retryAfter.removeValue(forKey: target)
        }
        observed[target] = .init(request: request, context: context, generation: generation, revision: revision, date: date)
    }

    func requestBoardAssessment(for targets: [Target], revision: UInt64, force: Bool = false) {
        for target in targets {
            let forced = force || pendingSingles[target]?.force == true || pendingBoard[target]?.force == true
            guard let work = eligibleWork(for: target, revision: revision, force: forced) else { continue }
            pendingSingles.removeValue(forKey: target)
            pendingBoard[target] = work
        }
        drain()
    }

    func requestAssessment(for request: GitLabMergeRequest, target: Target, revision: UInt64, force: Bool = false) {
        let current = observed[target]
        guard current?.revision != revision || current?.context == Self.context(request) else { return }
        observe(request, target: target, revision: revision, at: current?.date ?? .distantPast)
        let force = force || pendingBoard[target]?.force == true || pendingSingles[target]?.force == true
        guard let work = eligibleWork(for: target, revision: revision, force: force) else { return }
        if pendingBoard[target] != nil { pendingBoard[target] = work }
        else { pendingSingles[target] = work }
        drain()
    }

    var isWorking: Bool { task != nil || cacheLoad != nil }

    func cancelAssessments() {
        pendingBoard.removeAll()
        pendingSingles.removeAll()
        task?.cancel()
    }

    private func eligibleWork(for target: Target, revision: UInt64, force: Bool) -> Work? {
        guard let current = observed[target], current.revision == revision,
              inFlight[target] != current.generation, current.request.isOpen,
              isCurrentAccount(target, revision), isEligible(current.request, target) else { return nil }
        if !force {
            let timestamp = now()
            guard (retryAfter[target] ?? .distantPast) <= timestamp else { return nil }
            if let record = records[target], record.context == current.context,
               timestamp.timeIntervalSince(record.checkedAt) < Self.refreshInterval { return nil }
        }
        return .init(target: target, generation: current.generation, force: force)
    }

    private func drain() {
        guard task == nil, cacheLoad == nil, !pendingBoard.isEmpty || !pendingSingles.isEmpty else { return }
        task = Task(priority: .utility) { [weak self] in await self?.processPending() }
    }

    private func processPending() async {
        defer { task = nil; drain() }
        while !Task.isCancelled {
            let works: [Work]
            if let single = pendingSingles.values.first {
                pendingSingles.removeValue(forKey: single.target)
                works = [single]
            } else if !pendingBoard.isEmpty {
                works = pendingBoard.values.sorted { left, right in
                    let lhs = records[left.target]?.checkedAt ?? .distantPast
                    let rhs = records[right.target]?.checkedAt ?? .distantPast
                    if lhs != rhs { return lhs < rhs }
                    return (left.target.projectID, left.target.iid ?? 0) < (right.target.projectID, right.target.iid ?? 0)
                }
                pendingBoard.removeAll()
            } else { return }
            let ready = works.filter { work in
                guard let current = observed[work.target] else { return false }
                return eligibleWork(for: work.target, revision: current.revision, force: work.force)?.generation == work.generation
            }
            for work in ready { inFlight[work.target] = work.generation }
            await process(ready)
            inFlight.removeAll()
        }
    }

    private func process(_ works: [Work]) async {
        var pending: [(work: Work, input: AssessmentInput, digest: String)] = []
        var payloadBytes = 0
        var updatedRecords: [(Work, Record)] = []
        for work in works {
            guard !Task.isCancelled, pending.count < MRIssueAssessor.maximumRequests else { break }
            guard let current = currentRequest(for: work) else { continue }
            do {
                let candidates = try await readCandidates(current.request, work.target)
                guard currentRequest(for: work) != nil else { continue }
                let references = candidates.contains { $0.relation != .closing }
                    ? try await readReferencedRequests(current.request, work.target) : []
                let (evidence, digest, bytes) = try await Self.prepareEvidence(for: current.request, candidates: candidates,
                                                                             referencedRequests: references)
                guard currentRequest(for: work) != nil else { continue }
                if !work.force, var cached = records[work.target],
                   cached.context == current.context, cached.evidence == digest {
                    cached.checkedAt = now()
                    updatedRecords.append((work, cached))
                    continue
                }
                // Overflow remains due for the next poll. A board refresh issues one model request.
                guard payloadBytes + bytes <= MRIssueAssessor.maximumPayloadBytes else { break }
                payloadBytes += bytes
                pending.append((work, .init(request: current.request, target: work.target, evidence: evidence), digest))
            } catch {
                if currentRequest(for: work) != nil { retryAfter[work.target] = now().addingTimeInterval(Self.retryInterval) }
            }
        }
        let ready = pending.filter { currentRequest(for: $0.work) != nil }
        if !ready.isEmpty {
            let results = try? await assess(ready.map(\.input))
            for entry in ready {
                guard let current = currentRequest(for: entry.work) else { continue }
                guard let issues = results?[entry.work.target] else {
                    retryAfter[entry.work.target] = now().addingTimeInterval(Self.retryInterval)
                    continue
                }
                updatedRecords.append((entry.work, .init(version: Self.version, target: entry.work.target, context: current.context,
                    evidence: entry.digest, checkedAt: now(), issues: MRIssueAssessor.uniqueIssues(issues))))
            }
        }
        guard !Task.isCancelled else { return }
        await save(updatedRecords.compactMap { work, record in currentRequest(for: work) != nil ? record : nil })
    }

    private func currentRequest(for work: Work) -> ObservedRequest? {
        guard !Task.isCancelled, let current = observed[work.target], current.generation == work.generation,
              current.request.isOpen, isCurrentAccount(work.target, current.revision),
              isEligible(current.request, work.target) else { return nil }
        return current
    }

    private func save(_ updates: [Record]) async {
        guard !updates.isEmpty else { return }
        for record in updates { records[record.target] = record }
        guard let file else { return }
        await Self.writeCache(Array(records.values), to: file)
    }

    private nonisolated static func prepareEvidence(for request: GitLabMergeRequest, candidates: [MRIssueCandidate],
                                                     referencedRequests: [GitLabMergeRequest]) async throws
        -> (MRIssueAssessor.Input, String, Int) {
        let evidence = MRIssueAssessor.Input(request: request, candidates: candidates, referencedRequests: referencedRequests)
        return (evidence, try RemoteDigest.token(evidence), try JSONEncoder().encode(evidence).count + 64)
    }

    private nonisolated static func readCache(_ file: URL) async -> [Target: Record] {
        guard let data = try? Data(contentsOf: file), data.count <= 8_000_000,
              let saved = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        return Dictionary(saved.lazy.filter { $0.version == version }.map { ($0.target, $0) },
                          uniquingKeysWith: { _, latest in latest })
    }

    private nonisolated static func writeCache(_ records: [Record], to file: URL) async {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(records)
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
}
