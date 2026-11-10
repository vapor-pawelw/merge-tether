import Foundation

/// Manual consent replaces reviewer acceptance, but never semantic verification or
/// the author's published-reply obligation. Automatic resolution keeps its policy.
enum ManualDiscussionResolution {
    struct Plan: Sendable {
        let eligibleIDs: [String]
        let heldIDs: [String]
        let discussions: [GitLabMergeRequestDiscussion]
        var fingerprint: String? { ManualDiscussionResolution.fingerprint(discussions) }
        var confirmationDetails: String {
            func labels(_ ids: [String]) -> String {
                ids.map { id in
                    guard let root = discussions.first(where: { $0.id == id })?.notes.first else { return id }
                    let body = (root.body ?? "").replacingOccurrences(of: "\n", with: " ")
                    return "#\(root.id ?? 0) · " + String(body.prefix(160))
                }.joined(separator: "\n")
            }
            var details: [String] = []
            if !eligibleIDs.isEmpty { details.append(String(localized: .MergeActions.mergeActionsResolveReadyThreads(labels(eligibleIDs)))) }
            if !heldIDs.isEmpty { details.append(String(localized: .MergeActions.mergeActionsResolveHeldThreads(labels(heldIDs)))) }
            return details.joined(separator: "\n\n")
        }
        func matches(_ discussions: [GitLabMergeRequestDiscussion]) -> Bool {
            fingerprint != nil && fingerprint == ManualDiscussionResolution.fingerprint(discussions)
        }
        func acceptingResolution(_ resolved: GitLabMergeRequestDiscussion) -> Self? {
            guard let index = discussions.firstIndex(where: { $0.id == resolved.id }), resolved.notes.first?.resolved == true,
                  ManualDiscussionResolution.fingerprint([discussions[index]], includeRevisions: false)
                    == ManualDiscussionResolution.fingerprint([resolved], includeRevisions: false) else { return nil }
            var next = discussions
            next[index] = resolved
            return .init(eligibleIDs: eligibleIDs, heldIDs: heldIDs, discussions: next)
        }
    }
    struct Prepared {
        let request: GitLabMergeRequest
        let user: GitLabAuthenticatedUser
        let host: String
        let revision: UInt64
        let configuration: String
        let plan: Plan
        var reviewFingerprint: String? = nil
    }
    struct Result {
        let resolved: Int
        let selected: Int
        let held: Int
        var isComplete: Bool { resolved == selected && held == 0 }
    }

    static func plan(discussions: [GitLabMergeRequestDiscussion], assessment: ReReviewAssessment?,
                     authorID: Int, pendingDraftCount: Int,
                     ignoredSuggestions: [IgnoredFeedbackSuggestion] = []) -> Plan {
        let open = discussions.filter { $0.notes.first?.resolvable == true && $0.notes.first?.resolved == false }
        let valid = assessment.flatMap {
            (try? $0.reviewers(in: discussions, authorID: authorID, ignoredSuggestions: ignoredSuggestions)) != nil ? $0 : nil
        }
        let missingReplies = valid?.missingPublishedReplyNoteIDs(in: discussions, authorID: authorID) ?? []
        let verdicts = Dictionary((valid?.notes ?? []).map { ($0.noteID, $0) }, uniquingKeysWith: { first, _ in first })
        var eligible: [String] = [], held: [String] = []
        for thread in open {
            guard let id = thread.id, !id.isEmpty else { continue }
            let external = thread.notes.filter { $0.system != true && $0.author?.id != authorID }
            let ready = fingerprint(discussions) != nil && pendingDraftCount == 0 && valid != nil && !external.isEmpty && external.allSatisfy { note in
                guard let noteID = note.id, let verdict = verdicts[noteID],
                      !missingReplies.contains(noteID), (verdict.ignoredDecisionIDs ?? []).isEmpty,
                      !valid!.reviewRequests.contains(where: { $0.sourceNoteID == noteID }) else { return false }
                return verdict.state == .addressed || verdict.state == .informational && verdict.informationalAcknowledgementSafe == true
            }
            if ready { eligible.append(id) } else { held.append(id) }
        }
        return .init(eligibleIDs: eligible.sorted(), heldIDs: held.sorted(), discussions: discussions)
    }

    /// Bind IDs, topology and edit revisions as well as text. Resolution flags
    /// are intentionally excluded so completing one selected ID preserves the rest.
    static func fingerprint(_ discussions: [GitLabMergeRequestDiscussion], includeRevisions: Bool = true) -> String? {
        struct Row: Encodable {
            let discussion: String
            let note: Int
            let author: Int
            let body: String
            let created: String?
            let updated: String?
            let resolvable: Bool?
            let position: GitLabDraftNote.Position?
        }
        var discussionIDs: Set<String> = [], noteIDs: Set<Int> = []
        var rows: [Row] = []
        for thread in discussions {
            let notes = thread.notes.filter { $0.system != true }
            guard !notes.isEmpty else { continue }
            guard let id = thread.id, !id.isEmpty, discussionIDs.insert(id).inserted else { return nil }
            for note in notes {
                guard let noteID = note.id, noteID > 0, noteIDs.insert(noteID).inserted,
                      let author = note.author?.id, author > 0, let body = note.body else { return nil }
                rows.append(.init(discussion: id, note: noteID, author: author, body: body,
                    created: includeRevisions ? note.createdAt : nil, updated: includeRevisions ? note.updatedAt : nil,
                    resolvable: note.resolvable, position: note.position))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows.sorted { ($0.discussion, $0.note) < ($1.discussion, $1.note) }) else { return nil }
        return UserAttentionSnapshot.digest(String(decoding: data, as: UTF8.self))
    }

    @MainActor static func prepare(_ expected: GitLabMergeRequest, monitor: TodoMonitorService,
                                   expectedFingerprint: String? = nil) async throws -> Prepared {
        let glab = monitor.glab, settings = monitor.settings
        guard let host = glab.resolvedHost, let username = glab.currentUsername else { throw GlabError.notAuthenticated }
        let revision = glab.accountRevision
        let configuration = try MergeSubmissionFingerprint.configuration(settings)
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username)
        let request = try await glab.fetchMergeRequest(projectID: expected.projectID, iid: expected.iid, host: host)
        guard request.author.id == user.id, request.state == "opened",
              request.webURL.isGitLabMergeRequest(host: host, iid: request.iid),
              MergeRequestDependencySummary.Context(request) == .init(expected),
              request.semanticContextFingerprint == expected.semanticContextFingerprint else { throw CancellationError() }
        let threads = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: host)
        guard let fingerprint = ReviewVerdict.fingerprint(threads),
              expectedFingerprint == nil || expectedFingerprint == fingerprint else { throw CancellationError() }
        let drafts = try await glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid, host: host, userID: user.id)
        var assessment = monitor.attention.authorFeedbackCoordinator?.assessment(for: request, fingerprint: fingerprint)
        if assessment == nil, drafts == 0 {
            assessment = try await ManualFeedbackVerification.assess(request: request, discussions: threads,
                user: user, host: host, settings: settings, glab: glab)
        }
        let target = MRAutomationScope.Target(host: host, username: username, projectID: request.projectID, iid: request.iid)
        let plan = plan(discussions: threads, assessment: assessment, authorID: user.id, pendingDraftCount: drafts,
            ignoredSuggestions: settings.feedbackSuggestionDecisions.applicable(in: threads, for: target))
        guard glab.accountRevision == revision, glab.resolvedHost == host, glab.currentUsername == username,
              try MergeSubmissionFingerprint.configuration(settings) == configuration else { throw CancellationError() }
        return .init(request: request, user: user, host: host, revision: revision, configuration: configuration, plan: plan, reviewFingerprint: fingerprint)
    }

    @MainActor static func resolve(_ prepared: Prepared, glab: GlabService, settings: SettingsManager) async -> Result {
        var resolved = 0
        var checked = prepared.plan
        let request = prepared.request
        for id in prepared.plan.eligibleIDs {
            do {
                let checkSession: @MainActor @Sendable () throws -> Void = {
                    guard glab.accountRevision == prepared.revision, glab.resolvedHost == prepared.host,
                          glab.currentUsername == prepared.user.username,
                          try MergeSubmissionFingerprint.configuration(settings) == prepared.configuration else { throw CancellationError() }
                    let work = AssistantAutomationRunner.MergeRequestWork(host: prepared.host, projectID: request.projectID, iid: request.iid)
                    guard !AssistantAutomationRunner.isWorking(on: work), !settings.assistantHandoffs.contains(where: {
                        $0.key.work == work && $0.key.username == prepared.user.username && $0.operationalExecution?.state.isActive == true
                    }) else { throw CancellationError() }
                    try Task.checkCancellation()
                }
                try checkSession()
                let user = try await glab.fetchAuthenticatedUser(host: prepared.host, expectedUsername: prepared.user.username)
                let live = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: prepared.host)
                let drafts = try await glab.fetchOwnDraftNoteCount(projectID: request.projectID, iid: request.iid,
                    host: prepared.host, userID: prepared.user.id)
                let threads = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: prepared.host)
                guard user == prepared.user, live.author.id == user.id, live.state == "opened", drafts == 0,
                      MergeRequestDependencySummary.Context(live) == .init(request),
                      live.semanticContextFingerprint == request.semanticContextFingerprint,
                      checked.matches(threads), let thread = threads.first(where: { $0.id == id }),
                      thread.notes.first?.resolvable == true else { break }
                if thread.notes.first?.resolved == true { resolved += 1; continue }
                let final = try await glab.fetchMergeRequest(projectID: request.projectID, iid: request.iid, host: prepared.host)
                guard final.author.id == user.id, MergeRequestDependencySummary.Context(final) == .init(request),
                      final.semanticContextFingerprint == request.semanticContextFingerprint else { break }
                try checkSession()
                let response = try await glab.resolveAcceptedDiscussion(projectID: request.projectID, iid: request.iid, discussionID: id, host: prepared.host) {
                    do { try checkSession(); return true } catch { return false }
                }
                guard let next = checked.acceptingResolution(response) else { break }
                checked = next
                let updated = try await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: prepared.host)
                if let current = updated.first(where: { $0.id == id }), current.notes.first?.resolved == true,
                   let expected = checked.discussions.first(where: { $0.id == id }),
                   fingerprint([current]) == fingerprint([expected]) { resolved += 1 }
                if !checked.matches(updated) { break }
            } catch is CancellationError { break }
            catch { continue }
        }
        var held = prepared.plan.heldIDs.count + prepared.plan.eligibleIDs.count - resolved
        if let current = try? await glab.fetchMergeRequestDiscussions(projectID: request.projectID, iid: request.iid, host: prepared.host) {
            held = max(held, current.filter { $0.notes.first?.resolvable == true && $0.notes.first?.resolved == false }.count)
        }
        return .init(resolved: resolved, selected: prepared.plan.eligibleIDs.count, held: held)
    }
}

extension ManualDiscussionResolution {
    static func actionID(_ discussionIDs: [String]) -> String { "resolveThreads:" + discussionIDs.sorted().joined(separator: ",") }

}
