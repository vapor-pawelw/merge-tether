import Foundation
import Observation

/// Owns authored re-review readiness and delivery. Presentation callbacks never authorize a write.
@MainActor @Observable
final class ReReviewCoordinator {
    typealias Verify = @MainActor (ReReviewVerifier.Input, AutomationAssistant, String) async throws -> ReReviewAssessment

    struct Context: Hashable, Sendable {
        let host: String
        let username: String
        let revision: UInt64
        let projectID: Int
        let iid: Int

        var target: MRAutomationScope.Target {
            .init(host: host, username: username, projectID: projectID, iid: iid)
        }
    }

    struct Status {
        var state: ReReviewReadiness?
        var fingerprint: String?
        var requested = false
        var unconfirmed = false
    }

    enum ConfirmationResult: Equatable { case ignored, changed, unansweredFeedback, failed, confirmed }

    private struct ReReviewCheck {
        let key: String
        let fingerprint: String
        var state: ReReviewReadiness
        var assessment: ReReviewAssessment?
    }

    private struct VerificationTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var reReviewChecks: [Context: ReReviewCheck] = [:]
    private var reReviewTasks: [Context: VerificationTask] = [:]
    private var currentReviewerIDs: [Context: Set<Int>] = [:]
    @ObservationIgnored private var reReviewsInProgress: Set<Context> = []
    private var manualReReviewApprovals: [Context: String] = [:]
    private var runtimeScope: (host: String, username: String, revision: UInt64, scope: MRAutomationScope)?
    private let settings: SettingsManager
    private let glab: GlabService
    private let canAutomate: @MainActor (AutomationAssistant) async -> Bool
    private let verifyReReview: Verify
    private let authorFeedbackStatus: @MainActor (GitLabMergeRequest) -> AuthorFeedbackStatus?
    private let authorFeedbackAssessment: @MainActor (GitLabMergeRequest, String) -> ReReviewAssessment?
    var onChange: ((Context, Bool) -> Void)?
    var onRefreshRequested: ((Context, GitLabAuthenticatedUser) async -> Void)?

    init(settings: SettingsManager, glab: GlabService,
         canAutomate: @escaping @MainActor (AutomationAssistant) async -> Bool,
         verify: @escaping Verify,
         authorFeedbackStatus: @escaping @MainActor (GitLabMergeRequest) -> AuthorFeedbackStatus? = { _ in nil },
         authorFeedbackAssessment: @escaping @MainActor (GitLabMergeRequest, String) -> ReReviewAssessment? = { _, _ in nil }) {
        self.settings = settings
        self.glab = glab
        self.canAutomate = canAutomate
        self.verifyReReview = verify
        self.authorFeedbackStatus = authorFeedbackStatus
        self.authorFeedbackAssessment = authorFeedbackAssessment
    }

    var isVerifying: Bool { !reReviewTasks.isEmpty }

    func status(for context: Context, authorID: Int?) -> Status {
        guard isCurrent(context) else { return .init() }
        let check = reReviewChecks[context]
        let receipts = settings.reReviewReceipts.filter {
            $0.key.host == context.host && $0.key.authorID == authorID
                && $0.key.projectID == context.projectID && $0.key.iid == context.iid
                && currentReviewerIDs[context]?.contains($0.key.reviewerID) == true
        }.values
        return .init(state: check?.state, fingerprint: check?.fingerprint,
            requested: receipts.contains { $0.requested == true }, unconfirmed: receipts.contains { $0.unconfirmed })
    }

    func reset() {
        reReviewTasks.values.forEach { $0.task.cancel() }
        reReviewTasks = [:]
        reReviewChecks = [:]
        currentReviewerIDs = [:]
        manualReReviewApprovals = [:]
    }

    private func isCurrent(_ context: Context) -> Bool {
        glab.resolvedHost == context.host && glab.currentUsername == context.username
            && glab.accountRevision == context.revision
    }

    private func permitsAssistantAutomation(for context: Context) async -> Bool {
        guard isCurrent(context), !Task.isCancelled else { return false }
        let configuration = settings.automation
        return await canAutomate(configuration.assistant) && !Task.isCancelled
            && isCurrent(context) && settings.automation == configuration
    }

    private func notify(_ context: Context, unanswered: Bool = false) {
        guard isCurrent(context) else { return }
        onChange?(context, unanswered)
    }

    private func reReviewKey(_ request: GitLabMergeRequest, fingerprint: String, context: Context) -> String {
        let configuration = settings.automation
        return [ReReviewVerifier.policyVersion, context.host, context.username, String(request.projectID), String(request.iid), request.sha ?? "",
            fingerprint, request.semanticContextFingerprint, configuration.assistant.rawValue, configuration.autoVerifyReReview.description,
            configuration.assistant == .codex ? configuration.codexVerificationModel.rawValue : configuration.claudeVerificationModel.rawValue,
            configuration.verificationThinking.rawValue,
            settings.feedbackSuggestionDecisions.revision(for: context.target),
            settings.reviewParticipationPreferences.revision(host: context.host, username: context.username)]
            .joined(separator: "|")
    }

    private func refreshAfterPublication(_ context: Context, user: GitLabAuthenticatedUser) async {
        guard isCurrent(context) else { return }
        if let onRefreshRequested {
            await onRefreshRequested(context, user)
            return
        }
        guard let request = try? await glab.fetchMergeRequest(projectID: context.projectID, iid: context.iid, host: context.host),
              request.author.id == user.id,
              let drafts = try? await glab.fetchOwnDraftNotes(projectID: context.projectID, iid: context.iid, host: context.host, userID: user.id),
              let discussions = try? await glab.fetchMergeRequestDiscussions(projectID: context.projectID, iid: context.iid, host: context.host),
              isCurrent(context) else { return }
        await refresh(for: request, feedback: ReReviewFeedback(discussions: discussions, authorID: user.id),
            draftCount: drafts.count, context: context, user: user)
    }

    func retry(_ context: Context, user: GitLabAuthenticatedUser) async {
        guard isCurrent(context) else { return }
        reReviewTasks.removeValue(forKey: context)?.task.cancel()
        reReviewChecks.removeValue(forKey: context)
        await refreshAfterPublication(context, user: user)
    }

    func retryFailed(user: GitLabAuthenticatedUser) async {
        let failed = reReviewChecks.filter { $0.value.state == .unavailable || $0.value.state == .failed }.map(\.key)
        for context in failed { await retry(context, user: user) }
    }

    func cancelRuntimePreparation(outsideScope scope: MRAutomationScope) {
        if let host = glab.resolvedHost, let username = glab.currentUsername {
            runtimeScope = (host, username, glab.accountRevision, scope)
        } else { runtimeScope = nil }
        currentReviewerIDs = currentReviewerIDs.filter { isCurrent($0.key) }
        for context in Array(reReviewTasks.keys) {
            guard manualReReviewApprovals[context] == nil else { continue }
            if isCurrent(context), runtimePermitsReReview(context) { continue }
            reReviewTasks.removeValue(forKey: context)?.task.cancel()
            reReviewChecks.removeValue(forKey: context)
            notify(context)
        }
    }

    private func runtimePermitsReReview(_ context: Context) -> Bool {
        if manualReReviewApprovals[context] != nil { return true }
        guard let runtimeScope, runtimeScope.host == context.host, runtimeScope.username == context.username,
              runtimeScope.revision == context.revision else { return true }
        return runtimeScope.scope.resolve(context.target).active
    }

    func cancel(outsideScope scope: MRAutomationScope? = nil) {
        let affected = Set(reReviewTasks.keys).union(reReviewChecks.keys).union(currentReviewerIDs.keys)
        for context in affected {
            if let scope, scope.resolve(context.target).active { continue }
            reReviewTasks.removeValue(forKey: context)?.task.cancel()
            reReviewChecks.removeValue(forKey: context)
            currentReviewerIDs.removeValue(forKey: context)
            manualReReviewApprovals.removeValue(forKey: context)
            notify(context)
        }
    }

    /// A one-shot human decision stays bound to the displayed head, text and account revision.
    func confirm(_ context: Context, user: GitLabAuthenticatedUser, head: String, fingerprint: String) async -> ConfirmationResult {
        guard isCurrent(context), reReviewChecks[context]?.state.canConfirm == true,
              reReviewChecks[context]?.fingerprint == fingerprint,
              let displayedKey = reReviewChecks[context]?.key else { return .ignored }
        do {
            async let current = glab.fetchMergeRequest(projectID: context.projectID, iid: context.iid, host: context.host)
            async let threads = glab.fetchMergeRequestDiscussions(projectID: context.projectID, iid: context.iid, host: context.host)
            async let pending = glab.fetchOwnDraftNoteCount(projectID: context.projectID, iid: context.iid, host: context.host, userID: user.id)
            let (request, discussions, draftCount) = try await (current, threads, pending)
            guard isCurrent(context), request.sha == head, request.author.id == user.id, draftCount == 0,
                  reReviewChecks[context]?.key == displayedKey,
                  reReviewKey(request, fingerprint: fingerprint, context: context) == displayedKey,
                  ReviewVerdict.fingerprint(discussions) == fingerprint else { return .changed }
            let feedback = ReReviewFeedback(discussions: discussions, authorID: user.id)
            guard !feedback.hasUnansweredFeedback else { return .unansweredFeedback }
            manualReReviewApprovals[context] = reReviewKey(request, fingerprint: fingerprint, context: context)
            defer { manualReReviewApprovals.removeValue(forKey: context) }
            await refresh(for: request, feedback: feedback, draftCount: 0, context: context,
                user: user, discussions: discussions)
            notify(context)
            return .confirmed
        } catch { return .failed }
    }

    func refresh(
        for request: GitLabMergeRequest, feedback: ReReviewFeedback, draftCount: Int,
        context: Context, user: GitLabAuthenticatedUser, discussions suppliedDiscussions: [GitLabMergeRequestDiscussion]? = nil
    ) async {
        guard request.projectID == context.projectID, request.iid == context.iid, isCurrent(context) else { return }
        guard runtimePermitsReReview(context) else { return }
        guard settings.automation.hasAutomaticActionConsent, settings.automation.autoReReviewEnabled,
              isCurrent(context), request.state == "opened", request.author.id == user.id,
              settings.automation.scope.permits(request, host: context.host, username: context.username) else {
            reReviewTasks.removeValue(forKey: context)?.task.cancel()
            reReviewChecks.removeValue(forKey: context)
            notify(context)
            return
        }
        let host = context.host
        let target = MRAutomationScope.Target(host: host, username: context.username, projectID: request.projectID, iid: request.iid)
        guard reReviewsInProgress.insert(context).inserted else { return }
        defer { reReviewsInProgress.remove(context) }
        let baseline = settings.reReviewDraftBaselines[target]
        if draftCount > 0 {
            reReviewChecks.removeValue(forKey: context)
            reReviewTasks.removeValue(forKey: context)?.task.cancel()
            if baseline == nil {
                settings.reReviewDraftBaselines[target] = feedback.latestPublishedReplyID
                settings.save()
            }
            return
        }
        let observedPublication = baseline.map { feedback.latestPublishedReplyID > $0 } == true
        if baseline != nil, !observedPublication {
            settings.reReviewDraftBaselines.removeValue(forKey: target)
            settings.save()
        }
        guard let head = request.sha else { return }
        let authorProgress = authorFeedbackStatus(request)
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: request.projectID, iid: request.iid)
        let usedAssistant = settings.assistantHandoffs.contains {
            $0.key.work == work && $0.key.username == user.username
                && $0.execution?.state == .succeeded
                && !feedback.addressedNotes.isDisjoint(with: $0.feedbackNoteIDs ?? [])
        }
        let discussions: [GitLabMergeRequestDiscussion]
        if let suppliedDiscussions { discussions = suppliedDiscussions }
        else {
            guard let fresh = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host) else { return }
            discussions = fresh
        }
        guard !Task.isCancelled, isCurrent(context), runtimePermitsReReview(context),
              settings.automation.scope.permits(request, host: host, username: context.username) else { return }
        guard let fingerprint = ReviewVerdict.fingerprint(discussions) else { return }
        let activeIgnored = settings.feedbackSuggestionDecisions.applicable(in: discussions, for: target)
        let sharedAssessment = authorFeedbackAssessment(request, fingerprint)
        let key = reReviewKey(request, fingerprint: fingerprint, context: context)
        let reviewers: [GitLabMergeRequestReviewer]
        let approvers: Set<Int>
        do {
            async let states = glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
            async let approved = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
            (reviewers, approvers) = try await (states, approved)
            observeCurrentReviewers(reviewers, context: context)
        } catch {
            reReviewChecks[context] = .init(key: key, fingerprint: fingerprint, state: .failed)
            notify(context, unanswered: feedback.hasUnansweredFeedback)
            return
        }
        guard !Task.isCancelled, isCurrent(context), runtimePermitsReReview(context),
              settings.automation.scope.permits(request, host: host, username: context.username),
              usedAssistant || observedPublication || manualReReviewApprovals[context] != nil
                || sharedAssessment != nil || reviewers.contains(where: { $0.state == "unapproved" }) else { return }
        let history = MergeRequestReviewHistory(reviewers: reviewers, discussions: discussions, authorID: user.id)
        let earlierReviewers = Set(reviewers.filter {
            $0.state == "reviewed" || $0.state == "unapproved"
                || history.activities[$0.user.id]?.previouslyApproved == true
                || history.activities[$0.user.id]?.commented == true
        }.map(\.user.id))
        let assignedIDs = Set(reviewers.map(\.user.id))
        var candidates = feedback.addressedByReviewer.filter { assignedIDs.contains($0.key) }
        for reviewerID in earlierReviewers {
            candidates[reviewerID] = max(candidates[reviewerID] ?? 0, history.activities[reviewerID]?.noteID ?? 1, 1)
        }
        let existingCheck = reReviewChecks[context]
        let failedWithoutAssessment = existingCheck?.assessment == nil
            && (existingCheck?.state == .failed || existingCheck?.state == .unavailable)
        if let assessment = sharedAssessment, existingCheck?.key != key || existingCheck?.assessment == nil || failedWithoutAssessment {
            reReviewChecks[context] = .init(key: key, fingerprint: fingerprint, state: .checking, assessment: assessment)
        }
        var pendingReviewers: [Int: Int] = [:]
        for (reviewerID, noteID) in candidates {
            guard reviewerID != user.id, !approvers.contains(reviewerID),
                  !excludedReviewers(context, key: key, discussions: discussions, authorID: user.id).contains(reviewerID),
                  !reviewers.contains(where: { $0.user.id == reviewerID && $0.state == "approved" }) else { continue }
            if !reviewers.contains(where: { $0.user.id == reviewerID && $0.state == "unapproved" }),
               authorProgress?.phase == .complete, authorProgress?.head == head, authorProgress?.fingerprint == fingerprint,
               authorProgress?.semanticContextFingerprint == request.semanticContextFingerprint,
               authorProgress?.acceptedReviewerIDs.contains(reviewerID) == true { continue }
            let receiptKey = ReReviewReceipt.Key(host: host, authorID: user.id, projectID: request.projectID, iid: request.iid, reviewerID: reviewerID)
            guard settings.reReviewReceipts[receiptKey]?.covers(noteID: noteID, headSHA: head) != true else { continue }
            // Bot summaries never need a human review request, nor an expensive assessment.
            do {
                if try await glab.activeHumanReviewerUsername(userID: reviewerID, host: host) != nil {
                    pendingReviewers[reviewerID] = noteID
                }
                guard !Task.isCancelled, isCurrent(context), runtimePermitsReReview(context),
                      reReviewKey(request, fingerprint: fingerprint, context: context) == key,
                      settings.automation.scope.permits(request, host: host, username: context.username) else { return }
            } catch {
                reReviewChecks[context] = ReReviewCheck(key: key, fingerprint: fingerprint, state: .failed)
                notify(context, unanswered: feedback.hasUnansweredFeedback)
                return
            }
        }
        guard !pendingReviewers.isEmpty else {
            reReviewChecks.removeValue(forKey: context)
            notify(context, unanswered: feedback.hasUnansweredFeedback)
            return
        }
        let manual = manualReReviewApprovals[context] == key
        var recipients = pendingReviewers
        if !manual {
            if !settings.automation.autoVerifyReReview {
                reReviewTasks.removeValue(forKey: context)?.task.cancel()
                let assessment = reReviewChecks[context]?.key == key ? reReviewChecks[context]?.assessment : nil
                reReviewChecks[context] = ReReviewCheck(key: key, fingerprint: fingerprint, state: .manual, assessment: assessment)
                notify(context, unanswered: feedback.hasUnansweredFeedback)
                return
            }
            if reReviewChecks[context]?.key != key {
                reReviewTasks.removeValue(forKey: context)?.task.cancel()
                reReviewChecks[context] = ReReviewCheck(key: key, fingerprint: fingerprint, state: .checking)
                let assistant = settings.automation.assistant
                let model = assistant == .codex ? settings.automation.codexVerificationModel.rawValue : settings.automation.claudeVerificationModel.rawValue
                let thinking = settings.automation.verificationThinking
                let verificationID = UUID()
                let task = Task { [weak self] in
                    guard let self else { return }
                    defer {
                        if reReviewTasks[context]?.id == verificationID {
                            reReviewTasks.removeValue(forKey: context)
                        }
                    }
                    do {
                        let diff: Data = try await glab.mergeRequestAPI("/projects/\(request.projectID)/merge_requests/\(request.iid)/raw_diffs", host: host, decode: { $0 })
                        guard !Task.isCancelled, isCurrent(context), reReviewChecks[context]?.key == key,
                              runtimePermitsReReview(context),
                              settings.automation.scope.permits(request, host: host, username: context.username) else { return }
                        let input = ReReviewVerifier.Input(authorID: user.id, headSHA: head, title: request.title,
                                                          description: request.description,
                                                          diff: String(decoding: diff, as: UTF8.self), discussions: discussions,
                                                          target: .init(host: host, projectID: request.projectID, iid: request.iid,
                                                              url: request.webURL, expectedUsername: context.username),
                                                          semanticContextFingerprint: request.semanticContextFingerprint,
                                                          thinking: thinking, ignoredSuggestions: activeIgnored,
                                                          excludedReplyAuthorIDs: settings.reviewParticipationPreferences.excludedIDs(host: host, username: context.username).sorted())
                        let assessment = try await verifyReReview(input, assistant, model)
                        _ = try assessment.reviewers(in: discussions, authorID: user.id, ignoredSuggestions: activeIgnored,
                            excludedReplyAuthorIDs: settings.reviewParticipationPreferences.excludedIDs(host: host, username: context.username))
                        guard !Task.isCancelled, isCurrent(context), reReviewChecks[context]?.key == key,
                              runtimePermitsReReview(context) else { return }
                        reReviewChecks[context]?.assessment = assessment
                    } catch {
                        guard !Task.isCancelled, isCurrent(context), reReviewChecks[context]?.key == key else { return }
                        reReviewChecks[context]?.state = error as? ReReviewVerifier.VerificationError == .unavailable ? .unavailable : .failed
                    }
                    notify(context, unanswered: feedback.hasUnansweredFeedback)
                    await refreshAfterPublication(context, user: user)
                }
                reReviewTasks[context] = .init(id: verificationID, task: task)
                notify(context, unanswered: feedback.hasUnansweredFeedback)
                return
            }
            guard let assessment = reReviewChecks[context]?.assessment,
                  let assessed = try? assessment.reviewers(in: discussions, authorID: user.id, ignoredSuggestions: activeIgnored,
                    excludedReplyAuthorIDs: settings.reviewParticipationPreferences.excludedIDs(host: host, username: context.username)) else {
                notify(context, unanswered: feedback.hasUnansweredFeedback)
                return
            }
            let noReply = settings.reviewParticipationPreferences.excludedIDs(host: host, username: context.username)
            let allFeedbackReady = assessment.hasNoRemainingAuthorWork(in: discussions, authorID: user.id,
                ignoredSuggestions: activeIgnored, excludedReplyAuthorIDs: noReply)
                && assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: user.id, excludedReplyAuthorIDs: noReply).isEmpty
            recipients = pendingReviewers.filter {
                feedback.addressedByReviewer[$0.key] != nil && assessed[$0.key] != nil
                    || allFeedbackReady && earlierReviewers.contains($0.key)
            }
            let blockers = assessment.readinessBlockers
            reReviewChecks[context]?.state = assessment.notes.contains { $0.state == .blocking } ? .blocked(blockers) : .uncertain(blockers)
            let informationalReviewers = pendingReviewers.keys.filter { reviewerID in
                let theirNotes = discussions.flatMap(\.notes).filter { $0.author?.id == reviewerID && $0.system != true }
                return !theirNotes.isEmpty && history.activities[reviewerID]?.previouslyApproved != true && theirNotes.allSatisfy { note in
                    assessment.notes.first { $0.noteID == note.id }?.state == .informational
                }
            }
            let ignoredOnlyReviewers = pendingReviewers.keys.filter { reviewerID in
                let theirIDs = Set(discussions.flatMap(\.notes).filter { $0.author?.id == reviewerID && $0.system != true }.compactMap(\.id))
                let verdicts = assessment.notes.filter { theirIDs.contains($0.noteID) }
                return history.activities[reviewerID]?.previouslyApproved != true && verdicts.contains { $0.state == .ignoredByUser }
                    && verdicts.allSatisfy { $0.state == .ignoredByUser || $0.state == .informational }
            }
            for reviewerID in ignoredOnlyReviewers {
                pendingReviewers.removeValue(forKey: reviewerID)
                recipients.removeValue(forKey: reviewerID)
            }
            for reviewerID in informationalReviewers {
                recipients.removeValue(forKey: reviewerID)
                let receipt = ReReviewReceipt.Key(host: host, authorID: user.id, projectID: request.projectID, iid: request.iid, reviewerID: reviewerID)
                if let noteID = pendingReviewers.removeValue(forKey: reviewerID) {
                    settings.reReviewReceipts[receipt] = ReReviewReceipt(noteID: noteID, headSHA: head)
                }
            }
            if !informationalReviewers.isEmpty { settings.save() }
            notify(context, unanswered: feedback.hasUnansweredFeedback)
        }
        recipients = recipients.filter { !excludedReviewers(context, key: key, discussions: discussions, authorID: user.id).contains($0.key) }
        var finished = true
        for (reviewerID, noteID) in recipients.sorted(by: { $0.key < $1.key }) {
            guard settings.automaticPublicWritesAllowed else {
                reReviewChecks[context]?.state = .unavailable
                notify(context, unanswered: feedback.hasUnansweredFeedback)
                return
            }
            let receiptKey = ReReviewReceipt.Key(host: host, authorID: user.id, projectID: request.projectID,
                                                 iid: request.iid, reviewerID: reviewerID)
            guard settings.reReviewReceipts[receiptKey]?.covers(noteID: noteID, headSHA: head) != true else { continue }
            do {
                guard try await glab.activeHumanReviewerUsername(userID: reviewerID, host: host) != nil else { continue }
                async let fresh = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                async let threads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
                async let drafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
                let (current, liveDiscussions, liveDraftCount) = try await (fresh, threads, drafts)
                guard liveDraftCount == 0, !settings.pendingCommentReviews.contains(target), current.state == "opened", current.sha == head,
                      current.author.id == user.id, current.webURL.isGitLabMergeRequest(host: host, iid: current.iid),
                      ReviewVerdict.fingerprint(liveDiscussions) == fingerprint,
                      reReviewKey(current, fingerprint: fingerprint, context: context) == key,
                      try await glab.fetchAuthenticatedUser(host: host, expectedUsername: context.username) == user,
                      isCurrent(context), settings.automation.autoReReviewEnabled,
                      runtimePermitsReReview(context),
                      settings.automation.scope.permits(current, host: host, username: context.username) else { return }
                let liveReviewers = try await glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
                observeCurrentReviewers(liveReviewers, context: context)
                guard settings.automaticPublicWritesAllowed, !Task.isCancelled, isCurrent(context),
                      settings.automation.autoReReviewEnabled, !settings.pendingCommentReviews.contains(target),
                      settings.automation.scope.permits(current, host: host, username: context.username),
                      runtimePermitsReReview(context), reReviewChecks[context]?.key == key,
                      reReviewKey(current, fingerprint: fingerprint, context: context) == key,
                      !excludedReviewers(context, key: key, discussions: liveDiscussions, authorID: user.id).contains(reviewerID),
                      let reviewer = liveReviewers.first(where: { $0.user.id == reviewerID }) else { continue }
                if reviewer.state == "unreviewed" || reviewer.state == "review_started" {
                    settings.reReviewReceipts[receiptKey] = ReReviewReceipt(noteID: noteID, requested: true, headSHA: head)
                    settings.save()
                    continue
                }
                guard settings.reReviewReceipts[receiptKey]?.covers(noteID: noteID, headSHA: head) != true else { continue }
                if !manual {
                    guard await permitsAssistantAutomation(for: context),
                          reReviewKey(current, fingerprint: fingerprint, context: context) == key,
                          settings.automation.autoReReviewEnabled,
                          settings.automation.scope.permits(current, host: host, username: context.username) else {
                        if isCurrent(context) { reReviewChecks[context]?.state = .unavailable }
                        notify(context, unanswered: feedback.hasUnansweredFeedback)
                        return
                    }
                }
                // Dependency and identity checks may await slow processes. Read the
                // semantic source last; reusing `current` here would miss edits made
                // while checking the CLI, even when the source SHA is unchanged.
                let finalConfiguration = settings.automation
                let finalUser = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: context.username)
                async let finalMR = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
                async let finalThreads = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
                async let finalApprovers = glab.fetchMergeRequestApproverIDs(projectID: request.projectID, iid: request.iid, host: host)
                async let finalDrafts = glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
                let (checkedMR, checkedThreads, checkedDraftCount, checkedApprovers) = try await
                    (finalMR, finalThreads, finalDrafts, finalApprovers)
                guard settings.automaticPublicWritesAllowed, !Task.isCancelled, finalUser == user, isCurrent(context),
                      runtimePermitsReReview(context),
                      settings.automation == finalConfiguration, settings.automation.autoReReviewEnabled,
                      checkedDraftCount == 0, !settings.pendingCommentReviews.contains(target), checkedMR.state == "opened",
                      checkedMR.sha == head, checkedMR.author.id == user.id,
                      checkedMR.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
                      ReviewVerdict.fingerprint(checkedThreads) == fingerprint,
                      reReviewKey(checkedMR, fingerprint: fingerprint, context: context) == key,
                      reReviewChecks[context]?.key == key,
                      settings.automation.scope.permits(checkedMR, host: host, username: context.username) else { return }
                guard settings.reReviewReceipts[receiptKey]?.covers(noteID: noteID, headSHA: head) != true else { continue }
                let checkedReviewers = try await glab.fetchMergeRequestReviewers(projectID: request.projectID, iid: request.iid, host: host)
                observeCurrentReviewers(checkedReviewers, context: context)
                guard settings.automaticPublicWritesAllowed, !Task.isCancelled, isCurrent(context),
                      settings.automation == finalConfiguration, runtimePermitsReReview(context),
                      !settings.pendingCommentReviews.contains(target),
                      reReviewChecks[context]?.key == key,
                      reReviewKey(checkedMR, fingerprint: fingerprint, context: context) == key,
                      let checkedReviewer = checkedReviewers.first(where: { $0.user.id == reviewerID }),
                      !checkedApprovers.contains(reviewerID), checkedReviewer.state != "approved",
                      !excludedReviewers(context, key: key, discussions: checkedThreads, authorID: user.id).contains(reviewerID),
                      currentReviewerIDs[context]?.contains(reviewerID) == true else { continue }
                if checkedReviewer.state == "unreviewed" || checkedReviewer.state == "review_started" {
                    settings.reReviewReceipts[receiptKey] = ReReviewReceipt(noteID: noteID, requested: true, headSHA: head)
                    settings.save()
                    continue
                }
                settings.reReviewReceipts[receiptKey] = ReReviewReceipt(noteID: noteID, unconfirmed: true, headSHA: head)
                settings.save()
                guard settings.automaticPublicWritesAllowed else { throw CancellationError() }
                try await glab.requestReReview(of: checkedMR, userID: reviewerID, host: host) {
                    !Task.isCancelled && self.isCurrent(context) && self.settings.automaticPublicWritesAllowed
                        && self.settings.automation == finalConfiguration && self.settings.automation.autoReReviewEnabled
                        && self.runtimePermitsReReview(context)
                        && self.reReviewChecks[context]?.key == key
                        && self.reReviewKey(checkedMR, fingerprint: fingerprint, context: context) == key
                        && !self.settings.pendingCommentReviews.contains(target)
                        && self.settings.automation.scope.permits(checkedMR, host: host, username: context.username)
                        && self.currentReviewerIDs[context]?.contains(reviewerID) == true
                        && !self.excludedReviewers(context, key: key, discussions: checkedThreads, authorID: user.id).contains(reviewerID)
                }
                settings.reReviewReceipts[receiptKey]?.unconfirmed = false
                settings.reReviewReceipts[receiptKey]?.requested = true
                settings.save()
            } catch {
                finished = false
                reReviewChecks[context]?.state = .failed
                Log.monitor.error("Could not confirm automatic re-review: \(String(describing: error), privacy: .private)")
            }
        }
        if finished, recipients.count == pendingReviewers.count {
            reReviewChecks.removeValue(forKey: context)
        }
        notify(context, unanswered: feedback.hasUnansweredFeedback)
        if observedPublication, finished, recipients.count == pendingReviewers.count {
            settings.reReviewDraftBaselines.removeValue(forKey: target)
            settings.save()
        }
    }

    private func excludedReviewers(_ context: Context, key: String, discussions: [GitLabMergeRequestDiscussion], authorID: Int) -> Set<Int> {
        settings.reviewParticipationPreferences.excludedIDs(host: context.host, username: context.username)
            .union(settings.reviewParticipationPreferences.botIDs(host: context.host, username: context.username))
            .union(reReviewChecks[context]?.key == key
                ? reReviewChecks[context]?.assessment?.reviewerOptOutIDs(in: discussions, authorID: authorID) ?? [] : [])
    }

    private func observeCurrentReviewers(_ reviewers: [GitLabMergeRequestReviewer], context: Context) {
        guard isCurrent(context), !Task.isCancelled else { return }
        let ids = Set(reviewers.map(\.user.id))
        guard currentReviewerIDs[context] != ids else { return }
        currentReviewerIDs[context] = ids
        notify(context)
    }
}
