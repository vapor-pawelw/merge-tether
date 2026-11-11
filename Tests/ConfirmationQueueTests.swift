import Foundation
import Observation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor
@Suite struct ConfirmationQueueTests {
    @Test(arguments: ["reply", "question", "clean"])
    func semanticFeedbackOnAResolvedMRReachesTheBoardAndPhoneWithoutRawAttentionFlags(_ outcome: String) async throws {
        let question = ReReviewAssessment.CodeReviewRequest(sourceNoteID: 20, sourceQuote: "Cover retries",
            kind: .potentialDefect, summary: "Check the retry contract", question: "Does retrying preserve the request identity?")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 20,
            state: outcome == "clean" ? .informational : .addressed,
            reason: "The current semantic feedback outcome is independent of GitLab thread resolution.")],
            codeReviewRequests: outcome == "question" ? [question] : nil)
        let harness = try makeHarness(assistantWorked: false, authored: true, assessment: assessment)
        defer { harness.cleanUp() }
        harness.settings.automation.authorFeedback.isEnabled = true
        harness.settings.automation.autoReReviewEnabled = false
        let answer = outcome == "question"
            ? #",{"id":21,"author":{"id":3},"system":false,"resolvable":false,"body":"The retry correction and focused regression are verified."}"# : ""
        try harness.write("discussions.json", #"[{"id":"general","notes":[{"id":20,"author":{"id":8,"username":"reviewer"},"system":false,"resolvable":false,"body":"Cover retries"}\#(answer)]}]"#)
        try await harness.poll()
        let coordinator = try #require(harness.monitor.authorFeedbackCoordinator)
        let deadline = ContinuousClock.now + .seconds(5)
        while (coordinator.status(projectID: 1, iid: 2)?.phase != .complete || harness.monitor.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
        #expect(harness.monitor.items.isEmpty)
        let snapshot = try #require(harness.monitor.presentationSnapshot)
        #expect(snapshot.attention.isEmpty == (outcome == "clean"))
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: harness.gitlab.data("request.json"))
        let approvals = try JSONDecoder().decode(GitLabMergeRequestApprovalState.self,
            from: Data(#"{"rules":[{"approvals_required":1,"approved":true}]}"#.utf8))
        let checked = AuthoredMergeRequestStatus(request: request, approvals: approvals, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: false, dependencyReadiness: .ready, action: .enqueue)
        let account = MRBoardProjector.Account(host: host, username: "me", revision: harness.glab.accountRevision)
        var input = MRBoardProjector.Input(account: account)
        input.attention = snapshot
        input.authored = [checked]
        input.automation = harness.settings.automation
        input.assistantReady = true
        input.reviewAssistantReady = true
        let projector = MRBoardProjector(input: input)
        let presenter = BoardAttentionPresenter()
        presenter.updateAttention(projector.pendingUserAttention)
        let attention = presenter.userAttention(account: account.presentationKey)
        let row = try #require(projector.board(humanAttention: attention).own.first)
        let model = MRCardPresentation(row: row, reviewingContext: projector.reviewingContext(for: row),
            allowsRemoval: false, assistantReady: true)
        let human = try #require(model.humanAction)
        #expect(human.kind == (outcome == "clean" ? .merge : .feedback))
        let service = TodoMonitorService(settings: harness.settings, glab: harness.glab)
        defer { service.stopTimer() }
        let card = RemoteBoardAdapter.mergeActions(
            RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(row.item, account: "me@\(host)"), model: model),
            item: row.item, status: checked, monitor: service, account: "me@\(host)")
        #expect(card.primaryCTA?.destination == (outcome == "clean" ? .overview : .feedback))
        #expect(card.actions.contains { $0.kind == .enqueueMerge } == (outcome == "clean"))
        #expect(row.item.canOfferManualMerge(using: checked) == (outcome == "clean"))
        var staleAccount = MRBoardProjector.Input(account: .init(host: host, username: "other", revision: account.revision + 1))
        staleAccount.attention = snapshot
        #expect(MRBoardProjector(input: staleAccount).board().own.isEmpty)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        fields["sha"] = String(repeating: "b", count: 40)
        let changed = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
        let changedStatus = AuthoredMergeRequestStatus(request: changed, approvals: approvals, discussionsResolved: true,
            projectRequiresResolvedDiscussions: true, autoMergeEnabled: false, dependencyReadiness: .ready, action: .enqueue)
        #expect(!row.item.canOfferManualMerge(using: changedStatus))
        #expect(harness.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["fresh", "legacy110", "legacyFlags", "enabled", "disabled"])
    func completedManualReviewDoesNotGrantAutomaticWriteConsent(_ installation: String) async throws {
        // given
        let stored = installation == "legacyFlags"
            ? #"{"autoApproveEnabled":true,"publishDraftsWithoutConfirmation":true,"codexRelayEnabled":true}"# : nil
        let consent: AutomationPackageDecision? = installation == "enabled" ? .enabled : (installation == "disabled" ? .disabled : nil)
        let harness = try makeHarness(assistantWorked: false, consent: consent, storedAutomation: stored, legacyInboxOnly: installation == "legacy110")
        defer { harness.cleanUp() }
        if installation == "legacy110" {
            #expect(harness.defaults.data(forKey: "automation") == nil)
        }
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        harness.settings.glabPath = URL(fileURLWithPath: "/in-memory/glab")
        let handler = try #require(harness.gitlab.handler)
        harness.gitlab.handler = { call in
            if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as me") }
            return try await handler(call)
        }
        let coordinator = AssistantJobCoordinator(execute: { _, _ in
            try harness.recordVerdict("no_objections", head: head)
            return .init(result: .init(status: .succeeded, summary: "Review complete"), output: "")
        })
        let review = try await AssistantAutomationRunner.launch(.codex, title: "Manual review",
            mergeRequestURL: URL(string: "https://\(host)/g/p/-/merge_requests/2")!, prompt: "Review the MR",
            workspace: "", access: .gitLabRead, work: work, username: "me", settings: harness.settings,
            isReview: true, mrWorkflow: .review, manual: true, expectedHeadSHA: head, jobCoordinator: coordinator,
            configurationSnapshot: harness.settings.automation, glab: harness.glab)
        await coordinator.waitForTermination()
        #expect(harness.settings.assistantHandoffs.first { $0.id == review.id }?.execution?.state == .succeeded)
        #expect(review.resolvesOwnThreads == (consent == .enabled))

        // when
        try await harness.poll()

        // then
        #expect(harness.settings.automation.packageDecision == (consent ?? .undecided))
        if installation == "enabled" {
            #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        } else {
            #expect(harness.gitlab.requests.allSatisfy { $0.method == "GET" })
            let item = try #require(harness.monitor.currentItems.first)
            #expect(item.canApprove && !item.autoApproveReady)
            await harness.monitor.approve(item.id)
            #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        }
    }

    @Test(arguments: [AutomationPackageDecision.undecided, .disabled])
    func revokingConsentDuringFinalApprovalReadPreventsTheWrite(_ decision: AutomationPackageDecision) async throws {
        // given
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        let original = try #require(harness.gitlab.handler)
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 2)
        var reads = 0
        harness.gitlab.handler = { call in
            if call.endpoint == "/user", harness.monitor.confirmationStates[id] == .approving {
                reads += 1
                if reads == 2 { harness.settings.automation.packageDecision = decision }
            }
            return try await original(call)
        }

        // when
        try await harness.poll()

        // then
        #expect(reads == 2)
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.settings.automaticActionsAllowed)
    }

    @Test func failedExactLookupClearsCountsOnRetainedTrackedReviews() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":0}"#)
        try await harness.poll()
        let initial = try #require(harness.monitor.currentOpenItems.first)
        #expect(initial.approvalProgress?.completed == 2)
        try harness.write("reviewing.json", "[]")
        harness.gitlab.remove("request.json")
        harness.monitor.refresh(host: host, username: "me", todos: [])
        for _ in 0..<250 where harness.monitor.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!harness.monitor.isLoading && harness.monitor.hasError)
        let retained = try #require(harness.monitor.currentOpenItems.first)
        #expect(retained.approvalProgress == nil && retained.url == initial.url)
    }

    @Test func newerLifecycleHeadInvalidatesCountsReadForThePreviousHead() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":0}"#)
        try harness.write("reviewing.json", "[]")
        try harness.write("pause-approval-read", "")
        harness.monitor.refresh(host: host, username: "me", todos: [])
        for _ in 0..<250 where !harness.gitlab.has("approval-read-entered") {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(harness.gitlab.has("approval-read-entered"))
        let nextHead = String(repeating: "b", count: 40)
        let newer = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(harness.log("request.json").replacingOccurrences(of: head, with: nextHead).utf8))
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        harness.settings.mrLifecycleLedger.record(newer, for: target, now: Date())
        try harness.write("release-approval-read", "")
        for _ in 0..<250 where harness.monitor.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!harness.monitor.isLoading && !harness.monitor.hasError)
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.mergeRequest?.sha == nextHead)
        #expect(item.approvalProgress == nil)
    }

    @Test func aManualDraftUpdateCannotReplaceANewerCatalogContextWithItsOlderEvidence() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        harness.settings.automation.disableAssistantPackage()
        try harness.write("drafts.json", draftJSON)
        let monitor = harness.monitor, gitlab = harness.gitlab
        var peer = try #require(JSONSerialization.jsonObject(with: gitlab.data("request.json")) as? [String: Any])
        peer["iid"] = 3
        peer["title"] = "Retained peer"
        peer["web_url"] = "https://gitlab.example.org/g/p/-/merge_requests/3"
        let peerData = try JSONSerialization.data(withJSONObject: peer)
        let peerRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: peerData)
        harness.settings.mrLifecycleLedger.record(peerRequest,
            for: .init(host: host, username: "me", projectID: 1, iid: 3))
        let original = try #require(gitlab.handler)
        gitlab.handler = { request in
            if request.endpoint == "/projects/1/merge_requests/3" {
                return InMemoryGitLab.output(String(decoding: peerData, as: UTF8.self))
            }
            if request.endpoint.hasPrefix("/projects/1/merge_requests/3/") {
                if request.endpoint.contains("/reviewers?") {
                    // This retained-only peer is read after the first row's safety checks.
                    gitlab.write("final-catalog-read")
                    try await gitlab.waitFor("release-catalog-read")
                }
                if request.endpoint.hasSuffix("/approvals") {
                    return InMemoryGitLab.output(#"{"approvals_required":0,"approvals_left":0}"#)
                }
                return InMemoryGitLab.output("[]")
            }
            return try await original(request)
        }
        monitor.onRefreshed = { [weak monitor] in
            if monitor?.isLoading == false { gitlab.write("catalog-finished") }
        }
        monitor.refresh(host: host, username: "me", todos: [])
        try await gitlab.waitFor("final-catalog-read")
        let nextHead = String(repeating: "b", count: 40)
        let newer = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(harness.log("request.json").replacingOccurrences(of: head, with: nextHead).utf8))
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        harness.settings.mrLifecycleLedger.record(newer, for: target)
        try JSONEncoder().encode(newer).store(in: gitlab, as: "request.json")
        gitlab.write("release-catalog-read")
        try await gitlab.waitFor("catalog-finished")
        let evidence = try #require(monitor.currentItems.first { $0.id.iid == 2 })
        #expect(evidence.mergeRequest?.sha == head)
        #expect(monitor.currentOpenItems.first { $0.id.iid == 2 }?.mergeRequest?.sha == nextHead)

        let deleted = try #require(evidence.drafts.first)
        await monitor.deleteDraft(deleted, from: evidence.id)

        #expect(monitor.currentOpenItems.first { $0.id.iid == 2 }?.mergeRequest?.sha == nextHead)
        #expect(monitor.currentOpenItems.first { $0.id.iid == 2 }?.drafts.isEmpty == true)
        #expect(monitor.currentItems.first { $0.id.iid == 2 }?.mergeRequest?.sha == head)
        #expect(monitor.currentItems.first { $0.id.iid == 2 }?.drafts.contains { $0.id == deleted.id } == false)
        #expect(harness.log("publish.log").isEmpty && harness.log("approve.log").isEmpty)
    }

    @Test func anAccountRoundTripCannotExposeEarlierAttentionOrCatalogEvidence() async throws {
        let harness = try await manualHarness()
        defer { harness.cleanUp() }
        #expect(!harness.monitor.currentItems.isEmpty && !harness.monitor.currentOpenItems.isEmpty)
        harness.glab.currentUsername = "another"
        harness.glab.currentUsername = "me"
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.monitor.currentOpenItems.isEmpty)
        #expect(harness.log("publish.log").isEmpty && harness.log("approve.log").isEmpty)
    }

    @Test func aBackgroundVerifierCannotAdmitARetainedOnlyCatalogRow() async throws {
        var boundary: InMemoryGitLab?
        let harness = try makeHarness(assistantWorked: true, authored: true, reReviewGate: {
            boundary?.write("verifier-entered")
            try await boundary?.waitFor("finish-verification")
        })
        boundary = harness.gitlab
        defer { harness.cleanUp() }
        defer { harness.gitlab.write("finish-verification") }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("fail-verification", "yes")
        let monitor = harness.monitor, gitlab = harness.gitlab
        monitor.onRefreshed = { [weak monitor] in
            if monitor?.isLoading == false { gitlab.write("catalog-finished") }
        }
        monitor.refresh(host: host, username: "me", todos: [])
        try await gitlab.waitFor("verifier-entered")
        try await gitlab.waitFor("catalog-finished")
        let displayed = try #require(monitor.currentOpenItems.first)
        #expect(await monitor.finishCommentReview(displayed))

        try harness.write("authored.json", "[]")
        gitlab.remove("request.json")
        gitlab.remove("catalog-finished")
        monitor.refresh(host: host, username: "me", todos: [])
        try await gitlab.waitFor("catalog-finished")
        #expect(monitor.hasError && !monitor.currentOpenItems.isEmpty)
        #expect(monitor.currentItems.isEmpty)
        gitlab.write("finish-verification")
        try await harness.settleVerification()

        #expect(monitor.currentOpenItems.first?.reReviewReadiness == .failed)
        #expect(monitor.currentItems.isEmpty)
        #expect(harness.log("publish.log").isEmpty && harness.log("approve.log").isEmpty
            && harness.log("re-review.log").isEmpty)
    }

    @Test func trackedReviewsKeepTheirApprovalCountsAfterReviewerAssignmentIsRemoved() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("reviewing.json", "[]")
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":7,"username":"reviewer"}}]}"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.approvalProgress?.completed == 1 && item.approvalProgress?.required == 2)
    }

    @Test func anEarlyRefreshFailureDropsOnlyTheApprovalCounterAndKeepsTheMR() async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":0,"approved_by":[{"user":{"id":7,"username":"reviewer"}},{"user":{"id":8,"username":"other"}}]}"#)
        try await harness.poll()
        let initial = try #require(harness.monitor.currentOpenItems.first)
        #expect(initial.approvalProgress?.completed == 2)
        try harness.write("fail-next-approval-user", "")
        harness.monitor.refresh(host: host, username: "me", todos: [])
        for _ in 0..<200 where harness.monitor.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!harness.monitor.isLoading && harness.monitor.hasError)
        let retained = try #require(harness.monitor.currentOpenItems.first)
        #expect(retained.approvalProgress == nil && retained.url == initial.url)
    }
    @Test func requiredApprovalCountsRefreshAndBecomeUnknownAfterAReadFailure() async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", "[]")
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":7,"username":"reviewer"}}]}"#)
        try await harness.poll()
        let initial = try #require(harness.monitor.currentOpenItems.first)
        #expect(initial.approvalProgress?.completed == 1 && initial.approvalProgress?.required == 2)
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":0,"approved_by":[{"user":{"id":7,"username":"reviewer"}},{"user":{"id":8,"username":"other"}}]}"#)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.approvalProgress?.completed == 2)
        try harness.write("fail-approvals", "")
        try await harness.poll()
        let failed = try #require(harness.monitor.currentOpenItems.first)
        #expect(failed.approvalProgress == nil && failed.url == initial.url)
    }
    private let host = "gitlab.example.org"
    private let head = "0123456789012345678901234567890123456789"

    private final class ApprovalUserReadProbe {
        var armed = true
        var now = Date()
    }

    private final class OriginProbe {
        var notes: [GitLabMergeRequestDiscussion.Note] = []
        private var continuation: CheckedContinuation<AICommentOriginAssessment, Never>?
        private var result: AICommentOriginAssessment?
        func assess(_ source: [GitLabMergeRequestDiscussion.Note]) async -> AICommentOriginAssessment {
            notes = source
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(ai: Bool) {
            let assessment = AICommentOriginAssessment(notes: notes.compactMap { note in note.id.map {
                .init(noteID: $0, classification: ai ? .aiAssisted : .uncertain,
                    confidence: ai ? .high : .uncertain, evidence: ai ? "Verified fixture AI provenance." : "Insufficient source provenance.")
            } })
            result = assessment
            continuation?.resume(returning: assessment)
            continuation = nil
        }
    }

    @MainActor
    private struct Harness {
        let folder: URL
        let defaults: UserDefaults
        let suite: String
        let settings: SettingsManager
        let glab: GlabService
        let gitlab: InMemoryGitLab
        let monitor: MergeRequestAttentionMonitor

        func write(_ name: String, _ text: String) throws {
            gitlab.write(name, text)
        }

        func recordVerdict(_ verdict: String, head: String, authenticated: Bool = true) throws {
            let folder = self.folder.appending(path: "verdicts/gitlab.example.org")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions.json"))
            let key = AssistantAutomationRunner.ChatKey(assistant: settings.automation.assistant,
                work: .init(host: "gitlab.example.org", projectID: 1, iid: 2), username: "me", workspace: "", access: .gitLabRead)
            let run = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review", prompt: "", createdAt: Date(),
                allowsPush: false, execution: .init(state: .succeeded), workflow: .review, expectedHeadSHA: head)
            let value = ReviewVerdict(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2, headSHA: head,
                                      verdict: try #require(ReviewVerdict.Kind(rawValue: verdict)),
                                      discussionFingerprint: ReviewVerdict.fingerprint(discussions),
                                      username: "me", userID: 3, runID: run.id)
            try JSONEncoder().encode(value).write(to: folder.appending(path: "1-2.json"))
            if authenticated {
                settings.assistantHandoffs.append(run)
                let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: gitlab.data("drafts.json")).filter { $0.authorID == 3 }
                try AssistantJobJournal.saveWithLoadedKey(.init(result: .init(status: .succeeded, summary: "Reviewed"), output: ""),
                    for: run, reviewVerdict: value, reviewDrafts: drafts)
            }
        }

        func assess(noteID: Int, body: String) throws {
            let directory = folder.appending(path: "ai-assessments/gitlab.example.org")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = AICommentAssessment(version: 1, host: "gitlab.example.org", projectID: 1, iid: 2,
                noteID: noteID, bodySHA256: AICommentAssessmentStore.digest(body), confidence: "very_high", evidence: "Verified AI provenance")
            try JSONEncoder().encode(record).write(to: directory.appending(path: "1-2-\(noteID).json"))
        }

        func verifyFollowUpDrafts() throws {
            let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
            let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
            let run = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Follow up", prompt: "", createdAt: Date(), allowsPush: false,
                                                       followUpPushAllowed: true, execution: .init(state: .succeeded))
            settings.assistantHandoffs.append(run)
            let raw = try #require(JSONSerialization.jsonObject(with: gitlab.data("drafts.json")) as? [[String: Any]])
            let drafts = raw.filter { $0["author_id"] as? Int == 3 }.map {
                FollowUpVerification.DraftEvidence(id: $0["id"] as! Int, bodySHA256: AICommentAssessmentStore.digest($0["note"] as! String))
            }
            let receipt = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: run.id,
                host: work.host, projectID: 1, iid: 2, username: "me", userID: 3,
                headSHA: "0123456789012345678901234567890123456789", sourceProjectID: 1, sourceBranch: "fix",
                files: [.init(path: "Sources/A.swift", sha256: AICommentAssessmentStore.digest("fixed code\n"))], drafts: drafts)
            let url = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(receipt).write(to: url)
            try bindFollowUpDiscussions()
        }

        /// Explicit positive precondition; raw delivery proofs and unrequested sibling drafts remain unassessed.
        func assessFollowUpClaims(draftIDs: [Int]? = nil) throws {
            let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
            let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
            let origin = try JSONDecoder().decode(FollowUpVerification.self, from: Data(contentsOf: path))
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: gitlab.data("request.json"))
            let threads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions.json"))
            let ids = draftIDs ?? origin.drafts.map(\.id)
            try #require(FollowUpVerificationStore.validRecoveryScope(ids, origin: origin))
            let identity = UUID()
            let fingerprint = try #require(ReviewVerdict.fingerprint(threads))
            let proof = FollowUpVerificationStore.recoveredProof(origin: origin, assessmentID: identity, fingerprint: fingerprint,
                semanticContext: request.semanticContextFingerprint, recoveryContext: request.draftProofRecoveryContextFingerprint,
                draftIDs: ids)
            let assessment = DraftProofRecoveryVerifier.Assessment(drafts: ids.map {
                .init(draftID: $0, state: .valid, reason: "Independent fixture assessment supports this exact reply")
            })
            try FollowUpVerificationStore.persistRecovery(.init(version: 2,
                attemptID: AICommentAssessmentStore.digest(identity.uuidString), assessmentID: identity,
                assistant: settings.automation.assistant, model: settings.automation.codexVerificationModel.rawValue,
                origin: origin, proof: proof, assessment: assessment, requestedDraftIDs: ids), work: work, username: "me", in: folder)
        }

        func log(_ name: String) -> String {
            gitlab.text(name)
        }

        func bindFollowUpDiscussions() throws {
            let url = folder.appending(path: "follow-up-verifications/gitlab.example.org/1-2-me.json")
            var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: gitlab.data("discussions.json"))
            receipt["discussionFingerprint"] = ReviewVerdict.fingerprint(discussions)
            try JSONSerialization.data(withJSONObject: receipt).write(to: url)
        }

        func poll(waitForAIOrigin: Bool = true, timeout: Duration = .seconds(5)) async throws {
            monitor.refresh(host: "gitlab.example.org", username: "me", todos: [])
            let deadline = ContinuousClock.now + timeout
            while monitor.isLoading || monitor.isVerifyingReReview
                    || monitor.currentOpenItems.contains(where: { $0.reReviewReadiness == .checking })
                    || (waitForAIOrigin && monitor.isAssessingAIOrigins), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isLoading && !monitor.hasError)
        }

        func settleVerification() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.isVerifyingReReview, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!monitor.isVerifyingReReview)
        }

        func cleanUp() {
            gitlab.close()
            monitor.aiOriginCoordinator.cancel()
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// A GitLab stub where "me" (id 3) reviews MR !2, authored by someone else (id 9).
    private func makeHarness(assistantWorked: Bool, authored: Bool = false,
                             consent: AutomationPackageDecision? = .enabled, storedAutomation: String? = nil, legacyInboxOnly: Bool = false,
                             duringAutomationCheck: (@MainActor (InMemoryGitLab) -> Void)? = nil,
                             approvalReadClock: @escaping ReadOnlyAssessmentRetry.Clock = { Date() },
                             assessment: ReReviewAssessment? = nil,
                             assessAIOrigin: AICommentOriginCoordinator.Assess? = nil,
                             verifyDraftRecovery: DraftProofRecoveryCoordinator.Verify? = nil,
                             reReviewGate: (@MainActor () async throws -> Void)? = nil) throws -> Harness {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let suite = "ConfirmationQueueTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var request = """
            {"id":2,"project_id":1,"iid":2,"author":{"id":9,"username":"alice","name":"Alice"},
             "title":"Fix","web_url":"https://gitlab.example.org/g/p/-/merge_requests/2",
             "state":"opened","draft":false,"sha":"\(head)",
             "source_project_id":1,"source_branch":"fix","target_project_id":1,"target_branch":"main",
             "detailed_merge_status":"mergeable","has_conflicts":false,
             "labels":[],"user":{"can_merge":true},"blocking_discussions_resolved":true}
            """
        if authored { request = request.replacingOccurrences(of: "\"id\":9,\"username\":\"alice\",\"name\":\"Alice\"", with: "\"id\":3,\"username\":\"me\",\"name\":\"Me\"") }
        let gitlab = InMemoryGitLab()
        try Data((authored ? "[\(request)]" : "[]").utf8).store(in: gitlab, as: "authored.json")
        try Data((authored ? "[]" : "[\(request)]").utf8).store(in: gitlab, as: "reviewing.json")
        try Data(request.utf8).store(in: gitlab, as: "request.json")
        try Data("[]".utf8).store(in: gitlab, as: "drafts.json")
        try Data(#"[{"user":{"id":3},"state":"reviewed"}]"#.utf8).store(in: gitlab, as: "reviewers.json")
        try Data("[]".utf8).store(in: gitlab, as: "discussions.json")
        try Data(#"{"id":8,"username":"GitLabDuo","bot":true}"#.utf8).store(in: gitlab, as: "duo.json")
        try Data("fixed code\n".utf8).store(in: gitlab, as: "remote-file-content.txt")
        try Data(head.utf8).store(in: gitlab, as: "remote-head.txt")
        try Data(#"{"id":3,"username":"me"}"#.utf8).store(in: gitlab, as: "live-user.json")
        gitlab.handler = { request in
            if request.arguments == ["config", "get", "host"] || request.arguments == ["auth", "status"] {
                // The persisted-card projection test deliberately has no CLI auth report.
                return InMemoryGitLab.output(code: 100)
            }
            let path = request.endpoint
            if gitlab.has("ai-assessment-after-preview-pending") {
                gitlab.remove("ai-assessment-after-preview-pending")
                let destination = folder.appending(path: "ai-assessments/gitlab.example.org")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data(contentsOf: folder.appending(path: "late-ai-assessment.json"))
                    .write(to: destination.appending(path: "1-2-41.json"))
                gitlab.write("ai-assessment-added-after-preview")
            }
            switch path {
            case "/user":
                if gitlab.has("fail-next-approval-user") { gitlab.remove("fail-next-approval-user"); return InMemoryGitLab.output(code: 1) }
                return try gitlab.response("live-user.json")
            case let path where path.hasPrefix("/merge_requests?scope=created_by_me"):
                return gitlab.has("fail-owned-list") ? InMemoryGitLab.output(code: 1) : try gitlab.response("authored.json")
            case let path where path.hasPrefix("/merge_requests?scope=all"): return try gitlab.response("reviewing.json")
            case let path where path.hasSuffix("/draft_notes/bulk_publish"):
                Issue.record("Publication must name the checked draft ID")
                gitlab.append("publish.log", "unexpected bulk publication\n")
                return InMemoryGitLab.output(code: 1)
            case "graphql":
                gitlab.append("re-review-targets.log", request.command + "\n")
                gitlab.append("re-review.log", "requested\n")
                if gitlab.has("fail-review-request") { return InMemoryGitLab.output(code: 1) }
                return InMemoryGitLab.output(#"{"data":{"mergeRequestReviewerRereview":{"mergeRequest":{"iid":"2"},"errors":[]}}}"#)
            case let path where path.contains("/draft_notes/") && path.hasSuffix("/publish"):
                if gitlab.has("fail-publish") { return InMemoryGitLab.output(code: 1) }
                let id = Int(path.split(separator: "/").dropLast().last!)!
                if gitlab.text("fail-publish-id") == String(id) { return InMemoryGitLab.output(code: 1) }
                gitlab.append("selected.log", request.command + "\n")
                try gitlab.editArray("drafts.json") { $0.removeAll { $0["id"] as? Int == id } }
                for (source, destination) in [("after-selected-publish.json", "drafts.json"), ("user-after-selected-publish.json", "live-user.json")] {
                    if gitlab.has(source) { try gitlab.copy(source, destination); gitlab.remove(source) }
                }
                if gitlab.has("inject-unseen-draft") {
                    try gitlab.editArray("drafts.json") { drafts in
                        drafts.removeAll { $0["id"] as? Int == 99 }
                        drafts.append(["id": 99, "author_id": 3, "note": "/merge"])
                    }
                }
                if gitlab.has("published-discussions.json") {
                    let existing = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: gitlab.data("discussions.json"))
                    let existingIDs = Set(existing.flatMap(\.notes).compactMap(\.id))
                    let remaining = try JSONDecoder().decode([GitLabDraftNote].self, from: gitlab.data("drafts.json"))
                    let privateBodies = Set(remaining.filter { $0.authorID == 3 }.compactMap(\.note))
                    var threads = try #require(JSONSerialization.jsonObject(with: gitlab.data("published-discussions.json")) as? [[String: Any]])
                    for index in threads.indices {
                        var notes = try #require(threads[index]["notes"] as? [[String: Any]])
                        // Apply an own note only once its corresponding draft was actually sent.
                        notes.removeAll { note in
                            let author = note["author"] as? [String: Any]
                            return author?["id"] as? Int == 3 && !existingIDs.contains(note["id"] as? Int ?? 0)
                                && privateBodies.contains(note["body"] as? String ?? "")
                        }
                        threads[index]["notes"] = notes
                    }
                    try JSONSerialization.data(withJSONObject: threads).store(in: gitlab, as: "discussions.json")
                }
                if gitlab.has("request-after-publish.json") { try gitlab.copy("request-after-publish.json", "request.json") }
                if gitlab.has("ambiguous-publish-id"), gitlab.text("ambiguous-publish-id") == String(id) { return InMemoryGitLab.output(code: 1) }
                if gitlab.has("fail-read-after-publish") { gitlab.write("fail-next-draft-read") }
                return InMemoryGitLab.output("{}")
            case let path where path.contains("/draft_notes/"):
                #expect(request.method == "DELETE")
                if gitlab.has("fail-delete") { return InMemoryGitLab.output(code: 1) }
                gitlab.append("delete.log", request.command + "\n")
                try await gitlab.pause(ifPresent: "hold-delete", entered: "delete-started", until: "release-delete")
                let id = Int(path.split(separator: "/").last!)!
                try gitlab.editArray("drafts.json") { $0.removeAll { $0["id"] as? Int == id } }
                return InMemoryGitLab.output()
            case "/users/8":
                if gitlab.has("add-ai-assessment-after-preview") {
                    gitlab.remove("add-ai-assessment-after-preview"); gitlab.write("ai-assessment-after-preview-pending")
                }
                if gitlab.has("edit-after-proof-draft-read") && gitlab.has("proof-draft-read") {
                    gitlab.remove("edit-after-proof-draft-read")
                    try gitlab.editArray("drafts.json") { drafts in
                        for index in drafts.indices where drafts[index]["id"] as? Int == 12 { drafts[index]["note"] = "/merge" }
                    }
                    gitlab.write("edited-after-proof-draft-read")
                }
                if gitlab.has("pause-user-check") {
                    gitlab.remove("pause-user-check")
                    gitlab.append("user-check.log", "entered\n")
                    try await gitlab.waitFor("release-user-check")
                }
                return try gitlab.response("duo.json")
            case "/users/9", "/users/10":
                let id = Int(path.split(separator: "/").last!)!
                return InMemoryGitLab.output("{\"id\":\(id),\"username\":\"reviewer\(id)\",\"bot\":false,\"state\":\"active\"}")
            case let path where path.contains("/draft_notes"):
                if gitlab.has("approval-preflight-armed"), let count = Int(gitlab.text("approval-preflight-failures")), count > 0 {
                    gitlab.write("approval-preflight-failures", String(count - 1))
                    gitlab.append("approval-preflight.log", "failed\n")
                    return InMemoryGitLab.output(code: 1)
                }
                try await gitlab.pause(ifPresent: "pause-selected-read", entered: "selected-read-entered", until: "release-selected-read")
                if gitlab.has("proof-file-read") { gitlab.write("proof-draft-read") }
                if gitlab.has("fail-next-draft-read") { gitlab.remove("fail-next-draft-read"); return InMemoryGitLab.output(code: 1) }
                return try gitlab.response("drafts.json")
            case let path where path.hasSuffix("/raw_diffs"): return InMemoryGitLab.output("verified diff fixture\n")
            case let path where path.contains("/reviewers"):
                if gitlab.has("approval-preflight-failures") { gitlab.write("approval-preflight-armed") }
                return try gitlab.response("reviewers.json")
            case let path where path.hasSuffix("/approvals"):
                if gitlab.has("fail-approvals") { return InMemoryGitLab.output(code: 1) }
                try await gitlab.pause(ifPresent: "pause-approval-read", entered: "approval-read-entered", until: "release-approval-read")
                return gitlab.has("approvals.json") ? try gitlab.response("approvals.json") : InMemoryGitLab.output(#"{"approved_by":[]}"#)
            case let path where path.contains("/discussions"):
                if gitlab.has("fail-discussion-read") { return InMemoryGitLab.output(code: 1) }
                if gitlab.has("edit-on-this-discussion") {
                    gitlab.remove("edit-on-this-discussion")
                    try gitlab.editArray("drafts.json") { drafts in
                        for index in drafts.indices where drafts[index]["id"] as? Int == 11 { drafts[index]["note"] = "/merge" }
                    }
                }
                if gitlab.has("edit-after-next-discussion") { gitlab.remove("edit-after-next-discussion"); gitlab.write("edit-on-this-discussion") }
                if gitlab.has("capture-one-discussion") {
                    gitlab.remove("capture-one-discussion")
                    let captured = try gitlab.response("discussions.json")
                    gitlab.write("discussion-captured")
                    try await gitlab.waitFor("release-discussion")
                    return captured
                }
                if gitlab.has("change-during-discussions") {
                    try gitlab.editArray("drafts.json") { drafts in
                        for index in drafts.indices where drafts[index]["id"] as? Int == 12 { drafts[index]["note"] = "Edited while checking" }
                    }
                }
                return try gitlab.response("discussions.json")
            case let path where path.hasSuffix("/approve"):
                gitlab.append("approve.log", request.command + "\n")
                if gitlab.has("approval-response-lost") {
                    gitlab.write("approvals.json", #"{"approved_by":[{"user":{"id":3,"username":"me"}}]}"#)
                    return InMemoryGitLab.output(code: 1)
                }
                return gitlab.has("fail-approval-write") ? InMemoryGitLab.output(code: 1) : InMemoryGitLab.output(#"{"approved_by":[{"user":{"id":3}}]}"#)
            case "/projects/1/repository/branches/fix":
                return InMemoryGitLab.output("{\"commit\":{\"id\":\"\(gitlab.text("remote-head.txt"))\"}}")
            case let path where path.hasPrefix("/projects/1/repository/files/Sources%2FA.swift?ref="):
                if gitlab.has("edit-after-proof-draft-read") { gitlab.write("proof-file-read") }
                if gitlab.has("edit-during-proof") {
                    try gitlab.editArray("drafts.json") { drafts in
                        for index in drafts.indices where drafts[index]["id"] as? Int == 12 { drafts[index]["note"] = "New unsupported local fix" }
                    }
                }
                let object = ["file_path": "Sources/A.swift", "encoding": "base64", "content": gitlab.data("remote-file-content.txt").base64EncodedString()]
                return .init(stdout: try JSONSerialization.data(withJSONObject: object), stderr: "", exitCode: 0)
            case "/projects/99/merge_requests/2", "/projects/1/merge_requests/99":
                let parts = path.split(separator: "/")
                let project = Int(parts[1])!, iid = Int(parts[3])!
                var object = try #require(JSONSerialization.jsonObject(with: gitlab.data("request.json")) as? [String: Any])
                object.merge(["project_id": project, "iid": iid, "state": "closed", "source_project_id": project, "target_project_id": project,
                              "web_url": "https://gitlab.example.org/g/p/-/merge_requests/\(iid)"]) { _, new in new }
                return .init(stdout: try JSONSerialization.data(withJSONObject: object), stderr: "", exitCode: 0)
            case "/projects/1/merge_requests/2":
                let result = try gitlab.response("request.json")
                if gitlab.has("pause-selected-read") { gitlab.write("captured-ready-rereview-mr") }
                return result
            case "/projects/1":
                return InMemoryGitLab.output(code: 100)
            case let path where path.contains("/blocks?") || path.hasPrefix("/projects/1/merge_requests?"):
                // This fixture intentionally has no optional stack/dependency data.
                return InMemoryGitLab.output(code: 100)
            default: return try gitlab.unexpected(request)
            }
        }

        if legacyInboxOnly {
            defaults.set(true, forKey: "hasLaunchedBefore")
            defaults.set(RefreshInterval.fiveMinutes.rawValue, forKey: "refreshInterval")
        }
        if let storedAutomation { defaults.set(Data(storedAutomation.utf8), forKey: "automation") }
        let settings = SettingsManager(defaults: defaults)
        if let consent { settings.automation.packageDecision = consent }
        // These tests isolate publication/re-review from the independent acceptance workflow.
        settings.automation.autoResolveAcceptedFeedback = false
        if assistantWorked {
            let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
            let key = AssistantAutomationRunner.ChatKey(
                assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead
            )
            settings.assistantChats[key] = "thread"
        }
        let glab = gitlab.service(host: host, username: "me")
        let monitor = MergeRequestAttentionMonitor(
            glab: glab, settings: settings, verdictDirectory: folder.appending(path: "verdicts"),
            aiAssessmentDirectory: folder.appending(path: "ai-assessments"), followUpDirectory: folder,
            provenanceDirectory: folder.appending(path: "comment-origins"),
            canAutomate: { _ in
                duringAutomationCheck?(gitlab)
                return !gitlab.has("assistant-unavailable")
            },
            approvalReadClock: approvalReadClock, approvalReadWait: { _ in },
            verifyReReview: { input, _, _ in
                try await reReviewGate?()
                try JSONEncoder().encode(input).store(in: gitlab, as: "verifier-input.json")
                gitlab.append("verification.log", "verified\n")
                if gitlab.has("fail-verification") { throw ReReviewVerifier.VerificationError.failed }
                if gitlab.has("unavailable-verification") { throw ReReviewVerifier.VerificationError.unavailable }
                if let assessment { return assessment }
                return ReReviewAssessment(notes: input.discussions.flatMap(\.notes).filter {
                    $0.system != true && $0.author?.id != input.authorID
                }.compactMap { note in
                    note.id.map { .init(noteID: $0, state: .addressed, reason: "Verified fixture correction") }
                })
            },
            verifyDraftProofRecovery: verifyDraftRecovery ?? { _, _, _ in throw DraftProofRecoveryVerifier.Failure.failed },
            assessAIOrigin: assessAIOrigin ?? { _, notes, _, _, _ in
                .init(notes: notes.compactMap { note in note.id.map {
                    .init(noteID: $0, classification: .uncertain, confidence: .uncertain, evidence: "No AI provenance in this fixture.")
                } })
            }
        )
        return Harness(folder: folder, defaults: defaults, suite: suite, settings: settings, glab: glab, gitlab: gitlab, monitor: monitor)
    }

    @Test func deletingOneDraftPreservesOtherAndNewDrafts() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let draft = try #require(item.drafts.first)
        var current = try #require(JSONSerialization.jsonObject(with: Data(draftJSON.utf8)) as? [[String: Any]])
        current.append(["id": 99, "author_id": 3, "note": "Saved in GitLab"])
        try JSONSerialization.data(withJSONObject: current).store(in: harness.gitlab, as: "drafts.json")
        await harness.monitor.deleteDraft(draft, from: item.id)
        #expect(harness.log("delete.log").contains("/draft_notes/11"))
        #expect(harness.monitor.currentOpenItems.first?.drafts.map(\.id) == [12, 99])
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("drafts.json").contains("Someone else's draft"))
    }

    @Test func deletionSerializesWithPublicationAndOtherDeletionOnTheSameMR() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let first = try #require(item.drafts.first), second = try #require(item.drafts.last)
        try harness.write("hold-delete", "yes")
        let deletion = Task { await harness.monitor.deleteDraft(first, from: item.id) }
        let deadline = ContinuousClock.now + .seconds(2)
        while harness.log("delete.log").isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = !harness.log("delete.log").isEmpty
        if started {
            await harness.monitor.publishDrafts(of: item.id)
            await harness.monitor.deleteDraft(second, from: item.id)
            #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
            #expect(harness.log("delete.log").split(separator: "\n").count == 1)
        }
        try harness.write("release-delete", "yes")
        await deletion.value
        try #require(started)
        #expect(harness.monitor.currentOpenItems.first?.drafts == [second])
    }

    @Test func changedDraftIsNotDeletedAndItsNewContentIsShown() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let draft = try #require(item.drafts.first)
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Handle nil here.", with: "Changed in GitLab"))
        await harness.monitor.deleteDraft(draft, from: item.id)
        #expect(harness.log("delete.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts.first?.note == "Changed in GitLab")
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
    }

    @Test func failedDeletionKeepsDraftsAvailable() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("fail-delete", "yes")
        await harness.monitor.deleteDraft(try #require(item.drafts.first), from: item.id)
        #expect(harness.monitor.currentOpenItems.first?.drafts == item.drafts)
        #expect(harness.monitor.confirmationStates[item.id] == .failed)
    }

    @Test func changedAccountCannotDeleteDrafts() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("live-user.json", #"{"id":9,"username":"other"}"#)
        await harness.monitor.deleteDraft(try #require(item.drafts.first), from: item.id)
        #expect(harness.log("delete.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts == item.drafts)
        #expect(harness.monitor.confirmationStates[item.id] == .failed)
    }

    @Test func externalDeletionIsReconciledWithoutDeletingAnythingElse() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("drafts.json", "[]")
        await harness.monitor.deleteDraft(try #require(item.drafts.first), from: item.id)
        #expect(harness.log("delete.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
    }

    @Test func externalDraftRemovalKeepsTheHumanCheckpointAcrossRefreshAndRestart() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.draftCount == 0)
        #expect(item.requiresCommentReview)
        #expect(!item.canApprove)
        let reloaded = SettingsManager(defaults: harness.defaults)
        #expect(!reloaded.pendingCommentReviews.isEmpty)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
    }

    @Test func publishingInTheAppFinishesTheHumanCheckpoint() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.monitor.currentOpenItems.first?.requiresCommentReview == false)
        #expect(harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test func aNewDraftObservedByTheFastRefreshArmsTheCheckpoint() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        try #require(harness.monitor.currentItems.first?.canApprove == true)
        try harness.write("drafts.json", draftJSON)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(!harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test(arguments: [false, true])
    func automaticPublicationAfterADeletionStillNeedsTheHumanToFinish(_ inApp: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        if inApp {
            await harness.monitor.deleteDraft(try #require(item.drafts.first), from: item.id)
        } else {
            try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Thanks, looks fixed.","discussion_id":"abc"}]"#)
        }
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.requiresCommentReview == true)
    }

    @Test func automaticPublicationOfTheWholeReviewNeedsNoExtraConfirmation() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test func publicationDoesNotFinishCommentReviewForANewerCommit() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("request-after-publish.json", harness.log("request.json").replacingOccurrences(of: head, with: String(repeating: "f", count: 40)))
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.monitor.currentItems.first?.draftCount == 1)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(!harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test func aPartialSelectionDoesNotFinishWhenAnotherDraftDisappearsInGitLab() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("after-selected-publish.json", "[]")
        let target = MRDiscussionTarget(host: host, username: "me", projectID: 1, iid: 2, url: item.url)
        await harness.monitor.publishDrafts([try #require(item.drafts.first)], for: target)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.requiresCommentReview == true)
    }

    @Test func explicitCompletionRefusesANewDraftSavedInGitLab() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("drafts.json", draftJSON)
        await harness.monitor.finishCommentReview(item)
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
    }

    @Test func explicitCompletionUnlocksTheCheckpointAfterExternalDeletion() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        let item = try #require(harness.monitor.currentItems.first)
        await harness.monitor.finishCommentReview(item)
        #expect(harness.monitor.currentOpenItems.first?.requiresCommentReview == false)
        #expect(harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test func persistedCommentReviewReachesTheActualMacCardAndAttentionProjection() async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.applyPreset(.manual, for: .codex)
        harness.settings.glabPath = harness.glab.glabPath
        harness.settings.resolvedHost = host
        harness.settings.beginCommentReview(for: .init(host: host, username: "me", projectID: 1, iid: 2))
        let service = TodoMonitorService(settings: harness.settings, glab: harness.glab)
        defer { service.stopTimer() }
        service.attention.refresh(host: host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while service.attention.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!service.attention.isLoading && !service.attention.hasError)
        let row = try #require(service.boardSnapshot.own.first)
        #expect(service.userAttention.hasAttention && row.needsAttention)
        let card = MRCardPresentation(row: row, monitor: service, allowsRemoval: false)
        #expect(card.humanAction?.kind == .commentReview)
        #expect(card.actionLabel.map { String(localized: $0) } == String(localized: .CommentReview.commentReviewFinish))
    }

    @Test(arguments: ["head", "discussion", "account"])
    func explicitCompletionIsBoundToTheDisplayedSnapshot(change: String) async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        let item = try #require(harness.monitor.currentItems.first)
        switch change {
        case "head": try harness.write("request.json", harness.log("request.json").replacingOccurrences(of: head, with: String(repeating: "f", count: 40)))
        case "discussion": try harness.write("discussions.json", #"[{"id":"new","notes":[{"id":99,"author":{"id":9},"body":"Another concern","system":false}]}]"#)
        default: try harness.write("live-user.json", #"{"id":4,"username":"me"}"#)
        }
        let finished = await harness.monitor.finishCommentReview(item)
        #expect(!finished)
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(!harness.settings.pendingCommentReviews.isEmpty)
        #expect(harness.log("approve.log").isEmpty && harness.log("re-review.log").isEmpty)
    }

    @Test func deletingAllDraftsStillNeedsCompletionBeforeApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .manual
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        for draft in item.drafts { await harness.monitor.deleteDraft(draft, from: item.id) }
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.draftCount == 0)
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(harness.log("approve.log").isEmpty)
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentItems.first))
        try await harness.poll()
        #expect(harness.log("approve.log").contains("/approve"))
    }


    @Test(arguments: ["selected", "all", "remote"], ["current", "captureFailure", "postFailure"])
    func publicationRecordsOnlyCertainAppOriginsAndDisplayFailuresNeverChangePublication(flow: String, evidence: String) async throws {
        // given
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        let body = "App generated reply"
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"App generated reply","discussion_id":"thread"}]"#)
        try harness.write("discussions.json", #"[{"id":"thread","notes":[{"id":30,"author":{"id":8,"username":"reviewer"},"body":"Feedback","system":false}]}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let draft = try #require(item.drafts.first)
        let context = AICommentProvenanceStore.Context(host: host, username: "me", userID: 3, projectID: 1, iid: 2)
        let directory = harness.folder.appending(path: "comment-origins")
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(body))],
            baseline: [], current: [draft], context: context, runID: UUID(), headSHA: head, in: directory)
        let after = #"[{"id":"thread","notes":[{"id":30,"author":{"id":8,"username":"reviewer"},"body":"Feedback","system":false},{"id":40,"author":{"id":3,"username":"me"},"body":"App generated reply","system":false}]}]"#
        try harness.write("published-discussions.json", after)
        let handler = try #require(harness.gitlab.handler)
        var failedRead = false
        harness.gitlab.handler = { call in
            let hasPublished = !harness.log("selected.log").isEmpty || !harness.log("publish.log").isEmpty
            if call.endpoint.contains("/discussions?"), !failedRead,
               (evidence == "captureFailure" && !hasPublished) || (evidence == "postFailure" && hasPublished) {
                failedRead = true
                return InMemoryGitLab.output(code: 1)
            }
            return try await handler(call)
        }
        if flow != "remote" { try harness.write("inject-unseen-draft", "yes") }
        // when
        if flow == "all" { await harness.monitor.publishDrafts(of: item.id) }
        else if flow == "remote" {
            let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: [draft])
            #expect(result == .completed)
        } else {
            await harness.monitor.publishDrafts([draft], for: .init(host: host, username: "me", projectID: 1, iid: 2, url: item.url))
        }
        // then
        let writes = harness.gitlab.requests.filter { $0.method != "GET" && $0.endpoint.contains("draft_notes") }
        #expect(writes.count == 1)
        #expect(writes.first?.method == "PUT" && writes.first?.endpoint.hasSuffix("/draft_notes/11/publish") == true)
        if flow != "remote" {
            #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [99])
        }
        #expect(harness.monitor.confirmationStates[item.id] == nil)
        let published = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(after.utf8))[0].notes[1]
        #expect(AICommentProvenanceStore.isGenerated(published, discussionID: "thread", context: context, in: directory) == (evidence == "current"))
        #expect(failedRead == (evidence != "current"))
    }

    @Test(arguments: ["all", "aiOnly"], ["current", "captureFailure", "postFailure", "ledgerWriteFailure"])
    func automaticPublicationRecordsOriginsWithoutLettingDisplayFailuresBlockReplies(mode: String, evidence: String) async throws {
        // given
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = mode == "all"
        harness.settings.automation.publishAIRepliesWithoutConfirmation = mode == "aiOnly"
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Generated automatic reply","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: harness.gitlab.data("drafts.json"))
        let draft = try #require(drafts.first)
        let context = AICommentProvenanceStore.Context(host: host, username: "me", userID: 3, projectID: 1, iid: 2)
        let directory = harness.folder.appending(path: "comment-origins")
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(draft.note!))],
            baseline: [], current: drafts, context: context, runID: UUID(), headSHA: head, in: directory)
        if evidence == "ledgerWriteFailure" {
            let scope = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
            try Data("blocked".utf8).write(to: scope.appending(path: "notes"))
        }
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.automaticDraftIDs == [11])
        #expect(harness.log("selected.log").isEmpty)
        let after = #"[{"id":"abc","notes":[{"id":40,"body":"AI finding","author":{"id":8,"username":"GitLabDuo"},"system":false,"resolvable":true,"resolved":false},{"id":41,"body":"Generated automatic reply","author":{"id":3,"username":"me"},"system":false}]}]"#
        try harness.write("published-discussions.json", after)
        let handler = try #require(harness.gitlab.handler)
        var failedRead = false
        harness.gitlab.handler = { call in
            let hasPublished = !harness.log("selected.log").isEmpty
            if call.endpoint == "/user", harness.monitor.confirmationStates[item.id] == .publishing, !failedRead,
               (evidence == "captureFailure" && !hasPublished) || (evidence == "postFailure" && hasPublished) {
                failedRead = true
                return InMemoryGitLab.output(code: 1)
            }
            return try await handler(call)
        }
        // when
        try await harness.poll()
        // then
        let writes = harness.gitlab.requests.filter { $0.method != "GET" && $0.endpoint.contains("draft_notes") }
        #expect(writes.count == 1 && writes.first?.method == "PUT")
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.confirmationStates[item.id] == nil)
        let published = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(after.utf8))[0].notes[1]
        #expect(AICommentProvenanceStore.isGenerated(published, discussionID: "abc", context: context, in: directory) == (evidence == "current"))
        #expect(failedRead == (evidence == "captureFailure" || evidence == "postFailure"))
    }

    @Test func existingAuthenticatedFollowUpSealSuppliesDisplayOriginAtManualPublication() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Sealed AI reply","discussion_id":"thread"}]"#)
        try harness.write("discussions.json", #"[{"id":"thread","notes":[{"id":30,"author":{"id":8,"username":"reviewer"},"body":"Feedback","system":false}]}]"#)
        try harness.verifyFollowUpDrafts()
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let draft = try #require(item.drafts.first)
        let after = #"[{"id":"thread","notes":[{"id":30,"author":{"id":8,"username":"reviewer"},"body":"Feedback","system":false},{"id":40,"author":{"id":3,"username":"me"},"body":"Sealed AI reply","system":false}]}]"#
        try harness.write("published-discussions.json", after)
        await harness.monitor.publishDrafts([draft], for: .init(host: host, username: "me", projectID: 1, iid: 2, url: item.url))
        let note = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(after.utf8))[0].notes[1]
        #expect(AICommentProvenanceStore.isGenerated(note, discussionID: "thread",
            context: .init(host: host, username: "me", userID: 3, projectID: 1, iid: 2),
            in: harness.folder.appending(path: "comment-origins")))
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
    }

    @Test func generatedDraftDisplayEvidenceCannotAuthorizeAutomaticPublication() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Generated","discussion_id":"thread"}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let draft = try #require(item.drafts.first)
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest(draft.note!))],
            baseline: [], current: [draft], context: .init(host: host, username: "me", userID: 3, projectID: 1, iid: 2),
            runID: UUID(), headSHA: head, in: harness.folder.appending(path: "comment-origins"))
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        await harness.monitor.publishDrafts(of: item.id, automatic: true, checkedDraftIDs: [11])
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
    }

    private let draftJSON = #"""
        [{"id":11,"author_id":3,"note":"Handle nil here.","discussion_id":null,
          "position":{"new_path":"Sources/A.swift","new_line":12,"old_path":"Sources/A.swift","old_line":null}},
         {"id":12,"author_id":3,"note":"Thanks, looks fixed.","discussion_id":"abc","position":null},
         {"id":13,"author_id":8,"note":"Someone else's draft","discussion_id":null,"position":null}]
        """#

    private var manualTarget: MRDiscussionTarget {
        .init(host: host, username: "me", projectID: 1, iid: 2,
              url: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!)
    }

    private let manualDrafts = #"[{"id":11,"author_id":3,"note":"First selected comment"},{"id":12,"author_id":3,"note":"Keep this private","discussion_id":"human"},{"id":14,"author_id":3,"note":"Second selected comment"},{"id":13,"author_id":8,"note":"Another account's draft"}]"#

    private func manualHarness(authored: Bool = false) async throws -> Harness {
        let harness = try makeHarness(assistantWorked: false, authored: authored)
        harness.settings.automation.packageDecision = .disabled
        harness.settings.automation.publicationMode = .manual
        harness.settings.automation.autoReReviewEnabled = false
        harness.settings.automation.scope.mode = .selected
        try harness.write("assistant-unavailable", "yes")
        try harness.write("drafts.json", manualDrafts)
        try await harness.poll()
        return harness
    }

    private func manualSelection(_ harness: Harness) throws -> [GitLabDraftNote] {
        let drafts = try #require(harness.monitor.currentOpenItems.first?.drafts)
        return try [11, 14].map { id in try #require(drafts.first { $0.id == id }) }
    }

    @Test func detailsCheckboxesPublishOnlyTheRemainingCheckedDraftAndIgnoreLaterArrivals() async throws {
        // given
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let drafts = try #require(harness.monitor.currentOpenItems.first?.drafts)
        var selection = DraftPublicationSelection(selectingAll: drafts)
        for draft in drafts where draft.id != 14 { selection.setSelected(false, draft: draft) }
        let checked = selection.selectedDrafts(from: drafts)
        #expect(checked.compactMap(\.id) == [14])
        try harness.write("drafts.json", manualDrafts.replacingOccurrences(of: "]",
            with: #",{"id":15,"author_id":3,"note":"Later arrival"}]"#))
        // when
        await harness.monitor.publishDrafts(checked, for: manualTarget)
        // then
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
        #expect(harness.log("selected.log").contains("/draft_notes/14/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [11, 12, 15])
    }

    @Test func directMRPublicationPublishesAllDespiteAWindowSpecificSubset() async throws {
        // given
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let item = try #require(harness.monitor.currentOpenItems.first)
        var selection = DraftPublicationSelection(selectingAll: item.drafts)
        for draft in item.drafts where draft.id != 14 { selection.setSelected(false, draft: draft) }
        #expect(selection.selectedDrafts(from: item.drafts).count == 1)
        // when
        await harness.monitor.publishDrafts(of: item.id)
        // then
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 3)
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == true)
    }

    @Test func manualPublishAllNeverIncludesAnUnseenQuickActionArrivingAfterTheFirstWrite() async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let item = try #require(harness.monitor.currentOpenItems.first)
        try harness.write("inject-unseen-draft", "yes")
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 3)
        #expect(!harness.log("selected.log").contains("/draft_notes/99/publish"))
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [99])
    }

    @Test(arguments: ["all", "selected"], ["/merge", "resolve"])
    func explicitManualConsentStillPublishesCheckedQuickActions(flow: String, action: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        try harness.write("drafts.json", action == "resolve"
            ? #"[{"id":11,"author_id":3,"note":"Checked resolution","discussion_id":"human","resolve_discussion":true}]"#
            : #"[{"id":11,"author_id":3,"note":"/merge"}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentOpenItems.first)
        if flow == "all" { await harness.monitor.publishDrafts(of: item.id) }
        else { await harness.monitor.publishDrafts(item.drafts, for: manualTarget) }
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("publish.log").isEmpty)
    }

    @Test(arguments: ["head", "source", "semantic", "discussion"])
    func manualPublicationRejectsChangesToTheReviewedSourceAndDiscussion(change: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let item = try #require(harness.monitor.currentOpenItems.first)
        if change == "discussion" {
            try harness.write("discussions.json", #"[{"id":"new","notes":[{"id":40,"author":{"id":9},"body":"Incoming feedback","system":false}]}]"#)
        } else {
            let source = harness.log("request.json")
            let changed = change == "head" ? source.replacingOccurrences(of: head, with: String(repeating: "f", count: 40))
                : change == "source" ? source.replacingOccurrences(of: #""source_branch":"fix""#, with: #""source_branch":"other""#)
                : source.replacingOccurrences(of: #""title":"Fix""#, with: #""title":"Different scope""#)
            try harness.write("request.json", changed)
        }
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
    }

    @Test(arguments: ["read", "transport"])
    func aWorkerStartingDuringManualPublicationStopsTheCommandBoundary(stage: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let item = try #require(harness.monitor.currentOpenItems.first)
        let worker = try publicationWorker(harness, authored: false, state: .running)
        if stage == "read" { try harness.write("pause-selected-read", "yes") }
        else {
            harness.gitlab.beforeCommand = { request in
                guard request.endpoint.hasSuffix("/publish") else { return }
                harness.gitlab.write("selected-read-entered")
                try await harness.gitlab.waitFor("release-selected-read")
            }
        }
        let pending = Task { await harness.monitor.publishDrafts(of: item.id) }
        defer { pending.cancel(); try? harness.write("release-selected-read", "yes") }
        try await harness.gitlab.waitFor("selected-read-entered")
        harness.settings.assistantHandoffs.append(worker)
        try harness.write("release-selected-read", "yes")
        await pending.value
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
    }

    @Test func ownPublishedNotesPermitTheNextManualIDButIncomingFeedbackStopsIt() async throws {
        for incoming in [false, true] {
            let harness = try await manualHarness(); defer { harness.cleanUp() }
            let selected = try manualSelection(harness)
            let external = incoming ? #",{"id":41,"author":{"id":9},"body":"New objection","system":false}"# : ""
            try harness.write("published-discussions.json", #"[{"id":"own","notes":[{"id":40,"author":{"id":3},"body":"First selected comment","system":false}"# + external + "]}]")
            await harness.monitor.publishDrafts(selected, for: manualTarget)
            #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
            #expect(harness.log("selected.log").contains("/draft_notes/14/publish") == !incoming)
            #expect(harness.log("publish.log").isEmpty)
        }
    }

    @Test(arguments: ["failure", "ambiguous"], [(false, false), (false, true), (true, false), (true, true)])
    func retryPublishesOnlyRemainingIDsAfterPartialOrAmbiguousManualPublication(outcome: String, scenario: (Bool, Bool)) async throws {
        let (authored, incoming) = scenario
        let harness = try await manualHarness(authored: authored); defer { harness.cleanUp() }
        let id = try #require(harness.monitor.currentOpenItems.first?.id)
        let published = #"[{"id":"human","notes":[{"id":40,"author":{"id":3,"username":"me"},"body":"First selected comment","system":false},{"id":41,"author":{"id":3,"username":"me"},"body":"Keep this private","system":false},{"id":42,"author":{"id":3,"username":"me"},"body":"Second selected comment","system":false}]}]"#
        try harness.write("published-discussions.json", published)
        if outcome == "failure" { try harness.write("fail-publish-id", "14") }
        else { try harness.write("ambiguous-publish-id", "11") }
        await harness.monitor.publishDrafts(of: id)
        #expect(harness.monitor.currentOpenItems.first?.drafts.contains { $0.id == 11 } == false)
        let firstWrites = harness.log("selected.log").split(separator: "\n").count
        #expect(firstWrites == (outcome == "failure" ? 2 : 1))
        harness.gitlab.remove("fail-publish-id")
        harness.gitlab.remove("ambiguous-publish-id")
        if incoming {
            let changed = harness.log("discussions.json").dropLast() + #",{"id":"new","notes":[{"id":50,"author":{"id":9,"username":"alice"},"body":"New objection","system":false}]}]"#
            try harness.write("discussions.json", String(changed))
        }
        await harness.monitor.publishDrafts(of: id)
        #expect(harness.log("selected.log").components(separatedBy: "/draft_notes/11/publish").count == 2)
        #expect(harness.log("selected.log").split(separator: "\n").count == (incoming ? firstWrites : 3))
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == !incoming)
        if incoming { #expect(harness.monitor.confirmationStates[id] == .changed) }
        #expect(harness.log("publish.log").isEmpty)
    }

    @Test(arguments: [false, true])
    func anAmbiguousManualResponseNeverClaimsAIProvenanceOrCompletesTheHumanCheckpoint(hasPublicNote: Bool) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"First selected comment"}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentOpenItems.first)
        let context = AICommentProvenanceStore.Context(host: host, username: "me", userID: 3, projectID: 1, iid: 2)
        let directory = harness.folder.appending(path: "comment-origins")
        try AICommentProvenanceStore.recordGenerated([.init(id: 11, bodySHA256: AICommentAssessmentStore.digest("First selected comment"))],
            baseline: [], current: item.drafts, context: context, runID: UUID(), headSHA: head, in: directory)
        let after = #"[{"id":"own","notes":[{"id":40,"author":{"id":3,"username":"me"},"body":"First selected comment","system":false}]}]"#
        if hasPublicNote { try harness.write("published-discussions.json", after) }
        try harness.write("ambiguous-publish-id", "11")
        await harness.monitor.publishDrafts(of: item.id)
        let note = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(after.utf8))[0].notes[0]
        #expect(!AICommentProvenanceStore.isGenerated(note, discussionID: "own", context: context, in: directory))
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == true)
        #expect(harness.monitor.confirmationStates[item.id] == .failed)
        #expect(!harness.settings.pendingCommentReviews.isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
    }

    @Test(arguments: [false, true])
    func selectedManualDraftsPublishOnlyTheReviewedSubsetWithoutAutomationOrCLI(authored: Bool) async throws {
        let harness = try await manualHarness(authored: authored); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("selected.log").contains("/draft_notes/14/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [12])
        #expect(harness.log("drafts.json").contains("Another account's draft"))
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
    }

    @Test(arguments: ["body", "deleted", "position", "discussion", "resolve"])
    func anySelectedDraftChangeAbortsBeforePublishingEvenAnUnchangedFirstDraft(change: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        var drafts = try #require(JSONSerialization.jsonObject(with: Data(harness.log("drafts.json").utf8)) as? [[String: Any]])
        if change == "deleted" { drafts.removeAll { $0["id"] as? Int == 14 } }
        else if let index = drafts.firstIndex(where: { $0["id"] as? Int == 14 }) {
            if change == "body" { drafts[index]["note"] = "Changed selected body" }
            if change == "discussion" { drafts[index]["discussion_id"] = "changed-thread" }
            if change == "resolve" { drafts[index]["resolve_discussion"] = true }
            if change == "position" { drafts[index]["position"] = ["new_path": "Changed.swift", "new_line": 9] }
        }
        try JSONSerialization.data(withJSONObject: drafts).store(in: harness.gitlab, as: "drafts.json")
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == .changed)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == (change == "deleted" ? 2 : 3))
    }

    @Test(arguments: ["edit", "add"])
    func unrelatedDraftChangesDoNotBroadenOrBlockTheReviewedSelection(change: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        let updated = change == "edit" ? manualDrafts.replacingOccurrences(of: "Keep this private", with: "Changed private comment")
            : manualDrafts.replacingOccurrences(of: "]", with: #",{"id":15,"author_id":3,"note":"A newly added private comment"}]"#)
        try harness.write("drafts.json", updated)
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
        #expect(!harness.log("selected.log").contains("/draft_notes/15/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == (change == "add" ? 2 : 1))
    }

    @Test(arguments: ["empty", "duplicate", "missingID", "zeroID", "negativeID", "foreign", "missingBody", "blankBody"])
    func invalidManualSelectionCannotPublishAnything(invalid: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let original = try manualSelection(harness)
        let selected: [GitLabDraftNote]
        if invalid == "empty" { selected = [] }
        else if invalid == "duplicate" { selected = [original[0], original[0]] }
        else {
            var item: [String: Any] = ["id": 11, "author_id": 3, "note": "First selected comment"]
            if invalid == "missingID" { item.removeValue(forKey: "id") }
            if invalid == "zeroID" { item["id"] = 0 }
            if invalid == "negativeID" { item["id"] = -1 }
            if invalid == "foreign" { item["author_id"] = 8 }
            if invalid == "missingBody" { item.removeValue(forKey: "note") }
            if invalid == "blankBody" { item["note"] = " \n " }
            selected = try JSONDecoder().decode([GitLabDraftNote].self, from: JSONSerialization.data(withJSONObject: [item]))
        }
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 3)
    }

    @Test(arguments: ["host", "username", "project", "iid", "url"])
    func selectedDraftPublicationIsBoundToTheReviewedMergeRequestAndAccount(change: String) async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        let target = MRDiscussionTarget(host: change == "host" ? "another.example.org" : host,
            username: change == "username" ? "another" : "me", projectID: change == "project" ? 99 : 1,
            iid: change == "iid" ? 99 : 2,
            url: change == "url" ? URL(string: "https://gitlab.example.org/wrong/project/-/merge_requests/2")! : manualTarget.url)
        await harness.monitor.publishDrafts(selected, for: target)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 3)
    }

    @Test(arguments: ["failure", "changed", "account"])
    func partialManualPublicationPreservesRemainingDraftsAndStopsBeforeAnyUnsafeNextWrite(stop: String) async throws {
        let harness = try await manualHarness(authored: true); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        if stop == "failure" { try harness.write("fail-publish-id", "14") }
        if stop == "changed" {
            try harness.write("after-selected-publish.json", manualDrafts.replacingOccurrences(of: "Second selected comment", with: "Edited after first publish")
                .replacingOccurrences(of: #"{"id":11,"author_id":3,"note":"First selected comment"},"#, with: ""))
        }
        if stop == "account" { try harness.write("user-after-selected-publish.json", #"{"id":4,"username":"another"}"#) }
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/14/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [12, 14])
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == (stop == "changed" ? .changed : .failed))
    }

    @Test func liveAuthenticatedUserMismatchStopsSelectedPublicationBeforeTheFirstWrite() async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        try harness.write("live-user.json", #"{"id":4,"username":"me"}"#)
        await harness.monitor.publishDrafts(selected, for: manualTarget)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == .failed)
    }

    @Test func accountSwitchDuringSelectedDraftReadCannotPublishOrChangeTheNewAccountsConfirmation() async throws {
        let harness = try await manualHarness(); defer { harness.cleanUp() }
        let selected = try manualSelection(harness)
        try harness.write("pause-selected-read", "yes")
        let target = manualTarget
        let task = Task { await harness.monitor.publishDrafts(selected, for: target) }
        defer { task.cancel(); try? harness.write("release-selected-read", "yes") }
        let deadline = ContinuousClock.now + .seconds(3)
        while !harness.gitlab.has("selected-read-entered"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(harness.gitlab.has("selected-read-entered"))
        harness.glab.currentUsername = "another"
        try harness.write("live-user.json", #"{"id":4,"username":"another"}"#)
        harness.monitor.refresh(host: host, username: "another", todos: [])
        try harness.write("release-selected-read", "yes")
        await task.value
        let refreshDeadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.isLoading, ContinuousClock.now < refreshDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
    }

    @Test func reviewingProgressSeparatesStaleEvidenceFromOtherReviewersOpenThreads() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        let threads = #"[{"id":"mine","notes":[{"id":40,"author":{"id":3},"body":"Use a safe fallback","system":false,"resolvable":true,"resolved":true},{"id":41,"author":{"id":9},"body":"Fallback implemented","system":false}]},{"id":"other","notes":[{"id":50,"author":{"id":8},"body":"Other reviewer's condition","system":false,"resolvable":true,"resolved":false}]}]"#
        try harness.write("discussions.json", threads)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.reviewingProgress == .waitingForOtherDiscussions)
        let edited = threads.replacingOccurrences(of: "Other reviewer's condition", with: "Additional condition")
        try harness.write("discussions.json", edited)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.reviewingProgress == .needsReview)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.reviewingProgress == .waitingForOtherDiscussions)
        try harness.write("discussions.json", edited.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.reviewingProgress == .current)
    }

    @Test(arguments: ["failed-discussions", "incomplete-discussions", "different-head", "failed-drafts"])
    func quickRefreshDropsReviewProgressWhenItsSnapshotCannotBeValidated(_ failure: String) async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .current)
        switch failure {
        case "failed-discussions": try harness.write("fail-discussion-read", "yes")
        case "incomplete-discussions":
            try harness.write("discussions.json", #"[{"id":"partial","notes":[{"id":40,"author":{"id":8},"system":false}]}]"#)
        case "different-head":
            let updatedHead = String(repeating: "b", count: 40)
            try harness.write("request.json", harness.log("request.json").replacingOccurrences(of: head, with: updatedHead))
            try harness.recordVerdict("no_objections", head: updatedHead)
        default: try harness.write("fail-next-draft-read", "yes")
        }
        await harness.monitor.refreshPendingDrafts()
        let refreshed = try #require(harness.monitor.currentItems.first)
        #expect(refreshed.reviewingProgress == nil)
        #expect(refreshed.mergeRequest?.sha == head)
    }

    @Test func quickRefreshRecomputesSameHeadReviewProgressAfterTextAndResolutionChanges() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .current)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .needsReview)
        try harness.recordVerdict("no_objections", head: head)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .waitingForOtherDiscussions)
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .current)
    }

    @Test func failedCatalogRefreshCannotRetainCurrentProgressFromAnEarlierSnapshot() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.reviewingProgress == .current)
        try harness.write("fail-owned-list", "yes")
        try harness.write("reviewing.json", "[]")
        try harness.write("fail-discussion-read", "yes")
        harness.monitor.refresh(host: host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!harness.monitor.isLoading)
        #expect(harness.monitor.hasError)
        #expect(try #require(harness.monitor.currentItems.first).reviewingProgress == nil)
    }

    @Test func draftsAppearWithPreviewsAndPublishOnlyWhenUnchanged() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()

        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.needsConfirmation && !item.canApprove)
        #expect(item.drafts.map(\.kind) == [.line("Sources/A.swift:12"), .reply])

        // Publish only the shown IDs; a new arrival remains private and visible.
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "\"id\":13,\"author_id\":8", with: "\"id\":13,\"author_id\":3"))
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
        #expect(!harness.log("selected.log").contains("/draft_notes/13/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.compactMap(\.id) == [13])

        // A separate confirmation publishes the newly displayed ID.
        await harness.monitor.publishDrafts(of: item.id)
        #expect(harness.log("publish.log").isEmpty && !harness.log("selected.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == nil)
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == true)
    }

    @Test func remotePublicationSendsOnlyTheExactDisplayedDraftIDs() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts)
        #expect(result == .completed)
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").contains("/11/publish"))
        #expect(harness.log("selected.log").contains("/12/publish"))
        #expect(!harness.log("selected.log").contains("/13/publish"))
        #expect(harness.settings.pendingCommentReviews.isEmpty)
    }

    @Test(arguments: ["account", "executable"])
    func remotePublicationRejectsAChangedSessionDuringTheDraftRead(_ change: String) async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try #require(harness.monitor.hasSyncedCurrentCatalog)
        try #require(item.mergeRequest?.sha == head && item.drafts.compactMap(\.id) == [11, 12])
        let handler = try #require(harness.gitlab.handler)
        var changed = false
        harness.gitlab.handler = { request in
            let response = try await handler(request)
            if !changed, request.method == "GET", request.endpoint.contains("/draft_notes?") {
                changed = true
                if change == "account" {
                    harness.glab.currentUsername = "other"; harness.glab.currentUsername = "me"
                } else { harness.glab.glabPath = URL(fileURLWithPath: "/in-memory/replaced-glab") }
            }
            return response
        }
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts)
        #expect(changed)
        #expect(result == .changed)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] != .publishing)
    }

    @Test func remotePublicationRechecksTheAuthenticatedPrincipalBeforePosting() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("live-user.json", #"{"id":99,"username":"me"}"#)
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts)
        #expect(result == .changed)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
    }

    @Test(arguments: ["account", "executable"])
    func remotePublicationStopsAfterASessionChangeDuringTheFirstWrite(_ change: String) async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let handler = try #require(harness.gitlab.handler)
        var changed = false
        harness.gitlab.handler = { request in
            let response = try await handler(request)
            if request.method == "PUT", request.endpoint.hasSuffix("/11/publish") {
                changed = true
                if change == "account" {
                    harness.glab.currentUsername = "other"; harness.glab.currentUsername = "me"
                } else { harness.glab.glabPath = URL(fileURLWithPath: "/in-memory/replaced-glab") }
            }
            return response
        }
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts)
        try #require(changed)
        #expect(result == .uncertain)
        #expect(harness.log("selected.log").contains("/11/publish"))
        #expect(!harness.log("selected.log").contains("/12/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] != .publishing)
    }

    @Test func selectedPublicationRejectsAnAccountRoundTripDuringTheDraftRead() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let target = MRDiscussionTarget(host: host, username: "me", projectID: 1, iid: 2, url: item.url)
        let handler = try #require(harness.gitlab.handler)
        var changed = false
        harness.gitlab.handler = { request in
            let response = try await handler(request)
            if !changed, request.method == "GET", request.endpoint.contains("/draft_notes?") {
                changed = true
                harness.glab.currentUsername = "other"; harness.glab.currentUsername = "me"
            }
            return response
        }
        await harness.monitor.publishDrafts(item.drafts, for: target)
        #expect(changed)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] != .publishing)
    }

    @Test func remotePublicationStopsWhenAnUnseenDraftAppearsBetweenWrites() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        try harness.write("inject-unseen-draft", "")
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: head, expectedDrafts: item.drafts)
        #expect(result == .partial)
        #expect(harness.log("selected.log").contains("/11/publish"))
        #expect(!harness.log("selected.log").contains("/12/publish"))
        #expect(!harness.log("selected.log").contains("/99/publish"))
    }

    @Test(arguments: ["head", "draft", "quick-action", "resolve"])
    func remotePublicationRejectsChangedOrUnsafeContent(_ change: String) async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        var json = draftJSON
        if change == "quick-action" { json = json.replacingOccurrences(of: "Handle nil here.", with: "/merge") }
        if change == "resolve" { json = json.replacingOccurrences(of: "\"id\":11", with: "\"resolve_discussion\":true,\"id\":11") }
        try harness.write("drafts.json", json)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        if change == "draft" { try harness.write("drafts.json", json.replacingOccurrences(of: "Handle nil here.", with: "Edited")) }
        let result = await harness.monitor.publishRemoteDrafts(of: item.id, head: change == "head" ? "old" : head, expectedDrafts: item.drafts)
        #expect(result == .changed)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
    }

    private let othersThread = #"""
        [{"notes":[{"id":40,"author":{"id":8},"system":false,"body":"Please check this","resolvable":true,"resolved":false}]}]
        """#

    @Test func pendingDraftsLeaveReadyWhenDiscussionContentChanges() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)

        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        let stale = try #require(harness.monitor.currentItems.first)
        #expect(stale.section == .open)
        #expect(stale.drafts.count == 2)

        // A new completed review of the same head can make the drafts ready again.
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
    }

    @Test func visibleInboxRechecksCommentsEvenWhenDraftsHaveNotChanged() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentOpenItems.first?.section == .open)
    }

    @Test func identicalQuickChecksDoNotNotifyBoardEvidenceButChangedCommentsDo() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        await harness.monitor.refreshPendingDrafts()
        let changes = PendingDraftObservationChanges()
        withObservationTracking { _ = harness.monitor.currentOpenItems } onChange: { changes.record() }
        await harness.monitor.refreshPendingDrafts()
        #expect(changes.count == 0)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(changes.count == 1)
        #expect(harness.monitor.currentItems.first?.requiresDiscussionRecheck == true)
    }

    @Test(arguments: ["cancel", "account-round-trip"])
    func interruptedQuickCheckCannotReplaceConfirmedEvidence(_ interruption: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let original = try #require(harness.gitlab.handler)
        harness.gitlab.handler = { call in
            if call.endpoint.contains("/discussions") {
                harness.gitlab.write("poll-entered")
                try await harness.gitlab.waitFor("release-poll")
                return InMemoryGitLab.output(othersThread)
            }
            return try await original(call)
        }
        let check = Task { await harness.monitor.refreshPendingDrafts() }
        defer { check.cancel(); harness.gitlab.write("release-poll") }
        try await harness.gitlab.waitFor("poll-entered")
        if interruption == "cancel" { check.cancel() }
        else { harness.glab.currentUsername = "other"; harness.glab.currentUsername = "me" }
        harness.gitlab.write("release-poll")
        await check.value
        if interruption == "cancel" {
            #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        } else {
            #expect(harness.monitor.currentItems.isEmpty)
        }
        #expect(harness.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["head", "title", "description", "source_branch", "target_branch", "source_project_id", "target_project_id", "author", "discussion-body", "discussion-author", "draft-body", "draft-count", "draft-failure", "discussion-failure"])
    func changedQuickCheckEvidenceStillNotifiesAndRetainsTheMRLink(_ change: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        await harness.monitor.refreshPendingDrafts()
        let previous = try #require(harness.monitor.currentOpenItems.first)
        let changes = PendingDraftObservationChanges()
        withObservationTracking { _ = harness.monitor.currentOpenItems } onChange: { changes.record() }
        switch change {
        case "head":
            try harness.write("request.json", harness.log("request.json").replacingOccurrences(of: head, with: String(repeating: "b", count: 40)))
        case "title", "description", "source_branch", "target_branch", "source_project_id", "target_project_id", "author":
            var json = try #require(JSONSerialization.jsonObject(with: harness.gitlab.data("request.json")) as? [String: Any])
            if change.hasSuffix("_project_id") { json[change] = 77 }
            else if change == "author" { json[change] = ["id": 18, "username": "other-author", "name": "Other author"] }
            else { json[change] = "Edited requirements" }
            try JSONSerialization.data(withJSONObject: json).store(in: harness.gitlab, as: "request.json")
        case "discussion-body":
            try harness.write("discussions.json", othersThread.replacingOccurrences(of: "Please check this", with: "Edited request"))
        case "discussion-author":
            try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"id\":8", with: "\"id\":9"))
        case "draft-body":
            try harness.gitlab.editArray("drafts.json") { $0[0]["note"] = "Edited draft" }
        case "draft-count":
            try harness.gitlab.editArray("drafts.json") { $0.removeFirst() }
        case "draft-failure": try harness.write("fail-next-draft-read", "yes")
        default: try harness.write("fail-discussion-read", "yes")
        }
        await harness.monitor.refreshPendingDrafts()
        #expect(changes.count == 1)
        let current = try #require(harness.monitor.currentOpenItems.first)
        #expect(current.url == previous.url)
        #expect(current.draftCount > 0)
        let changedRequest = ["head", "title", "description", "source_branch", "target_branch", "source_project_id", "target_project_id", "author"].contains(change)
        if changedRequest || change.hasSuffix("failure") { #expect(current.requiresDiscussionRecheck) }
        if changedRequest {
            #expect(!current.canApprove && !current.canConfirmReReview)
            #expect(current.reviewingProgress == nil)
            #expect(current.mergeRequest?.sourceBranch == previous.mergeRequest?.sourceBranch)
            #expect(current.mergeRequest?.targetBranch == previous.mergeRequest?.targetBranch)
        }
    }

    @Test(arguments: ["fail-next-draft-read", "fail-discussion-read"])
    func repeatedQuickReadFailureDoesNotChurnButRecoveryPublishesFreshEvidence(_ failure: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let link = try #require(harness.monitor.currentItems.first?.url)
        try harness.write(failure, "yes")
        await harness.monitor.refreshPendingDrafts()
        try #require(harness.monitor.currentItems.first?.requiresDiscussionRecheck == true)
        let changes = PendingDraftObservationChanges()
        withObservationTracking { _ = harness.monitor.currentOpenItems } onChange: { changes.record() }
        try harness.write(failure, "yes")
        await harness.monitor.refreshPendingDrafts()
        #expect(changes.count == 0)
        #expect(harness.monitor.currentItems.first?.url == link)
        harness.gitlab.remove(failure)
        await harness.monitor.refreshPendingDrafts()
        #expect(changes.count == 1)
        #expect(harness.monitor.currentItems.first?.requiresDiscussionRecheck == false)
        #expect(harness.monitor.currentItems.first?.url == link)
    }

    @Test(arguments: [false, true])
    func draftsWithoutCurrentDiscussionEvidenceRemainAvailableOutsideReady(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: authored)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.section == .open)
        #expect(item.needsConfirmation && item.drafts.count == 2)
    }

    @Test func authorRepliesNeedCurrentDiscussionEvidence() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try harness.bindFollowUpDiscussions()
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)

        try harness.write("discussions.json", #"[{"notes":[{"id":50,"author":{"id":8},"body":"Another question","system":false,"resolvable":false}]}]"#)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func quickRefreshInvalidatesManualApprovalAfterNewComment() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.canApprove == true)
        try harness.write("discussions.json", othersThread)
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.canApprove != true)
        #expect(harness.log("approve.log").isEmpty)
    }

    @Test(arguments: ["fail-next-draft-read", "fail-discussion-read"])
    func failedQuickCheckKeepsDraftsOutsideReady(failure: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write(failure, "yes")
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func editedCommentsInvalidateDraftReadinessButResolutionChangesDoNot() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "Please check this", with: "Edited request"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test func quickRefreshChecksTheLiveHeadInsteadOfTheListSnapshot() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .unpublishedComments)
        try harness.write("request.json", harness.log("request.json").replacingOccurrences(of: head, with: String(repeating: "f", count: 40)))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test func delayedQuickCheckCannotOverwriteANewerFullPoll() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("capture-one-discussion", "yes")
        let quickCheck = Task { await harness.monitor.refreshPendingDrafts() }
        defer { try? harness.write("release-discussion", "yes") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !harness.gitlab.has("discussion-captured"),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(harness.gitlab.has("discussion-captured"))
        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.section == .open)
        try harness.write("release-discussion", "yes")
        await quickCheck.value
        #expect(harness.monitor.currentItems.first?.section == .open)
    }

    @Test(arguments: [false, true])
    func automaticPublicationRejectsDraftsAfterNewComment(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: authored)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", draftJSON)
        if authored { try harness.verifyFollowUpDrafts() }
        else { try harness.recordVerdict("objections", head: head) }
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.write("discussions.json", othersThread)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
    }

    @Test func automaticPublicationRechecksTheExactDraftAfterDiscussionCheck() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Checked finding"}]"#)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        // The full poll reads discussions once; the final publication check reads
        // them again, after its earlier draft read. The ID stays the same.
        try harness.write("edit-after-next-discussion", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.log("drafts.json").contains("/merge"))
    }

    @Test func manualApprovalNeedsANoObjectionsVerdictForTheCurrentHead() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("no_objections", head: String(repeating: "f", count: 40))
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)

        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove && !item.autoApproveReady)
        #expect(harness.log("approve.log").isEmpty)

        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").contains("sha=\(head)"))
        #expect(harness.monitor.currentItems.isEmpty)

        // Until GitLab reports the approval, the same head is not offered again.
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
    }

    @Test(arguments: ["raw", "otherAccount", "substitutedRun", "tamperedCheckpoint"])
    func automaticApprovalRequiresTheExactAccountAndAuthenticatedCompletedReview(_ evidence: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head, authenticated: evidence != "raw")
        let path = harness.folder.appending(path: "verdicts/gitlab.example.org/1-2.json")
        if evidence == "otherAccount" || evidence == "substitutedRun" {
            var value = try JSONDecoder().decode(ReviewVerdict.self, from: Data(contentsOf: path))
            if evidence == "otherAccount" { value.username = "other"; value.userID = 9 }
            else { value.runID = UUID() }
            try JSONEncoder().encode(value).write(to: path)
        }
        if evidence == "tamperedCheckpoint" {
            let run = try #require(harness.settings.assistantHandoffs.last)
            try Data("worker-written completion".utf8).write(to: AssistantJobJournal.checkpointURL(for: run.id))
        }
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        if evidence == "raw" {
            let item = try #require(harness.monitor.currentItems.first)
            #expect(item.canApprove && !item.autoApproveReady)
            await harness.monitor.approve(item.id)
            #expect(harness.log("approve.log").contains("/approve"))
        }
        if evidence == "otherAccount" {
            #expect(harness.monitor.currentOpenItems.allSatisfy { !$0.canApprove && !$0.autoApproveReady })
        }
    }

    @Test func persistenceHoldStopsAutomaticApprovalButKeepsExplicitFreshApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.recordPersistenceFailure("workflowActivity")
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove)
        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
    }

    @Test func forgingObservedDraftHistoryCannotNormalizeNewFeedbackForAutomaticApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("discussions.json", #"[{"id":"own","notes":[{"id":40,"author":{"id":3,"username":"me"},"body":"Block this merge","system":false}]}]"#)
        ReviewVerdictStore.rememberDrafts([.init(id: 11, authorID: 3, note: "Block this merge", discussionID: nil, position: nil)],
            host: host, projectID: 1, iid: 2, in: harness.folder.appending(path: "verdicts"))
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.allSatisfy { !$0.autoApproveReady })
    }

    @Test func confirmedAppPublicationPreservesAutomaticApprovalWithoutAIOriginEvidence() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = false
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Checked reply","discussion_id":"own"}]"#)
        try harness.write("discussions.json", #"[{"id":"own","notes":[]}]"#)
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("published-discussions.json", #"[{"id":"own","notes":[{"id":40,"author":{"id":3,"username":"me"},"body":"Checked reply","system":false}]}]"#)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("approve.log").contains("/approve"))
    }

    @Test func validatedReviewCompletionCapturesExactPendingDraftsAndFailsClosedWhenTheyCannotBeRead() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Reviewed draft","discussion_id":"own"}]"#)
        try harness.recordVerdict("no_objections", head: head)
        let index = try #require(harness.settings.assistantHandoffs.indices.last)
        harness.settings.assistantHandoffs[index].execution?.state = .running
        harness.settings.assistantHandoffs[index].mergeRequestURL = URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")
        let run = harness.settings.assistantHandoffs[index]
        let result = AssistantJobResult(status: .succeeded, summary: "Reviewed")
        let captured = await AssistantJobExecutor.reviewVerdictForCompletion(result, user: .init(id: 3, username: "me"),
            handoff: run, settings: harness.settings, glab: harness.glab, directory: harness.folder.appending(path: "verdicts"))
        let evidence = try #require(captured)
        #expect(evidence.drafts == [.init(id: 11, authorID: 3, note: "Reviewed draft", discussionID: "own", position: nil)])
        try harness.write("fail-next-draft-read", "yes")
        let missing = await AssistantJobExecutor.reviewVerdictForCompletion(result, user: .init(id: 3, username: "me"),
            handoff: run, settings: harness.settings, glab: harness.glab, directory: harness.folder.appending(path: "verdicts"))
        #expect(missing == nil)
    }

    @Test(arguments: ["created", "edited"])
    func publishingALaterDraftCannotNormalizeAnOlderCompletedReview(_ change: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = false
        try harness.write("discussions.json", #"[{"id":"own","notes":[]}]"#)
        if change == "edited" {
            try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Earlier draft","discussion_id":"own"}]"#)
        }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"New blocking concern","discussion_id":"own"}]"#)
        try harness.write("published-discussions.json", #"[{"id":"own","notes":[{"id":40,"author":{"id":3,"username":"me"},"body":"New blocking concern","system":false}]}]"#)
        try await harness.poll()
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("approve.log").isEmpty)
    }

    @Test func persistenceFailureDuringTheFinalApprovalAuthReadCannotSubmit() async throws {
        // given
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        let original = try #require(harness.gitlab.handler)
        let id = MergeRequestAttentionMonitor.Item.ID(projectID: 1, iid: 2)
        var approvalAuthReads = 0
        harness.gitlab.handler = { call in
            if call.endpoint == "/user", harness.monitor.confirmationStates[id] == .approving {
                approvalAuthReads += 1
                if approvalAuthReads == 2 { harness.settings.recordPersistenceFailure("automationAttemptReceipts") }
            }
            return try await original(call)
        }

        // when
        try await harness.poll()

        // then
        #expect(approvalAuthReads == 2)
        #expect(harness.log("approve.log").isEmpty)
        #expect(!harness.settings.automaticActionsAllowed)
    }

    @Test(arguments: [1, 3])
    func automaticApprovalReadFailuresDoNotPermanentlyRequireManualApproval(_ failures: Int) async throws {
        let probe = ApprovalUserReadProbe()
        let harness = try makeHarness(assistantWorked: true, approvalReadClock: { probe.now })
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("approval-preflight-failures", String(failures))

        try await harness.poll(timeout: .seconds(15))

        #expect(harness.log("approval-preflight.log").split(separator: "\n").count == failures)
        #expect(harness.log("approve.log").split(separator: "\n").count == (failures == 1 ? 1 : 0))
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
        try harness.write("approval-preflight-failures", "0")
        try await harness.poll()
        #expect(harness.log("approve.log").split(separator: "\n").count == (failures == 1 ? 1 : 0))
        #expect(harness.log("approval-preflight.log").split(separator: "\n").count == failures)
        probe.now = probe.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        try await harness.poll()
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func theAdaptersFinalUserReadCannotCreateAnApprovalWriteFence() async throws {
        let probe = ApprovalUserReadProbe()
        let harness = try makeHarness(assistantWorked: true, duringAutomationCheck: { folder in
            guard probe.armed else { return }
            probe.armed = false
            folder.write("fail-next-approval-user", "yes")
        }, approvalReadClock: { probe.now })
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)

        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        probe.now = probe.now.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        try await harness.poll()

        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func anAmbiguousApprovalResponseIsReconciledWithoutAnotherSubmission() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("approval-response-lost", "yes")

        try await harness.poll()

        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
        try await harness.poll()
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func anUnconfirmedApprovalWriteRemainsFencedButManualRetryFirstReconcilesItsEffect() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("fail-approval-write", "yes")
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove && harness.monitor.confirmationStates[item.id] == .failed)

        // GitLab confirms the original effect only after the unsuccessful readback.
        try harness.write("approvals.json", #"{"approved_by":[{"user":{"id":3,"username":"me"}}]}"#)
        harness.gitlab.remove("fail-approval-write")
        await harness.monitor.approve(item.id)

        #expect(harness.log("approve.log").split(separator: "\n").count == 1)
        #expect(harness.monitor.confirmationStates[item.id] == nil)
    }

    @Test func approvalIsNotOfferedOnceApproved() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.recordVerdict("no_objections", head: head)
        try harness.write("reviewers.json", #"[{"user":{"id":3},"state":"approved"}]"#)
        try await harness.poll()
        #expect(harness.monitor.currentItems.isEmpty)
        #expect(harness.log("approve.log").isEmpty)
    }

    @Test func anAuthorReplyOnTheSameHeadInvalidatesTheEarlierVerdict() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove)
        try harness.write("discussions.json", #"[{"id":"reply","notes":[{"id":71,"author":{"id":9},"system":false,"body":"Please check this approach too","resolvable":false}]}]"#)
        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").isEmpty)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func autoApprovalIsOnByDefaultAndWaitsForEveryDiscussion() async throws {
        #expect(AutomationSettings().autoApproveEnabled)
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        // Waiting on others is not something the user has to confirm.
        #expect(harness.monitor.currentItems.isEmpty)

        // Another reviewer's thread gets resolved without our action.
        try harness.write("discussions.json", othersThread.replacingOccurrences(of: "\"resolved\":false", with: "\"resolved\":true"))
        try await harness.poll()
        #expect(harness.log("approve.log").contains("sha=\(head)"))
    }

    @Test func optingOutOneMergeRequestFallsBackToManualApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.autoApproveOptOuts.insert(
            .init(host: host, username: "me", projectID: 1, iid: 2)
        )
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.canApprove == true)
    }

    @Test(arguments: [AutomationPackageDecision.undecided, .disabled])
    func missingConsentStopsAutomaticPublicationButKeepsExplicitFreshPublication(_ decision: AutomationPackageDecision) async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, consent: decision)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .all
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)

        // when
        try await harness.poll()
        try await harness.poll()

        // then
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(harness.log("publish.log").isEmpty && !harness.log("selected.log").isEmpty)
    }

    @Test func persistenceHoldStopsAutomaticPublicationButKeepsExplicitFreshPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        harness.settings.recordPersistenceFailure("assistantHandoffs")
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)

        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(harness.log("publish.log").isEmpty && !harness.log("selected.log").isEmpty)
    }

    @Test func unavailableCLIBlocksAutomaticPublicationButKeepsManualPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("assistant-unavailable", "yes")
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)

        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(harness.log("publish.log").isEmpty)
        let writes = harness.gitlab.requests.filter { $0.method != "GET" && $0.endpoint.contains("/draft_notes") }
        #expect(writes.map(\.method) == ["PUT", "PUT"])
        #expect(writes.map(\.endpoint) == [
            "/projects/1/merge_requests/2/draft_notes/11/publish",
            "/projects/1/merge_requests/2/draft_notes/12/publish"
        ])
        #expect(harness.monitor.currentOpenItems.first?.drafts.isEmpty == true)
    }

    @Test func unavailableCLIBlocksAutomaticAIReplyPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("assistant-unavailable", "yes")
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func unavailableCLIBlocksAutomaticApprovalButKeepsManualApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("assistant-unavailable", "yes")
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.log("approve.log").isEmpty)
        await harness.monitor.approve(.init(projectID: 1, iid: 2))
        #expect(!harness.log("approve.log").isEmpty)
    }

    @Test func automaticPublishingIsOffByDefaultAndWaitsForSettledDrafts() async throws {
        #expect(AutomationSettings().publishDraftsWithoutConfirmation == false)

        let manual = try makeHarness(assistantWorked: true)
        defer { manual.cleanUp() }
        try manual.write("drafts.json", draftJSON)
        try await manual.poll()
        try await manual.poll()
        #expect(manual.log("publish.log").isEmpty)

        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "looks fixed", with: "looks fixed now"))
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
    }
    private let duoDiscussion = #"[{"id":"abc","notes":[{"id":40,"body":"AI finding","author":{"id":8,"username":"GitLabDuo"},"system":false,"resolvable":true,"resolved":false}]}]"#

    @Test func duoRepliesPublishSelectivelyWithoutSendingOtherDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("selected.log").contains("--method PUT"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 1)
        try await harness.poll()
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
    }

    @Test func humanAICommentRequiresCurrentContentBoundAssessment() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        let human = duoDiscussion.replacingOccurrences(of: "GitLabDuo", with: "alice")
        try harness.write("discussions.json", human)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.assess(noteID: 40, body: "old text")
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        try harness.assess(noteID: 40, body: "AI finding")
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
    }

    @Test func aiPublicationRespectsScopeOptOutAndVerifiedDuoIdentity() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        harness.settings.automation.publishAIRepliesWithoutConfirmation = false
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.publishAIRepliesWithoutConfirmation = true
        harness.settings.automation.scope.mode = .selected
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.scope.mode = .all
        try harness.write("duo.json", #"{"id":8,"username":"GitLabDuo","bot":false}"#)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
    }

    @Test func aiPublicationFailureKeepsDraftsAndReportsFailure() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.write("fail-publish", "yes")
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == .failed)
    }

    @Test func externalPublicationKeepsTheCompletionActionWithoutFullPolling() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.monitor.currentItems.first?.requiresCommentReview == true)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func editingReplyDuringEligibilityCheckPreventsPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("change-during-discussions", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func unmanagedAIRepliesStayPrivate() async throws {
        let harness = try makeHarness(assistantWorked: false)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        // Raw helper evidence does not create an app-owned review run for this unmanaged MR.
        try harness.recordVerdict("objections", head: head, authenticated: false)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func allCommentPublishingTakesPrecedenceOverAIOnly() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func automaticPublishingRejectsGitLabQuickActions() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "/submit_review approve"))
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
    }

    @Test func publicationRepositoryRestrictionKeepsDraftsPrivateAndNeedingHumanAction() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.publicationRestrictions.repositories = [
            .init(host: host, entityID: 99, label: "other/project")
        ]
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.draftCount == 2)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        #expect(item.draftIDsHandledAutomatically(automation: harness.settings.automation,
            target: target, assistantPreparing: true).isEmpty)
    }

    @Test(arguments: [AutomationPublicationMode.filtered, .aiReplies])
    func automaticPublicationCannotExpandBeyondCheckedPreviewWhenLiveAIProofImproves(mode: AutomationPublicationMode) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = mode
        harness.settings.automation.publicationRestrictions.requireAI = true
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"First reply","discussion_id":"abc"},{"id":14,"author_id":3,"note":"Second reply","discussion_id":"later"}]"#)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"body":"AI finding","author":{"id":8,"username":"GitLabDuo"},"system":false}]},{"id":"later","notes":[{"id":41,"body":"Later AI finding","author":{"id":9,"username":"alice"},"system":false}]}]"#)
        try harness.recordVerdict("objections", head: head)
        let lateProof = AICommentAssessment(version: 1, host: host, projectID: 1, iid: 2, noteID: 41,
            bodySHA256: AICommentAssessmentStore.digest("Later AI finding"), confidence: "very_high", evidence: "Verified AI provenance")
        try JSONEncoder().encode(lateProof).write(to: harness.folder.appending(path: "late-ai-assessment.json"))
        try await harness.poll()
        let preview = try #require(harness.monitor.currentItems.first)
        #expect(preview.automaticDraftIDs == [12])
        try harness.write("add-ai-assessment-after-preview", "yes")

        try await harness.poll()

        #expect(harness.gitlab.has("ai-assessment-added-after-preview"))
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/14/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [14])
    }

    @Test(arguments: ["repository", "mrAuthor"])
    func excludedOwnDraftsDoNotRequireAutomaticRemoteVerification(condition: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.allowFollowUpPush = false
        let excluded = PublicationIdentity(host: host, entityID: 99, label: "Excluded")
        if condition == "repository" { harness.settings.automation.publicationRestrictions.repositories = [excluded] }
        else { harness.settings.automation.publicationRestrictions.mergeRequestAuthors = [excluded] }
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Verified fix","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()

        try await harness.poll()

        let item = try #require(harness.monitor.currentItems.first)
        #expect(!item.awaitingRemoteVerification && !item.requiresDiscussionRecheck)
        let row = MergeRequestBoardSnapshot.Row(item: item, latestJob: nil, intents: [])
        #expect(MRHumanAction(row: row, assistantReady: true)?.kind == .publication)
        #expect(harness.log("selected.log").isEmpty && item.draftCount == 1)
    }

    @Test func addingAnExcludingFilterClearsStaleAutomaticVerificationWarningDuringDraftRefresh() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.publicationRestrictions.repositories = [.init(host: host, entityID: 1, label: "g/p")]
        harness.settings.automation.allowFollowUpPush = false
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Verified fix","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == true)
        harness.settings.automation.publicationRestrictions.repositories = [.init(host: host, entityID: 99, label: "other/repo")]

        await harness.monitor.refreshPendingDrafts()

        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == false)
        #expect(harness.monitor.currentItems.first?.requiresDiscussionRecheck == false)
    }

    @Test func authorDraftEditedToQuickActionDuringFinalAIIdentityLookupStaysPrivate() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.publicationRestrictions.requireAI = true
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Verified fix","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try await harness.poll()
        try harness.write("edit-after-proof-draft-read", "yes")

        try await harness.poll()

        #expect(harness.gitlab.has("edited-after-proof-draft-read"))
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 1)
    }

    @Test func sourceAndAIRestrictionsSelectMatchingReplyIDsOnly() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.publicationRestrictions = .init(
            repositories: [.init(host: host, entityID: 1, label: "g/p")],
            mergeRequestAuthors: [.init(host: host, entityID: 9, label: "@alice")],
            sourceCommentAuthors: [.init(host: host, entityID: 8, label: "@GitLabDuo")], requireAI: true)
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        #expect(item.draftIDsHandledAutomatically(automation: harness.settings.automation,
            target: target, assistantPreparing: true) == [12])
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
    }

    @Test func editingPublicationRestrictionsImmediatelyInvalidatesAutomaticDraftPreview() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .all
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        #expect(!item.draftIDsHandledAutomatically(automation: harness.settings.automation,
            target: target, assistantPreparing: true).isEmpty)
        harness.settings.automation.publicationRestrictions.requireAI = true
        #expect(item.draftIDsHandledAutomatically(automation: harness.settings.automation,
            target: target, assistantPreparing: true).isEmpty)
    }

    @Test func finalPublicationUsesLiveMRAuthorRatherThanListSnapshot() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .filtered
        harness.settings.automation.publicationRestrictions.mergeRequestAuthors = [
            .init(host: host, entityID: 9, label: "@alice")
        ]
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let live = harness.log("request.json").replacingOccurrences(of: "\"id\":9,\"username\":\"alice\"", with: "\"id\":7,\"username\":\"someone-else\"")
        try harness.write("request.json", live)
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func aVerifierCompletionCannotRequestReviewAfterItsAuthoredRowWasRemoved() async throws {
        // given
        let gate = InMemoryGitLab()
        let harness = try makeHarness(assistantWorked: true, authored: true, reReviewGate: {
            gate.write("verifier-entered")
            try await gate.waitFor("release-verifier")
        })
        defer {
            gate.close()
            harness.monitor.automationConfigurationChanged()
            harness.cleanUp()
        }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.authorFeedback.isEnabled = false
        harness.settings.automation.workflowRules[.newDiscussion].mode = .off
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"unapproved"}]"#)
        harness.monitor.refresh(host: host, username: "me", todos: [])
        try await gate.waitFor("verifier-entered")
        let initialDeadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.isLoading, ContinuousClock.now < initialDeadline { await Task.yield() }
        try #require(!harness.monitor.isLoading && harness.monitor.isVerifyingReReview)
        try #require(harness.monitor.currentOpenItems.first?.isAuthored == true)

        // when
        harness.settings.ignoredMergeRequests.insert(.init(host: host, username: "me", projectID: 1, iid: 2))
        try harness.write("authored.json", "[]")
        harness.monitor.onRefreshed = { gate.write("row-removal-observed") }
        harness.monitor.refresh(host: host, username: "me", todos: [])
        try await gate.waitFor("row-removal-observed")
        try #require(harness.monitor.currentOpenItems.isEmpty)
        gate.write("release-verifier")
        let completionDeadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.isVerifyingReReview, ContinuousClock.now < completionDeadline { await Task.yield() }

        // then
        #expect(!harness.monitor.isVerifyingReReview)
        #expect(harness.log("re-review.log").isEmpty && harness.settings.reReviewReceipts.isEmpty)
        #expect(harness.monitor.currentOpenItems.isEmpty)
    }

    @Test(arguments: ["draft", "closed"])
    func runtimeRevocationStopsAPollOwnedReReviewAfterItsFinalReadySnapshot(_ state: String) async throws {
        var armFinalRead = false
        let harness = try makeHarness(assistantWorked: true, authored: true, duringAutomationCheck: { folder in
            if armFinalRead {
                armFinalRead = false
                folder.write("pause-selected-read")
            }
        })
        defer {
            try? harness.write("release-selected-read", "yes")
            harness.monitor.automationConfigurationChanged()
            harness.cleanUp()
        }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        // Keep the completed assessment while an unavailable dependency prevents its first write.
        try harness.write("assistant-unavailable", "yes")
        try await harness.poll()
        try #require(!harness.monitor.isVerifyingReReview && harness.log("verification.log") == "verified\n")
        try #require(harness.log("re-review.log").isEmpty)
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        harness.gitlab.remove("assistant-unavailable")
        armFinalRead = true
        harness.monitor.refresh(host: host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while (!harness.gitlab.has("selected-read-entered")
               || !harness.gitlab.has("captured-ready-rereview-mr")),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(harness.gitlab.has("selected-read-entered"))
        try #require(harness.gitlab.has("captured-ready-rereview-mr"))
        try #require(!harness.monitor.isVerifyingReReview)
        let original = harness.log("request.json")
        let current = state == "draft" ? original.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
            : original.replacingOccurrences(of: "\"state\":\"opened\"", with: "\"state\":\"closed\"")
        try harness.write("request.json", current)
        var projected = harness.settings.automation.scope
        projected[.init(host: host, username: "me", projectID: 1, iid: 2)] = .paused
        try #require(harness.settings.reReviewReceipts.isEmpty)
        harness.monitor.cancelRuntimePreparation(outsideScope: projected)
        try harness.write("release-selected-read", "yes")
        let settled = ContinuousClock.now + .seconds(5)
        while harness.monitor.isLoading, ContinuousClock.now < settled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!harness.monitor.isLoading)
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.settings.reReviewReceipts.isEmpty)
    }

    @Test func runtimeScopeRevocationCancelsReReviewWithoutLosingItsBaselineAndCanResume() async throws {
        var calls = 0
        var cancelled = false
        let harness = try makeHarness(assistantWorked: true, authored: true, reReviewGate: {
            calls += 1
            if calls == 1 {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = true; throw error }
            }
        })
        defer { harness.monitor.automationConfigurationChanged(); harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        harness.monitor.refresh(host: host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while (calls == 0 || harness.monitor.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(calls == 1 && harness.monitor.isVerifyingReReview)
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let baseline = harness.settings.reReviewDraftBaselines[target]
        let configuration = harness.settings.automation
        var projected = configuration.scope
        projected[target] = .paused
        harness.monitor.cancelRuntimePreparation(outsideScope: projected)
        for _ in 0..<50 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled && !harness.monitor.isVerifyingReReview)
        #expect(harness.settings.automation == configuration)
        #expect(harness.settings.reReviewDraftBaselines[target] == baseline)
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.reReviewReadiness == nil)
        if !cancelled { return }
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        harness.monitor.cancelRuntimePreparation(outsideScope: configuration.scope)
        try await harness.poll()
        #expect(calls == 2)
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func persistenceHoldAllowsReReviewChecksButCannotRequestReviewer() async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        harness.settings.recordPersistenceFailure("reReviewReceipts")
        try await harness.poll()
        let displayed = try #require(harness.monitor.currentOpenItems.first)

        // when
        let finished = await harness.monitor.finishCommentReview(displayed)
        try await harness.settleVerification()

        // then
        #expect(finished)
        #expect(!harness.log("verification.log").isEmpty)
        #expect(harness.log("re-review.log").isEmpty)
    }

    private func prepareAuthoredFeedback(_ harness: Harness) throws {
        harness.settings.automation.autoReReviewEnabled = true
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "Verified correction"))
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"reviewed"}]"#)
        try harness.write("duo.json", #"{"id":8,"username":"reviewer","bot":false,"state":"active"}"#)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"Review feedback","system":false,"resolvable":true,"resolved":false}]}]"#)
        try harness.write("published-discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"Review feedback","system":false,"resolvable":true,"resolved":false},{"id":41,"author":{"id":3},"body":"Verified correction","system":false}]}]"#)
    }

    @Test(arguments: ["title", "description"])
    func reReviewIncludesDescriptionAndRechecksSameHeadContextEdits(_ field: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.verificationThinking = .low
        try harness.write("fail-verification", "yes")
        let original = harness.log("request.json").replacingOccurrences(of: "\"title\":\"Fix\"",
            with: "\"title\":\"Fix\",\"description\":\"Current fallback documented\"")
        try harness.write("request.json", original)
        try harness.write("authored.json", "[\(original)]")
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        let input = try #require(JSONSerialization.jsonObject(with: Data(harness.log("verifier-input.json").utf8)) as? [String: Any])
        #expect(input["description"] as? String == "Current fallback documented")
        #expect(input["thinking"] as? String == "low")
        let target = input["target"] as? [String: Any]
        #expect(target?["host"] as? String == host)
        #expect(target?["projectID"] as? Int == 1)
        #expect(target?["iid"] as? Int == 2)
        #expect(target?["url"] as? String == "https://gitlab.example.org/g/p/-/merge_requests/2")
        #expect(target?["expectedUsername"] as? String == "me")
        let snapshot = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(original.utf8))
        #expect(input["semanticContextFingerprint"] as? String == snapshot.semanticContextFingerprint)
        #expect(harness.log("verification.log") == "verified\n")
        let edited = original.replacingOccurrences(of: field == "title" ? "\"title\":\"Fix\"" : "Current fallback documented",
            with: field == "title" ? "\"title\":\"Changed scope\"" : "New fallback requirement")
        try harness.write("request.json", edited)
        try harness.write("authored.json", "[\(edited)]")
        try await harness.poll()
        #expect(harness.log("verification.log") == "verified\nverified\n")
        #expect(harness.log("re-review.log").isEmpty)
    }

    @Test(arguments: ["unapproved", "reviewed"])
    func readyFeedbackAlsoRequestsEarlierReviewersWithoutComments(_ state: String) async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("reviewers.json", """
            [{"user":{"id":8},"state":"reviewed"},
             {"user":{"id":9},"state":"\(state)"},
             {"user":{"id":10},"state":"unreviewed"}]
            """)

        // when
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        try #require(displayed.requiresCommentReview)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        try await harness.settleVerification()
        try await harness.poll()

        // then
        #expect(harness.log("re-review.log") == "requested\nrequested\n")
        let requests = harness.log("re-review-targets.log")
        #expect(requests.contains("userId=gid://gitlab/User/8"))
        #expect(requests.contains("userId=gid://gitlab/User/9"))
        #expect(!requests.contains("userId=gid://gitlab/User/10"))
    }

    @Test(arguments: [ReReviewAssessment.Note.State.blocking, .uncertain])
    func earlierApproversWaitUntilAllFeedbackIsReady(_ state: ReReviewAssessment.Note.State) async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true, assessment: .init(notes: [
            .init(noteID: 40, state: state, reason: "Remaining work or missing evidence")
        ]))
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"reviewed"},{"user":{"id":9},"state":"unapproved"}]"#)

        // when
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        try #require(displayed.requiresCommentReview)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        try await harness.settleVerification()

        // then
        #expect(harness.log("re-review.log").isEmpty)
    }

    @Test func resolvedEarlierCommentsDoNotNeedANewAuthorReplyToRequestReReview() async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        let threads = harness.log("published-discussions.json").dropLast() + #",{"id":"earlier","notes":[{"id":30,"author":{"id":9},"body":"Earlier finding","system":false,"resolvable":true,"resolved":true,"resolved_by":{"id":9}}]}]"#
        try harness.write("discussions.json", String(threads))
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"reviewed"},{"user":{"id":9},"state":"reviewed"}]"#)

        // when
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        try #require(displayed.requiresCommentReview)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        try await harness.settleVerification()

        // then
        #expect(harness.log("re-review.log") == "requested\nrequested\n")
        #expect(harness.log("re-review-targets.log").contains("userId=gid://gitlab/User/9"))
    }

    @Test func aLaterHeadCanRequestEarlierApprovalAgainWithoutNewCommentIDs() async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"unreviewed"},{"user":{"id":9},"state":"unapproved"}]"#)
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        try #require(displayed.requiresCommentReview)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        try await harness.settleVerification()
        try #require(harness.log("re-review.log") == "requested\n")

        // when
        let nextHead = String(repeating: "b", count: 40)
        for file in ["request.json", "authored.json"] {
            try harness.write(file, harness.log(file).replacingOccurrences(of: head, with: nextHead))
        }
        try await harness.poll()
        try await harness.poll()

        // then
        #expect(harness.log("re-review.log") == "requested\nrequested\n")
    }

    @Test(arguments: ["unapproved", "unreviewed"])
    func approvalHoverOrdersCurrentThenEarlierThenCommentOnlyThenAssigned(_ state: String) async throws {
        // given
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        let people = #"[{"id":10,"username":"waiting","name":"Waiting"},{"id":9,"username":"past","name":"Past"},{"id":8,"username":"comments","name":"Comments"}]"#
        for file in ["request.json", "authored.json"] {
            try harness.write(file, harness.log(file).replacingOccurrences(of: "\"labels\":[]", with: "\"labels\":[],\"reviewers\":\(people)"))
        }
        try harness.write("approvals.json", #"{"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"id":7,"username":"current","name":"Current"}}]}"#)
        try harness.write("reviewers.json", """
            [{"user":{"id":10},"state":"unreviewed"},{"user":{"id":9},"state":"\(state)"},{"user":{"id":8},"state":"reviewed"}]
            """)
        try harness.write("discussions.json", #"[{"notes":[{"id":30,"author":{"id":9,"username":"past"},"system":true,"body":"approved this merge request","created_at":"2026-01-01T12:00:00Z"}]},{"notes":[{"id":40,"author":{"id":8,"username":"comments"},"system":false,"body":"A comment","created_at":"2026-01-02T12:00:00Z"}]}]"#)

        // when
        try await harness.poll()

        // then
        let item = try #require(harness.monitor.currentOpenItems.first)
        let progress = try #require(item.approvalProgress)
        let participants = progress.participants(reviewers: item.mergeRequest?.reviewers ?? [])
        #expect(participants.map(\.id) == [7, 9, 8, 10])
        #expect(participants.map(\.status) == [.approved, .previouslyApproved, .commented, .assigned])
    }

    @Test func currentApprovalDoesNotGetResetByAReReviewRequest() async throws {
        // given
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("approvals.json", #"{"approved_by":[{"user":{"id":8}}]}"#)
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"approved"}]"#)

        // when
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        try #require(displayed.requiresCommentReview)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        try await harness.settleVerification()

        // then
        #expect(harness.log("re-review.log").isEmpty)
    }

    @Test func informationalOnlyReviewerCompletesReReviewWithoutARequestOrStaleReadiness() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true, assessment: .init(notes: [
            .init(noteID: 40, state: .informational, reason: "Informational review summary")
        ]))
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        try #require(harness.settings.reReviewDraftBaselines[target] != nil)
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))

        try await harness.poll()

        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(harness.log("re-review.log").isEmpty)
        #expect(item.reReviewReadiness == nil && !item.canConfirmReReview)
        #expect(harness.settings.reReviewDraftBaselines[target] == nil)
        #expect(harness.settings.reReviewReceipts.values.allSatisfy { $0.requested != true && !$0.unconfirmed })
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.reReviewReadiness == nil)
        #expect(harness.log("re-review.log").isEmpty)
    }

    @Test(arguments: [ReReviewAssessment.Note.State.informational, .uncertain])
    func informationalReviewerDoesNotHideMixedReadyAndBlockingReviewers(_ firstState: ReReviewAssessment.Note.State) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true, assessment: .init(notes: [
            .init(noteID: 40, state: firstState, reason: "Review summary needing no action or more verification"),
            .init(noteID: 50, state: .addressed, reason: "Verified correction is ready for review"),
            .init(noteID: 60, state: .blocking, reason: "Missing required regression test")
        ]))
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        try #require(harness.settings.reReviewDraftBaselines[target] != nil)
        try harness.write("drafts.json", "[]")
        try harness.write("reviewers.json", #"[{"user":{"id":8},"state":"reviewed"},{"user":{"id":9},"state":"reviewed"},{"user":{"id":10},"state":"reviewed"}]"#)
        try harness.write("discussions.json", #"[{"id":"info","notes":[{"id":40,"author":{"id":8,"username":"reviewer"},"body":"Informational summary","system":false,"resolvable":false},{"id":41,"author":{"id":3,"username":"me"},"body":"Acknowledged","system":false}]},{"id":"ready","notes":[{"id":50,"author":{"id":9,"username":"reviewer9"},"body":"Please fix A","system":false,"resolvable":false},{"id":51,"author":{"id":3,"username":"me"},"body":"Fixed A","system":false}]},{"id":"blocked","notes":[{"id":60,"author":{"id":10,"username":"reviewer10"},"body":"Please fix B","system":false,"resolvable":false},{"id":61,"author":{"id":3,"username":"me"},"body":"Fix B is pending","system":false}]}]"#)

        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()

        #expect(harness.log("re-review.log") == "requested\n")
        let requests = harness.log("re-review-targets.log")
        #expect(requests.contains("userId=gid://gitlab/User/9"))
        #expect(!requests.contains("userId=gid://gitlab/User/8") && !requests.contains("userId=gid://gitlab/User/10"))
        let item = try #require(harness.monitor.currentOpenItems.first)
        guard case .blocked(let blockers) = item.reReviewReadiness else {
            Issue.record("The unaddressed reviewer's blocker must remain visible")
            return
        }
        #expect(blockers.map(\.noteID) == (firstState == .uncertain ? [60, 40] : [60]))
        #expect(blockers.filter(\.isUncertain).map(\.noteID) == (firstState == .uncertain ? [40] : []))
        #expect(harness.settings.reReviewDraftBaselines[target] != nil)
    }

    @Test(arguments: ["title", "description"])
    func finalReReviewDependencyCheckCannotAuthorizeAChangedSemanticContext(_ field: String) async throws {
        var armed = false
        var changed = false
        let harness = try makeHarness(assistantWorked: true, authored: true, duringAutomationCheck: { folder in
            guard armed else { return }
            armed = false
            let current = folder.text("request.json")
            let edited = current.replacingOccurrences(of: "\"title\":\"Fix\"",
                with: field == "title" ? "\"title\":\"New acceptance criteria\""
                    : "\"title\":\"Fix\",\"description\":\"New acceptance criteria\"")
            folder.write("request.json", edited)
            changed = true
        })
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.authorFeedback.isEnabled = false
        harness.settings.automation.workflowRules[.newDiscussion].mode = .off
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        await harness.monitor.refreshPendingDrafts()
        try await harness.settleVerification()
        armed = true
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()

        #expect(changed)
        #expect(harness.log("verification.log").contains("verified"))
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.settings.reReviewReceipts.values.allSatisfy { $0.requested != true && !$0.unconfirmed })
    }

    @Test(arguments: ["title", "description"])
    func manualReReviewCannotConfirmAnUndisplayedContextEdit(_ field: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.autoVerifyReReview = false
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        let item = try #require(harness.monitor.currentOpenItems.first)
        try #require(item.canConfirmReReview)
        let edited = harness.log("request.json").replacingOccurrences(of: "\"title\":\"Fix\"",
            with: field == "title" ? "\"title\":\"Changed scope\"" : "\"title\":\"Fix\",\"description\":\"New acceptance criteria\"")
        try harness.write("request.json", edited)
        await harness.monitor.confirmReReview(item.id, head: head,
            fingerprint: try #require(item.reReviewFingerprint))
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
    }


    @Test(arguments: [AssistantJobExecution.State.succeeded, .queued, .running, .blocked, .failed, .cancelled, .interrupted])
    func onlyCompletedHeadlessFeedbackStartsReReviewWithoutPublicationBaseline(state: AssistantJobExecution.State) async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        harness.settings.assistantHandoffs = [.init(id: UUID(), key: key, title: "Follow up", prompt: "", createdAt: Date(),
            allowsPush: false, feedbackNoteIDs: [40], execution: .init(state: state))]

        try await harness.poll()

        #expect(harness.log("re-review.log") == (state == .succeeded ? "requested\n" : ""))
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
    }

    @Test func legacyGUIReceiptIsNotCompletionProofForAutomaticReReview() async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
        harness.settings.assistantHandoffs = [.init(id: UUID(), key: key, title: "Legacy", prompt: "", createdAt: Date(),
            allowsPush: false, relayComplete: true, openedAt: Date(), feedbackNoteIDs: [40])]

        try await harness.poll()

        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.log("verification.log").isEmpty)
    }

    @Test func disablingVerificationWaitsForExplicitConfirmationAndRejectsChangedDiscussions() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.autoVerifyReReview = false
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.canConfirmReReview)
        #expect(harness.log("verification.log").isEmpty && harness.log("re-review.log").isEmpty)
        let fingerprint = try #require(item.reReviewFingerprint)
        let previous = harness.log("discussions.json")
        try harness.write("discussions.json", previous.replacingOccurrences(of: "Review feedback", with: "Edited feedback"))
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .changed)
        try await harness.poll()
        let current = try #require(harness.monitor.currentOpenItems.first)
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: try #require(current.reReviewFingerprint))
        #expect(harness.log("re-review.log") == "requested\n")
        await harness.monitor.confirmReReview(item.id, head: head, fingerprint: fingerprint)
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func failedVerificationIsVisibleCachedAndCanBeRetriedWithoutPublishingAnything() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("fail-verification", "yes")
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.reReviewReadiness == .failed && item.canConfirmReReview)
        #expect(harness.log("re-review.log").isEmpty)
        try await harness.poll()
        #expect(harness.log("verification.log") == "verified\n")
        harness.gitlab.remove("fail-verification")
        await harness.monitor.retryReReview(item.id)
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
    }
    @Test(arguments: ["failed", "unavailable"], [ReReviewAssessment.Note.State.addressed, .blocking])
    func aCurrentSharedAssessmentReplacesOnlyAnEmptyCachedVerifierFailure(_ failure: String, _ state: ReReviewAssessment.Note.State) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true, assessment: .init(notes: [
            .init(noteID: 40, state: state, reason: "Current source checked", summary: "The current correction needs reviewer attention.")
        ]))
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        let marker = failure == "failed" ? "fail-verification" : "unavailable-verification"
        try harness.write(marker, "yes")
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        let before = try #require(harness.monitor.currentOpenItems.first)
        #expect(before.reReviewReadiness == (failure == "failed" ? .failed : .unavailable))
        #expect(harness.log("re-review.log").isEmpty)

        harness.gitlab.remove(marker)
        try await completeSharedAuthorFeedback(harness)
        try await harness.poll()

        let current = try #require(harness.monitor.currentOpenItems.first)
        #expect(current.reReviewReadiness != .failed && current.reReviewReadiness != .unavailable)
        if state == .addressed {
            #expect(harness.log("re-review.log") == "requested\n")
            try await harness.poll()
            #expect(harness.log("re-review.log") == "requested\n")
        } else {
            guard case .blocked(let blockers) = current.reReviewReadiness else {
                Issue.record("The current semantic blocker must replace the obsolete transport failure")
                return
            }
            #expect(blockers.map(\.noteID) == [40])
            #expect(blockers.first?.summary == "The current correction needs reviewer attention.")
            #expect(harness.log("re-review.log").isEmpty)
        }
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
        #expect(harness.log("verification.log") == "verified\nverified\n")
    }

    @Test func aCatalogCommitCannotOverwriteAVerifierThatFinishedDuringItsFinalRead() async throws {
        var boundary: InMemoryGitLab?
        let harness = try makeHarness(assistantWorked: true, authored: true, reReviewGate: {
            boundary?.write("verifier-entered")
            try await boundary?.waitFor("finish-verification")
        })
        boundary = harness.gitlab
        defer { harness.cleanUp() }
        defer {
            harness.gitlab.write("finish-verification")
            harness.gitlab.write("release-catalog")
        }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try harness.write("fail-verification", "yes")
        // Start a verifier for the current row, then refresh the catalog again
        // while that existing verifier is suspended.
        harness.monitor.refresh(host: host, username: "me", todos: [])
        let firstDeadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.isLoading || !harness.gitlab.has("verifier-entered"), ContinuousClock.now < firstDeadline {
            await Task.yield()
        }
        try #require(!harness.monitor.isLoading && harness.gitlab.has("verifier-entered"))
        let displayed = try #require(harness.monitor.currentOpenItems.first)
        let finished = await harness.monitor.finishCommentReview(displayed)
        try #require(finished)
        var other = try #require(JSONSerialization.jsonObject(with: harness.gitlab.data("request.json")) as? [String: Any])
        other["iid"] = 3
        other["author"] = ["id": 9, "username": "alice", "name": "Alice"]
        other["web_url"] = "https://gitlab.example.org/g/p/-/merge_requests/3"
        let otherJSON = String(decoding: try JSONSerialization.data(withJSONObject: other), as: UTF8.self)
        try harness.write("reviewing.json", "[" + otherJSON + "]")
        let original = try #require(harness.gitlab.handler)
        harness.gitlab.handler = { request in
            if request.endpoint.hasPrefix("/projects/1/merge_requests/3/draft_notes") {
                harness.gitlab.write("catalog-paused")
                try await harness.gitlab.waitFor("release-catalog")
                return InMemoryGitLab.output("[]")
            }
            if request.endpoint.hasPrefix("/projects/1/merge_requests/3/discussions") {
                return InMemoryGitLab.output("[]")
            }
            if request.endpoint == "/projects/1/merge_requests/3" { return InMemoryGitLab.output(otherJSON) }
            return try await original(request)
        }

        harness.monitor.refresh(host: host, username: "me", todos: [])
        let deadline = ContinuousClock.now + .seconds(5)
        while !harness.gitlab.has("catalog-paused") || !harness.gitlab.has("verifier-entered"), ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(harness.gitlab.has("catalog-paused") && harness.gitlab.has("verifier-entered"))
        harness.gitlab.write("finish-verification")
        while harness.monitor.isVerifyingReReview, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!harness.monitor.isVerifyingReReview)
        harness.gitlab.write("release-catalog")
        while harness.monitor.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!harness.monitor.isLoading && !harness.monitor.hasError)

        let item = try #require(harness.monitor.currentOpenItems.first { $0.id.iid == 2 })
        #expect(item.reReviewReadiness == .failed)
        #expect(item.canConfirmReReview)
        #expect(harness.log("re-review.log").isEmpty)
    }

    @Test func sharedSemanticSuccessDoesNotHideAnUnconfirmedReviewerRequestOrRepeatItsWrite() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("fail-review-request", "yes")
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        try await harness.poll()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.settings.reReviewReceipts.values.contains { $0.unconfirmed })

        try await completeSharedAuthorFeedback(harness)
        try await harness.poll()

        let current = try #require(harness.monitor.currentOpenItems.first)
        #expect(current.reReviewUnconfirmed)
        #expect(harness.settings.reReviewReceipts.values.contains { $0.unconfirmed && $0.requested != true })
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
    }

    private func completeSharedAuthorFeedback(_ harness: Harness) async throws {
        let coordinator = try #require(harness.monitor.authorFeedbackCoordinator)
        // Finish the independent verifier without clearing or retrying the failed
        // secondary gate. The next normal poll consumes its shared result.
        coordinator.onRemoteChange = nil
        harness.settings.automation.authorFeedback.isEnabled = true
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(harness.log("request.json").utf8))
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(harness.log("discussions.json").utf8))
        coordinator.refresh(request: request, discussions: discussions, drafts: 0, host: host, user: .init(id: 3, username: "me"))
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.status(projectID: 1, iid: 2)?.phase == .checking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coordinator.status(projectID: 1, iid: 2)?.phase == .complete)
        #expect(coordinator.assessment(for: request, fingerprint: try #require(ReviewVerdict.fingerprint(discussions))) != nil)
    }

    @Test func unavailableCLIBlocksAutomaticReReviewButKeepsManualConfirmation() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("assistant-unavailable", "yes")
        try await harness.poll()
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log").isEmpty)
        let item = try #require(harness.monitor.currentOpenItems.first)
        #expect(item.reReviewReadiness == .unavailable && item.canConfirmReReview)
        await harness.monitor.confirmReReview(item.id, head: head,
                                              fingerprint: try #require(item.reReviewFingerprint))
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test(arguments: [false, true])
    func partialDiscussionReadsDoNotRebindAnOlderFeedbackSnapshot(afterPublication: Bool) async throws {
        let harness = try makeHarness(assistantWorked: false, authored: true)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        let original = #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"Original feedback","system":false,"resolvable":true,"resolved":false}]}]"#
        try harness.write("discussions.json", original)
        try await harness.poll()
        let before = try #require(harness.monitor.currentOpenItems.first)
        try #require(before.observedDiscussionFingerprint != nil)
        #expect(before.feedback.first?.body == "Original feedback")
        let edited = original.replacingOccurrences(of: "Original feedback", with: "New expectation after the snapshot")
        if afterPublication {
            try harness.write("published-discussions.json", edited)
            await harness.monitor.publishDrafts(of: before.id)
        } else {
            try harness.write("discussions.json", edited)
            await harness.monitor.refreshPendingDrafts()
        }
        let current = try #require(harness.monitor.currentOpenItems.first)
        #expect(current.feedback.first?.body == "Original feedback")
        #expect(current.observedDiscussionFingerprint == nil)
    }

    @Test func publishButtonImmediatelyRequestsEligibleReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        #expect(harness.log("re-review.log").isEmpty)
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
        #expect(harness.monitor.currentOpenItems.first?.reReviewReadiness == nil)
        try await harness.poll()
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func browserPublicationWaitsForExplicitCompletionBeforeReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("drafts.json", "[]")
        try harness.write("discussions.json", harness.log("published-discussions.json"))
        await harness.monitor.refreshPendingDrafts()
        #expect(harness.log("re-review.log").isEmpty)
        let displayed = try #require(harness.monitor.currentItems.first)
        #expect(displayed.requiresCommentReview)
        await harness.monitor.finishCommentReview(displayed)
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func publicationAndPollingDoNotDuplicateReReviewRequests() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try await harness.poll()
        try harness.write("pause-user-check", "yes")
        defer { try? harness.write("release-user-check", "") }
        let publisher = Task { await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.log("user-check.log").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!harness.log("user-check.log").isEmpty)
        try await harness.poll()
        try harness.write("release-user-check", "")
        await publisher.value
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test func automaticPublishAllLeavesNewUncheckedDraftsPrivateAndVisible() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        let checkedIDs = try #require(harness.monitor.currentItems.first).automaticDraftIDs
        #expect(checkedIDs == [11, 12])
        try harness.write("inject-unseen-draft", "yes")
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(!harness.log("selected.log").contains("/draft_notes/99/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [99])
        let writes = harness.gitlab.requests.filter { $0.method != "GET" }
        let expected = checkedIDs.sorted().map { "/projects/1/merge_requests/2/draft_notes/\($0)/publish" }
        #expect(writes.map(\.endpoint) == expected)
        #expect(writes.allSatisfy { $0.method == "PUT" })
        #expect(!harness.gitlab.requests.contains { $0.endpoint.contains("/bulk_publish") })
        #expect(harness.log("drafts.json").contains("/merge"))
    }

    @Test func automaticAIReplyPublicationImmediatelyRequestsEligibleReReview() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Fixed","discussion_id":"abc"}]"#)
        try harness.assess(noteID: 40, body: "AI finding")
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"AI finding","system":false,"resolvable":true,"resolved":false}]}]"#)
        try harness.write("published-discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8},"body":"AI finding","system":false,"resolvable":true,"resolved":false},{"id":41,"author":{"id":3},"body":"Fixed","system":false}]}]"#)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("re-review.log") == "requested\n")
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    @Test func publishAllStillPublishesSafeRepliesAlongsideUnsafeDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Handle nil here.", with: "/merge"))
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
    }

    @Test func successfulPublicationKeepsTheCheckpointWhenTheFinalReadFails() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        try prepareAuthoredFeedback(harness)
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Fixed","discussion_id":"abc"}]"#)
        try await harness.poll()
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try harness.write("fail-read-after-publish", "yes")
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("re-review.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.requiresCommentReview == true)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == nil)
        await harness.monitor.refreshPendingDrafts()
        await harness.monitor.finishCommentReview(try #require(harness.monitor.currentOpenItems.first))
        try await harness.settleVerification()
        #expect(harness.log("re-review.log") == "requested\n")
    }

    @Test(arguments: [false, true])
    func draftReplyPreviewsIdentifyOtherThreadParticipants(authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: false, authored: authored)
        defer { harness.cleanUp() }
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8,"username":"GitLabDuo"},"system":false},{"id":41,"author":{"id":3,"username":"me"},"system":false},{"id":42,"author":{"id":9,"username":"alice"},"system":false},{"id":43,"author":{"id":8,"username":"GitLabDuo"},"system":false},{"id":44,"author":{"id":10,"username":"system-bot"},"system":true}]}]"#)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.replyRecipients["abc"] == "@GitLabDuo, @alice")
        #expect(item.replyRecipients["unknown"] == nil)
    }

    @Test(arguments: [true, false]) func automaticAuthorPublicationRejectsUnverifiedLocalOnlyDrafts(publishAll: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = publishAll
        try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "The local follow-up fixes the assertion."))
        try harness.write("discussions.json", duoDiscussion)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    private func prepareIndependentPublicationReply(_ harness: Harness, authored: Bool) async throws {
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Verified reply A","discussion_id":"abc"},{"id":13,"author_id":3,"note":"Reply B needs repair","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        if authored {
            try harness.verifyFollowUpDrafts()
            try harness.assessFollowUpClaims(draftIDs: [12])
            // Keep the publication test independent of actual coder dispatch.
            harness.monitor.draftProofRecoveryCoordinator?.onNeedsRepair = nil
            harness.monitor.draftProofRecoveryCoordinator?.onChange = nil
        } else {
            try harness.recordVerdict("objections", head: head)
        }
        try await harness.poll()
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.draftProofRecoveryCoordinator?.isChecking(work: .init(host: host, projectID: 1, iid: 2)) == true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(harness.log("selected.log").isEmpty)
    }

    private func publicationWorker(_ harness: Harness, authored: Bool, state: AssistantJobExecution.State) throws -> AssistantAutomationRunner.Handoff {
        let work = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(harness.log("request.json").utf8))
        var repair: DraftReplyRepair.Context?
        if authored {
            let originURL = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: harness.folder)
            let origin = try JSONDecoder().decode(FollowUpVerification.self, from: Data(contentsOf: originURL))
            let snapshot = DraftProofRecoveryCoordinator.Snapshot(request: request,
                discussions: try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(harness.log("discussions.json").utf8)),
                drafts: try JSONDecoder().decode([GitLabDraftNote].self, from: Data(harness.log("drafts.json").utf8)),
                user: .init(id: 3, username: "me"), host: host, branchHead: head)
            repair = DraftReplyRepair.context(snapshot: snapshot, origin: origin,
                rejection: .init(draftID: 13, state: .uncertain, reason: "Reply B needs a correction"), configuration: harness.settings.automation)
            try #require(repair != nil)
        }
        return .init(id: UUID(), key: .init(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead),
            title: authored ? "Repair B" : "Review in progress", prompt: "Fixture work", createdAt: Date().addingTimeInterval(1),
            allowsPush: false, draftRepair: repair, followUpPushAllowed: authored ? true : nil,
            execution: .init(state: state), taskPrompt: "Fixture work", mergeRequestURL: request.webURL,
            workflow: authored ? .followUp : .review, expectedHeadSHA: head)
    }

    private func publicationProofIDs(_ harness: Harness) -> Set<UUID> {
        Set(FollowUpVerificationStore.publicationReceipts(work: .init(host: host, projectID: 1, iid: 2),
            username: "me", settings: harness.settings, in: harness.folder)
            .filter { $0.drafts.contains { $0.id == 12 } }.map(\.verificationID))
    }

    @Test(arguments: [(false, AutomationPublicationMode.all), (false, .aiReplies), (true, .all), (true, .aiReplies)],
          [AssistantJobExecution.State.queued, .running])
    func activeWorkPausesAutomaticPublicationWithoutRevokingIndependentProof(_ scenario: (Bool, AutomationPublicationMode),
                                                                         _ state: AssistantJobExecution.State) async throws {
        let (authored, mode) = scenario
        let harness = try makeHarness(assistantWorked: true, authored: authored, verifyDraftRecovery: { input, _, _ in
            .init(drafts: input.requestedDraftIDs.map { .init(draftID: $0, state: .uncertain, reason: "Reply B remains unverified") })
        })
        defer { harness.monitor.draftProofRecoveryCoordinator?.cancel(); harness.cleanUp() }
        harness.settings.automation.publicationMode = mode
        try await prepareIndependentPublicationReply(harness, authored: authored)
        let proofIDs = publicationProofIDs(harness)
        if authored { #expect(proofIDs.count == 1) }
        let job = try publicationWorker(harness, authored: authored, state: state)
        harness.settings.assistantHandoffs.append(job)

        try await harness.poll()

        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        if authored { #expect(publicationProofIDs(harness) == proofIDs) }
        let index = try #require(harness.settings.assistantHandoffs.firstIndex { $0.id == job.id })
        harness.settings.assistantHandoffs[index].execution?.state = .succeeded
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        if authored {
            #expect(!harness.log("selected.log").contains("/draft_notes/13/publish"))
            #expect(publicationProofIDs(harness) == proofIDs)
        }
    }

    @Test(arguments: [false, true], [AutomationPublicationMode.all, .aiReplies])
    func workStartingDuringFinalReadsStopsTheAutomaticPublish(_ authored: Bool, _ mode: AutomationPublicationMode) async throws {
        let probe = ApprovalUserReadProbe()
        probe.armed = false
        let harness = try makeHarness(assistantWorked: true, authored: authored, duringAutomationCheck: { folder in
            guard probe.armed else { return }
            probe.armed = false
            folder.write("pause-selected-read", "yes")
        }, verifyDraftRecovery: { input, _, _ in
            .init(drafts: input.requestedDraftIDs.map { .init(draftID: $0, state: .uncertain, reason: "Reply B remains unverified") })
        })
        defer { harness.monitor.draftProofRecoveryCoordinator?.cancel(); harness.cleanUp() }
        harness.settings.automation.publicationMode = mode
        try await prepareIndependentPublicationReply(harness, authored: authored)
        let proofIDs = publicationProofIDs(harness)
        let job = try publicationWorker(harness, authored: authored, state: .running)
        probe.armed = true
        let polling = Task { try await harness.poll() }
        defer { try? harness.write("release-selected-read", "yes") }
        let deadline = ContinuousClock.now + .seconds(4)
        while !harness.gitlab.has("selected-read-entered"),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(harness.gitlab.has("selected-read-entered"))
        harness.settings.assistantHandoffs.append(job)
        try harness.write("release-selected-read", "yes")
        try await polling.value

        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        if authored { #expect(publicationProofIDs(harness) == proofIDs) }
        let index = try #require(harness.settings.assistantHandoffs.firstIndex { $0.id == job.id })
        harness.settings.assistantHandoffs[index].execution?.state = .succeeded
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
    }

    @Test(arguments: ["account", "project", "iid", "host"])
    func unrelatedActiveWorkDoesNotBlockAutomaticPublication(_ difference: String) async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .aiReplies
        try await prepareIndependentPublicationReply(harness, authored: false)
        harness.settings.assistantHandoffs.append(.init(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: difference == "host" ? "other.example.org" : host,
                projectID: difference == "project" ? 99 : 1, iid: difference == "iid" ? 99 : 2),
            username: difference == "account" ? "other" : "me", workspace: "", access: .gitLabRead),
            title: "Other active work", prompt: "Fixture", createdAt: Date(), allowsPush: false,
            execution: .init(state: .running), workflow: .review))
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
    }

    @Test(arguments: [false, true])
    func activeWorkBlocksExplicitManualPublication(_ authored: Bool) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: authored, verifyDraftRecovery: { input, _, _ in
            .init(drafts: input.requestedDraftIDs.map { .init(draftID: $0, state: .uncertain, reason: "Reply B remains unverified") })
        })
        defer { harness.monitor.draftProofRecoveryCoordinator?.cancel(); harness.cleanUp() }
        harness.settings.automation.publicationMode = .manual
        try await prepareIndependentPublicationReply(harness, authored: authored)
        let job = try publicationWorker(harness, authored: authored, state: .running)
        harness.settings.assistantHandoffs.append(job)
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(harness.log("publish.log").isEmpty && harness.log("selected.log").isEmpty)
        #expect(harness.monitor.confirmationStates[.init(projectID: 1, iid: 2)] == .changed)
        let index = try #require(harness.settings.assistantHandoffs.firstIndex { $0.id == job.id })
        harness.settings.assistantHandoffs[index].execution?.state = .succeeded
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(!harness.log("selected.log").isEmpty)
    }

    @Test func aVerifiedAuthorReplyIsEligibleAndPublishesWhileAnUnverifiedSiblingStaysPrivate() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .aiReplies
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Unproven sibling","discussion_id":"abc"},{"id":12,"author_id":3,"note":"Verified sibling","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications",
            work: .init(host: host, projectID: 1, iid: 2), username: "me", in: harness.folder)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        record["drafts"] = (record["drafts"] as? [[String: Any]])?.filter { $0["id"] as? Int == 12 }
        try JSONSerialization.data(withJSONObject: record).write(to: path)
        try harness.assessFollowUpClaims(draftIDs: [12])
        try await harness.poll()
        let preview = try #require(harness.monitor.currentOpenItems.first)
        #expect(preview.awaitingRemoteVerification)
        #expect(preview.requiresDiscussionRecheck)
        #expect(preview.automaticDraftIDs == [12])
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [11])
    }

    @Test func changedHeadAutomaticallyRechecksKnownDraftsAndPublishesOnlyValidAIReplies() async throws {
        var checkedHeads: [String] = []
        let harness = try makeHarness(assistantWorked: true, authored: true, verifyDraftRecovery: { input, _, _ in
            checkedHeads.append(input.snapshot.request.sha ?? "")
            return .init(drafts: input.requestedDraftIDs.map {
                .init(draftID: $0, state: $0 == 13 ? .uncertain : .valid,
                    reason: $0 == 13 ? "Missing current evidence" : "Verified current source and tests")
            })
        })
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .aiReplies
        try harness.write("drafts.json", #"[{"id":11,"author_id":3,"note":"Verified human reply","discussion_id":"human"},{"id":12,"author_id":3,"note":"Verified AI reply","discussion_id":"abc"},{"id":13,"author_id":3,"note":"Unverified AI reply","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", #"[{"id":"abc","notes":[{"id":40,"author":{"id":8,"username":"GitLabDuo"},"body":"AI finding","system":false,"resolvable":true,"resolved":false}]},{"id":"human","notes":[{"id":41,"author":{"id":9,"username":"alice"},"body":"Human finding","system":false,"resolvable":true,"resolved":false}]}]"#)
        try harness.verifyFollowUpDrafts()
        let currentHead = String(repeating: "b", count: 40)
        for name in ["request.json", "authored.json"] {
            try harness.write(name, harness.log(name).replacingOccurrences(of: head, with: currentHead))
        }
        try harness.write("remote-head.txt", currentHead)
        try harness.write("remote-file-content.txt", "updated current source\n")
        for _ in 0..<4 {
            try await harness.poll()
            let deadline = ContinuousClock.now + .seconds(3)
            while harness.monitor.draftProofRecoveryCoordinator?.isChecking(work: .init(host: host, projectID: 1, iid: 2)) == true,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if harness.log("selected.log").contains("/draft_notes/12/publish") { break }
        }
        #expect(!checkedHeads.isEmpty && checkedHeads.allSatisfy { $0 == currentHead })
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/13/publish"))
        #expect(harness.log("publish.log").isEmpty)
        let remaining = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(harness.log("drafts.json").utf8))
        #expect(Set(remaining.compactMap(\.id)) == [11, 13])
    }

    @Test func authorFollowUpPushOffBlocksEvenPreviouslyVerifiedDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        harness.settings.automation.allowFollowUpPush = false
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == true)
        #expect(harness.monitor.currentItems.first?.draftCount == 2)
    }

    @Test func testedPushedCurrentHeadAllowsExactAuthorReplyDrafts() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").split(separator: "\n").count == 2)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 0)
    }

    private func prepareSupersededFollowUpProofs(_ harness: Harness) throws -> UUID {
        harness.settings.automation.publicationMode = .aiReplies
        let pending = #"[{"id":11,"author_id":3,"note":"Earlier human reply","discussion_id":"human"},{"id":12,"author_id":3,"note":"Earlier AI reply","discussion_id":"abc"}]"#
        let newer = #"[{"id":21,"author_id":3,"note":"Latest AI reply","discussion_id":"new-ai"},{"id":22,"author_id":3,"note":"Latest human reply","discussion_id":"new-human"}]"#
        let discussions = #"[{"id":"abc","notes":[{"id":40,"author":{"id":8,"username":"GitLabDuo"},"body":"AI finding","system":false,"resolvable":true,"resolved":false}]},{"id":"human","notes":[{"id":41,"author":{"id":9,"username":"alice"},"body":"Human finding","system":false,"resolvable":true,"resolved":false}]},{"id":"new-ai","notes":[{"id":50,"author":{"id":8,"username":"GitLabDuo"},"body":"New source finding","system":false,"resolvable":true,"resolved":false}]},{"id":"new-human","notes":[{"id":51,"author":{"id":9,"username":"alice"},"body":"New reviewer finding","system":false,"resolvable":true,"resolved":false}]}]"#
        try harness.write("discussions.json", discussions)
        try harness.write("drafts.json", pending)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        let originalRun = try #require(harness.settings.assistantHandoffs.last?.id)
        let proofURL = harness.folder.appending(path: "follow-up-verifications/gitlab.example.org/1-2-me.json")
        let proof = try JSONDecoder().decode(FollowUpVerification.self, from: Data(contentsOf: proofURL))
        let archive = harness.folder.appending(path: "follow-up-verifications-archive/gitlab.example.org/1-2-me/\(proof.verificationID.uuidString).json")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: proofURL).write(to: archive)
        try harness.write("drafts.json", newer)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        let sent = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(newer.utf8))
        ReviewVerdictStore.rememberDrafts(sent, host: host, projectID: 1, iid: 2, in: harness.folder.appending(path: "verdicts"))
        var published = try #require(JSONSerialization.jsonObject(with: Data(discussions.utf8)) as? [[String: Any]])
        for index in [2, 3] {
            var notes = try #require(published[index]["notes"] as? [[String: Any]])
            notes.append(["id": 50 + index, "author": ["id": 3, "username": "me"], "system": false,
                          "body": index == 2 ? "Latest AI reply" : "Latest human reply"])
            published[index]["notes"] = notes
        }
        try JSONSerialization.data(withJSONObject: published).store(in: harness.gitlab, as: "discussions.json")
        try harness.write("drafts.json", pending)
        return originalRun
    }

    @Test func laterSealedRepliesDoNotHideCurrentEarlierProofOrPublishHumanRepliesUnderAIOnly() async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        _ = try prepareSupersededFollowUpProofs(harness)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.requiresDiscussionRecheck == false)
        #expect(harness.monitor.currentOpenItems.first?.awaitingRemoteVerification == false)
        try await harness.poll()
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.monitor.currentOpenItems.first?.drafts.compactMap(\.id) == [11])
        #expect(harness.monitor.currentOpenItems.first?.requiresDiscussionRecheck == false)
    }

    @Test(arguments: ["aiAssisted", "uncertain", "proofPending", "noWorker"])
    func humanPostedSourcesAreAssessedWithoutAWorkerAndStayNeutralUntilClassificationFinishes(outcome: String) async throws {
        let probe = OriginProbe()
        defer { probe.finish(ai: false) }
        let harness = try makeHarness(assistantWorked: outcome != "noWorker", authored: true,
            assessAIOrigin: { _, notes, _, _, _ in await probe.assess(notes) })
        defer { harness.cleanUp() }
        harness.settings.automation.publicationMode = .aiReplies
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Verified fix","discussion_id":"human"}]"#)
        try harness.write("discussions.json", #"[{"id":"human","notes":[{"id":49,"author":{"id":9,"username":"alice"},"body":"A source comment posted by a human account.","system":false,"resolvable":true,"resolved":false}]}]"#)
        if outcome != "proofPending" && outcome != "noWorker" {
            try harness.verifyFollowUpDrafts()
            try harness.assessFollowUpClaims()
        }
        try await harness.poll(waitForAIOrigin: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.notes.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.notes.compactMap(\.id) == [49])
        let pending = try #require(harness.monitor.currentOpenItems.first)
        #expect(pending.aiOriginChecking)
        let row = MergeRequestBoardSnapshot.Row(item: pending, latestJob: harness.settings.assistantHandoffs.last, intents: [])
        #expect(!row.needsAttention)
        #expect(MRHumanAction(row: row, assistantReady: true) == nil)
        #expect(harness.log("selected.log").isEmpty)
        probe.finish(ai: outcome != "uncertain")
        try await harness.poll()
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first?.aiOriginChecking == false)
        if outcome == "aiAssisted" {
            #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        } else {
            #expect(harness.log("selected.log").isEmpty)
            #expect(harness.monitor.currentOpenItems.first?.draftCount == 1)
        }
    }

    @Test(arguments: ["unknownOrigin", "editedBody", "editedFeedback", "remoteContent"])
    func earlierProofStillNeedsItsOwnOriginExactDraftAndLiveEvidence(change: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        let originalRun = try prepareSupersededFollowUpProofs(harness)
        if change == "unknownOrigin" { harness.settings.assistantHandoffs.removeAll { $0.id == originalRun } }
        if change == "editedBody" { try harness.write("drafts.json", harness.log("drafts.json").replacingOccurrences(of: "Earlier AI reply", with: "Changed claim")) }
        if change == "editedFeedback" { try harness.write("discussions.json", harness.log("discussions.json").replacingOccurrences(of: "AI finding", with: "A new expectation")) }
        if change == "remoteContent" { try harness.write("remote-file-content.txt", "Different remote source") }
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.draftCount == 2)
    }

    @Test(arguments: ["content", "body", "head", "run", "duringProof"])
    func authorPublicationRejectsStaleOrMismatchedRemoteEvidence(change: String) async throws {
        let harness = try makeHarness(assistantWorked: true, authored: true)
        defer { harness.cleanUp() }
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims()
        if change == "content" { try harness.write("remote-file-content.txt", "old code") }
        if change == "duringProof" { try harness.write("edit-during-proof", "yes") }
        if change == "body" { try harness.write("drafts.json", draftJSON.replacingOccurrences(of: "Thanks, looks fixed.", with: "A different unsupported fix claim")) }
        if change == "head" { try harness.write("remote-head.txt", String(repeating: "b", count: 40)) }
        if change == "run" {
            var later = try #require(harness.settings.assistantHandoffs.last)
            later = .init(id: UUID(), key: later.key, title: "New unfinished run", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: true)
            harness.settings.assistantHandoffs.append(later)
        }
        try await harness.poll()
        try await harness.poll()
        let sent = harness.log("selected.log")
        if change == "body" || change == "duringProof" {
            #expect(!sent.contains("/draft_notes/12/publish"))
        } else { #expect(sent.isEmpty) }
        #expect(harness.monitor.currentItems.first?.awaitingRemoteVerification == true)
    }

    @Test func restoringAutomaticPublicationResumesOnlyEligibleAIRepliesWithoutAnotherPoll() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        harness.settings.autoPublishOptOuts.insert(target)
        harness.settings.automation.publishDraftsWithoutConfirmation = false
        harness.settings.automation.publishAIRepliesWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)

        harness.settings.autoPublishOptOuts.remove(target)
        harness.settings.save()
        await harness.monitor.resumeAutomaticAction(.commentPublication, for: target)
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.map(\.id) == [11])
    }

    @Test func restoringAutomaticApprovalRechecksAndApprovesWithoutAnotherPoll() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        harness.settings.autoApproveOptOuts.insert(target)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(harness.monitor.currentItems.first?.canApprove == true)
        harness.settings.autoApproveOptOuts.remove(target)
        harness.settings.save()
        await harness.monitor.resumeAutomaticAction(.approval, for: target)
        #expect(harness.log("approve.log").contains("sha=\(head)"))
        #expect(harness.monitor.currentItems.first?.canApprove != true)
    }

    @Test func automaticPublicationOptOutDuringFinalAsyncChecksStopsOnlyTheWrite() async throws {
        var settings: SettingsManager?
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        let harness = try makeHarness(assistantWorked: true, duringAutomationCheck: { _ in
            settings?.autoPublishOptOuts.insert(target)
        })
        defer { harness.cleanUp() }
        settings = harness.settings
        harness.settings.automation.publishDraftsWithoutConfirmation = true
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try await harness.poll()
        #expect(harness.settings.autoPublishOptOuts.contains(target))
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.count == 2)
        #expect(harness.settings.automation.publishDraftsWithoutConfirmation)
    }

    @Test func restoringAutoDuringARefreshWaitsForFreshSelectiveCompletionAndDoesNotDuplicateWrites() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        try harness.write("pause-user-check", "yes")
        defer { try? harness.write("release-user-check", "") }
        let polling = Task { try await harness.poll() }
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.log("user-check.log").isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!harness.log("user-check.log").isEmpty)
        harness.settings.autoPublishOptOuts.insert(target)
        harness.settings.autoPublishOptOuts.remove(target)
        var startedResumes = 0
        let first = Task { @MainActor in startedResumes += 1; await harness.monitor.resumeAutomaticAction(.commentPublication, for: target) }
        let second = Task { @MainActor in startedResumes += 1; await harness.monitor.resumeAutomaticAction(.commentPublication, for: target) }
        let resumeDeadline = ContinuousClock.now + .seconds(5)
        while startedResumes < 2, ContinuousClock.now < resumeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(startedResumes == 2)
        #expect(harness.monitor.isLoading && harness.log("selected.log").isEmpty)
        try harness.write("release-user-check", "")
        _ = await (first.value, second.value)
        #expect(harness.log("selected.log").split(separator: "\n").count == 1)
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(harness.log("publish.log").isEmpty)
        try await polling.value
    }

    @Test func optedOutApprovalWaitsForAutomaticReadinessButKeepsDeliberateManualApproval() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.autoApproveOptOuts.insert(.init(host: host, username: "me", projectID: 1, iid: 2))
        try harness.write("discussions.json", othersThread)
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        #expect(!harness.monitor.currentItems.contains { $0.id == .init(projectID: 1, iid: 2) && $0.needsAttention })
        #expect(harness.monitor.currentOpenItems.first?.canApprove == true)
        await harness.monitor.approve(.init(projectID: 1, iid: 2))
        #expect(harness.log("approve.log").contains("sha=\(head)"))
    }

    @Test func publicationOptOutDoesNotRestrictExplicitManualPublication() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.autoPublishOptOuts.insert(.init(host: host, username: "me", projectID: 1, iid: 2))
        try harness.write("drafts.json", draftJSON)
        try harness.recordVerdict("objections", head: head)
        try await harness.poll()
        await harness.monitor.publishDrafts(of: .init(projectID: 1, iid: 2))
        #expect(harness.log("publish.log").isEmpty && !harness.log("selected.log").isEmpty)
        #expect(harness.monitor.currentItems.first?.drafts.isEmpty != false)
    }

    @Test func restoringPublicationRechecksItsOwnStaleProofAndAutomaticallyPublishesOnlyTheEligibleAIReply() async throws {
        var verifiedHeads: [String] = []
        let harness = try makeHarness(assistantWorked: true, authored: true, verifyDraftRecovery: { input, _, _ in
            verifiedHeads.append(input.snapshot.request.sha ?? "")
            return .init(drafts: input.requestedDraftIDs.map {
                .init(draftID: $0, state: .valid, reason: "Verified this reply against the current source")
            })
        })
        defer { harness.monitor.draftProofRecoveryCoordinator?.cancel(); harness.cleanUp() }
        let target = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 2)
        harness.settings.automation.publicationMode = .aiReplies
        harness.settings.automation.allowFollowUpPush = true
        harness.settings.autoPublishOptOuts.insert(target)
        try harness.write("drafts.json", draftJSON)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        try harness.assessFollowUpClaims(draftIDs: [12])
        try await harness.poll()
        try await harness.poll()
        #expect(verifiedHeads.isEmpty && harness.log("selected.log").isEmpty)

        let currentHead = String(repeating: "b", count: 40)
        for file in ["request.json", "authored.json"] {
            try harness.write(file, harness.log(file).replacingOccurrences(of: head, with: currentHead))
        }
        try harness.write("remote-head.txt", currentHead)
        try harness.write("remote-file-content.txt", "verified updated source\n")
        harness.settings.autoPublishOptOuts.remove(target)
        harness.settings.save()

        await harness.monitor.resumeAutomaticAction(.commentPublication, for: target)
        let deadline = ContinuousClock.now + .seconds(5)
        while (!harness.log("selected.log").contains("/draft_notes/12/publish")
                || harness.monitor.currentOpenItems.first?.drafts.map(\.id) != [11]
                || harness.monitor.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(verifiedHeads == [currentHead])
        #expect(harness.log("selected.log").contains("/draft_notes/12/publish"))
        #expect(!harness.log("selected.log").contains("/draft_notes/11/publish"))
        #expect(harness.log("publish.log").isEmpty)
        #expect(harness.monitor.currentOpenItems.first?.drafts.map(\.id) == [11])
    }

    @Test func restoringApprovalForOneMRDoesNotStartAnotherMRsDraftRecoveryOrRepair() async throws {
        var assessedMRs: [Int] = []
        var repairedMRs: [Int] = []
        let harness = try makeHarness(assistantWorked: true, authored: true, verifyDraftRecovery: { input, _, _ in
            assessedMRs.append(input.snapshot.request.iid)
            return .init(drafts: input.requestedDraftIDs.map {
                .init(draftID: $0, state: .uncertain, reason: "This reply needs a separate correction")
            })
        })
        defer { harness.monitor.draftProofRecoveryCoordinator?.cancel(); harness.cleanUp() }
        let approvalTarget = MRAutomationScope.Target(host: host, username: "me", projectID: 1, iid: 3)
        harness.settings.autoApproveOptOuts.insert(approvalTarget)
        var reviewerMR = try #require(JSONSerialization.jsonObject(with: Data(harness.log("request.json").utf8)) as? [String: Any])
        reviewerMR["iid"] = 3
        reviewerMR["author"] = ["id": 9, "username": "alice", "name": "Alice"]
        reviewerMR["web_url"] = "https://gitlab.example.org/g/p/-/merge_requests/3"
        let reviewerJSON = String(decoding: try JSONSerialization.data(withJSONObject: reviewerMR), as: UTF8.self)
        try harness.write("reviewing.json", "[" + reviewerJSON + "]")
        try harness.write("request-3.json", reviewerJSON)
        let originalHandler = try #require(harness.gitlab.handler)
        harness.gitlab.handler = { request in
            switch request.endpoint {
            case "/projects/1/merge_requests/3": return try harness.gitlab.response("request-3.json")
            case let path where path.hasPrefix("/projects/1/merge_requests/3/draft_notes") || path.hasPrefix("/projects/1/merge_requests/3/discussions"):
                return InMemoryGitLab.output("[]")
            default: return try await originalHandler(request)
            }
        }
        let review = AssistantAutomationRunner.Handoff(id: UUID(),
            key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: 3), username: "me", workspace: "", access: .gitLabRead),
            title: "Completed review", prompt: "", createdAt: Date(), allowsPush: false,
            execution: .init(state: .succeeded), workflow: .review, expectedHeadSHA: head)
        harness.settings.assistantHandoffs.append(review)
        let verdict = ReviewVerdict(version: 1, host: host, projectID: 1, iid: 3, headSHA: head,
            verdict: try #require(ReviewVerdict.Kind(rawValue: "no_objections")),
            discussionFingerprint: ReviewVerdict.fingerprint([]), username: "me", userID: 3, runID: review.id)
        try AssistantJobJournal.saveWithLoadedKey(.init(result: .init(status: .succeeded, summary: "Reviewed"), output: ""),
            for: review, reviewVerdict: verdict, reviewDrafts: [])
        let verdictURL = harness.folder.appending(path: "verdicts/gitlab.example.org/1-3.json")
        try FileManager.default.createDirectory(at: verdictURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(verdict).write(to: verdictURL)
        try await harness.poll()
        #expect(harness.monitor.currentOpenItems.first { $0.id.iid == 3 }?.canApprove == true)

        // MR !2 becomes independently eligible for a recovery after the last normal poll.
        harness.settings.automation.allowFollowUpPush = true
        harness.settings.automation.authorFeedback.isEnabled = true
        try harness.write("drafts.json", #"[{"id":12,"author_id":3,"note":"Unsupported prepared reply","discussion_id":"abc"}]"#)
        try harness.write("discussions.json", duoDiscussion)
        try harness.verifyFollowUpDrafts()
        let newHead = String(repeating: "b", count: 40)
        for file in ["request.json", "authored.json"] {
            try harness.write(file, harness.log(file).replacingOccurrences(of: head, with: newHead))
        }
        try harness.write("remote-head.txt", newHead)
        harness.monitor.draftProofRecoveryCoordinator?.onChange = nil
        harness.monitor.draftProofRecoveryCoordinator?.onNeedsRepair = { snapshot, _, _ in
            repairedMRs.append(snapshot.request.iid)
            // Hold the first repair attempt so a capacity-style nil result cannot
            // be retried by another refresh before this assertion observes it.
            try await harness.gitlab.waitFor("release-repair")
            return nil
        }
        defer { harness.gitlab.write("release-repair") }
        harness.settings.autoApproveOptOuts.remove(approvalTarget)
        harness.settings.save()

        await harness.monitor.resumeAutomaticAction(.approval, for: approvalTarget)
        let unrelatedWork = AssistantAutomationRunner.MergeRequestWork(host: host, projectID: 1, iid: 2)
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.monitor.draftProofRecoveryCoordinator?.isChecking(work: unrelatedWork) == true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        #expect(harness.log("approve.log").contains("/merge_requests/3/approve"))
        #expect(assessedMRs.isEmpty && repairedMRs.isEmpty)
        #expect(harness.log("selected.log").isEmpty && harness.log("publish.log").isEmpty)

        // Normal monitoring still owns and can start the independent recovery.
        try await harness.poll()
        let normalDeadline = ContinuousClock.now + .seconds(5)
        while repairedMRs.isEmpty,
              ContinuousClock.now < normalDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(assessedMRs == [2])
        #expect(repairedMRs == [2])
        #expect(harness.monitor.draftProofRecoveryCoordinator?.isChecking(work: unrelatedWork) == true)
    }

    @Test func approvalRechecksTheLiveGitLabAccountBeforePosting() async throws {
        let harness = try makeHarness(assistantWorked: true)
        defer { harness.cleanUp() }
        harness.settings.automation.autoApproveEnabled = false
        try harness.recordVerdict("no_objections", head: head)
        try await harness.poll()
        let item = try #require(harness.monitor.currentItems.first)
        #expect(item.canApprove)
        try harness.write("live-user.json", #"{"id":9,"username":"other"}"#)
        await harness.monitor.approve(item.id)
        #expect(harness.log("approve.log").isEmpty)
        #expect(harness.monitor.confirmationStates[item.id] == .failed)
    }

}

private final class PendingDraftObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
