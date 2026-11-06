import Foundation
import Observation

struct AuthorFeedbackStatus: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case checking, complete, waitingPublication, failed }
    let head: String
    let fingerprint: String
    var phase: Phase
    var findings: [AuthorFeedbackPolicy.Finding] = []
    var pendingDraftCount = 0
    var acceptedReviewerIDs: Set<Int> = []
    var followUpNoteIDs: Set<Int> = []
    var replyNoteIDs: Set<Int> = []

    var needsAttention: Bool {
        phase == .failed || phase == .waitingPublication || findings.contains {
            [.needsChanges, .needsVerification].contains($0.state)
        }
    }
    var waitingForReviewer: Bool { findings.contains { $0.state == .waitingAcceptance } }
}

/// Verifier work is bounded, cached by source/text/policy, and independent of GUI chats.
@MainActor @Observable
final class AuthorFeedbackCoordinator {
    private(set) var statuses: [MRAutomationScope.Target: AuthorFeedbackStatus] = [:]
    @ObservationIgnored private var tasks: [MRAutomationScope.Target: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [MRAutomationScope.Target: Input] = [:]
    @ObservationIgnored private var cache: [MRAutomationScope.Target: (String, ReReviewAssessment)] = [:]
    private let settings: SettingsManager
    private let glab: GlabService
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let verify: @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment
    var onRemoteChange: (() -> Void)?
    var onNeedsWork: ((GitLabMergeRequest, Set<Int>, String) async -> Void)?

    private struct Input {
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]
        let user: GitLabAuthenticatedUser
        let target: MRAutomationScope.Target
        let configuration: AutomationSettings
        let fingerprint: String
        let drafts: Int
    }

    init(settings: SettingsManager, glab: GlabService,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool = { await AssistantCLI.detect($0, requireCLI: true).isReady },
         verify: @escaping @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment = {
             try await ReReviewVerifier.verify($0, assistant: $1, model: $2)
         }) {
        self.settings = settings; self.glab = glab; self.canAutomate = canAutomate; self.verify = verify
    }

    func status(projectID: Int, iid: Int) -> AuthorFeedbackStatus? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return nil }
        return statuses[.init(host: host, username: username, projectID: projectID, iid: iid)]
    }

    func assessment(projectID: Int, iid: Int, head: String, fingerprint: String) -> ReReviewAssessment? {
        guard let host = glab.resolvedHost, let username = glab.currentUsername,
              let state = status(projectID: projectID, iid: iid), state.phase == .complete,
              state.head == head, state.fingerprint == fingerprint else { return nil }
        return cache[.init(host: host, username: username, projectID: projectID, iid: iid)]?.1
    }

    func refresh(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion], drafts: Int,
                 host: String, user: GitLabAuthenticatedUser) {
        let target = MRAutomationScope.Target(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        let configuration = settings.automation
        let workflow = configuration.workflowRules[.newDiscussion]
        let followsFeedback = configuration.authorFeedback.isEnabled
            || (workflow.mode == .assistant && workflow.includes(request))
        guard request.author.id == user.id, request.state == "opened", request.draft == false,
              configuration.autoResolveAcceptedFeedback || configuration.autoMergeEnabled || followsFeedback,
              settings.automation.packageDecision != .disabled,
              settings.automation.packageDecision == .enabled || settings.automation.usesAssistant
                || settings.automation.autoReReviewEnabled || settings.automation.autoMergeEnabled,
              settings.automation.scope.permits(request, host: host, username: user.username),
              let fingerprint = ReviewVerdict.fingerprint(discussions), let head = request.sha else { return }
        let hasFeedback = discussions.contains { $0.notes.contains { $0.system == false && $0.author?.id != user.id } }
        guard hasFeedback else { statuses.removeValue(forKey: target); return }
        if let status = statuses[target], status.head == head, status.fingerprint == fingerprint,
           status.phase == .failed { return }
        if drafts > 0 {
            pending.removeValue(forKey: target); tasks[target]?.cancel()
            statuses[target] = .init(head: head, fingerprint: fingerprint, phase: .waitingPublication, pendingDraftCount: drafts)
            return
        }
        let input = Input(request: request, discussions: discussions, user: user, target: target,
                          configuration: settings.automation, fingerprint: fingerprint, drafts: drafts)
        if statuses[target]?.head != head || statuses[target]?.fingerprint != fingerprint {
            statuses[target] = .init(head: head, fingerprint: fingerprint, phase: .checking)
        }
        pending[target] = input
        startNext()
    }

    func cancel(outsideScope: MRAutomationScope? = nil) {
        for target in Set(tasks.keys).union(pending.keys).union(statuses.keys) {
            guard outsideScope.map({ !$0.resolve(target).active }) ?? true else { continue }
            pending.removeValue(forKey: target); tasks[target]?.cancel()
            statuses.removeValue(forKey: target); cache.removeValue(forKey: target)
        }
    }

    func invalidate(projectID: Int, iid: Int) {
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { return }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: projectID, iid: iid)
        cache.removeValue(forKey: target)
        statuses.removeValue(forKey: target)
    }

    private func startNext() {
        while tasks.count < 2, let (target, input) = pending.first(where: { tasks[$0.key] == nil }) {
            pending.removeValue(forKey: target)
            if statuses[target]?.head != input.request.sha || statuses[target]?.fingerprint != input.fingerprint {
                statuses[target] = .init(head: input.request.sha ?? "", fingerprint: input.fingerprint, phase: .checking)
            }
            tasks[target] = Task { [weak self] in
                guard let self else { return }
                defer { tasks.removeValue(forKey: target); startNext() }
                do { try await process(input) }
                catch is CancellationError {
                    if !Task.isCancelled, isCurrent(input) {
                        statuses.removeValue(forKey: target)
                        onRemoteChange?()
                    }
                }
                catch {
                    if !Task.isCancelled, isCurrent(input) {
                        statuses[target] = .init(head: input.request.sha ?? "", fingerprint: input.fingerprint, phase: .failed)
                        Log.monitor.error("Author feedback verification failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
        }
    }

    private func isCurrent(_ input: Input) -> Bool {
        !Task.isCancelled && glab.resolvedHost == input.target.host && glab.currentUsername == input.user.username
            && settings.automation == input.configuration
            && settings.automation.packageDecision != .disabled
            && !settings.ignoredMergeRequests.contains(input.target)
            && settings.automation.scope.permits(input.request, host: input.target.host, username: input.user.username)
    }

    private func process(_ input: Input) async throws {
        guard isCurrent(input) else { throw CancellationError() }
        guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
        guard isCurrent(input) else { throw CancellationError() }
        let request = input.request
        let host = input.target.host
        let diff: Data = try await glab.mergeRequestAPI("/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = (request.sha ?? "") + "|" + input.fingerprint + "|" + UserAttentionSnapshot.digest(String(decoding: diff, as: UTF8.self))
            + "|" + String(decoding: try encoder.encode(input.configuration), as: UTF8.self)
        let assessment: ReReviewAssessment
        if let stored = cache[input.target], stored.0 == key { assessment = stored.1 }
        else {
            let model = input.configuration.assistant == .codex
                ? input.configuration.codexVerificationModel.rawValue : input.configuration.claudeVerificationModel.rawValue
            assessment = try await verify(.init(authorID: input.user.id, headSHA: request.sha ?? "", title: request.title,
                diff: String(decoding: diff, as: UTF8.self), discussions: input.discussions), input.configuration.assistant, model)
            _ = try assessment.reviewers(in: input.discussions, authorID: input.user.id)
            guard isCurrent(input) else { throw CancellationError() }
            cache[input.target] = (key, assessment)
        }
        guard isCurrent(input) else { throw CancellationError() }
        var approved = try await glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
        var threads = input.discussions
        let initial = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback)
        var accepted: Set<Int> = []
        var changed = false
        for finding in initial where finding.canResolve {
            guard isCurrent(input) else { throw CancellationError() }
            guard await canAutomate(input.configuration.assistant) else { throw ReReviewVerifier.VerificationError.unavailable }
            guard isCurrent(input), let discussionID = finding.discussionID else { throw CancellationError() }
            async let currentMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            async let currentThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: input.user.username)
            async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: input.user.id)
            async let approvals = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
            let (live, discussions, user, count, liveApproved) = try await (currentMR, currentThreads, currentUser, drafts, approvals)
            approved = liveApproved
            guard isCurrent(input), live.sha == request.sha, live.state == "opened", live.draft == false,
                  live.author.id == input.user.id, user == input.user, count == 0,
                  settings.automation.scope.permits(live, host: host, username: user.username),
                  live.webURL == request.webURL, ReviewVerdict.fingerprint(discussions) == input.fingerprint else { throw CancellationError() }
            threads = discussions
            let permitted = AuthorFeedbackPolicy.evaluate(discussions: discussions, assessment: assessment, authorID: user.id,
                approvedReviewerIDs: liveApproved).contains { $0.discussionID == discussionID && $0.canResolve }
            guard permitted else { continue }
            try await glab.resolveAcceptedDiscussion(projectID: request.projectID, iid: request.iid, discussionID: discussionID, host: host)
            changed = true
            accepted.insert(finding.reviewerID)
            threads = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            let confirmed = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            guard isCurrent(input), confirmed.sha == request.sha,
                  settings.automation.scope.permits(confirmed, host: host, username: input.user.username),
                  ReviewVerdict.fingerprint(threads) == input.fingerprint else { throw CancellationError() }
        }
        guard isCurrent(input) else { throw CancellationError() }
        let findings = AuthorFeedbackPolicy.evaluate(discussions: threads, assessment: assessment, authorID: input.user.id,
            approvedReviewerIDs: approved, enabled: input.configuration.autoResolveAcceptedFeedback)
        accepted.formUnion(AuthorFeedbackPolicy.acceptedReviewers(discussions: threads, assessment: assessment,
            authorID: input.user.id, approvedReviewerIDs: approved))
        let allNotes: [GitLabMergeRequestDiscussion.Note] = threads.flatMap(\.notes)
        let outstandingNotes = allNotes.filter {
            $0.system == false && $0.author?.id != input.user.id
        }
        let outstanding: Set<Int> = Set(outstandingNotes.compactMap(\.id))
        var followUp = Set(assessment.notes.filter {
            outstanding.contains($0.noteID) && ($0.state == .blocking || $0.state == .uncertain)
        }.map(\.noteID))
        var missingReplies: Set<Int> = []
        for finding in findings where finding.state == .waitingAcceptance {
            guard let thread = threads.first(where: { $0.id == finding.discussionID }),
                  !thread.notes.contains(where: { $0.author?.id == input.user.id && ($0.id ?? 0) > finding.id }) else { continue }
            missingReplies.insert(finding.id)
        }
        followUp.formUnion(missingReplies)
        if !followUp.isEmpty, isCurrent(input) { await onNeedsWork?(request, followUp, input.fingerprint) }
        guard isCurrent(input) else { throw CancellationError() }
        let completed = AuthorFeedbackStatus(head: request.sha ?? "", fingerprint: input.fingerprint, phase: .complete,
            findings: findings, acceptedReviewerIDs: accepted, followUpNoteIDs: followUp, replyNoteIDs: missingReplies)
        let updated = statuses[input.target] != completed
        statuses[input.target] = completed
        if changed || updated { onRemoteChange?() }
    }
}

extension GlabService {
    func fetchMergeRequestApproverIDs(projectID: Int, iid: Int, host: String) async throws -> Set<Int> {
        struct Approvals: Decodable {
            struct Entry: Decodable { let user: GitLabWorkflowUser }
            let approvedBy: [Entry]
            enum CodingKeys: String, CodingKey { case approvedBy = "approved_by" }
        }
        let approvals: Approvals = try await mergeRequestAPI("/projects/\(projectID)/merge_requests/\(iid)/approvals", host: host)
        return Set(approvals.approvedBy.map(\.user.id).filter { $0 > 0 })
    }

    func resolveAcceptedDiscussion(projectID: Int, iid: Int, discussionID: String, host: String) async throws {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !discussionID.isEmpty, let encoded = discussionID.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw GlabError.decoding("Missing discussion identity")
        }
        let result: GitLabMergeRequestDiscussion = try await mergeRequestAPI(
            "/projects/\(projectID)/merge_requests/\(iid)/discussions/\(encoded)", host: host,
            arguments: ["--method", "PUT", "--field", "resolved=true"])
        guard result.id == discussionID, !result.notes.isEmpty,
              result.notes.allSatisfy({ $0.resolvable != true || $0.resolved == true }) else {
            throw GlabError.decoding("GitLab did not confirm discussion resolution")
        }
    }
}
