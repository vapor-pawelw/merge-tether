import Foundation
import MergeTetherRemote

struct AgentQuestionContext: Encodable, Sendable {
    struct Settings: Encodable, Sendable {
        let profile: String?
        let decision: String
        let automationOn: Bool
        let automaticPublicActionsAllowed: Bool
        let autoMerge: Bool
        let autoMergeWithOtherAssignees: Bool
        let treatAssignedMergeRequestsAsOwn: Bool
        let publicationMode: String
        let autoApproval: Bool
        let followUpPush: Bool
        let conflictPush: Bool
        let autoReReview: Bool
        let autoClaimPipelineFailures: Bool
    }

    struct Card: Encodable, Sendable {
        let lane: String
        let project: String?
        let iid: Int
        let title: String
        let url: URL
        let state: String?
        let draft: Bool
        let pipeline: String?
        let pipelineCheckedAt: Date?
        let approvalsCompleted: Int?
        let approvalsRequired: Int?
        let unresolvedDiscussions: Bool?
        let privateDrafts: Int
        let effectiveRules: [String]
        let autoMergeConfigured: Bool
        let eligibleForAutoMerge: Bool?
        let mergeBlockers: [String]?
        let mergeSubmission: String?
        let gitLabMergeStatus: String?
        let gitLabHasConflicts: Bool?
        let evidenceCurrent: Bool
    }

    struct Detail: Encodable, Sendable {
        enum ActivityRead: String, Encodable {
            case cached, live, partial, unavailable
        }

        struct PersonLink: Encodable, Sendable {
            let person: RemotePerson
            let url: URL

            init?(_ person: PersonIdentity, on source: URL) {
                guard let url = person.remotePerson.profileURL(on: source),
                      GlabService.redactWorkflowEvidence(url.absoluteString) == url.absoluteString else { return nil }
                self.url = url
                self.person = person.remotePerson
            }

            enum CodingKeys: CodingKey { case name, username, url }

            func encode(to encoder: any Encoder) throws {
                var fields = encoder.container(keyedBy: CodingKeys.self)
                try fields.encodeIfPresent(person.name.map(GlabService.redactWorkflowEvidence), forKey: .name)
                try fields.encodeIfPresent(person.username, forKey: .username)
                try fields.encode(url, forKey: .url)
            }
        }

        struct Event: Encodable, Sendable {
            let id: String
            let date: Date
            let source: String
            let title: String
            var status: String? = nil
            var origin: String? = nil
            var reason: String? = nil
            var trigger: String? = nil
            var currentHead: Bool? = nil
            var head: String? = nil
            var actor: String? = nil
            var actorURL: URL? = nil
            var noteURL: URL? = nil
            var discussionID: String? = nil
            var draftID: Int? = nil
            var location: String? = nil
            var updatedAt: Date? = nil
            var resolved: Bool? = nil
            var body: String? = nil
            var bodyTruncated: Bool? = nil
            var publishedBody: String? = nil
            var publishedBodyTruncated: Bool? = nil
            var jobID: UUID? = nil
            var relatedJobID: UUID? = nil
            var intentID: UUID? = nil
            var startedAt: Date? = nil
            var finishedAt: Date? = nil
            var pipelineID: Int? = nil
            var noteIDs: [Int]? = nil
        }
        let iid: Int
        let url: URL
        let author: String?
        let assignees: [String]?
        let currentUserIsAuthor: Bool?
        let currentUserIsAssignee: Bool?
        let visibleReason: String?
        let sourceBranch: String?
        let targetBranch: String?
        let gitLabMergeStatus: String?
        let gitLabHasConflicts: Bool?
        let recordedConflictWarning: Bool
        let assignmentClaimOffered: Bool
        let evidenceMatchesCurrentCatalog: Bool
        let followUpPolicyHold: String?
        let activityRead: ActivityRead
        let missingActivitySources: [String]
        let cachedDiscussionsReadAt: Date?
        let people: [PersonLink]
        let eventLog: [Event]
        let omittedEvents: Int
    }

    let capturedAt: Date
    let lastInboxRefresh: Date?
    let lastAuthoredRefresh: Date?
    let boardState: String
    let settings: Settings
    let cards: [Card]
    let omittedCards: Int
}

@MainActor extension TodoMonitorService {
    func agentQuestionContext() -> AgentQuestionContext {
        let board = boardSnapshot
        let configured = settings.configuredAutomation
        let options = AgentQuestionContext.Settings(profile: configured.baselinePreset?.rawValue,
            decision: configured.packageDecision.rawValue, automationOn: settings.automationGloballyEnabled,
            automaticPublicActionsAllowed: self.settings.automaticPublicWritesAllowed,
            autoMerge: configured.autoMergeEnabled, autoMergeWithOtherAssignees: configured.autoMergeWithOtherAssignees,
            treatAssignedMergeRequestsAsOwn: self.settings.treatAssignedMergeRequestsAsOwn,
            publicationMode: configured.publicationMode.rawValue, autoApproval: configured.autoApproveEnabled,
            followUpPush: configured.allowFollowUpPush, conflictPush: configured.allowConflictPush,
            autoReReview: configured.autoReReviewEnabled, autoClaimPipelineFailures: configured.autoClaimPipelineFailures)
        let boardState = menuBarGitLabStatus
        let lanes = [("Own", board.own), ("Reviewing", board.reviewed), ("Inbox", board.otherMergeRequests)]
        let authoredByID = Dictionary(authoredMergeRequests.requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = lanes.flatMap { lane, rows in rows.map { (lane, $0) } }
        let cards = rows.prefix(180).compactMap { lane, row in
            agentQuestionCard(row, lane: lane, authored: authoredByID[row.id], boardCurrent: boardState == .current)
        }
        return .init(capturedAt: .now, lastInboxRefresh: lastRefresh, lastAuthoredRefresh: authoredMergeRequests.lastRefresh,
            boardState: String(describing: boardState), settings: options, cards: cards, omittedCards: rows.count - cards.count)
    }

    private struct QuestionActivity: Sendable {
        let notes: [MRGitLabActivity]?
        let resources: [MRGitLabActivity.Resource: [MRGitLabActivity]]
    }

    private func agentQuestionRows(for iids: [Int]) -> [MergeRequestBoardSnapshot.Row] {
        var unique = Set<Int>()
        let selected = Set(iids.filter { $0 > 0 && unique.insert($0).inserted }.prefix(4))
        guard !selected.isEmpty else { return [] }
        let board = boardSnapshot
        var seen = Set<URL>()
        return Array((board.own + board.reviewed + board.otherMergeRequests)
            .filter { selected.contains($0.id.iid) && seen.insert($0.displayURL).inserted }
            .prefix(8))
    }

    func agentQuestionDetails(for iids: [Int]) -> [AgentQuestionContext.Detail] {
        let rows = agentQuestionRows(for: iids)
        return rows.compactMap { agentQuestionDetail($0, bodyBudget: 48_000 / rows.count) }
    }

    func freshAgentQuestionDetails(for iids: [Int]) async -> [AgentQuestionContext.Detail] {
        let rows = agentQuestionRows(for: iids)
        guard !rows.isEmpty, let host = glab.resolvedHost, let username = glab.currentUsername else { return [] }
        let targets = rows.compactMap { row -> MRDiscussionTarget? in
            guard row.displayURL.isGitLabMergeRequest(host: host, iid: row.id.iid),
                  row.displayURL.query == nil, row.displayURL.fragment == nil, row.id.projectID > 0 else { return nil }
            return .init(host: host, username: username, projectID: row.id.projectID, iid: row.id.iid, url: row.displayURL)
        }
        guard !targets.isEmpty, !Task.isCancelled else { return [] }
        let revision = glab.accountRevision, executable = glab.glabPath
        func isCurrent() -> Bool {
            !Task.isCancelled && glab.accountRevision == revision && glab.glabPath == executable
                && glab.resolvedHost == host && glab.currentUsername == username
        }
        let bodyBudget = 48_000 / rows.count
        let user: GitLabAuthenticatedUser
        do {
            user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: username)
        } catch {
            guard isCurrent() else { return [] }
            return rows.compactMap {
                agentQuestionDetail($0, bodyBudget: bodyBudget, permitsCachedActivity: (error as? GlabError) != .notAuthenticated)
            }
        }
        guard isCurrent() else { return [] }
        let activity = await withTaskGroup(of: (URL, QuestionActivity).self) { group in
            for target in targets {
                group.addTask { [glab] in
                    async let discussions = try? glab.fetchMergeRequestDiscussions(projectID: target.projectID,
                        iid: target.iid, host: target.host, timeout: 15, cacheResult: false)
                    async let resources = MRGitLabActivityStore.readResources(for: target, glab: glab, timeout: 15)
                    let (threads, events) = await (discussions, resources)
                    return (target.url, .init(notes: threads.map(MRGitLabActivity.notes(in:)), resources: events))
                }
            }
            var results: [URL: QuestionActivity] = [:]
            for await (url, activity) in group { results[url] = activity }
            return results
        }
        guard isCurrent() else { return [] }
        let verified = try? await glab.fetchAuthenticatedUser(host: host, expectedUsername: username, expectedUserID: user.id)
        guard isCurrent() else { return [] }
        return rows.compactMap {
            agentQuestionDetail($0, bodyBudget: bodyBudget, live: verified == nil ? nil : activity[$0.displayURL],
                                permitsCachedActivity: verified != nil)
        }
    }

    private func agentQuestionDetail(_ row: MergeRequestBoardSnapshot.Row, bodyBudget: Int,
                                     live: QuestionActivity? = nil, permitsCachedActivity: Bool = true) -> AgentQuestionContext.Detail? {
        let url = row.displayURL
        guard let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: url),
              url.query == nil, url.fragment == nil else { return nil }
        let request = row.displayRequest
        let policyHold = request.flatMap {
            settings.configuredAutomation.followUpAutomationHold(for: $0, target: target,
                ignored: settings.ignoredMergeRequests.contains(target),
                requiresTodoRouting: row.attentionIntents.contains { $0.kind == .followUp })
        }
        let cached = live?.notes == nil && permitsCachedActivity
            ? glab.cachedDiscussions(projectID: target.projectID, iid: row.id.iid) : nil
        let notes = live?.notes ?? cached.map { MRGitLabActivity.notes(in: $0.discussions) }
        var missing = MRGitLabActivity.Resource.allCases.filter { live?.resources[$0] == nil }.map(\.rawValue)
        if live?.notes == nil { missing.append("discussions") }
        let read: AgentQuestionContext.Detail.ActivityRead
        if live != nil {
            read = missing.isEmpty ? .live : .partial
        } else {
            read = notes == nil ? .unavailable : .cached
        }
        let history = MRAutomationHistory(target: target, handoffs: assistantHandoffs,
            workflows: authoredMergeRequests.workflow.entries, events: settings.automationEvents,
            gitLab: (notes ?? []) + (live?.resources.values.flatMap { $0 } ?? []))
        let excerpt = history.entries.prefix(50)
        var remaining = bodyBudget
        let events = excerpt.map { entry in
            agentQuestionEvent(entry, url: url, head: request?.sha, target: target, remaining: &remaining)
        }
        var people: [PersonIdentity] = []
        if let request {
            people = ([request.author] + (request.assignees ?? []) + (request.reviewers ?? [])).prefix(40).map(\.person)
        }
        for entry in excerpt {
            if case .gitLab(let activity, _) = entry.source, let person = activity.person { people.append(person) }
        }
        people.append(.init(name: nil, username: target.username))
        let directory = PersonDirectory(people)
        var seen = Set<URL>()
        let links = people.compactMap { person -> AgentQuestionContext.Detail.PersonLink? in
            guard let username = person.normalizedUsername,
                  let link = AgentQuestionContext.Detail.PersonLink(directory.person(username: username), on: url),
                  seen.insert(link.url).inserted else { return nil }
            return link
        }
        let explanation = confirmedHumanAction(for: row)?.explanation
            ?? row.latestJob?.operationalExecution?.attentionExplanation
        return .init(iid: row.id.iid, url: url,
            author: request.map { cleanQuestionEvidence($0.author.username) },
            assignees: request?.assignees.map { $0.prefix(20).map { cleanQuestionEvidence($0.username) } },
            currentUserIsAuthor: request.map { $0.author.username == target.username },
            currentUserIsAssignee: request?.assignees.map { $0.contains { $0.username == target.username } },
            visibleReason: explanation.map(cleanQuestionEvidence),
            sourceBranch: request.map { cleanQuestionEvidence($0.sourceBranch) },
            targetBranch: request.map { cleanQuestionEvidence($0.targetBranch) },
            gitLabMergeStatus: request?.detailedMergeStatus?.rawValue, gitLabHasConflicts: request?.hasConflicts,
            recordedConflictWarning: row.item.hasConflict || row.attentionIntents.contains { $0.kind == .conflict },
            assignmentClaimOffered: row.waitsForAssignmentClaim,
            evidenceMatchesCurrentCatalog: row.evidenceMatchesCatalogContext,
            followUpPolicyHold: policyHold.map { String(localized: $0.message) },
            activityRead: read, missingActivitySources: missing, cachedDiscussionsReadAt: cached?.readAt,
            people: links, eventLog: events, omittedEvents: history.entries.count - events.count)
    }

    private func agentQuestionEvent(_ event: MRAutomationHistory.Entry, url: URL, head: String?,
                                    target: MRAutomationScope.Target, remaining: inout Int) -> AgentQuestionContext.Detail.Event {
        var detail: AgentQuestionContext.Detail.Event
        func actorURL(_ person: PersonIdentity?) -> URL? {
            person.flatMap { AgentQuestionContext.Detail.PersonLink($0, on: url)?.url }
        }
        switch event.source {
        case .job(let job, _):
            let execution = job.operationalExecution
            detail = .init(id: event.id, date: event.createdAt, source: "agent job", title: cleanQuestionEvidence(job.title),
                status: execution.map { String(localized: $0.statusTitle) },
                origin: job.manual == nil && job.pipelineHandoffConfirmation == nil ? nil : (event.isAutomatic ? "automatic" : "manual"),
                reason: (execution?.attentionExplanation ?? execution?.summary ?? execution?.errorExplanation).map(cleanQuestionEvidence),
                trigger: ReviewLaunchReason.message(for: job.reviewLaunchReasons ?? []),
                head: job.expectedHeadSHA, jobID: job.id, relatedJobID: job.retryOf,
                startedAt: execution?.startedAt, finishedAt: execution?.finishedAt, noteIDs: job.feedbackNoteIDs.map { Array($0.prefix(30)) })
        case .workflow(let workflow):
            detail = .init(id: event.id, date: event.createdAt, source: "workflow", title: String(localized: workflow.event.kind.displayLabel),
                status: String(describing: workflow.state), origin: "automatic", reason: workflow.summary.map(cleanQuestionEvidence),
                trigger: cleanQuestionEvidence(workflow.event.context), head: workflow.event.mergeRequest.sha,
                jobID: workflow.assistantJobID ?? workflow.preparedReviewJobID,
                pipelineID: workflow.event.pipelineID, noteIDs: Array(workflow.event.noteIDs.prefix(30)))
        case .event(let decision):
            let person = PersonIdentity(name: nil, username: target.username)
            detail = .init(id: event.id, date: event.createdAt, source: "MergeTether", title: String(localized: decision.title),
                status: decision.state.rawValue, origin: decision.origin.rawValue, reason: decision.message.map(cleanQuestionEvidence),
                head: decision.approvedHeadSHA, actor: person.displayName, actorURL: actorURL(person),
                noteURL: decision.publishedNoteID.flatMap(url.gitLabNoteURL), discussionID: decision.publication?.discussionID,
                draftID: decision.publication?.draftID, location: decision.publication?.location.map(cleanQuestionEvidence),
                jobID: decision.jobID, relatedJobID: decision.relatedJobID, intentID: decision.intentID)
            (detail.body, detail.bodyTruncated) = questionBody(decision.publication?.body, budget: &remaining,
                                                               alreadyTruncated: decision.publication?.bodyTruncated == true)
        case .gitLab(let activity, let receipt):
            detail = .init(id: event.id, date: event.createdAt, source: "GitLab",
                title: String(localized: receipt?.action == .publication ? receipt?.title ?? activity.title : activity.title),
                status: receipt?.state.rawValue, origin: receipt?.origin.rawValue, actor: activity.actor.map(cleanQuestionEvidence),
                actorURL: actorURL(activity.person), noteURL: activity.noteID.flatMap(url.gitLabNoteURL),
                discussionID: activity.discussionID, draftID: receipt?.publication?.draftID,
                location: (activity.location ?? receipt?.publication?.location).map(cleanQuestionEvidence),
                updatedAt: activity.updatedAt, resolved: activity.resolved)
            (detail.body, detail.bodyTruncated) = questionBody(activity.body, budget: &remaining)
            if let publication = receipt?.publication, publication.body != activity.body.map(GlabService.redactWorkflowEvidence) {
                (detail.publishedBody, detail.publishedBodyTruncated) = questionBody(publication.body, budget: &remaining,
                    alreadyTruncated: publication.bodyTruncated == true)
            }
        }
        detail.currentHead = detail.head.flatMap { sha in head.map { $0 == sha } }
        return detail
    }

    private func questionBody(_ body: String?, budget: inout Int, alreadyTruncated: Bool = false) -> (String?, Bool?) {
        guard let body else { return (nil, nil) }
        let clean = GlabService.redactWorkflowEvidence(body)
        let length = min(clean.utf8.count, budget, 16_384)
        budget -= length
        let truncated = alreadyTruncated || clean.utf8.count > length
        return (length > 0 ? String(decoding: clean.utf8.prefix(length), as: UTF8.self) : nil, truncated ? true : nil)
    }

    private func cleanQuestionEvidence(_ text: String) -> String {
        String(GlabService.redactWorkflowEvidence(text).prefix(2_000))
    }

    private func agentQuestionCard(_ row: MergeRequestBoardSnapshot.Row, lane: String,
                                   authored: AuthoredMergeRequestStatus?, boardCurrent: Bool) -> AgentQuestionContext.Card? {
        let url = row.displayURL
        guard let target = scopeTarget(projectID: row.id.projectID, iid: row.id.iid, url: url),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let request = row.displayRequest
        let current = boardCurrent && row.evidenceMatchesCatalogContext && !attentionRefreshFailed(for: row)
            && !isRecheckingAttention(for: row)
        let status = request.flatMap { request in current && authored?.matchesCurrentRequest(request) == true ? authored : nil }
        let reading: MREffectivePolicyPresentation.ReadState = current ? .current : .unavailable
        let input = MREffectivePolicyPresentation.Input(request: request, target: target, settings: settings,
            assistantReady: selectedAssistantReady, readState: reading,
            submission: status?.displayedSubmissionState ?? (request?.hasQueuedMerge == true ? .queued : .none))
        let approval = current ? row.item.approvalProgress : nil
        let blockers = status.map { status in
            var blockers = status.blockers.map { String(describing: $0) }
            if let observed = row.item.manualMergeBlocker(using: status) {
                let description = String(localized: observed.title)
                if !blockers.contains(description) { blockers.append(description) }
            }
            return blockers
        }
        return .init(lane: lane, project: url.gitLabProjectPath, iid: row.id.iid,
            title: String(GlabService.redactWorkflowEvidence(row.displayTitle).prefix(160)), url: url,
            state: request.map { String(describing: $0.state) }, draft: row.isDraft,
            pipeline: (row.pipelineEvidence?.headPipeline ?? request?.headPipeline)?.status.rawValue,
            pipelineCheckedAt: row.pipelineEvidenceCheckedAt, approvalsCompleted: approval?.completed,
            approvalsRequired: approval?.required,
            unresolvedDiscussions: request?.blockingDiscussionsResolved.map { !$0 },
            privateDrafts: current ? row.item.draftCount : 0,
            effectiveRules: MREffectivePolicyPresentation(input: input).clauses.map { String(localized: $0.message) },
            autoMergeConfigured: input.mergeAllowed,
            eligibleForAutoMerge: status == nil ? nil : row.isEligibleForAutomaticMerge,
            mergeBlockers: blockers, mergeSubmission: input.submission == .none ? nil : input.submission.rawValue,
            gitLabMergeStatus: request?.detailedMergeStatus?.rawValue, gitLabHasConflicts: request?.hasConflicts,
            evidenceCurrent: current)
    }
}
