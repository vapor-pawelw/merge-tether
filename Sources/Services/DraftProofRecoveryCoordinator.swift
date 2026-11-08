import Foundation
import Observation

/// A read-only recovery is a separate assessment, never a replay of its original worker.
@MainActor @Observable
final class DraftProofRecoveryCoordinator {
    struct RejectedDraft: Sendable {
        let draftID: Int
        let state: DraftProofRecoveryVerifier.Assessment.State
        let reason: String
        let summary: String?
        let discussionRootNoteID: Int?
    }
    struct Snapshot: Sendable {
        var request: GitLabMergeRequest
        var discussions: [GitLabMergeRequestDiscussion]
        var drafts: [GitLabDraftNote]
        var user: GitLabAuthenticatedUser
        let host: String
        var branchHead: String
        var work: AssistantAutomationRunner.MergeRequestWork {
            .init(host: host, projectID: request.projectID, iid: request.iid)
        }
    }
    typealias Fetch = @MainActor (Snapshot) async throws -> Snapshot
    typealias HashFile = @MainActor (Snapshot, FollowUpVerification.FileEvidence) async throws -> String
    typealias Verify = @MainActor (DraftProofRecoveryVerifier.Input, AutomationAssistant, String) async throws -> DraftProofRecoveryVerifier.Assessment
    typealias Repair = @MainActor (Snapshot, FollowUpVerification, DraftProofRecoveryVerifier.Assessment) async throws -> UUID?
    private struct AttemptContext: Codable {
        let key: String
        let discussionFingerprint: String
        let drafts: [FollowUpVerification.DraftEvidence]
        var originID: UUID? = nil
    }
    private struct PendingAssessment: Codable {
        let assessment: DraftProofRecoveryVerifier.Assessment
        let headSHA: String
        let files: [FollowUpVerification.FileEvidence]
    }
    private struct Attempt: Codable {
        enum Phase: String, Codable { case checking, repairing, verified, blocked }
        let id: String
        var phase: Phase
        var reason: String?
        var assessment: DraftProofRecoveryVerifier.Assessment? = nil
        var context: AttemptContext? = nil
        var retryAfter: Date? = nil
        var repairTerminal: Bool? = nil
        var repairRetryAfter: Date? = nil
        var repairCodingPolicy: String? = nil
        var repairDraftIDs: [Int]? = nil
        var pendingAssessment: PendingAssessment? = nil
    }
    private struct Request {
        let snapshot: Snapshot
        let origin: FollowUpVerification
        let draftIDs: [Int]
        let configuration: AutomationSettings
        let context: AttemptContext
        let id: String
    }
    private let settings: SettingsManager
    private let directory: URL
    private let verdictDirectory: URL
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let fetch: Fetch
    private let hashFile: HashFile
    private let verify: Verify
    private let accountIsCurrent: @MainActor (Snapshot) -> Bool
    private let retryWait: ReadOnlyAssessmentRetry.Wait
    private let now: ReadOnlyAssessmentRetry.Clock
    @ObservationIgnored private var tasks: [AssistantAutomationRunner.MergeRequestWork: Task<Void, Never>] = [:]
    @ObservationIgnored private var repairTasks: [AssistantAutomationRunner.MergeRequestWork: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [AssistantAutomationRunner.MergeRequestWork: Request] = [:]
    private var states: [AssistantAutomationRunner.MergeRequestWork: Attempt] = [:]
    private var attemptAccounts: [AssistantAutomationRunner.MergeRequestWork: String] = [:]
    private var presentationContexts: [AssistantAutomationRunner.MergeRequestWork: String] = [:]
    private var discussionRoots: [AssistantAutomationRunner.MergeRequestWork: [Int: Int]] = [:]
    private var semanticCache: [AssistantAutomationRunner.MergeRequestWork: (String, DraftProofRecoveryVerifier.Assessment)] = [:]
    var onChange: (() -> Void)?
    var onNeedsRepair: Repair?

    init(settings: SettingsManager, directory: URL, verdictDirectory: URL? = nil,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool,
         fetch: @escaping Fetch, hashFile: @escaping HashFile, verify: @escaping Verify,
         accountIsCurrent: @escaping @MainActor (Snapshot) -> Bool = { _ in true },
         retryWait: @escaping ReadOnlyAssessmentRetry.Wait = ReadOnlyAssessmentRetry.wait,
         now: @escaping ReadOnlyAssessmentRetry.Clock = { Date() }) {
        self.settings = settings; self.directory = directory; self.canAutomate = canAutomate
        self.verdictDirectory = verdictDirectory ?? directory.appending(path: "verdicts")
        self.fetch = fetch; self.hashFile = hashFile; self.verify = verify; self.accountIsCurrent = accountIsCurrent
        self.retryWait = retryWait
        self.now = now
    }

    func isChecking(work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        states[work]?.phase == .checking || (states[work]?.phase == .repairing && stoppedRepairReason(work: work) == nil)
    }
    func isReadOnlyFailure(work: AssistantAutomationRunner.MergeRequestWork) -> Bool {
        guard let state = states[work], state.phase == .blocked else { return false }
        return state.retryAfter != nil || state.repairRetryAfter != nil
    }
    func retryReadOnlyFailures(host: String, username: String) {
        for (work, saved) in states where work.host == host && attemptAccounts[work] == username
            && saved.phase == .blocked && (saved.retryAfter != nil || saved.repairRetryAfter != nil) {
            var state = saved
            if state.retryAfter != nil { state.retryAfter = .distantPast }
            if state.repairRetryAfter != nil { state.repairRetryAfter = .distantPast }
            states[work] = state
            try? persistAttempt(state, work: work, username: username)
        }
    }
    func failure(work: AssistantAutomationRunner.MergeRequestWork) -> String? {
        states[work]?.phase == .blocked ? states[work]?.reason : stoppedRepairReason(work: work)
    }

    private func stoppedRepairReason(work: AssistantAutomationRunner.MergeRequestWork) -> String? {
        guard let state = states[work], state.phase == .repairing,
              let job = settings.assistantHandoffs.filter({ job in
                  job.key.work == work && job.draftRepair.map { repair in
                      state.context?.drafts.contains { $0.id == repair.draftID && $0.bodySHA256 == repair.bodySHA256 } == true
                  } == true
              }).max(by: { $0.createdAt < $1.createdAt }), let execution = job.execution else { return nil }
        if execution.state.isActive { return nil }
        if execution.state == .succeeded {
            let origins = FollowUpVerificationStore.recoveryOrigins(work: work, username: job.key.username, settings: settings, in: directory)
            return origins.contains { $0.runID == job.id } ? nil : "The coding task finished without a current sealed reply correction. Its result still needs verified evidence."
        }
        return execution.attentionExplanation ?? "The coding agent could not finish repairing the prepared reply. Inspect its recorded result."
    }

    func summary(work: AssistantAutomationRunner.MergeRequestWork) -> String? {
        guard let state = states[work], state.phase == .blocked else { return nil }
        // A later stale-snapshot or transport error must not inherit an earlier claim's explanation.
        return state.assessment?.drafts.first {
            $0.state != .valid && GlabService.redactWorkflowEvidence($0.reason) == state.reason
        }.flatMap { AgentExplanation.summary($0.summary) }
    }

    func rejectedDrafts(work: AssistantAutomationRunner.MergeRequestWork, drafts: [GitLabDraftNote]) -> [RejectedDraft] {
        guard let state = states[work], state.repairRetryAfter == nil,
              state.phase == .blocked || stoppedRepairReason(work: work) != nil,
              let assessment = state.assessment,
              let owned = state.context?.drafts else { return [] }
        return assessment.drafts.filter { claim in
            claim.state != .valid && drafts.contains { draft in
                draft.id == claim.draftID && owned.contains {
                    $0.id == claim.draftID && $0.bodySHA256 == AICommentAssessmentStore.digest(draft.note ?? "")
                }
            }
        }.map {
            .init(draftID: $0.draftID, state: $0.state, reason: $0.reason,
                summary: AgentExplanation.summary($0.summary), discussionRootNoteID: discussionRoots[work]?[$0.draftID])
        }
    }

    func presentationIsCurrent(request: GitLabMergeRequest, host: String, fingerprint: String, configuration: AutomationSettings) -> Bool {
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
        guard let context = presentationContexts[work] else { return false }
        return configuration == settings.automation && configuration.allowFollowUpPush
            && (configuration.publicationMode != .manual || DraftReplyRepair.preparationAllowed(request, configuration: configuration))
            && context == presentationContext(request: request, fingerprint: fingerprint, configuration: configuration)
    }

    private func presentationContext(request: GitLabMergeRequest, fingerprint: String, configuration: AutomationSettings) -> String? {
        var presentationPolicy = configuration
        presentationPolicy.scope = MRAutomationScope()
        guard let data = try? JSONEncoder.sorted.encode(presentationPolicy) else { return nil }
        return (request.sha ?? "") + "|" + request.draftProofRecoveryContextFingerprint + "|" + fingerprint + "|" + AICommentAssessmentStore.digest(String(decoding: data, as: UTF8.self))
    }

    func schedule(snapshot: Snapshot, origin: FollowUpVerification, draftIDs: [Int]? = nil, configuration: AutomationSettings) {
        let proposed = draftIDs ?? origin.drafts.map(\.id)
        guard FollowUpVerificationStore.validRecoveryScope(proposed, origin: origin),
              permitted(snapshot, configuration: configuration), matchesOwnership(snapshot, origin: origin, draftIDs: proposed),
              FollowUpVerificationStore.recoveryOrigins(work: snapshot.work, username: snapshot.user.username,
                  settings: settings, in: directory).contains(origin),
              let fingerprint = ReviewVerdict.fingerprint(snapshot.discussions),
              let key = try? verdictContextKey(snapshot, configuration: configuration) else { return }
        attemptAccounts[snapshot.work] = snapshot.user.username
        let presentation = presentationContext(request: snapshot.request, fingerprint: fingerprint, configuration: configuration)
        discussionRoots[snapshot.work] = Dictionary(snapshot.drafts.compactMap { draft -> (Int, Int)? in
            guard let id = draft.id, let discussionID = draft.discussionID,
                  let root = snapshot.discussions.first(where: { $0.id == discussionID })?.notes.first?.id else { return nil }
            return (id, root)
        }, uniquingKeysWith: { first, _ in first })
        if (states[snapshot.work]?.phase == .checking || repairTasks[snapshot.work] != nil),
           presentationContexts[snapshot.work] == presentation { return }
        presentationContexts[snapshot.work] = presentation
        let previous = priorAttempts(snapshot: snapshot, origin: origin, configuration: configuration, key: key)
        let matching = previous.filter { attempt in
            !(attempt.assessment == nil && attempt.retryAfter.map { $0 <= now() } == true)
                && attempt.context?.key == key && attempt.context.map {
                discussionMatches($0.discussionFingerprint, snapshot: snapshot)
                    // A failure without a semantic verdict is scoped to its evidence origin.
                    // Preserve in-flight checks across normalized publication of our own replies.
                    && (attempt.phase == .checking || attempt.assessment != nil
                        || $0.originID == nil || $0.originID == origin.verificationID)
            } == true
        }
        let known = matching.flatMap { $0.context?.drafts ?? [] }
        let selected = proposed.filter { id in
            guard let evidence = origin.drafts.first(where: { $0.id == id }) else { return false }
            return !known.contains(evidence)
        }.sorted()
        guard !selected.isEmpty else {
            if let running = states[snapshot.work], running.phase == .checking,
               tasks[snapshot.work]?.isCancelled == false,
               matching.contains(where: { $0.id == running.id && $0.phase == .checking }) {
                return
            }
            let requested = Set(proposed)
            let blocked = matching.first { attempt in
                attempt.context?.drafts.contains { requested.contains($0.id) } == true
            }
            let reason = ((blocked?.repairTerminal == true || blocked?.repairRetryAfter != nil) ? blocked?.reason : nil)
                ?? blocked?.assessment?.drafts.first { requested.contains($0.draftID) && $0.state != .valid }?.reason
                ?? blocked?.reason ?? String(localized: .DraftProofRecovery.draftProofRecoveryInterrupted)
            var restored = blocked ?? .init(id: key, phase: .blocked)
            restored.phase = .blocked; restored.reason = reason
            states[snapshot.work] = restored
            if let assessment = blocked?.assessment, assessment.drafts.contains(where: { $0.state != .valid }),
               let context = blocked?.context {
                let request = Request(snapshot: snapshot, origin: origin, draftIDs: proposed,
                    configuration: configuration, context: context, id: blocked?.id ?? key)
                scheduleRepair(request, assessment: assessment)
            }
            return
        }
        let context = AttemptContext(key: key, discussionFingerprint: fingerprint,
            drafts: origin.drafts.filter { selected.contains($0.id) }, originID: origin.verificationID)
        let id = AICommentAssessmentStore.digest(key + "|" + fingerprint + "|" + selected.map(String.init).joined(separator: ",")
            + "|" + origin.verificationID.uuidString)
        let request = Request(snapshot: snapshot, origin: origin, draftIDs: selected,
            configuration: configuration, context: context, id: id)
        let resume = previous.first {
            $0.id == id && $0.context?.key == context.key && $0.context?.originID == context.originID
                && $0.context?.drafts == context.drafts && $0.context?.discussionFingerprint == context.discussionFingerprint
        }?.pendingAssessment
        tasks[snapshot.work]?.cancel()
        states[snapshot.work] = .init(id: id, phase: .checking, context: context, pendingAssessment: resume)
        pending[snapshot.work] = request
        startNext()
    }

    func retry(work: AssistantAutomationRunner.MergeRequestWork, username: String) {
        settings.recordAutomationEvent(target: .init(host: work.host, username: username, projectID: work.projectID, iid: work.iid),
            action: .verification, origin: .manual, state: .requested,
            message: String(localized: .DraftProofRecovery.draftProofRecoveryRetryRequested))
        tasks[work]?.cancel(); repairTasks[work]?.cancel(); pending.removeValue(forKey: work)
        states.removeValue(forKey: work); presentationContexts.removeValue(forKey: work); discussionRoots.removeValue(forKey: work)
        semanticCache.removeValue(forKey: work)
        let folder = attemptFolder(work: work, username: username)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(UUID()).write(to: folder.appending(path: "retry-generation.json"), options: .atomic)
        } catch {
            Log.monitor.error("Could not reset draft verification attempts: \(String(describing: error), privacy: .private)")
        }
    }

    func cancel(outsideScope scope: MRAutomationScope? = nil) {
        for work in Set(tasks.keys).union(repairTasks.keys).union(pending.keys).union(states.keys) {
            guard let username = pending[work]?.snapshot.user.username ?? settings.assistantHandoffs.first(where: { $0.key.work == work })?.key.username,
                  scope.map({ !$0.resolve(.init(host: work.host, username: username, projectID: work.projectID, iid: work.iid)).active }) ?? true else { continue }
            tasks[work]?.cancel(); repairTasks[work]?.cancel(); pending.removeValue(forKey: work)
            states.removeValue(forKey: work); presentationContexts.removeValue(forKey: work); discussionRoots.removeValue(forKey: work)
            attemptAccounts.removeValue(forKey: work)
            semanticCache.removeValue(forKey: work)
        }
    }

    private func startNext() {
        while tasks.count < 2, let (work, request) = pending.first(where: { tasks[$0.key] == nil }) {
            pending.removeValue(forKey: work)
            tasks[work] = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: work); startNext(); onChange?() }
                do {
                    // Persist before invoking the verifier; a restart cannot silently repeat it.
                    try Task.checkCancellation()
                    try writeAttempt(states[work] ?? .init(id: request.id, phase: .checking), request: request)
                    record(request, state: .queued, message: String(localized: .DraftProofRecovery.draftProofRecoveryChecking))
                    try await process(request)
                } catch {
                    guard !Task.isCancelled, states[work]?.id == request.id else { return }
                    let reason: String
                    if let blocked = error as? Blocked { reason = blocked.reason }
                    else { reason = GlabService.redactWorkflowEvidence(String(localized: .DraftProofRecovery.draftProofRecoveryFailed) + " " + String(describing: error)) }
                    let semanticPending = states[work]?.pendingAssessment
                    states[work] = .init(id: request.id, phase: .blocked, reason: reason,
                        assessment: nil, context: request.context,
                        retryAfter: error is Blocked || error is CancellationError ? nil : now().addingTimeInterval(ReadOnlyAssessmentRetry.cooldown),
                        pendingAssessment: semanticPending)
                    try? writeAttempt(states[work]!, request: request)
                    record(request, state: .failed, message: reason)
                }
            }
        }
    }

    private func record(_ input: Request, state: MRAutomationEvent.State, message: String) {
        let snapshot = input.snapshot
        settings.recordAutomationEvent(target: .init(host: snapshot.host, username: snapshot.user.username,
            projectID: snapshot.request.projectID, iid: snapshot.request.iid), action: .verification,
            origin: .automatic, state: state, message: message, jobID: input.origin.runID)
    }

    private struct Blocked: Error { let reason: String }
    private struct VerifierUnavailable: Error, CustomStringConvertible {
        var description: String { String(localized: .DraftProofRecovery.draftProofRecoveryUnavailable) }
    }
    private struct Prepared {
        let snapshot: Snapshot
        let files: [FollowUpVerification.FileEvidence]
        let assessment: DraftProofRecoveryVerifier.Assessment
        let model: String
        let head: String
        let fingerprint: String
    }

    private func scheduleRepair(_ input: Request, assessment: DraftProofRecoveryVerifier.Assessment) {
        guard repairTasks[input.snapshot.work] == nil, onNeedsRepair != nil,
              DraftReplyRepair.preparationAllowed(input.snapshot.request, configuration: input.configuration) else { return }
        let work = input.snapshot.work
        let policy = input.configuration.assistant.rawValue + "|" + input.configuration.codexReviewModel.rawValue
            + "|" + input.configuration.codexReviewThinking.rawValue
        let scope = input.draftIDs.sorted()
        if let previous = states[work], previous.repairCodingPolicy == policy, previous.repairDraftIDs == scope,
           previous.repairTerminal == true || previous.repairRetryAfter.map({ $0 > now() }) == true {
            return
        }
        states[work]?.repairTerminal = nil
        states[work]?.repairRetryAfter = nil
        states[work]?.repairCodingPolicy = policy
        states[work]?.repairDraftIDs = scope
        states[work]?.phase = .repairing
        repairTasks[work] = Task { [weak self] in
            guard let self else { return }
            var notify = false
            defer { repairTasks.removeValue(forKey: work); if notify { onChange?() } }
            do {
                guard current(input), let launch = onNeedsRepair else { throw CancellationError() }
                let live = try await ReadOnlyAssessmentRetry.run(isCurrent: { current(input) }, wait: retryWait) {
                    try await fetch(input.snapshot)
                }
                guard current(input), sameContext(input.snapshot, live),
                      matchesOwnership(live, origin: input.origin, draftIDs: input.draftIDs) else {
                    throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryChanged))
                }
                let scoped = DraftProofRecoveryVerifier.Assessment(drafts: assessment.drafts.filter { input.draftIDs.contains($0.draftID) })
                let result = await DraftReplyRepair.dispatch(snapshot: live, origin: input.origin, assessment: scoped,
                    settings: settings, directory: directory, launch: launch)
                guard !Task.isCancelled, states[work]?.id == input.id,
                      permitted(input.snapshot, configuration: input.configuration) else { return }
                switch result {
                case .working: states[work]?.phase = .repairing
                case .blocked(let reason):
                    states[work]?.phase = .blocked; states[work]?.reason = reason
                    states[work]?.repairTerminal = true
                    if let state = states[work] { try? writeAttempt(state, request: input) }
                    notify = true
                }
            } catch {
                guard !Task.isCancelled, states[work]?.id == input.id else { return }
                states[work]?.phase = .blocked
                states[work]?.reason = (error as? Blocked)?.reason ?? GlabService.redactWorkflowEvidence(String(describing: error))
                states[work]?.repairTerminal = error is Blocked || error is CancellationError
                states[work]?.repairRetryAfter = error is Blocked || error is CancellationError
                    ? nil : now().addingTimeInterval(ReadOnlyAssessmentRetry.cooldown)
                if let state = states[work] { try? writeAttempt(state, request: input) }
                notify = true
            }
        }
    }

    private func prepare(_ input: Request) async throws -> Prepared {
        let snapshot = input.snapshot
        let live = try await fetch(snapshot)
        guard current(input), sameContext(snapshot, live), pipelineEvidence(snapshot.request) == pipelineEvidence(live.request),
              matchesOwnership(live, origin: input.origin, draftIDs: input.draftIDs) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryChanged))
        }
        var files: [FollowUpVerification.FileEvidence] = []
        for file in input.origin.files {
            let hash = try await hashFile(live, file)
            guard current(input) else { throw CancellationError() }
            files.append(.init(path: file.path, sha256: hash))
        }
        guard let head = live.request.sha,
              FollowUpVerificationStore.validRecoveryEvidence(headSHA: head, files: files, origin: input.origin) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoverySourceChanged))
        }
        let model = input.configuration.assistant == .codex
            ? input.configuration.codexVerificationModel.rawValue : input.configuration.claudeVerificationModel.rawValue
        let assessment: DraftProofRecoveryVerifier.Assessment
        if let pending = states[snapshot.work]?.pendingAssessment {
            guard pending.headSHA == head, pending.files == files else {
                throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoverySourceChanged))
            }
            try DraftProofRecoveryVerifier.validate(pending.assessment, draftIDs: input.draftIDs)
            assessment = pending.assessment
        } else if let cached = semanticCache[snapshot.work], cached.0 == input.id { assessment = cached.1 }
        else {
            let available = await canAutomate(input.configuration.assistant)
            guard current(input) else { throw CancellationError() }
            guard available else { throw VerifierUnavailable() }
            assessment = try await verify(.init(snapshot: live, origin: input.origin, draftIDs: input.draftIDs, currentFiles: files), input.configuration.assistant, model)
            try DraftProofRecoveryVerifier.validate(assessment, draftIDs: input.draftIDs)
            guard current(input) else { throw CancellationError() }
            semanticCache[snapshot.work] = (input.id, assessment)
        }
        guard current(input) else { throw CancellationError() }
        // A verifier response is durable before final I/O, but is not a completed proof or rejection yet.
        states[snapshot.work]?.pendingAssessment = .init(assessment: assessment, headSHA: head, files: files)
        try writeAttempt(states[snapshot.work]!, request: input)
        let final = try await fetch(snapshot)
        guard current(input), sameContext(snapshot, final), matchesOwnership(final, origin: input.origin, draftIDs: input.draftIDs),
              let fingerprint = ReviewVerdict.fingerprint(final.discussions) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryChanged))
        }
        for file in files {
            guard try await hashFile(final, file) == file.sha256, current(input) else {
                throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoverySourceChanged))
            }
        }
        return Prepared(snapshot: final, files: files, assessment: assessment, model: model, head: head, fingerprint: fingerprint)
    }

    private func process(_ input: Request) async throws {
        let snapshot = input.snapshot
        let checked: Result<Prepared, Blocked> = try await ReadOnlyAssessmentRetry.run(isCurrent: { current(input) }, wait: retryWait) {
            do { return .success(try await prepare(input)) }
            catch let blocked as Blocked { return .failure(blocked) }
        }
        let prepared = try checked.get()
        let assessment = prepared.assessment
        states[snapshot.work]?.assessment = assessment
        try writeAttempt(states[snapshot.work]!, request: input)
        let valid = assessment.drafts.filter { $0.state == .valid }.map(\.draftID)
        let rejection = assessment.drafts.first { $0.state != .valid }
        guard !valid.isEmpty else {
            let reason = rejection.map { GlabService.redactWorkflowEvidence($0.reason) }
                ?? String(localized: .DraftProofRecovery.draftProofRecoveryFailed)
            states[snapshot.work] = .init(id: input.id, phase: .blocked, reason: reason, assessment: assessment, context: input.context)
            try writeAttempt(states[snapshot.work]!, request: input)
            record(input, state: .failed, message: reason)
            scheduleRepair(input, assessment: assessment)
            return
        }
        let final = prepared.snapshot
        let assessmentID = UUID()
        let proof = FollowUpVerificationStore.recoveredProof(origin: input.origin, assessmentID: assessmentID,
            fingerprint: prepared.fingerprint, semanticContext: final.request.semanticContextFingerprint,
            recoveryContext: final.request.draftProofRecoveryContextFingerprint, draftIDs: valid, headSHA: prepared.head, files: prepared.files)
        try FollowUpVerificationStore.persistRecovery(.init(version: 2, attemptID: input.id, assessmentID: assessmentID,
            assistant: input.configuration.assistant, model: prepared.model, origin: input.origin, proof: proof,
            assessment: assessment, requestedDraftIDs: input.draftIDs),
            work: snapshot.work, username: snapshot.user.username, in: directory)
        if let rejection {
            let reason = GlabService.redactWorkflowEvidence(rejection.reason)
            states[snapshot.work] = .init(id: input.id, phase: .blocked, reason: reason, assessment: assessment, context: input.context)
            try writeAttempt(states[snapshot.work]!, request: input)
            record(input, state: .blocked, message: reason)
            scheduleRepair(input, assessment: assessment)
        } else {
            states[snapshot.work] = .init(id: input.id, phase: .verified, assessment: assessment, context: input.context)
            try writeAttempt(states[snapshot.work]!, request: input)
            record(input, state: .completed, message: String(localized: .DraftProofRecovery.draftProofRecoveryCompleted))
        }
    }

    private func current(_ input: Request) -> Bool {
        !Task.isCancelled && states[input.snapshot.work]?.id == input.id
            && permitted(input.snapshot, configuration: input.configuration)
            && FollowUpVerificationStore.recoveryOrigins(work: input.snapshot.work, username: input.snapshot.user.username,
                settings: settings, in: directory).contains(input.origin)
    }

    private func permitted(_ snapshot: Snapshot, configuration: AutomationSettings) -> Bool {
        accountIsCurrent(snapshot) && configuration.preservingScope(from: settings.automation) == settings.automation
            && settings.automation.packageDecision != .disabled
            && settings.automation.allowFollowUpPush
            && (settings.automation.publicationMode != .manual
                || DraftReplyRepair.preparationAllowed(snapshot.request, configuration: settings.automation))
            && settings.automation.scope.permits(snapshot.request, host: snapshot.host, username: snapshot.user.username)
            && !settings.ignoredMergeRequests.contains(.init(host: snapshot.host, username: snapshot.user.username,
                projectID: snapshot.request.projectID, iid: snapshot.request.iid))
    }

    private func matchesOwnership(_ snapshot: Snapshot, origin: FollowUpVerification, draftIDs: [Int]) -> Bool {
        snapshot.request.draft == false && snapshot.request.webURL.isGitLabMergeRequest(host: snapshot.host, iid: snapshot.request.iid)
            && snapshot.request.state == "opened" && snapshot.request.author.id == snapshot.user.id
            && snapshot.branchHead == snapshot.request.sha && draftIDs.allSatisfy { draftID in
                let matching = snapshot.drafts.filter { $0.id == draftID }
                return matching.count == 1 && AutomaticPublicationPolicy.safeForAutomaticPublication(matching[0])
                    && origin.owns(matching[0], request: snapshot.request, host: snapshot.host, user: snapshot.user)
            }
    }

    private func sameContext(_ original: Snapshot, _ live: Snapshot) -> Bool {
        live.host == original.host && live.user == original.user && live.request.projectID == original.request.projectID
            && live.request.iid == original.request.iid && live.request.webURL == original.request.webURL
            && live.request.sha == original.request.sha && live.branchHead == original.branchHead
            && live.request.state == "opened" && live.request.author.id == original.user.id
            && live.request.sourceProjectID == original.request.sourceProjectID
            && live.request.sourceBranch == original.request.sourceBranch
            && live.request.draftProofRecoveryContextFingerprint == original.request.draftProofRecoveryContextFingerprint
            && ReviewVerdict.fingerprint(original.discussions).map { discussionMatches($0, snapshot: live) } == true
    }

    private func attemptFolder(work: AssistantAutomationRunner.MergeRequestWork, username: String) -> URL {
        FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts", work: work, username: username, in: directory).deletingPathExtension()
    }
    private func pipelineEvidence(_ request: GitLabMergeRequest) -> String {
        (try? JSONEncoder.sorted.encode(request.headPipeline)).map { String(decoding: $0, as: UTF8.self) } ?? "unknown"
    }

    private func verdictContextKey(_ snapshot: Snapshot, configuration: AutomationSettings) throws -> String {
        let folder = attemptFolder(work: snapshot.work, username: snapshot.user.username)
        let epoch = (try? Data(contentsOf: folder.appending(path: "retry-generation.json"))) ?? Data()
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
        // Publication policy and unrelated scope adoption do not alter a claim's truth.
        return AICommentAssessmentStore.digest("draft-verdict-v1|\(snapshot.host)|\(snapshot.user.id)|\(snapshot.user.username)"
            + "|\(snapshot.request.sha ?? "")|\(snapshot.branchHead)|\(snapshot.request.draftProofRecoveryContextFingerprint)"
            + "|\(configuration.assistant.rawValue)|\(model)|\(DraftProofRecoveryVerifier.criteriaVersion)"
            + "|" + pipelineEvidence(snapshot.request) + "|" + AICommentAssessmentStore.digest(String(decoding: epoch, as: UTF8.self)))
    }

    private func discussionMatches(_ fingerprint: String, snapshot: Snapshot) -> Bool {
        ReviewVerdict(version: 1, host: snapshot.host, projectID: snapshot.request.projectID, iid: snapshot.request.iid,
            headSHA: snapshot.request.sha ?? "", verdict: .noObjections, discussionFingerprint: fingerprint)
            .covers(head: snapshot.request.sha ?? "", discussions: snapshot.discussions, reviewerID: snapshot.user.id,
                publishedDrafts: ReviewVerdictStore.seenDrafts(host: snapshot.host, projectID: snapshot.request.projectID,
                    iid: snapshot.request.iid, in: verdictDirectory))
    }

    private func storedAttempts(work: AssistantAutomationRunner.MergeRequestWork, username: String) -> [Attempt] {
        let folder = attemptFolder(work: work, username: username)
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap { path in
            guard path.pathExtension == "json", (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 250_000,
                  let data = try? Data(contentsOf: path), let record = try? JSONDecoder().decode(Attempt.self, from: data),
                  record.id == path.deletingPathExtension().lastPathComponent else { return nil }
            return record
        }
    }

    private func priorAttempts(snapshot: Snapshot, origin: FollowUpVerification, configuration: AutomationSettings, key: String) -> [Attempt] {
        var attempts = storedAttempts(work: snapshot.work, username: snapshot.user.username)
        let folder = attemptFolder(work: snapshot.work, username: snapshot.user.username)
        guard !FileManager.default.fileExists(atPath: folder.appending(path: "retry-generation.json").path) else { return attempts }
        let model = configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue
        for record in FollowUpVerificationStore.recoveryRecords(work: snapshot.work, username: snapshot.user.username,
            settings: settings, in: directory) {
            guard attempts.first(where: { $0.id == record.attemptID })?.context == nil,
                  record.assistant == configuration.assistant, record.model == model,
                  record.proof.userID == snapshot.user.id, record.proof.headSHA == snapshot.request.sha,
                  record.proof.recoveryContextFingerprint == snapshot.request.draftProofRecoveryContextFingerprint,
                  let fingerprint = record.proof.discussionFingerprint, discussionMatches(fingerprint, snapshot: snapshot) else { continue }
            let scope = record.requestedDraftIDs ?? record.origin.drafts.map(\.id)
            let rejected = record.assessment.drafts.first { $0.state != .valid }
            let context = AttemptContext(key: key, discussionFingerprint: fingerprint,
                drafts: record.origin.drafts.filter { scope.contains($0.id) })
            let imported = Attempt(id: record.attemptID, phase: rejected == nil ? .verified : .blocked,
                reason: rejected?.reason, assessment: record.assessment, context: context)
            try? persistAttempt(imported, work: snapshot.work, username: snapshot.user.username)
            attempts.removeAll { $0.id == record.attemptID }; attempts.append(imported)
        }
        // Old failed/interrupted records lacked scope and context metadata. Migrate
        // them conservatively once; never turn missing historical evidence into another try.
        for legacy in attempts where legacy.context == nil && snapshot.request.sha == origin.headSHA {
            let context = AttemptContext(key: key, discussionFingerprint: ReviewVerdict.fingerprint(snapshot.discussions) ?? "",
                drafts: origin.drafts)
            var imported = legacy; imported.context = context
            try? persistAttempt(imported, work: snapshot.work, username: snapshot.user.username)
            if let index = attempts.firstIndex(where: { $0.id == legacy.id }) { attempts[index] = imported }
        }
        return attempts
    }

    private func persistAttempt(_ attempt: Attempt, work: AssistantAutomationRunner.MergeRequestWork, username: String) throws {
        let folder = attemptFolder(work: work, username: username)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(attempt).write(to: folder.appending(path: "\(attempt.id).json"), options: .atomic)
    }

    private func writeAttempt(_ attempt: Attempt, request: Request) throws {
        var bound = attempt
        bound.context = request.context
        if bound.phase == .checking, bound.assessment == nil {
            bound.retryAfter = now().addingTimeInterval(ReadOnlyAssessmentRetry.cooldown)
        }
        try persistAttempt(bound, work: request.snapshot.work, username: request.snapshot.user.username)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
