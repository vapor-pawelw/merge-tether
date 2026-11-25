import Foundation

/// Owns one verifier batch at a time. The assignment ledger also holds inbox
/// candidates so both sources share a single durable decision per MR.
@MainActor
final class IncomingReviewFilterCoordinator {
    typealias Target = MRAutomationScope.Target
    typealias Ledger = IncomingReviewFilterLedger
    typealias Verifier = IncomingReviewFilterVerifier
    typealias Classify = @MainActor ([Verifier.Evidence], Verifier.Configuration, URL, String, String) async throws -> [UUID: Verifier.Result]

    private struct Account: Equatable {
        let host: String
        let username: String
        let revision: UInt64

        func contains(_ target: Target) -> Bool { target.host == host && target.username == username }
    }

    private struct Candidate: Sendable {
        let target: Target
        let entry: Ledger.Entry
    }

    private let settings: SettingsManager
    private let glab: GlabService
    private let dependencies: AssistantDependencyMonitor
    private let health: AssistantCLIHealthStore
    private let classify: Classify
    private let batchDelay: Duration
    private var worker: Task<Void, Never>?
    private var stopped = false
    var onReleased: (() -> Void)?
    var onHidden: (([HiddenReview]) -> Void)?

    init(settings: SettingsManager, glab: GlabService, dependencies: AssistantDependencyMonitor,
         health: AssistantCLIHealthStore, batchDelay: Duration = .seconds(1),
         classify: @escaping Classify = IncomingReviewFilterVerifier.run) {
        self.settings = settings
        self.glab = glab
        self.dependencies = dependencies
        self.health = health
        self.batchDelay = batchDelay
        self.classify = classify
        var ledger = settings.reviewAssignments
        let hidden = settings.ignoredMergeRequests
        if ledger.incomingReviewFilter.releaseInterrupted(hidden: hidden) {
            for target in hidden { ledger.markSeen(target) }
            publish(ledger)
        }
    }

    private var account: Account? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return .init(host: host, username: username, revision: glab.accountRevision)
    }

    var isEnabled: Bool { configuration != nil }

    private var configuration: Verifier.Configuration? {
        guard settings.automationGloballyEnabled, let criteria = settings.incomingReviewFilterSettings.activeCriteria else { return nil }
        return .init(criteria: criteria, automation: settings.automation)
    }

    func observeInbox(_ todos: [Todo], host: String, username: String, excluding: Set<Target>) {
        var ledger = settings.reviewAssignments
        let previous = ledger.incomingReviewFilter
        ledger.observeInboxForFiltering(todos, host: host, username: username, enabled: configuration != nil, excluding: excluding)
        if ledger.incomingReviewFilter != previous { publish(ledger) }
        schedule()
    }

    func observeAssignments(_ observed: ReviewAssignmentLedger, host: String, username: String, excluding: Set<Target>) {
        let previous = settings.reviewAssignments.assignmentTargets(host: host, username: username)
        var ledger = observed
        ledger.incomingReviewFilter.observeAssignments(ledger.entries(host: host, username: username) ?? [],
            host: host, username: username, previous: previous, enabled: configuration != nil, excluding: excluding)
        publish(ledger)
        schedule()
    }

    func configurationChanged() {
        worker?.cancel()
        var ledger = settings.reviewAssignments
        if ledger.incomingReviewFilter.releasePending(.configurationChanged) {
            publish(ledger)
            onReleased?()
        }
    }

    func stop() {
        stopped = true
        worker?.cancel()
    }

    func releaseForManualAdd(_ target: Target) {
        var ledger = settings.reviewAssignments
        guard ledger.incomingReviewFilter.releaseForManualAdd(target) else { return }
        publish(ledger)
    }

    private func pending(for account: Account) -> [Candidate] {
        settings.reviewAssignments.incomingReviewFilter.entries.compactMap { target, entry in
            guard account.contains(target), entry.outcome == .pending else { return nil }
            return Candidate(target: target, entry: entry)
        }.sorted { $0.entry.queuedAt < $1.entry.queuedAt }
    }

    private func schedule() {
        guard !stopped, worker == nil, let account, !pending(for: account).isEmpty else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                worker = nil
                schedule()
            }
            do { try await Task.sleep(for: batchDelay) }
            catch { return }
            guard self.account == account else {
                releaseInterruptedAccount(pending(for: account), account: account)
                return
            }
            await drain(account)
        }
    }

    private func drain(_ account: Account) async {
        while !Task.isCancelled, self.account == account {
            let batch = pending(for: account)
            guard !batch.isEmpty else { return }
            guard let configuration else {
                release(batch, reason: .configurationChanged)
                return
            }
            guard let assistant = configuration.assistant, health.hold(for: assistant) == nil else {
                release(batch, reason: .unavailable)
                return
            }
            let status: AssistantDependencyStatus
            if let known = dependencies.statuses[assistant] { status = known }
            else { status = await dependencies.check(assistant) }
            guard isCurrent(account, configuration) else {
                releaseInterruptedAccount(batch, account: account)
                return
            }
            guard case .ready(let executable) = status else {
                release(batch, reason: .unavailable)
                return
            }
            let expired = batch.filter { Date().timeIntervalSince($0.entry.queuedAt) >= 180 }
            if !expired.isEmpty {
                release(expired, reason: .failed)
                continue
            }
            await verify(Array(batch.prefix(12)), configuration: configuration, executable: executable, account: account)
        }
    }

    private func verify(_ batch: [Candidate], configuration: Verifier.Configuration, executable: URL, account: Account) async {
        let initial = await readEvidence(batch, account: account)
        guard isCurrent(account, configuration) else {
            releaseInterruptedAccount(batch, account: account)
            return
        }
        guard !initial.isEmpty else {
            release(batch, reason: .uncertain(nil))
            return
        }
        let decisions: [UUID: Verifier.Result]
        do {
            let evidence = batch.compactMap { initial[$0.entry.id] }
            decisions = try await classify(evidence, configuration, executable, account.host, account.username)
        } catch {
            guard isCurrent(account, configuration) else {
                releaseInterruptedAccount(batch, account: account)
                return
            }
            let unavailable = configuration.assistant.flatMap(health.hold(for:)) != nil
                || error is AssistantUsageRunner.AccessError
            release(pending(for: account), reason: unavailable ? .unavailable : .failed)
            if !unavailable { dependencies.refresh(force: true) }
            return
        }
        guard isCurrent(account, configuration) else {
            releaseInterruptedAccount(batch, account: account)
            return
        }
        let rejected = batch.filter { decisions[$0.entry.id]?.decision == .reject }
        let confirmed = await readEvidence(rejected, account: account)
        guard isCurrent(account, configuration) else {
            releaseInterruptedAccount(batch, account: account)
            return
        }
        let hideable = rejected.compactMap { candidate -> HiddenReview? in
            let id = candidate.entry.id, target = candidate.target
            guard let current = settings.reviewAssignments.incomingReviewFilter.entries[target],
                  current.id == id, current.outcome == .pending, !settings.ignoredMergeRequests.contains(target),
                  let original = initial[id], confirmed[id] == original else { return nil }
            return .init(target: target, title: original.title, url: original.url)
        }
        let toHide = Set(hideable.map(\.target))
        let reasons = Dictionary(uniqueKeysWithValues: rejected.compactMap { candidate -> (Target, String)? in
            guard toHide.contains(candidate.target), let result = decisions[candidate.entry.id] else { return nil }
            return (candidate.target, GlabService.redactWorkflowEvidence(result.reason))
        })
        let hidden = !hideable.isEmpty && settings.hideFilteredReviews(hideable, reasons: reasons) ? toHide : []
        settle(batch, hidden: hidden) { candidate in
            guard let decision = decisions[candidate.entry.id], initial[candidate.entry.id] != nil else {
                return .bypassed(.uncertain(nil))
            }
            switch decision.decision {
            case .accept: return .passed
            case .reject:
                if hidden.contains(candidate.target) { return .passed }
                return .bypassed(toHide.contains(candidate.target) ? .storage : .uncertain(nil))
            case .uncertain:
                return .bypassed(.uncertain(GlabService.redactWorkflowEvidence(decision.reason)))
            }
        }
        if !hidden.isEmpty { onHidden?(hideable) }
    }

    private func isCurrent(_ account: Account, _ configuration: Verifier.Configuration) -> Bool {
        !Task.isCancelled && self.account == account && self.configuration == configuration
    }

    private func readEvidence(_ batch: [Candidate], account: Account) async -> [UUID: Verifier.Evidence] {
        await withTaskGroup(of: Verifier.Evidence?.self) { group in
            for candidate in batch {
                group.addTask { [glab] in
                    let target = candidate.target
                    guard await glab.accountRevision == account.revision, let iid = target.iid,
                          let request = try? await glab.fetchMergeRequest(
                        projectID: target.projectID, iid: iid, host: target.host) else { return nil }
                    return Verifier.Evidence(id: candidate.entry.id, request: request, target: target, url: candidate.entry.url)
                }
            }
            var result: [UUID: Verifier.Evidence] = [:]
            for await evidence in group {
                if let evidence { result[evidence.id] = evidence }
            }
            return result
        }
    }

    private func releaseInterruptedAccount(_ batch: [Candidate], account: Account) {
        if self.account != account, !stopped { release(batch, reason: .interrupted) }
    }

    private func release(_ batch: [Candidate], reason: IncomingReviewFilterNotice) {
        settle(batch) { _ in .bypassed(reason) }
    }

    private func settle(_ batch: [Candidate], hidden: Set<Target> = [], outcome: (Candidate) -> Ledger.Outcome) {
        var ledger = settings.reviewAssignments
        var released = false
        let currentAccount = account
        for candidate in batch {
            let target = candidate.target
            guard let current = ledger.incomingReviewFilter.entries[target], current.id == candidate.entry.id,
                  current.outcome == .pending else { continue }
            ledger.incomingReviewFilter.settle(target, id: current.id, outcome: outcome(candidate))
            if hidden.contains(target) { ledger.markSeen(target) }
            else if currentAccount?.contains(target) == true { released = true }
        }
        if !publish(ledger) || released { onReleased?() }
    }

    @discardableResult
    private func publish(_ ledger: ReviewAssignmentLedger) -> Bool {
        if settings.saveReviewAssignments(ledger) { return true }
        // Do not rely on a rejected decision whose transition failed to persist.
        var fallback = ledger
        for (target, entry) in settings.reviewAssignments.incomingReviewFilter.entries
            where entry.outcome == .pending {
            fallback.incomingReviewFilter.replacePendingAfterWriteFailure(target, id: entry.id,
                hidden: settings.ignoredMergeRequests.contains(target))
        }
        fallback.incomingReviewFilter.releasePending(.storage)
        if !settings.saveReviewAssignments(fallback) { settings.reviewAssignments = fallback }
        return false
    }
}
