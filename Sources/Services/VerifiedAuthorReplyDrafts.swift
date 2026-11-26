import Foundation

/// An app-written acknowledgement for a finding already verified against the
/// current MR. Worker-generated free text uses the separate draft proof verifier.
@MainActor
final class VerifiedAuthorReplyDrafts {
    fileprivate struct Context: Codable, Equatable, Sendable {
        let target: MRAutomationScope.Target
        let userID: Int
        let sourceHead: String
        let requestFingerprint: String
        let discussionFingerprint: String
        let activeDiscussionFingerprint: String
        let discussionID: String
        let sourceNoteID: Int
        let feedbackDecisionRevision: String
        let participationRevision: String
        let semanticOptOutIDs: [Int]
    }

    struct Receipt: Codable, Equatable, Sendable {
        fileprivate let context: Context
        let draft: GitLabDraftNote
        var sourceHead: String { context.sourceHead }
        var discussionID: String { context.discussionID }
        var sourceNoteIDs: [Int] { [context.sourceNoteID] }
    }

    @MainActor
    private final class DraftWrite {
        var admitted = false
    }

    private let settings: SettingsManager
    private let glab: GlabService
    private let directory: URL
    private var preparing: Set<MRAutomationScope.Target> = []

    init(settings: SettingsManager, glab: GlabService, directory: URL = FollowUpVerificationStore.directory) {
        self.settings = settings
        self.glab = glab
        self.directory = directory.appending(path: "verified-author-replies", directoryHint: .isDirectory)
    }

    func prepare(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                 assessment: ReReviewAssessment, owedNoteIDs: Set<Int>, user: GitLabAuthenticatedUser,
                 host: String, shouldProceed: @escaping @MainActor @Sendable () -> Bool) async -> Set<Int> {
        guard owedNoteIDs.count == 1, let noteID = owedNoteIDs.first,
              let discussionID = Self.eligibleDiscussion(noteID, assessment: assessment, discussions: discussions, userID: user.id),
              let sourceProjectID = request.sourceProjectID, sourceProjectID > 0,
              let context = context(request: request, discussions: discussions, user: user, host: host,
                  discussionID: discussionID, noteID: noteID, semanticOptOutIDs: assessment
                      .reviewerOptOutIDs(in: discussions, authorID: user.id).sorted()) else { return [] }
        // The verifier checks the exact standard reply independently of the app language.
        var acknowledgement: LocalizedStringResource = .AutomaticActions.automaticActionsVerifiedReplyAcknowledgement
        acknowledgement.locale = Locale(identifier: "en")
        let body = String(localized: acknowledgement)
        let preview = GitLabDraftNote(id: nil, authorID: user.id, note: body, discussionID: discussionID, position: nil)
        let configuration = settings.automation
        let accountRevision = glab.accountRevision
        let policyIsCurrent: @MainActor @Sendable () -> Bool = { [self] in
            !Task.isCancelled && glab.accountRevision == accountRevision
                && settings.automation == configuration && Self.feedbackEnabled(configuration, request: request)
                && permitsReply(preview, context: context, request: request, discussions: discussions, user: user)
        }
        let allowed: @MainActor @Sendable () -> Bool = { shouldProceed() && policyIsCurrent() }
        guard allowed(), let reservation = reservationURL(for: context) else { return [] }
        guard preparing.insert(context.target).inserted else { return [noteID] }
        defer { preparing.remove(context.target) }
        guard await AssistantJobJournal.loadKey(), allowed() else { return [] }
        if FileManager.default.fileExists(atPath: reservation.path) { return [noteID] }

        let write = DraftWrite()
        do {
            async let currentUser = glab.fetchAuthenticatedUser(host: host, expectedUsername: user.username)
            async let currentRequest = glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: host)
            async let currentHead = glab.fetchBranchHeadSHA(projectID: sourceProjectID, branch: request.sourceBranch, host: host)
            async let currentDiscussions = glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
            async let currentDrafts = glab.fetchOwnDraftNotes(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
            let (account, live, head, threads, drafts) = try await
                (currentUser, currentRequest, currentHead, currentDiscussions, currentDrafts)
            guard account == user, head == context.sourceHead,
                  !drafts.contains(where: { $0.discussionID == discussionID }),
                  matches(context, request: live, discussions: threads, user: account, host: host),
                  allowed() else { return [] }

            // An ambiguous response may have created a private draft. Keep a durable
            // attempt fence for this snapshot instead of retrying or starting a worker.
            try save(context, to: reservation, kind: "verified-author-reply-attempt")
            let draft = try await glab.createDraftReply(projectID: request.projectID, iid: request.iid,
                host: host, userID: user.id, discussionID: discussionID, body: body, shouldProceed: {
                    guard allowed() else { return false }
                    write.admitted = true
                    return true
                })
            let reloaded = try await glab.fetchOwnDraftNotes(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
            // A poll may already have observed the draft this request created.
            // The receipt still binds the original evidence and the exact read-back.
            if let draftID = draft.id, reloaded.filter({ $0.id == draftID || $0.discussionID == discussionID }) == [draft],
               policyIsCurrent() {
                try save(Receipt(context: context, draft: draft), to: receiptURL(for: draftID, target: context.target),
                    kind: "verified-author-reply")
            }
            return [noteID]
        } catch {
            if !write.admitted, let prior: Context = read(reservation, kind: "verified-author-reply-attempt"), prior == context {
                try? FileManager.default.removeItem(at: reservation)
            }
            Log.monitor.error("Could not prepare verified author reply: \(String(describing: error), privacy: .private)")
            return write.admitted ? [noteID] : []
        }
    }

    func receipt(for draft: GitLabDraftNote, request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                 user: GitLabAuthenticatedUser, host: String) -> Receipt? {
        guard let draftID = draft.id, draftID > 0 else { return nil }
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        let url = receiptURL(for: draftID, target: target)
        if !AssistantJobJournal.isKeyReady, FileManager.default.fileExists(atPath: url.path) {
            Task { _ = await AssistantJobJournal.loadKey() }
        }
        guard let receipt: Receipt = read(url, kind: "verified-author-reply"), receipt.draft == draft,
              let body = draft.note, let originalBody = receipt.draft.note, body.utf8.elementsEqual(originalBody.utf8),
              receipt.draft.position?.baseSHA == draft.position?.baseSHA,
              receipt.draft.position?.headSHA == draft.position?.headSHA,
              receipt.draft.position?.positionType == draft.position?.positionType,
              matches(receipt.context, request: request, discussions: discussions, user: user, host: host),
              permitsReply(draft, context: receipt.context, request: request, discussions: discussions, user: user) else { return nil }
        return receipt
    }

    private static func eligibleDiscussion(_ noteID: Int, assessment: ReReviewAssessment,
                                           discussions: [GitLabMergeRequestDiscussion], userID: Int) -> String? {
        let findings = assessment.notes.filter { $0.noteID == noteID }
        guard findings.count == 1, let finding = findings.first,
              finding.state == .addressed, finding.informationalPurpose == .concreteCodeReviewFeedback,
              finding.addressedReplyAcknowledgementSafe == true, finding.publishedReplyNoteID == nil,
              finding.manualDecision == nil, finding.reviewerOptOut == nil, (finding.ignoredDecisionIDs ?? []).isEmpty,
              !assessment.automaticWorkNoteIDs.contains(noteID),
              assessment.missingPublishedReplyNoteIDs(in: discussions, authorID: userID).contains(noteID) else { return nil }
        let matches = discussions.filter { $0.notes.contains { $0.id == noteID } }
        guard matches.count == 1, let thread = matches.first, let id = thread.id, !id.isEmpty,
              thread.notes.filter({ $0.system != true }).count == 1, let note = thread.reviewRoot,
              note.id == noteID, note.system == false, note.resolvable == true, note.resolved == false,
              note.author?.id != userID else { return nil }
        return id
    }

    private static func feedbackEnabled(_ configuration: AutomationSettings, request: GitLabMergeRequest) -> Bool {
        let rule = configuration.authorFeedback
        let workflow = configuration.workflowRules[.newDiscussion]
        return rule.runner == .assistant && rule.isConfigured && rule.includes(project: request.webURL.gitLabProjectPath)
            && (rule.isEnabled || (workflow.mode == .assistant && workflow.includes(request)))
    }

    private func context(request: GitLabMergeRequest, discussions: [GitLabMergeRequestDiscussion],
                         user: GitLabAuthenticatedUser, host: String, discussionID: String,
                         noteID: Int, semanticOptOutIDs: [Int]) -> Context? {
        guard let head = request.sha, !head.isEmpty, request.isOpen, request.draft != nil,
              request.author.id == user.id, request.author.username == user.username,
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              let fingerprint = ManualDiscussionResolution.fingerprint(discussions),
              let activeFingerprint = ManualDiscussionResolution.fingerprint(GitLabMergeRequestDiscussion.activeForReview(discussions)),
              discussions.contains(where: { $0.id == discussionID && !$0.isResolvedForReview && $0.reviewRoot?.id == noteID }) else {
            return nil
        }
        let target = MRAutomationScope.Target.mergeRequest(host: host, username: user.username, projectID: request.projectID, iid: request.iid)
        return .init(target: target, userID: user.id, sourceHead: head,
            requestFingerprint: request.draftProofRecoveryContextFingerprint, discussionFingerprint: fingerprint,
            activeDiscussionFingerprint: activeFingerprint, discussionID: discussionID, sourceNoteID: noteID,
            feedbackDecisionRevision: settings.feedbackSuggestionDecisions.revision(for: target),
            participationRevision: settings.reviewParticipationPreferences.revision(host: host, username: user.username),
            semanticOptOutIDs: semanticOptOutIDs)
    }

    private func matches(_ previouslyVerified: Context, request: GitLabMergeRequest,
                         discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser, host: String) -> Bool {
        context(request: request, discussions: discussions, user: user, host: host, discussionID: previouslyVerified.discussionID,
            noteID: previouslyVerified.sourceNoteID, semanticOptOutIDs: previouslyVerified.semanticOptOutIDs) == previouslyVerified
    }

    private func permitsReply(_ draft: GitLabDraftNote, context: Context, request: GitLabMergeRequest,
                              discussions: [GitLabMergeRequestDiscussion], user: GitLabAuthenticatedUser) -> Bool {
        let host = context.target.host
        return glab.resolvedHost == host && glab.currentUsername == user.username
            && settings.automaticPublicWritesAllowed && settings.automation.permitsFollowUpPush(manual: false)
            && !settings.ignoredMergeRequests.contains(context.target)
            && settings.automation.scope.permits(request, host: host, username: user.username)
            && AutomaticPublicationPolicy.safeForAutomaticPublication(draft)
            && settings.reviewParticipationPreferences.permitsAutomaticReply(draft, discussions: discussions,
                requestAuthorID: request.author.id, userID: user.id, host: host, username: user.username,
                semanticOptOutIDs: Set(context.semanticOptOutIDs))
    }

    private func reservationURL(for context: Context) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(context) else { return nil }
        let key = UserAttentionSnapshot.digest(String(decoding: data, as: UTF8.self))
        return directory.appending(path: "attempt-\(key).json")
    }

    private func receiptURL(for draftID: Int, target: MRAutomationScope.Target) -> URL {
        let key = UserAttentionSnapshot.digest("\(target.host)/\(target.username)/\(target.projectID)/\(target.iid ?? 0)")
        return directory.appending(path: "\(key)-\(draftID).json")
    }

    private func read<Value: Decodable>(_ url: URL, kind: String) -> Value? {
        guard let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size < 64_000,
              let data = try? Data(contentsOf: url),
              let authenticated = AssistantJobJournal.authenticatedEvidence(data, context: kind) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: authenticated)
    }

    private func save<Value: Encodable>(_ value: Value, to url: URL, kind: String) throws {
        let payload = try AssistantJobJournal.sealEvidence(JSONEncoder().encode(value), context: kind)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try payload.write(to: url, options: .atomic)
    }
}
