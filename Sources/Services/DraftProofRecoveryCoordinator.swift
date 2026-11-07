import Foundation
import Observation

/// A read-only recovery is a separate assessment, never a replay of its original worker.
@MainActor @Observable
final class DraftProofRecoveryCoordinator {
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
    private struct AttemptContext: Codable {
        let key: String
        let discussionFingerprint: String
        let drafts: [FollowUpVerification.DraftEvidence]
    }
    private struct Attempt: Codable {
        enum Phase: String, Codable { case checking, verified, blocked }
        let id: String
        var phase: Phase
        var reason: String?
        var assessment: DraftProofRecoveryVerifier.Assessment? = nil
        var context: AttemptContext? = nil
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
    @ObservationIgnored private var tasks: [AssistantAutomationRunner.MergeRequestWork: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [AssistantAutomationRunner.MergeRequestWork: Request] = [:]
    private var states: [AssistantAutomationRunner.MergeRequestWork: Attempt] = [:]
    private var presentationContexts: [AssistantAutomationRunner.MergeRequestWork: String] = [:]
    var onChange: (() -> Void)?

    init(settings: SettingsManager, directory: URL, verdictDirectory: URL? = nil,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool,
         fetch: @escaping Fetch, hashFile: @escaping HashFile, verify: @escaping Verify,
         accountIsCurrent: @escaping @MainActor (Snapshot) -> Bool = { _ in true }) {
        self.settings = settings; self.directory = directory; self.canAutomate = canAutomate
        self.verdictDirectory = verdictDirectory ?? directory.appending(path: "verdicts")
        self.fetch = fetch; self.hashFile = hashFile; self.verify = verify; self.accountIsCurrent = accountIsCurrent
    }

    func isChecking(work: AssistantAutomationRunner.MergeRequestWork) -> Bool { states[work]?.phase == .checking }
    func failure(work: AssistantAutomationRunner.MergeRequestWork) -> String? {
        states[work]?.phase == .blocked ? states[work]?.reason : nil
    }

    func presentationIsCurrent(request: GitLabMergeRequest, host: String, fingerprint: String, configuration: AutomationSettings) -> Bool {
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
        guard let context = presentationContexts[work] else { return false }
        return configuration == settings.automation && configuration.allowFollowUpPush && configuration.publicationMode != .manual
            && context == presentationContext(request: request, fingerprint: fingerprint, configuration: configuration)
    }

    private func presentationContext(request: GitLabMergeRequest, fingerprint: String, configuration: AutomationSettings) -> String? {
        var presentationPolicy = configuration
        presentationPolicy.scope = MRAutomationScope()
        guard let data = try? JSONEncoder.sorted.encode(presentationPolicy) else { return nil }
        return request.draftProofRecoveryContextFingerprint + "|" + fingerprint + "|" + AICommentAssessmentStore.digest(String(decoding: data, as: UTF8.self))
    }

    func schedule(snapshot: Snapshot, origin: FollowUpVerification, draftIDs: [Int]? = nil, configuration: AutomationSettings) {
        let proposed = draftIDs ?? origin.drafts.map(\.id)
        guard FollowUpVerificationStore.validRecoveryScope(proposed, origin: origin),
              permitted(snapshot, configuration: configuration), matchesOwnership(snapshot, origin: origin, draftIDs: proposed),
              FollowUpVerificationStore.recoveryOrigins(work: snapshot.work, username: snapshot.user.username,
                  settings: settings, in: directory).contains(origin),
              let fingerprint = ReviewVerdict.fingerprint(snapshot.discussions),
              let key = try? verdictContextKey(snapshot, configuration: configuration) else { return }
        let presentation = presentationContext(request: snapshot.request, fingerprint: fingerprint, configuration: configuration)
        if states[snapshot.work]?.phase == .checking, presentationContexts[snapshot.work] == presentation { return }
        presentationContexts[snapshot.work] = presentation
        let previous = priorAttempts(snapshot: snapshot, origin: origin, configuration: configuration, key: key)
        let matching = previous.filter { attempt in
            attempt.context?.key == key && attempt.context.map {
                discussionMatches($0.discussionFingerprint, snapshot: snapshot)
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
            let reason = blocked?.assessment?.drafts.first { requested.contains($0.draftID) && $0.state != .valid }?.reason
                ?? blocked?.reason ?? String(localized: .DraftProofRecovery.draftProofRecoveryInterrupted)
            states[snapshot.work] = .init(id: blocked?.id ?? key, phase: .blocked, reason: reason,
                assessment: blocked?.assessment, context: blocked?.context)
            return
        }
        let context = AttemptContext(key: key, discussionFingerprint: fingerprint,
            drafts: origin.drafts.filter { selected.contains($0.id) })
        let id = AICommentAssessmentStore.digest(key + "|" + fingerprint + "|" + selected.map(String.init).joined(separator: ","))
        let request = Request(snapshot: snapshot, origin: origin, draftIDs: selected,
            configuration: configuration, context: context, id: id)
        tasks[snapshot.work]?.cancel()
        states[snapshot.work] = .init(id: id, phase: .checking, context: context)
        pending[snapshot.work] = request
        startNext()
    }

    func retry(work: AssistantAutomationRunner.MergeRequestWork, username: String) {
        settings.recordAutomationEvent(target: .init(host: work.host, username: username, projectID: work.projectID, iid: work.iid),
            action: .verification, origin: .manual, state: .requested,
            message: String(localized: .DraftProofRecovery.draftProofRecoveryRetryRequested))
        tasks[work]?.cancel(); pending.removeValue(forKey: work); states.removeValue(forKey: work); presentationContexts.removeValue(forKey: work)
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
        for work in Set(tasks.keys).union(pending.keys).union(states.keys) {
            guard let username = pending[work]?.snapshot.user.username ?? settings.assistantHandoffs.first(where: { $0.key.work == work })?.key.username,
                  scope.map({ !$0.resolve(.init(host: work.host, username: username, projectID: work.projectID, iid: work.iid)).active }) ?? true else { continue }
            tasks[work]?.cancel(); pending.removeValue(forKey: work); states.removeValue(forKey: work); presentationContexts.removeValue(forKey: work)
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
                    try writeAttempt(.init(id: request.id, phase: .checking), request: request)
                    record(request, state: .queued, message: String(localized: .DraftProofRecovery.draftProofRecoveryChecking))
                    try await process(request)
                } catch {
                    guard !Task.isCancelled, states[work]?.id == request.id else { return }
                    let reason: String
                    if let blocked = error as? Blocked { reason = blocked.reason }
                    else { reason = String(localized: .DraftProofRecovery.draftProofRecoveryFailed) }
                    states[work] = .init(id: request.id, phase: .blocked, reason: reason,
                        assessment: states[work]?.assessment, context: request.context)
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

    private func process(_ input: Request) async throws {
        let snapshot = input.snapshot
        guard current(input), await canAutomate(input.configuration.assistant), current(input) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryUnavailable))
        }
        let live = try await fetch(snapshot)
        guard current(input), sameContext(snapshot, live), pipelineEvidence(snapshot.request) == pipelineEvidence(live.request),
              matchesOwnership(live, origin: input.origin, draftIDs: input.draftIDs) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryChanged))
        }
        for file in input.origin.files {
            guard try await hashFile(live, file) == file.sha256, current(input) else {
                throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoverySourceChanged))
            }
        }
        let model = input.configuration.assistant == .codex
            ? input.configuration.codexVerificationModel.rawValue : input.configuration.claudeVerificationModel.rawValue
        let assessment = try await verify(.init(snapshot: live, origin: input.origin, draftIDs: input.draftIDs), input.configuration.assistant, model)
        try DraftProofRecoveryVerifier.validate(assessment, draftIDs: input.draftIDs)
        guard current(input) else { throw CancellationError() }
        states[snapshot.work]?.assessment = assessment
        try writeAttempt(states[snapshot.work]!, request: input)
        let valid = assessment.drafts.filter { $0.state == .valid }.map(\.draftID)
        let rejection = assessment.drafts.first { $0.state != .valid }
        guard !valid.isEmpty else {
            throw Blocked(reason: rejection.map { GlabService.redactWorkflowEvidence($0.reason) }
                ?? String(localized: .DraftProofRecovery.draftProofRecoveryFailed))
        }
        let final = try await fetch(snapshot)
        guard current(input), sameContext(snapshot, final), matchesOwnership(final, origin: input.origin, draftIDs: input.draftIDs),
              let fingerprint = ReviewVerdict.fingerprint(final.discussions) else {
            throw Blocked(reason: String(localized: .DraftProofRecovery.draftProofRecoveryChanged))
        }
        let assessmentID = UUID()
        let proof = FollowUpVerificationStore.recoveredProof(origin: input.origin, assessmentID: assessmentID,
            fingerprint: fingerprint, semanticContext: final.request.semanticContextFingerprint,
            recoveryContext: final.request.draftProofRecoveryContextFingerprint, draftIDs: valid)
        try FollowUpVerificationStore.persistRecovery(.init(version: 1, attemptID: input.id, assessmentID: assessmentID,
            assistant: input.configuration.assistant, model: model, origin: input.origin, proof: proof,
            assessment: assessment, requestedDraftIDs: input.draftIDs),
            work: snapshot.work, username: snapshot.user.username, in: directory)
        if let rejection {
            let reason = GlabService.redactWorkflowEvidence(rejection.reason)
            states[snapshot.work] = .init(id: input.id, phase: .blocked, reason: reason, assessment: assessment, context: input.context)
            try writeAttempt(states[snapshot.work]!, request: input)
            record(input, state: .blocked, message: reason)
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
            && settings.automation.allowFollowUpPush && settings.automation.publicationMode != .manual
            && settings.automation.scope.permits(snapshot.request, host: snapshot.host, username: snapshot.user.username)
            && !settings.ignoredMergeRequests.contains(.init(host: snapshot.host, username: snapshot.user.username,
                projectID: snapshot.request.projectID, iid: snapshot.request.iid))
    }

    private func matchesOwnership(_ snapshot: Snapshot, origin: FollowUpVerification, draftIDs: [Int]) -> Bool {
        snapshot.request.draft == false && snapshot.request.webURL.isGitLabMergeRequest(host: snapshot.host, iid: snapshot.request.iid)
            && snapshot.branchHead == origin.headSHA && draftIDs.allSatisfy { draftID in
                let matching = snapshot.drafts.filter { $0.id == draftID }
                return matching.count == 1 && AutomaticPublicationPolicy.safeForAutomaticPublication(matching[0])
                    && origin.covers(matching[0], request: snapshot.request, host: snapshot.host, user: snapshot.user, runID: origin.runID)
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
        for legacy in attempts where legacy.context == nil {
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
        try persistAttempt(bound, work: request.snapshot.work, username: request.snapshot.user.username)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
