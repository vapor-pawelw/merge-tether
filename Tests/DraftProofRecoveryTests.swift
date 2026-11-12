import CryptoKit
import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct DraftProofRecoveryTests {
    @Test func onlyTheExactAppAuthenticatedAssessmentCanAuthorizePublication() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.publication().count == 1)
        let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recoveries",
            work: f.work, username: "me", in: f.folder).deletingPathExtension()
        let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let path = try #require(paths.first)
        let sealed = try Data(contentsOf: path)
        let payload = try #require(AssistantJobJournal.authenticatedEvidence(sealed, context: "follow-up-proof-recovery"))
        // Copying the app's payload without its authentication cannot substitute a verifier result.
        try payload.write(to: path)
        #expect(f.publication().isEmpty)
        try sealed.write(to: path)
        #expect(f.publication().count == 1)
        let envelopeObject = try JSONSerialization.jsonObject(with: sealed)
        var envelope = try #require(envelopeObject as? [String: Any])
        envelope["payload"] = Data("rewritten assessment".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: path)
        #expect(f.publication().isEmpty)
    }

    @Test func anUnsignedHistoricalAssessmentOffersVerificationRetryWithoutPromotingItsClaims() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recoveries",
            work: f.work, username: "me", in: f.folder).deletingPathExtension()
        let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let path = try #require(paths.first)
        let bytes = try Data(contentsOf: path)
        let payload = try #require(AssistantJobJournal.authenticatedEvidence(bytes, context: "follow-up-proof-recovery"))
        try payload.write(to: path)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.publication().isEmpty && restarted.failure(work: f.work) != nil)
        #expect(f.assessments == 1)
        restarted.retry(work: f.work, username: "me")
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 2 && f.publication().count == 1)
    }

    @Test(arguments: ["known", "unknown"])
    func corruptRecoveryRecordsRemainBlockedAndSurviveExplicitRetry(_ record: String) async throws {
        // given
        let f = try Fixture()
        defer { f.clean() }
        let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts",
            work: f.work, username: "me", in: f.folder).deletingPathExtension()
        var path = folder.appending(path: "unknown.json")
        if record == "known" {
            f.claimState = .invalid
            let first = f.coordinator()
            first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
            try await f.settle(first)
            path = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let raw = Data("unsupported recovery attempt".utf8)
        try raw.write(to: path)
        f.assessments = 0
        f.claimState = .valid
        let coordinator = f.coordinator()
        f.enableRepairs(coordinator)

        // when
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        coordinator.retry(work: f.work, username: "me")

        // then
        #expect(f.assessments == 0 && f.repairJobs.isEmpty && f.publication().isEmpty)
        #expect(coordinator.failure(work: f.work) != nil)
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
        #expect((try? Data(contentsOf: path)) == raw)
        #expect(!SettingsManager(defaults: f.defaults).automaticActionsAllowed)
    }

    @Test(arguments: ["beforeStart", "afterAssessment"])
    func recoveryJournalWriteFailureCannotRenewTheRetryBudget(_ phase: String) async throws {
        // given
        let f = try Fixture()
        defer { f.clean() }
        let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts",
            work: f.work, username: "me", in: f.folder).deletingPathExtension()
        if phase == "beforeStart" {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a directory".utf8).write(to: folder)
        } else {
            f.duringAssessment = {
                do {
                    try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("retained"))
                    try Data("not a directory".utf8).write(to: folder)
                } catch { Issue.record(error) }
            }
        }
        let coordinator = f.coordinator()

        // when
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        let assessments = f.assessments
        f.clock = f.clock.addingTimeInterval(3_600)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)

        // then
        #expect(assessments == (phase == "beforeStart" ? 0 : 1))
        #expect(f.assessments == assessments && f.publication().isEmpty)
        #expect(coordinator.failure(work: f.work) != nil)
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
        #expect(f.settings.persistenceDegraded.contains("draftProofRecoveryAttempts"))
        #expect(!SettingsManager(defaults: f.defaults).automaticActionsAllowed)
    }

    @Test func corruptRepairReservationCannotResetTheTwoAttemptLimit() async throws {
        // given
        let f = try Fixture()
        defer { f.clean() }
        let folder = FollowUpVerificationStore.recordURL(kind: "draft-repair-attempts", work: f.work,
            username: "me", in: f.folder).deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [URL] = []
        for reason in ["first correction", "second correction"] {
            let rejection = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 12, state: .invalid, reason: reason)
            let context = try #require(DraftReplyRepair.context(snapshot: f.snapshot, origin: f.proof,
                rejection: rejection, configuration: f.settings.automation))
            let job = AssistantAutomationRunner.Handoff(id: UUID(), key: f.settings.assistantHandoffs[0].key,
                title: "Fixture repair", prompt: "", createdAt: Date(), allowsPush: false, draftRepair: context,
                execution: .init(state: .succeeded))
            f.settings.assistantHandoffs.append(job)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context))
            let path = folder.appending(path: context.key + ".json")
            try JSONSerialization.data(withJSONObject: ["context": object, "jobID": job.id.uuidString]).write(to: path)
            paths.append(path)
        }
        let raw = Data("unsupported reservation".utf8)
        try raw.write(to: paths[0])
        var launches = 0

        // when
        let status = await DraftReplyRepair.dispatch(snapshot: f.snapshot, origin: f.proof,
            assessment: .init(drafts: [.init(draftID: 12, state: .invalid, reason: "third correction")]),
            settings: f.settings, directory: f.folder, launch: { _, _, _ in launches += 1; return UUID() })

        // then
        if case .working = status { Issue.record("Corrupt reservation cannot admit another worker") }
        #expect(launches == 0)
        #expect((try? Data(contentsOf: paths[0])) == raw)
        #expect(FileManager.default.fileExists(atPath: paths[1].path))
        #expect(f.settings.persistenceDegraded.contains("draftReplyRepairAttempts"))
    }

    @Test(arguments: ["default", "forceOn", "revoked"])
    func draftClaimRecoveryRequiresCurrentEffectivePermission(_ policy: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(draft: true)
        f.live = f.snapshot
        let target = MRAutomationScope.Target(host: f.work.host, username: "me", projectID: 1, iid: 2)
        if policy != "default" { f.settings.automation.scope.setManualChoice(.forceOn, for: target) }
        f.duringAssessment = {
            if policy == "revoked" { f.settings.automation.scope.setManualChoice(.paused, for: target) }
        }
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == (policy == "default" ? 0 : 1))
        #expect(f.publication().count == (policy == "forceOn" ? 1 : 0))
        #expect(f.live.request.draft == true)
    }

    @Test func draftReplyRepairContextUsesCurrentPolicyWithoutWaivingOwnership() throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(draft: true)
        f.live = f.snapshot
        let claim = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 12, state: .uncertain, reason: "A reply needs correction")
        #expect(!DraftReplyRepair.preparationAllowed(f.snapshot.request, configuration: f.settings.automation))
        #expect(DraftReplyRepair.context(snapshot: f.snapshot, origin: f.proof, rejection: claim, configuration: f.settings.automation) == nil)
        let target = MRAutomationScope.Target(host: f.work.host, username: "me", projectID: 1, iid: 2)
        f.settings.automation.scope.setManualChoice(.forceOn, for: target)
        #expect(DraftReplyRepair.preparationAllowed(f.snapshot.request, configuration: f.settings.automation))
        let context = try #require(DraftReplyRepair.context(snapshot: f.snapshot, origin: f.proof, rejection: claim, configuration: f.settings.automation))
        #expect(context.matches(f.snapshot, configuration: f.settings.automation))
        f.settings.automation.scope.setManualChoice(.paused, for: target)
        #expect(!context.matches(f.snapshot, configuration: f.settings.automation))
    }

    @Test(arguments: AutomationAssistant.allCases)
    func aDraftClaimProviderNeedsTheControllersExactConfiguration(_ assistant: AutomationAssistant) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(draft: true)
        let script = f.folder.appending(path: "draft-claim-cli")
        try Data("""
            #!/usr/bin/python3
            import json,sys,pathlib
            args=sys.argv[1:]
            pathlib.Path(__file__+'.started').write_text('yes')
            result={'drafts':[{'draftID':12,'state':'valid','reason':'Exact current source and reply verified.','summary':'Current proof supports this reply.'}]}
            if args[0]=='exec': json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var input = DraftProofRecoveryVerifier.Input(snapshot: f.snapshot, origin: f.proof)
        do {
            _ = try await DraftProofRecoveryVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
            Issue.record("A Draft requires the controller's explicit current policy")
        } catch DraftProofRecoveryVerifier.Failure.invalidEvidence { }
        #expect(!FileManager.default.fileExists(atPath: script.path + ".started"))
        let target = MRAutomationScope.Target(host: f.work.host, username: "me", projectID: 1, iid: 2)
        f.settings.automation.scope.setManualChoice(.forceOn, for: target)
        input.configuration = f.settings.automation
        let result = try await DraftProofRecoveryVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
        #expect(result.drafts.first?.state == .valid)
        try FileManager.default.removeItem(atPath: script.path + ".started")
        f.settings.automation.scope.setManualChoice(.paused, for: target)
        input.configuration = f.settings.automation
        do {
            _ = try await DraftProofRecoveryVerifier.run(input, assistant: assistant, model: "fixture", executable: script)
            Issue.record("Force off must block the provider before launch")
        } catch DraftProofRecoveryVerifier.Failure.invalidEvidence { }
        #expect(!FileManager.default.fileExists(atPath: script.path + ".started"))
    }

    @Test(arguments: VerificationThinking.allCases)
    func passesTheSelectedThinkingToDraftClaimVerification(_ thinking: VerificationThinking) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.automation.verificationThinking = thinking
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.verifierThinking == [thinking])
    }

    @Test func changingThinkingDoesNotSolicitAnotherOpinionOnARejectedDraft() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.automation.verificationThinking = .medium
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        f.settings.automation.verificationThinking = .high
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1)
        #expect(f.publication().isEmpty)
    }

    @Test(arguments: ["cooldown", "providerRecovered"])
    func unavailableProviderCanRecoverWithoutManuallyResettingDraftEvidence(_ recovery: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.automationAvailable = false
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 0 && coordinator.isReadOnlyFailure(work: f.work))
        f.automationAvailable = true
        coordinator.retryReadOnlyFailures(host: "other.example.org", username: "me")
        coordinator.retryReadOnlyFailures(host: f.work.host, username: "another-user")
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 0) // A different account cannot release this account's cached failure.
        if recovery == "cooldown" {
            f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        } else {
            coordinator.retryReadOnlyFailures(host: f.work.host, username: "me")
        }
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1 && f.publication().count == 1)
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
    }

    @Test func providerRecoveryDoesNotSolicitAnotherOpinionOnASemanticRejection() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        coordinator.retryReadOnlyFailures(host: f.work.host, username: "me")
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1 && f.publication().isEmpty)
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running, .blocked, .failed])
    func anExactReplyRepairDoesNotRevokeItsOriginsOtherOwnedReplies(_ state: AssistantJobExecution.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        let old = f.proof
        f.proof = .init(version: old.version, sealed: old.sealed, verificationID: old.verificationID, runID: old.runID,
            host: old.host, projectID: old.projectID, iid: old.iid, username: old.username, userID: old.userID,
            headSHA: old.headSHA, sourceProjectID: old.sourceProjectID, sourceBranch: old.sourceBranch, files: old.files,
            drafts: old.drafts + [.init(id: 14, bodySHA256: AICommentAssessmentStore.digest("Third claim"))])
        f.snapshot.drafts.append(.init(id: 14, authorID: 3, note: "Third claim", discussionID: "thread", position: nil))
        f.live = f.snapshot
        try f.persist(f.proof)
        f.settings.assistantHandoffs[0].execution = .init(state: .succeeded)
        let checkA = f.coordinator()
        checkA.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [12], configuration: f.settings.automation)
        try await f.settle(checkA)
        let verifiedA = try #require(f.publication().first { $0.drafts.map(\.id) == [12] })
        let rejectionB = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 13, state: .uncertain, reason: "B needs correction")
        let repairB = try #require(DraftReplyRepair.context(snapshot: f.snapshot, origin: f.proof,
            rejection: rejectionB, configuration: f.settings.automation))
        let origin = f.settings.assistantHandoffs[0]
        f.settings.assistantHandoffs.append(.init(id: UUID(), key: origin.key, title: "Repair B", prompt: "",
            createdAt: origin.createdAt.addingTimeInterval(1), allowsPush: false, draftRepair: repairB,
            followUpPushAllowed: true, execution: .init(state: state), workflow: .followUp, expectedHeadSHA: f.proof.headSHA))
        func origins() -> [FollowUpVerification] {
            FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder)
        }
        #expect(origins().contains(f.proof))
        #expect(f.publication().contains(verifiedA)) // Receipt evidence survives; publication admission is checked separately.
        let rejectionC = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 14, state: .uncertain, reason: "C needs correction")
        #expect(origins().contains { DraftReplyRepair.context(snapshot: f.snapshot, origin: $0,
            rejection: rejectionC, configuration: f.settings.automation) != nil })
        #expect(f.repairJobs.count == 1) // The active sibling must not launch parallel work.
        f.settings.assistantHandoffs[1].execution?.state = .failed
        f.claimState = .uncertain
        let checkC = f.coordinator()
        f.enableRepairs(checkC)
        checkC.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [14], configuration: f.settings.automation)
        try await f.waitForRepairs(2)
        #expect(f.repairJobs.last?.draftRepair?.draftID == 14)
        #expect(f.publication().contains(verifiedA))

        f.snapshot.drafts[1] = .init(id: 13, authorID: 3, note: "Edited but never sealed", discussionID: "thread", position: nil)
        f.live = f.snapshot
        #expect(!origins().contains { $0.owns(f.snapshot.drafts[1], request: f.snapshot.request, host: f.work.host, user: f.snapshot.user) })
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        #expect(!verifiedA.covers(f.snapshot.drafts[0], request: f.snapshot.request, host: f.work.host,
            user: f.snapshot.user, runID: verifiedA.runID)) // A changed source head still requires a fresh claim check.

        // A normal unfinished follow-up has broad authority and must retain its whole-origin fence.
        f.settings.assistantHandoffs[1].draftRepair = nil
        #expect(origins().isEmpty)
        #expect(f.publication().isEmpty)
    }

    @Test func currentDeliverySealRequiresIndependentClaimsBeforeAutomaticPublication() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.assistantHandoffs[0].execution = .init(state: .succeeded)
        f.proof = f.currentProof(runID: f.proof.runID, body: "Fixed")
        try f.persist(f.proof)
        #expect(!f.receipts().isEmpty) // Delivery/history remains available.
        #expect(f.publication().isEmpty)
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1 && f.publication().count == 1)
    }

    @Test func repairIsExactAndDurableWhileAnotherWorkerOrRestartCannotDuplicateIt() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        f.enableRepairs(coordinator)
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.waitForRepairs(1)
        #expect(coordinator.isChecking(work: f.work) && coordinator.failure(work: f.work) == nil)
        #expect(coordinator.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).isEmpty)
        let repair = try #require(f.repairJobs.first?.draftRepair)
        #expect(repair.draftID == 12 && repair.bodySHA256 == f.proof.drafts[0].bodySHA256)
        let restored = f.coordinator()
        f.enableRepairs(restored)
        restored.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await Task.sleep(for: .milliseconds(40))
        #expect(f.repairJobs.count == 1 && f.publication().isEmpty)
        // Clearing visible history does not remove the durable attempt reservation.
        f.settings.assistantHandoffs.removeAll { $0.draftRepair != nil }
        restored.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restored)
        #expect(f.repairJobs.isEmpty && restored.failure(work: f.work) != nil)
    }

    @Test func declinedRepairAdmissionRetriesAfterCapacityReturnsWithoutAnotherSemanticVote() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        var changes = 0
        var admissions = 0
        coordinator.onChange = { changes += 1 }
        coordinator.onNeedsRepair = { _, _, _ in admissions += 1; return nil }
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        let deadline = ContinuousClock.now + .seconds(3)
        while admissions == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(admissions == 1 && f.repairJobs.isEmpty && coordinator.isChecking(work: f.work))
        #expect(changes <= 1) // The completed claim check may refresh once; declined admission must not refresh-loop.
        f.enableRepairs(coordinator)
        while f.repairJobs.isEmpty, ContinuousClock.now < deadline {
            coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.assessments == 1 && f.repairJobs.count == 1)
    }

    @Test func aTerminalRepairOutcomeDoesNotRestartProgressAndRefreshOnEveryPoll() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        var launches = 0
        coordinator.onNeedsRepair = { _, _, _ in
            launches += 1
            throw AssistantJobExecutor.ExecutionError.missingResult
        }
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(launches == 1 && coordinator.failure(work: f.work) != nil)
        var refreshed = 0
        coordinator.onChange = { refreshed += 1 }
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        #expect(!coordinator.isChecking(work: f.work))
        try await Task.sleep(for: .milliseconds(40))
        #expect(refreshed == 0 && launches == 1 && f.assessments == 1)
    }

    @Test(arguments: ["edited", "foreign", "pushOff", "feedbackOff", "scope", "account"])
    func repairNeverAdoptsUnknownBodiesOrExpandsDisabledPermissions(_ change: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        if change == "edited" { f.snapshot.drafts = [.init(id: 12, authorID: 3, note: "User-edited wording", discussionID: "thread", position: nil)]; f.live = f.snapshot }
        if change == "foreign" { f.settings.assistantHandoffs.removeAll() }
        if change == "pushOff" { f.settings.automation.allowFollowUpPush = false }
        if change == "feedbackOff" { f.settings.automation.authorFeedback.isEnabled = false; f.settings.automation.workflowRules[.newDiscussion].mode = .off }
        if change == "scope" { f.settings.automation.scope.mode = .selected }
        if change == "account" { f.live.user = .init(id: 99, username: "other") }
        let coordinator = f.coordinator()
        f.enableRepairs(coordinator)
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.repairJobs.isEmpty && f.publication().isEmpty)
    }

    @Test func switchedProviderCanVerifyKnownHistoricalOwnershipWithoutAdoptingAnArbitraryRun() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.automation.assistant = .claude
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1 && f.publication().count == 1)
        f.settings.assistantHandoffs.removeAll()
        f.settings.assistantHandoffs = [.init(id: UUID(),
            key: .init(assistant: .claude, work: f.work, username: "me", workspace: "", access: .gitLabRead),
            title: "Unrelated provider run", prompt: "", createdAt: Date(), allowsPush: false,
            followUpPushAllowed: true, execution: .init(state: .succeeded))]
        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder).isEmpty)
    }

    @Test func rejectedProjectionIdentifiesTheOwnedReplyAndCannotFollowUserEditsOrTransportFailures() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimsOverride = [.init(draftID: 12, state: .uncertain, reason: "The asserted test is absent", summary: "This reply describes a test that was not confirmed.")]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        let rejected = try #require(coordinator.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).first)
        #expect(rejected.draftID == 12 && rejected.discussionRootNoteID == 10)
        #expect(rejected.summary == "This reply describes a test that was not confirmed.")
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
        let edited = [GitLabDraftNote(id: 12, authorID: 3, note: "User edit", discussionID: "thread", position: nil)]
        #expect(coordinator.rejectedDrafts(work: f.work, drafts: edited).isEmpty)
        coordinator.retry(work: f.work, username: "me")
        f.verifyFails = true
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(coordinator.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).isEmpty)
        #expect(coordinator.summary(work: f.work) == nil)
        #expect(coordinator.isReadOnlyFailure(work: f.work))
    }

    @Test func transientEvidenceRetriesAreBoundedAndRefreshAfterCooldownWithoutReplayingAWorker() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.verifyFailuresRemaining = 2
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 3 && f.publication().count == 1)
        #expect(!coordinator.isReadOnlyFailure(work: f.work))
        coordinator.retry(work: f.work, username: "me")
        f.verifyFails = true
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 6)
        #expect(coordinator.isReadOnlyFailure(work: f.work))
        let restored = f.coordinator()
        restored.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restored)
        #expect(f.assessments == 6)
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        f.verifyFails = false
        restored.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restored)
        #expect(f.assessments == 7 && f.repairJobs.isEmpty)
        #expect(!restored.isReadOnlyFailure(work: f.work))
    }

    @Test func transientFinalReadCannotSolicitASecondSemanticOpinion() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        f.fetchFailuresAfterAssessment = 1
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(f.publication().isEmpty && coordinator.failure(work: f.work) != nil)
    }

    @Test func restartResumesFinalEvidenceReadsWithoutRevotingARejectedClaim() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        f.fetchFailuresAfterAssessment = 100
        let interrupted = f.coordinator()
        interrupted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(interrupted)
        #expect(f.assessments == 1 && interrupted.isReadOnlyFailure(work: f.work))
        #expect(f.publication().isEmpty)
        // The semantic response is not a completed rejection until final live evidence is validated.
        #expect(interrupted.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).isEmpty)

        f.fetchFailuresAfterAssessment = 0
        f.claimState = .valid // A second model call would incorrectly turn the same claim into publication evidence.
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1 && f.publication().isEmpty)
        #expect(restarted.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).map(\.state) == [.uncertain])
        #expect(!restarted.isReadOnlyFailure(work: f.work))
    }

    @Test func restartResumesAnAuthenticatedPositiveAssessmentWithoutAnotherProviderCall() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.fetchFailuresAfterAssessment = 100
        let interrupted = f.coordinator()
        interrupted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(interrupted)
        #expect(f.assessments == 1 && interrupted.isReadOnlyFailure(work: f.work))
        #expect(f.publication().isEmpty)

        f.fetchFailuresAfterAssessment = 0
        f.verifyFails = true
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1 && f.publication().count == 1)
    }

    @Test func maximumDraftScopeWithLongLegalReasonsFitsTheJournalAndResumesWithoutAnotherProviderCall() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let drafts = (12..<112).map {
            GitLabDraftNote(id: $0, authorID: 3, note: "Fixed claim \($0)", discussionID: "thread", position: nil)
        }
        let old = f.proof
        f.proof = .init(version: old.version, sealed: old.sealed, verificationID: old.verificationID, runID: old.runID,
            host: old.host, projectID: old.projectID, iid: old.iid, username: old.username, userID: old.userID,
            headSHA: old.headSHA, sourceProjectID: old.sourceProjectID, sourceBranch: old.sourceBranch, files: old.files,
            drafts: drafts.map { .init(id: $0.id!, bodySHA256: AICommentAssessmentStore.digest($0.note!)) })
        f.snapshot.drafts = drafts
        f.live = f.snapshot
        try f.persist(f.proof)
        f.claimsOverride = drafts.map { .init(draftID: $0.id!, state: .valid, reason: String(repeating: "x", count: 1000)) }
        f.fetchFailuresAfterAssessment = 100
        let interrupted = f.coordinator()
        interrupted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(interrupted)
        #expect(f.assessments == 1 && interrupted.isReadOnlyFailure(work: f.work))
        #expect(f.publication().isEmpty)
        let pendingData = try Data(contentsOf: f.pendingAttemptPath())
        #expect(pendingData.count < 250_000)
        #expect(!f.settings.persistenceDegraded.contains("draftProofRecoveryAttempts"))

        f.fetchFailuresAfterAssessment = 0
        f.verifyFails = true
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1 && f.publication().first?.drafts.count == 100)
        #expect(!f.settings.persistenceDegraded.contains("draftProofRecoveryAttempts"))
    }

    @Test(arguments: ["unsigned", "edited", "signature", "wrongDomain"])
    func anUnauthenticatedPendingPositiveRequiresFreshVerification(tampering: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.fetchFailuresAfterAssessment = 100
        let interrupted = f.coordinator()
        interrupted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(interrupted)
        #expect(f.assessments == 1 && f.publication().isEmpty)
        try f.editPendingAssessment { pending, _ in
            switch tampering {
            case "unsigned": pending.removeValue(forKey: "authentication")
            case "edited":
                var assessment = try #require(pending["assessment"] as? [String: Any])
                var drafts = try #require(assessment["drafts"] as? [[String: Any]])
                drafts[0]["reason"] = "Rewritten positive claim"
                assessment["drafts"] = drafts
                pending["assessment"] = assessment
            default:
                let base64 = try #require(pending["authentication"] as? String)
                let sealed = try #require(Data(base64Encoded: base64))
                if tampering == "signature" {
                    let object = try JSONSerialization.jsonObject(with: sealed)
                    var envelope = try #require(object as? [String: Any])
                    envelope["signature"] = Data(repeating: 0, count: 32).base64EncodedString()
                    pending["authentication"] = try JSONSerialization.data(withJSONObject: envelope).base64EncodedString()
                } else {
                    let payload = try #require(AssistantJobJournal.authenticatedEvidence(sealed,
                        context: "draft-proof-recovery-pending-assessment-v1"))
                    pending["authentication"] = try AssistantJobJournal.sealEvidence(payload,
                        context: "follow-up-proof-recovery").base64EncodedString()
                }
            }
        }
        // Keep the historical cooldown fence even when its pending positive is untrusted.
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1 && f.publication().isEmpty)
        f.fetchFailuresAfterAssessment = 0
        f.claimState = .uncertain
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 2 && f.publication().isEmpty)
        #expect(restarted.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).map(\.state) == [.uncertain])
        #expect(!f.settings.persistenceDegraded.contains("draftProofRecoveryAttempts"))
    }

    @Test(arguments: ["host", "projectID", "iid", "username", "userID", "attemptID", "origin", "context", "drafts", "headSHA", "files"])
    func anAuthenticPendingAssessmentCannotResumeInAnotherContext(changedBinding: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.fetchFailuresAfterAssessment = 100
        let interrupted = f.coordinator()
        interrupted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(interrupted)
        #expect(f.assessments == 1 && f.publication().isEmpty)
        try f.editPendingAssessment { pending, attempt in
            let base64 = try #require(pending["authentication"] as? String)
            let sealed = try #require(Data(base64Encoded: base64))
            let payload = try #require(AssistantJobJournal.authenticatedEvidence(sealed,
                context: "draft-proof-recovery-pending-assessment-v1"))
            let origin = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.proof))
            var binding: [String: Any] = ["host": f.snapshot.host, "projectID": f.snapshot.request.projectID,
                "iid": f.snapshot.request.iid, "username": f.snapshot.user.username, "userID": f.snapshot.user.id,
                "origin": origin, "attemptID": try #require(attempt["id"]), "context": try #require(attempt["context"]),
                "assessment": try #require(pending["assessment"]), "headSHA": try #require(pending["headSHA"]),
                "files": try #require(pending["files"])]
            let original = try JSONSerialization.data(withJSONObject: binding, options: [.sortedKeys])
            #expect(payload == Data(SHA256.hash(data: original)))
            switch changedBinding {
            case "projectID", "iid", "userID": binding[changedBinding] = 99
            case "origin":
                var origin = try #require(binding["origin"] as? [String: Any])
                origin["verificationID"] = UUID().uuidString
                binding["origin"] = origin
            case "context", "drafts":
                var context = try #require(binding["context"] as? [String: Any])
                if changedBinding == "context" { context["discussionFingerprint"] = "different discussions" }
                else {
                    var drafts = try #require(context["drafts"] as? [[String: Any]])
                    drafts[0]["bodySHA256"] = AICommentAssessmentStore.digest("Another draft body")
                    context["drafts"] = drafts
                }
                binding["context"] = context
            case "files":
                var files = try #require(binding["files"] as? [[String: Any]])
                files[0]["sha256"] = AICommentAssessmentStore.digest("Another file content")
                binding["files"] = files
            default: binding[changedBinding] = "another context"
            }
            let changed = try JSONSerialization.data(withJSONObject: binding, options: [.sortedKeys])
            pending["authentication"] = try AssistantJobJournal.sealEvidence(Data(SHA256.hash(data: changed)),
                context: "draft-proof-recovery-pending-assessment-v1").base64EncodedString()
        }
        f.fetchFailuresAfterAssessment = 0
        f.claimState = .uncertain
        f.clock = f.clock.addingTimeInterval(ReadOnlyAssessmentRetry.cooldown + 1)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 2 && f.publication().isEmpty)
        #expect(restarted.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).map(\.state) == [.uncertain])
    }

    @Test func explicitManualRepairRetryPersistsItsExactPredecessorBeforeExecution() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        f.enableRepairs(coordinator)
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.waitForRepairs(1)
        let index = try #require(f.settings.assistantHandoffs.indices.last)
        f.settings.assistantHandoffs[index].execution = .init(state: .failed, blocker: "The required local check could not complete.")
        let stopped = f.settings.assistantHandoffs[index]
        let context = try #require(stopped.draftRepair)
        #expect(!coordinator.isChecking(work: f.work))
        #expect(coordinator.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).map(\.draftID) == [12])
        let jobs = AssistantJobCoordinator(execute: { job, _ in
            #expect(job.retryOf == stopped.id && job.manual == true && job.draftRepair?.key == context.key)
            return .init(result: .init(status: .succeeded, summary: "Synthetic explicit retry finished"), output: "")
        })
        let retry = try await AssistantAutomationRunner.retry(stopped.id, settings: f.settings,
            expectedHeadSHA: context.headSHA, jobCoordinator: jobs)
        #expect(try DraftReplyRepair.retryPredecessor(context, runID: retry.id, settings: f.settings) == stopped.id)
        let deadline = ContinuousClock.now + .seconds(3)
        while jobs.isWorking(on: f.work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try f.archive(f.proof)
        f.snapshot.drafts[0] = .init(id: 12, authorID: 3, note: "Honest supported correction", discussionID: "thread", position: nil)
        f.live = f.snapshot
        let proof = f.currentProof(runID: retry.id, body: "Honest supported correction")
        try f.persist(proof)
        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder).contains(proof))
        #expect(f.publication().isEmpty)
        #expect(f.settings.assistantHandoffs.first(where: { $0.id == stopped.id })?.execution?.state == .failed)
    }

    @Test(arguments: ["automatic", "active", "unrelated", "head", "role"])
    func manualRepairRetryCannotRetireAnotherOrActiveContext(_ change: String) throws {
        let f = try Fixture()
        defer { f.clean() }
        let claim = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 12, state: .uncertain, reason: "Unproven test")
        let context = try #require(DraftReplyRepair.context(snapshot: f.snapshot, origin: f.proof, rejection: claim, configuration: f.settings.automation))
        let key = f.settings.assistantHandoffs[0].key
        var stopped = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Repair", prompt: "", createdAt: Date(), allowsPush: false,
            draftRepair: context, followUpPushAllowed: true, execution: .init(state: .failed), workflow: .followUp, expectedHeadSHA: context.headSHA)
        var retry = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Retry", prompt: "", createdAt: Date(), allowsPush: false,
            draftRepair: context, followUpPushAllowed: true, execution: .init(state: .queued), workflow: .followUp,
            manual: true, expectedHeadSHA: context.headSHA, retryOf: stopped.id)
        switch change {
        case "automatic": retry.manual = false
        case "active": stopped.execution?.state = .running
        case "unrelated": retry.retryOf = UUID()
        case "head": retry.expectedHeadSHA = String(repeating: "b", count: 40)
        default: stopped.workflow = .review
        }
        f.settings.assistantHandoffs += [stopped, retry]
        #expect(throws: AssistantJobExecutor.ExecutionError.disabledPermission) {
            try DraftReplyRepair.retryPredecessor(context, runID: retry.id, settings: f.settings)
        }
    }

    @Test(arguments: [AutomationPublicationMode.aiReplies, .manual])
    func rejectedOwnedDraftReturnsToCodingPreparationWithoutGrantingPublication(_ mode: AutomationPublicationMode) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.automation.publicationMode = mode
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        var rejected: [Int] = []
        coordinator.onNeedsRepair = { snapshot, origin, assessment in
            #expect(snapshot.user == f.snapshot.user && snapshot.request.sha == f.snapshot.request.sha)
            #expect(origin == f.proof)
            rejected = assessment.drafts.filter { $0.state != .valid }.map(\.draftID)
            return nil // The launcher is busy; it performs no remote work.
        }
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        let deadline = ContinuousClock.now + .seconds(3)
        while rejected.isEmpty && coordinator.isChecking(work: f.work), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rejected == [12])
        #expect(f.receipts().isEmpty)
        #expect(f.live.drafts == f.snapshot.drafts)
    }

    @Test(arguments: ["valid", "extraID", "missingIntent", "wrongIntent", "unknownAncestor", "unfinishedAncestor"])
    func repairedSealIsQuarantinedAndCannotManufactureDraftOwnership(_ scenario: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        f.enableRepairs(coordinator)
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.waitForRepairs(1)
        let index = try #require(f.settings.assistantHandoffs.indices.last)
        f.settings.assistantHandoffs[index].execution?.state = .succeeded
        try f.archive(f.proof)
        f.snapshot.drafts[0] = .init(id: 12, authorID: 3, note: "Corrected supported facts", discussionID: "thread", position: nil)
        f.live = f.snapshot
        var repaired = f.currentProof(runID: f.settings.assistantHandoffs[index].id,
            body: "Corrected supported facts", extraID: scenario == "extraID" ? 999 : nil)
        if scenario == "missingIntent" { repaired.repairIntent = nil }
        if scenario == "wrongIntent" { repaired.repairIntent = .init(draftID: 12, bodySHA256: AICommentAssessmentStore.digest("An unexpected user's edit")) }
        if scenario == "unknownAncestor" {
            let archive = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: f.work, username: "me", in: f.folder).deletingPathExtension()
            try FileManager.default.removeItem(at: archive)
        }
        if scenario == "unfinishedAncestor" {
            let origin = f.settings.assistantHandoffs[0]
            f.settings.assistantHandoffs.append(.init(id: UUID(), key: origin.key, title: "Unfinished intervening work", prompt: "",
                createdAt: origin.createdAt.addingTimeInterval(0.000001), allowsPush: false, followUpPushAllowed: true,
                execution: .init(state: .failed)))
        }
        try f.persist(repaired)
        #expect(f.publication().isEmpty)
        let origins = FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder)
        #expect(origins.contains(repaired) == (scenario == "valid"))
        if scenario == "valid" {
            f.claimState = .valid
            let check = f.coordinator()
            check.schedule(snapshot: f.snapshot, origin: repaired, configuration: f.settings.automation)
            try await f.settle(check)
            #expect(f.publication().contains { $0.runID == repaired.runID && $0.drafts.map(\.id) == [12] })
        }
    }

    @Test func selfEditedRepliesCannotResetTheBoundedRepairLineage() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.claimState = .uncertain
        var origin = f.proof
        for attempt in 1...2 {
            let coordinator = f.coordinator()
            f.enableRepairs(coordinator)
            coordinator.schedule(snapshot: f.snapshot, origin: origin, configuration: f.settings.automation)
            try await f.waitForRepairs(attempt)
            let index = try #require(f.settings.assistantHandoffs.indices.last)
            f.settings.assistantHandoffs[index].execution?.state = .succeeded
            try f.archive(origin)
            let body = "Still unsupported wording revision \(attempt)"
            f.snapshot.drafts[0] = .init(id: 12, authorID: 3, note: body, discussionID: "thread", position: nil)
            f.live = f.snapshot
            origin = f.currentProof(runID: f.settings.assistantHandoffs[index].id, body: body)
            try f.persist(origin)
        }
        let final = f.coordinator()
        f.enableRepairs(final)
        final.schedule(snapshot: f.snapshot, origin: origin, configuration: f.settings.automation)
        try await f.settle(final)
        #expect(f.repairJobs.count == 2 && final.failure(work: f.work) != nil)
        #expect(final.rejectedDrafts(work: f.work, drafts: f.snapshot.drafts).map(\.draftID) == [12])
        #expect(f.publication().isEmpty)
    }

    @Test func aMisnamedArchiveCannotEstablishHistoricalDraftOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = fixture.proof
        let unrelated = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: original.runID,
            host: original.host, projectID: original.projectID, iid: original.iid, username: original.username,
            userID: original.userID, headSHA: original.headSHA, sourceProjectID: original.sourceProjectID,
            sourceBranch: original.sourceBranch, files: original.files,
            drafts: [.init(id: 999, bodySHA256: AICommentAssessmentStore.digest("User-created draft"))])
        let archive = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: fixture.work,
            username: "me", in: fixture.folder).deletingPathExtension()
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try JSONEncoder().encode(unrelated).write(to: archive.appending(path: "unrelated.json"))
        let origins = FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder)
        #expect(origins == [original])
    }

    @Test(arguments: [DraftProofRecoveryVerifier.Assessment.State.valid, .uncertain, .invalid])
    func aBlockedWorkerWithSealedRepliesCanReachIndependentVerification(_ verdict: DraftProofRecoveryVerifier.Assessment.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.assistantHandoffs[0].execution = .init(state: .blocked, blocker: "The response remains private.")
        f.proof = f.currentProof(runID: f.proof.runID, body: "Fixed")
        try f.persist(f.proof)
        f.claimState = verdict
        let origins = FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder)
        let origin = try #require(origins.first)
        #expect(f.publication().isEmpty)
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: origin, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(f.publication().isEmpty == (verdict != .valid))
        #expect(f.settings.assistantHandoffs[0].execution?.state == .blocked)
    }

    @Test(arguments: ["same", "head", "branch", "account", "provider"])
    func aLaterSealedBlockedReplyDoesNotStrandOtherRepliesAtTheSameSourceHead(_ change: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        let earlier = f.settings.assistantHandoffs[0]
        f.settings.assistantHandoffs[0].execution = .init(state: .blocked)
        let earlierProof = f.currentProof(runID: earlier.id, body: "Fixed")
        try f.archive(earlierProof)
        let laterKey = AssistantAutomationRunner.ChatKey(assistant: change == "provider" ? .claude : earlier.key.assistant,
            work: earlier.key.work, username: earlier.key.username, workspace: earlier.key.workspace, access: earlier.key.access)
        let later = AssistantAutomationRunner.Handoff(id: UUID(), key: laterKey, title: "Another sealed response", prompt: "",
            createdAt: earlier.createdAt.addingTimeInterval(1), allowsPush: false, followUpPushAllowed: true,
            execution: .init(state: .blocked), workflow: .followUp)
        f.settings.assistantHandoffs.append(later)
        let laterProof = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: later.id,
            host: earlierProof.host, projectID: earlierProof.projectID, iid: earlierProof.iid,
            username: earlierProof.username, userID: change == "account" ? 99 : earlierProof.userID,
            headSHA: change == "head" ? String(repeating: "b", count: 40) : earlierProof.headSHA,
            sourceProjectID: earlierProof.sourceProjectID, sourceBranch: change == "branch" ? "other" : earlierProof.sourceBranch,
            files: earlierProof.files, drafts: [.init(id: 13, bodySHA256: AICommentAssessmentStore.digest("Another claim"))],
            discussionFingerprint: earlierProof.discussionFingerprint)
        try f.persist(laterProof)
        let origins = FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder)
        if change != "same" {
            #expect(!origins.contains(earlierProof))
            return
        }
        #expect(Set(origins.map(\.runID)) == [earlier.id, later.id])
        let coordinator = f.coordinator()
        for origin in origins {
            coordinator.schedule(snapshot: f.snapshot, origin: origin, configuration: f.settings.automation)
            try await f.settle(coordinator)
        }
        #expect(Set(f.publication().flatMap { $0.drafts.map(\.id) }) == [12, 13])
        #expect(f.settings.assistantHandoffs.allSatisfy { $0.execution?.state == .blocked })
    }

    @Test(arguments: ["missing", "unsealed", "fingerprint", "failed", "active"])
    func aStoppedResultWithoutACompletedSealCannotEstablishReplyOwnership(_ change: String) throws {
        let f = try Fixture()
        defer { f.clean() }
        f.settings.assistantHandoffs[0].execution = .init(state: change == "failed" ? .failed : change == "active" ? .running : .blocked)
        var proof = f.currentProof(runID: f.proof.runID, body: "Fixed")
        if change == "fingerprint" { proof.discussionFingerprint = nil }
        try f.persist(proof)
        let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: f.work, username: "me", in: f.folder)
        if change == "missing" { try FileManager.default.removeItem(at: path) }
        if change == "unsealed" {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            json["sealed"] = false
            try JSONSerialization.data(withJSONObject: json).write(to: path)
        }
        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder).isEmpty)
    }

    @Test func sealedHistoricalDraftOwnershipCanBeReverifiedWithoutRewritingItsLegacyJob() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let origins = FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder)
        #expect(origins == [fixture.proof])
        #expect(fixture.settings.assistantHandoffs.first?.execution == nil)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
    }

    @Test func unknownOriginAndNewerUnfinishedRunCannotBeRecovered() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = fixture.settings.assistantHandoffs.removeFirst()
        #expect(FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
        fixture.settings.assistantHandoffs = [original, .init(id: UUID(), key: original.key, title: "Newer follow-up", prompt: "", createdAt: original.createdAt.addingTimeInterval(1), allowsPush: false, followUpPushAllowed: true, execution: .init(state: .failed))]
        #expect(FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
    }

    @Test func aCachedRejectedClaimRetainsHumanCopySeparatelyFromItsDiagnostic() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let diagnostic = "Current account and source snapshot match, but the reported regression has no test evidence."
        let summary = "The test described in this reply could not be confirmed. Check the reply before publishing."
        f.claimsOverride = [.init(draftID: 12, state: .uncertain, reason: diagnostic, summary: summary)]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(coordinator.failure(work: f.work) == diagnostic)
        #expect(coordinator.summary(work: f.work) == summary)
        let restored = f.coordinator()
        restored.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(restored)
        #expect(f.assessments == 1)
        #expect(restored.summary(work: f.work) == summary)
        #expect(f.receipts().isEmpty)
    }

    @Test func freshClaimAndRemoteContentAssessmentProducesSeparateCurrentProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 1)
        let proofs = FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder)
        let recovered = try #require(proofs.first)
        #expect(recovered.runID == fixture.proof.runID)
        #expect(recovered.verificationID != fixture.proof.verificationID)
        #expect(recovered.discussionFingerprint == ReviewVerdict.fingerprint(fixture.snapshot.discussions))
        #expect(recovered.drafts == fixture.proof.drafts)
        #expect(fixture.settings.assistantHandoffs.first?.execution == nil)
        #expect(FollowUpVerificationStore.receipt(work: fixture.work, username: "me", in: fixture.folder) == fixture.proof)
    }

    @Test(arguments: ["unknown", "edited", "deleted", "account", "head", "context", "files", "invalid", "uncertain", "quickAction", "resolve"])
    func unsafeOrUnprovenDraftsNeverGainFreshProof(_ change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        if change == "unknown" { fixture.snapshot.drafts = [.init(id: 999, authorID: 3, note: "Fixed", discussionID: "thread", position: nil)] }
        if change == "edited" { fixture.snapshot.drafts = [.init(id: 12, authorID: 3, note: "Changed claim", discussionID: "thread", position: nil)] }
        if change == "deleted" { fixture.snapshot.drafts = [] }
        if change == "account" { fixture.live.user = .init(id: 4, username: "other") }
        if change == "head" { fixture.live.request = try fixture.request(head: String(repeating: "b", count: 40)) }
        if change == "context" { fixture.live.request = try fixture.request(title: "New requirement") }
        if change == "files" { fixture.remoteHash = AICommentAssessmentStore.digest("wrong source") }
        if change == "invalid" { fixture.claimState = .invalid }
        if change == "uncertain" { fixture.claimState = .uncertain }
        if change == "quickAction" || change == "resolve" {
            fixture.snapshot.drafts = [.init(id: 12, authorID: 3, note: change == "quickAction" ? "Fixed\n/merge" : "Fixed", discussionID: "thread", resolveDiscussion: change == "resolve", position: nil)]
        }
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
    }

    @Test func retargetingAtTheSameSourceHeadInvalidatesRecoveredProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let recovered = try #require(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).first)
        for changed in [try fixture.request(targetBranch: "other-target"), try fixture.request(targetProjectID: 9)] {
            #expect(!recovered.covers(fixture.snapshot.drafts[0], request: changed, host: fixture.work.host, user: fixture.snapshot.user, runID: recovered.runID))
        }
    }

    @Test(arguments: ["account", "head", "context", "body", "targetBranch", "targetProject"])
    func changesDuringClaimAssessmentCannotSealFreshProof(_ change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.duringAssessment = {
            do {
                switch change {
                case "account": fixture.live.user = .init(id: 4, username: "other")
                case "head": fixture.live.request = try fixture.request(head: String(repeating: "b", count: 40))
                case "context": fixture.live.request = try fixture.request(title: "New acceptance criteria")
                case "body": fixture.live.drafts = [.init(id: 12, authorID: 3, note: "Edited during verification", discussionID: "thread", position: nil)]
                case "targetBranch": fixture.live.request = try fixture.request(targetBranch: "other-target")
                default: fixture.live.request = try fixture.request(targetProjectID: 9)
                }
            } catch { Issue.record(error) }
        }
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 1)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
        #expect(coordinator.failure(work: fixture.work) != nil)
    }

    @Test(arguments: ["missing", "duplicate", "unknown"])
    func malformedClaimCoverageCannotCreatePublicationProof(_ malformed: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let claim = DraftProofRecoveryVerifier.Assessment.Draft(draftID: 12, state: .valid, reason: "Checked source and test")
        fixture.claimsOverride = malformed == "missing" ? [] : malformed == "duplicate" ? [claim, claim]
            : [.init(draftID: 999, state: .valid, reason: "Unrequested ID")]
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 3)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
        #expect(coordinator.failure(work: fixture.work) != nil)
    }

    @Test func recoveryPresentationIsBoundToCurrentMetadataDiscussionAndPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.claimState = .uncertain
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let fingerprint = try #require(ReviewVerdict.fingerprint(fixture.snapshot.discussions))
        #expect(coordinator.failure(work: fixture.work) != nil)
        #expect(coordinator.presentationIsCurrent(request: fixture.snapshot.request, host: fixture.work.host,
            fingerprint: fingerprint, configuration: fixture.settings.automation))
        #expect(!coordinator.presentationIsCurrent(request: try fixture.request(title: "New criteria"), host: fixture.work.host,
            fingerprint: fingerprint, configuration: fixture.settings.automation))
        #expect(!coordinator.presentationIsCurrent(request: fixture.snapshot.request, host: fixture.work.host,
            fingerprint: String(repeating: "c", count: 64), configuration: fixture.settings.automation))
        var changed = fixture.settings.automation
        changed.publicationMode = .manual
        #expect(!coordinator.presentationIsCurrent(request: fixture.snapshot.request, host: fixture.work.host,
            fingerprint: fingerprint, configuration: changed))
    }

    @Test func multiplePendingOriginsFinishOneAtATimeWithoutCancellingEachOther() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let other = fixture.proof
        let second = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: other.runID,
            host: other.host, projectID: other.projectID, iid: other.iid, username: other.username, userID: other.userID,
            headSHA: other.headSHA, sourceProjectID: other.sourceProjectID, sourceBranch: other.sourceBranch,
            files: other.files, drafts: [.init(id: 13, bodySHA256: AICommentAssessmentStore.digest("Another fixed concern"))])
        let archive = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: fixture.work, username: "me", in: fixture.folder).deletingPathExtension()
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try JSONEncoder().encode(second).write(to: archive.appending(path: "\(second.verificationID.uuidString).json"))
        fixture.snapshot.drafts.append(.init(id: 13, authorID: 3, note: "Another fixed concern", discussionID: "thread", position: nil))
        fixture.live = fixture.snapshot
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        coordinator.schedule(snapshot: fixture.snapshot, origin: second, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let first = FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder)
        #expect(first.contains { $0.drafts == fixture.proof.drafts })
        coordinator.schedule(snapshot: fixture.snapshot, origin: second, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let final = FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder)
        #expect(Set(final.flatMap(\.drafts).map(\.id)) == [12, 13])
        #expect(fixture.assessments == 2)
    }

    @Test func explicitSuccessfulEnvironmentReplacementAllowsFreshRecoveryWithoutTrustingTheOldProof() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let origin = fixture.settings.assistantHandoffs[0]
        let blocked = AssistantAutomationRunner.Handoff(id: UUID(), key: origin.key, title: "Blocked follow-up", prompt: "", createdAt: origin.createdAt.addingTimeInterval(1), allowsPush: false, followUpPushAllowed: true, execution: .init(state: .blocked), environmentRecoveryAttempted: true, expectedHeadSHA: fixture.proof.headSHA)
        let replacement = AssistantAutomationRunner.Handoff(id: UUID(), key: origin.key, title: "Environment recovery", prompt: "", createdAt: origin.createdAt.addingTimeInterval(2), allowsPush: false, followUpPushAllowed: true, execution: .init(state: .succeeded), environmentRecoveryOf: blocked.id, expectedHeadSHA: fixture.proof.headSHA)
        fixture.settings.assistantHandoffs += [blocked, replacement]
        #expect(FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).contains(fixture.proof))
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 1)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).count == 1)
        #expect(fixture.settings.assistantHandoffs.first { $0.id == blocked.id }?.execution?.state == .blocked)
    }

    @Test(arguments: ["unrelated", "head", "account", "failed", "active"])
    func arbitraryOrIncompleteLaterSuccessCannotSupersedeAStoppedRun(_ change: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let origin = fixture.settings.assistantHandoffs[0]
        let blocked = AssistantAutomationRunner.Handoff(id: UUID(), key: origin.key, title: "Blocked", prompt: "", createdAt: origin.createdAt.addingTimeInterval(1), allowsPush: false, followUpPushAllowed: true, execution: .init(state: .blocked), environmentRecoveryAttempted: true, expectedHeadSHA: fixture.proof.headSHA)
        let key = change == "account" ? AssistantAutomationRunner.ChatKey(assistant: .codex, work: fixture.work, username: "other", workspace: "", access: .gitLabRead) : origin.key
        let replacement = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Later task", prompt: "", createdAt: origin.createdAt.addingTimeInterval(2), allowsPush: false, followUpPushAllowed: true,
            execution: .init(state: change == "failed" ? .failed : change == "active" ? .running : .succeeded),
            environmentRecoveryOf: change == "unrelated" ? nil : blocked.id,
            expectedHeadSHA: change == "head" ? String(repeating: "b", count: 40) : fixture.proof.headSHA)
        fixture.settings.assistantHandoffs += [blocked, replacement]
        #expect(FollowUpVerificationStore.recoveryOrigins(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
    }

    @Test(arguments: [DraftProofRecoveryVerifier.Assessment.State.valid, .uncertain])
    func aSuccessfulExplicitManualRetryOnlyUnlocksFreshIndependentClaimVerification(_ claim: DraftProofRecoveryVerifier.Assessment.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let (stopped, replacement) = f.addManualRetry()
        // Neither the retry's success nor the historical source hashes establish
        // truth at a later head. The ordinary read-only verifier must check it.
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        f.remoteHash = AICommentAssessmentStore.digest("current source and regression tests")
        f.claimState = claim

        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder) == [f.proof])
        #expect(f.receipts().isEmpty)
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)

        #expect(f.assessments == 1)
        #expect(f.receipts().isEmpty == (claim != .valid))
        if claim == .valid {
            let recovered = try #require(f.receipts().first)
            #expect(recovered.headSHA == f.snapshot.request.sha)
            #expect(recovered.files == [.init(path: "Sources/Fixed.swift", sha256: f.remoteHash)])
        }
        #expect(f.settings.assistantHandoffs.count == 3)
        #expect(f.settings.assistantHandoffs.first { $0.id == stopped.id }?.execution?.state == .blocked)
        #expect(f.settings.assistantHandoffs.first { $0.id == replacement.id }?.execution?.state == .succeeded)
        #expect(f.snapshot.drafts.map(\.note) == ["Fixed"])
    }

    @Test(arguments: ["noLink", "wrongOld", "automaticEvent", "failedEvent", "eventTarget", "task", "notes", "emptyNotes", "head", "key", "workflow", "url", "permissions", "failed", "active", "cancelled", "unknown", "newerFailure"])
    func aManualRetryCannotHideAnUnrelatedOrUnfinishedSupersedingTask(_ change: String) throws {
        let f = try Fixture()
        defer { f.clean() }
        var (stopped, replacement) = f.addManualRetry()
        switch change {
        case "noLink": f.settings.automationEvents = []
        case "wrongOld": f.settings.automationEvents[0].relatedJobID = UUID()
        case "automaticEvent", "failedEvent", "eventTarget":
            f.settings.automationEvents = []
            f.settings.recordAutomationEvent(target: .init(host: f.work.host, username: change == "eventTarget" ? "other" : "me", projectID: 1, iid: 2),
                action: .retry, origin: change == "automaticEvent" ? .automatic : .manual,
                state: change == "failedEvent" ? .failed : .queued, jobID: replacement.id, relatedJobID: stopped.id)
        case "task": replacement.taskPrompt = "A different task"
        case "notes": replacement.feedbackNoteIDs = [999]
        case "emptyNotes": stopped.feedbackNoteIDs = []; replacement.feedbackNoteIDs = []
        case "head": replacement.expectedHeadSHA = String(repeating: "b", count: 40)
        case "key":
            replacement = .init(id: replacement.id,
                key: .init(assistant: .claude, work: f.work, username: "me", workspace: "", access: .gitLabRead),
                title: replacement.title, prompt: replacement.prompt, createdAt: replacement.createdAt,
                allowsPush: replacement.allowsPush, feedbackNoteIDs: replacement.feedbackNoteIDs,
                followUpPushAllowed: true, execution: replacement.execution, taskPrompt: replacement.taskPrompt,
                mergeRequestURL: replacement.mergeRequestURL, workflow: .followUp, manual: true, expectedHeadSHA: replacement.expectedHeadSHA)
        case "workflow": replacement.workflow = .review
        case "url": replacement.mergeRequestURL = URL(string: "https://gitlab.example.org/group/other/-/merge_requests/2")
        case "permissions": replacement.followUpPushAllowed = false
        case "failed": replacement.execution?.state = .failed
        case "active": replacement.execution?.state = .running
        case "cancelled": replacement.execution?.state = .cancelled
        case "unknown": replacement.execution = nil
        default: break
        }
        f.settings.assistantHandoffs = [f.settings.assistantHandoffs[0], stopped, replacement]
        if change == "newerFailure" {
            f.settings.assistantHandoffs.append(.init(id: UUID(), key: stopped.key, title: "Newer relevant failure", prompt: "",
                createdAt: replacement.createdAt.addingTimeInterval(1), allowsPush: false, feedbackNoteIDs: [10],
                followUpPushAllowed: true, execution: .init(state: .failed)))
        }
        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder).isEmpty)
        #expect(f.receipts().isEmpty)
    }

    @Test func evenAnExactSuccessfulManualRetryCannotAdoptAUserEditedDraft() async throws {
        let f = try Fixture()
        defer { f.clean() }
        _ = f.addManualRetry()
        let original = f.snapshot.drafts[0]
        f.snapshot.drafts[0] = .init(id: original.id, authorID: original.authorID, note: "User edited this reply",
            discussionID: original.discussionID, position: original.position)
        f.live = f.snapshot
        #expect(FollowUpVerificationStore.recoveryOrigins(work: f.work, username: "me", settings: f.settings, in: f.folder) == [f.proof])
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 0 && f.receipts().isEmpty)
        #expect(f.snapshot.drafts[0].note == "User edited this reply")
    }

    @Test func failedAttemptIsBoundedAcrossPollsAndRestartsButNewContextGetsOneAssessment() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.claimState = .uncertain
        let first = fixture.coordinator()
        first.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(first)
        first.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(first)
        let restarted = fixture.coordinator()
        restarted.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(restarted)
        #expect(fixture.assessments == 1)
        fixture.snapshot.request = try fixture.request(title: "Updated acceptance criteria")
        fixture.live = fixture.snapshot
        restarted.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(restarted)
        #expect(fixture.assessments == 2)
    }

    @Test(arguments: [true, false])
    func eachProofAttemptRecordsOneQueuedAndOneTerminalAuditEvent(_ valid: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.claimState = valid ? .valid : .uncertain
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let restarted = fixture.coordinator()
        restarted.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(restarted)
        let events = fixture.settings.automationEvents.filter { $0.action == .verification && $0.origin == .automatic }
        #expect(events.count == 2)
        #expect(events.filter { $0.state == .queued }.count == 1)
        #expect(events.filter { $0.state == (valid ? .completed : .failed) }.count == 1)
        let target = MRAutomationScope.Target(host: fixture.work.host, username: "me", projectID: 1, iid: 2)
        #expect(events.allSatisfy { $0.target == target && $0.jobID == fixture.proof.runID && $0.message?.isEmpty == false })
        #expect(fixture.assessments == 1)
    }

    @Test func explicitRetryAddsOneManualAuditEventBeforeANewBoundedAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        fixture.claimState = .uncertain
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        coordinator.retry(work: fixture.work, username: "me")
        fixture.claimState = .valid
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let manual = fixture.settings.automationEvents.filter { $0.action == .verification && $0.origin == .manual }
        #expect(manual.count == 1)
        #expect(manual.first?.state == .requested)
        #expect(manual.first?.target == .init(host: fixture.work.host, username: "me", projectID: 1, iid: 2))
        let automatic = fixture.settings.automationEvents.filter { $0.action == .verification && $0.origin == .automatic }
        #expect(automatic.filter { $0.state == .queued }.count == 2)
        #expect(automatic.filter { $0.state == .failed }.count == 1)
        #expect(automatic.filter { $0.state == .completed }.count == 1)
        #expect(fixture.assessments == 2)
    }

    @Test func aRefreshedSiblingDoesNotPreventRecoveryOfAnUntouchedKnownDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.addSibling()
        fixture.snapshot.drafts[0] = .init(id: 12, authorID: 3, note: "Refreshed by a newer verified run", discussionID: "thread", position: nil)
        fixture.live = fixture.snapshot
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, draftIDs: [13], configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 1)
        let proof = try #require(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).first)
        #expect(proof.drafts.map(\.id) == [13])
        #expect(proof.runID == fixture.proof.runID)
        let directory = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recoveries", work: fixture.work, username: "me", in: fixture.folder).deletingPathExtension()
        let path = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: path)
        let payload = try #require(AssistantJobJournal.authenticatedEvidence(bytes, context: "follow-up-proof-recovery"))
        let record = try JSONDecoder().decode(FollowUpVerificationStore.RecoveryRecord.self, from: payload)
        #expect(record.origin == fixture.proof)
        #expect(record.requestedDraftIDs == [13])
    }

    @Test func aValidClaimGainsItsOwnProofWhileAnUncertainSiblingStaysPrivate() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.addSibling()
        fixture.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Current source and tests establish this claim."),
            .init(draftID: 13, state: .uncertain, reason: "Independent test evidence is unavailable.")]
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        let proof = try #require(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).first)
        #expect(proof.drafts.map(\.id) == [12])
        #expect(proof.covers(fixture.snapshot.drafts[0], request: fixture.snapshot.request, host: fixture.work.host, user: fixture.snapshot.user, runID: proof.runID))
        #expect(!proof.covers(fixture.snapshot.drafts[1], request: fixture.snapshot.request, host: fixture.work.host, user: fixture.snapshot.user, runID: proof.runID))
        #expect(coordinator.failure(work: fixture.work) != nil)
        #expect(fixture.settings.automationEvents.contains { $0.action == .verification && $0.state == .blocked })
    }

    @Test(arguments: ["unknown", "edited", "empty", "duplicate"])
    func explicitRecoveryScopeCannotAdoptUnknownOrChangedDrafts(_ change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        if change == "edited" { fixture.snapshot.drafts[0] = .init(id: 12, authorID: 3, note: "Edited", discussionID: "thread", position: nil) }
        let ids = change == "unknown" ? [999] : change == "empty" ? [] : change == "duplicate" ? [12, 12] : [12]
        let coordinator = fixture.coordinator()
        coordinator.schedule(snapshot: fixture.snapshot, origin: fixture.proof, draftIDs: ids, configuration: fixture.settings.automation)
        try await fixture.settle(coordinator)
        #expect(fixture.assessments == 0)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).isEmpty)
    }

    @Test(arguments: [false, true])
    func oldFullRecoveryRecordsRemainValidButAnUnknownExplicitScopeDoesNot(_ unknownScope: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let id = UUID(), fingerprint = try #require(ReviewVerdict.fingerprint(fixture.snapshot.discussions))
        let proof = FollowUpVerificationStore.recoveredProof(origin: fixture.proof, assessmentID: id, fingerprint: fingerprint,
            semanticContext: fixture.snapshot.request.semanticContextFingerprint, recoveryContext: fixture.snapshot.request.draftProofRecoveryContextFingerprint)
        let record = FollowUpVerificationStore.RecoveryRecord(version: 1, attemptID: String(repeating: "e", count: 64),
            assessmentID: id, assistant: .codex, model: fixture.settings.automation.codexVerificationModel.rawValue,
            origin: fixture.proof, proof: proof,
            assessment: .init(drafts: [.init(draftID: 12, state: .valid, reason: "Verified legacy result.")]),
            requestedDraftIDs: unknownScope ? [999] : nil)
        try FollowUpVerificationStore.persistRecovery(record, work: fixture.work, username: "me", in: fixture.folder)
        #expect(FollowUpVerificationStore.contextReceipts(work: fixture.work, username: "me", settings: fixture.settings, in: fixture.folder).count == (unknownScope ? 0 : 1))
    }

    @Test(arguments: [DraftProofRecoveryVerifier.Assessment.State.invalid, .uncertain])
    func rejectedDraftCannotGainAnotherAutomaticChanceWhenTheScopeShrinks(_ state: DraftProofRecoveryVerifier.Assessment.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Proven A"), .init(draftID: 13, state: state, reason: "B remains unproved")]
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "A stochastic second answer must not be requested")]
        first.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(first)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1)
        #expect(!f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
        #expect(restarted.failure(work: f.work) != nil)
    }

    @Test(arguments: [false, true])
    func rejectedOrFailedAttemptsWithoutARecoveryRecordFenceEachDraftAcrossScopeChanges(_ failure: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.verifyFails = failure
        f.claimState = .invalid
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        #expect(f.receipts().isEmpty)
        f.verifyFails = false
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "Should not be asked twice")]
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == (failure ? 3 : 1))
        #expect(f.receipts().isEmpty)
    }

    @Test func publishingAKnownValidSiblingDoesNotReopenTheRejectedVerdict() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        ReviewVerdictStore.rememberDrafts(f.snapshot.drafts, host: f.work.host, projectID: 1, iid: 2, in: f.folder.appending(path: "verdicts"))
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Proven A"), .init(draftID: 13, state: .uncertain, reason: "Unproved B")]
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        f.publishKnownA()
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "Must not get a second chance from our publication")]
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1)
        #expect(!f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
        #expect(restarted.failure(work: f.work) != nil)
    }

    @Test(arguments: ["discussion", "ci", "model"])
    func meaningfulNewClaimEvidencePermitsOneNewAssessment(_ change: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        try f.setPipeline(status: "running")
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Proven A"), .init(draftID: 13, state: .uncertain, reason: "Await independent evidence")]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        if change == "discussion" {
            f.snapshot.discussions = [.init(id: "thread", notes: f.snapshot.discussions[0].notes + [.init(id: 21,
                author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: "New independent evidence")])]
            f.live = f.snapshot
        } else if change == "ci" { try f.setPipeline(status: "success") }
        else { f.settings.automation.codexVerificationModel = .luna56 }
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "New evidence establishes B")]
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 2)
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
    }

    @Test func unrelatedScopeAdoptionCannotReopenOrInterruptTheClaimAssessment() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.duringAssessment = { f.settings.automation.scope[.init(host: f.work.host, username: "me", projectID: 99, iid: 999)] = .active }
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Proven A"), .init(draftID: 13, state: .invalid, reason: "Unproved B")]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 12 } })
        f.duringAssessment = nil
        f.settings.automation.scope[.init(host: f.work.host, username: "me", projectID: 100, iid: 1000)] = .active
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "Unrelated adoption cannot grant another chance")]
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(!f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
    }

    @Test func manualRetryAloneReopensAnUnchangedRejectedDraftAndPreservesValidProof() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Proven A"), .init(draftID: 13, state: .invalid, reason: "Unproved B")]
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1)
        restarted.retry(work: f.work, username: "me")
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 12 } })
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "Explicitly requested fresh verification")]
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 2)
        #expect(Set(f.receipts().flatMap(\.drafts).map(\.id)) == [12, 13])
    }

    @Test(arguments: [false, true])
    func legacyPartialAndAllRejectedAttemptsCannotLoseTheirNegativeFence(_ allRejected: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.claimsOverride = [.init(draftID: 12, state: allRejected ? .invalid : .valid, reason: "Original A result"),
            .init(draftID: 13, state: .uncertain, reason: "Original B result")]
        let first = f.coordinator()
        first.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(first)
        let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts", work: f.work, username: "me", in: f.folder).deletingPathExtension()
        for path in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            object.removeValue(forKey: "context"); object.removeValue(forKey: "assessment")
            try JSONSerialization.data(withJSONObject: object).write(to: path)
        }
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "Legacy result cannot be forgotten")]
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 1)
        #expect(!f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
    }

    @Test(arguments: [false, true])
    func onlyKnownAppPublicationMayPreserveAnInFlightSiblingAssessment(_ ownPublication: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        ReviewVerdictStore.rememberDrafts(f.snapshot.drafts, host: f.work.host, projectID: 1, iid: 2, in: f.folder.appending(path: "verdicts"))
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "A independently verified")]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [12], configuration: f.settings.automation)
        try await f.settle(coordinator)
        f.duringAssessment = {
            if ownPublication { f.publishKnownA() }
            else {
                f.live.discussions = [.init(id: "thread", notes: f.live.discussions[0].notes + [.init(id: 22,
                    author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
                    resolvable: true, resolved: false, resolvedBy: nil, body: "Fixed")])]
            }
        }
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "B independently verified")]
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 2)
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 13 } } == ownPublication)
        #expect((coordinator.failure(work: f.work) != nil) == !ownPublication)
    }

    @Test func normalizedPublicationKeepsTheExistingSiblingVerifierProcessingUntilItFinishes() async throws {
        let f = try Fixture()
        defer { f.releaseVerification(); f.clean() }
        try f.addSibling()
        ReviewVerdictStore.rememberDrafts(f.snapshot.drafts, host: f.work.host, projectID: 1, iid: 2, in: f.folder.appending(path: "verdicts"))
        let coordinator = f.coordinator()
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "A verified")]
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [12], configuration: f.settings.automation)
        try await f.settle(coordinator)
        f.claimsOverride = [.init(draftID: 13, state: .valid, reason: "B verified")]
        f.holdVerification = true
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        let started = ContinuousClock.now + .seconds(3)
        while f.verificationGate == nil, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(10)) }
        try #require(f.verificationGate != nil)
        #expect(coordinator.isChecking(work: f.work))
        f.publishKnownA()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        #expect(coordinator.isChecking(work: f.work))
        #expect(coordinator.failure(work: f.work) == nil)
        f.releaseVerification()
        let finished = ContinuousClock.now + .seconds(3)
        while !f.receipts().contains(where: { $0.drafts.contains { $0.id == 13 } }), ContinuousClock.now < finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
        #expect(f.assessments == 2)
        #expect(!coordinator.isChecking(work: f.work))
        #expect(coordinator.failure(work: f.work) == nil)
    }

    @Test(arguments: [false, true])
    func changedHeadGetsFreshClaimChecksAndCurrentSourceProofWithoutAdoptingItsSibling(_ legacyAttempt: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.addSibling()
        f.claimState = .uncertain
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        if legacyAttempt {
            let folder = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts", work: f.work,
                username: "me", in: f.folder).deletingPathExtension()
            for path in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
                object.removeValue(forKey: "context"); object.removeValue(forKey: "assessment")
                try JSONSerialization.data(withJSONObject: object).write(to: path)
            }
        }
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        f.remoteHash = AICommentAssessmentStore.digest("updated current source and regression tests")
        f.claimsOverride = [.init(draftID: 12, state: .valid, reason: "Verified against the new source commit"),
            .init(draftID: 13, state: .uncertain, reason: "The other claim remains unsupported")]
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 2)
        let recovered = try #require(f.receipts().first)
        #expect(recovered.headSHA == f.snapshot.request.sha)
        #expect(recovered.files == [.init(path: "Sources/Fixed.swift", sha256: f.remoteHash)])
        #expect(recovered.runID == f.proof.runID && recovered.drafts.map(\.id) == [12])
        #expect(recovered.covers(f.snapshot.drafts[0], request: f.snapshot.request, host: f.work.host, user: f.snapshot.user, runID: recovered.runID))
        #expect(!recovered.covers(f.snapshot.drafts[0], request: try f.request(), host: f.work.host, user: f.snapshot.user, runID: recovered.runID))
        #expect(!f.proof.covers(f.snapshot.drafts[0], request: f.snapshot.request, host: f.work.host, user: f.snapshot.user, runID: f.proof.runID))
        let restarted = f.coordinator()
        restarted.schedule(snapshot: f.snapshot, origin: f.proof, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(restarted)
        #expect(f.assessments == 2)
    }

    @Test(arguments: [DraftProofRecoveryVerifier.Assessment.State.invalid, .uncertain])
    func aNewHeadDoesNotMakeAnUnsupportedClaimPublishable(_ state: DraftProofRecoveryVerifier.Assessment.State) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        f.claimState = state
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(f.receipts().isEmpty)
        #expect(coordinator.failure(work: f.work) != nil)
    }

    @Test func anotherHeadChangeDuringFreshClaimVerificationCannotCreatePublicationProof() async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        f.duringAssessment = {
            f.live.request = try! f.request(head: String(repeating: "c", count: 40))
            f.live.branchHead = f.live.request.sha!
        }
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(f.receipts().isEmpty)
    }

    @Test(arguments: AutomationAssistant.allCases, VerificationThinking.allCases)
    func headlessClaimVerifierReceivesTheCurrentHeadInsteadOfTheHistoricalHead(_ assistant: AutomationAssistant, _ thinking: VerificationThinking) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        let script = f.folder.appending(path: "claim-cli")
        try Data("""
            #!/usr/bin/python3
            import json,sys,pathlib
            args=sys.argv[1:]; raw=sys.stdin.read(); codex=args[0]=='exec'
            evidence=json.loads(raw[raw.index('{'):]) if codex else json.loads(raw)
            pathlib.Path(__file__+'.capture').write_text(json.dumps(evidence))
            pathlib.Path(__file__+'.arguments').write_text(json.dumps(args))
            result={'drafts':[{'draftID':12,'state':'valid','reason':'Current source and regression tests checked.','summary':'The reply is supported by the current code and tests.'}]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let currentFiles = [FollowUpVerification.FileEvidence(path: "Sources/Fixed.swift",
            sha256: AICommentAssessmentStore.digest("new committed source and tests"))]
        var input = DraftProofRecoveryVerifier.Input(snapshot: f.snapshot, origin: f.proof, currentFiles: currentFiles)
        #expect(input.thinking == .high)
        input.thinking = thinking
        let result = try await DraftProofRecoveryVerifier.run(input,
            assistant: assistant, model: "fixture", executable: script)
        #expect(result.drafts.first?.state == .valid)
        #expect(result.drafts.first?.summary == "The reply is supported by the current code and tests.")
        let arguments = try JSONDecoder().decode([String].self,
            from: Data(contentsOf: URL(fileURLWithPath: script.path + ".arguments")))
        if assistant == .codex {
            #expect(arguments.contains("model_reasoning_effort=\"\(thinking.rawValue)\""))
        } else {
            let effortIndex = try #require(arguments.firstIndex(of: "--effort"))
            #expect(arguments[effortIndex + 1] == thinking.rawValue)
        }
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: script.path + ".capture"))) as? [String: Any])
        let target = try #require(payload["target"] as? [String: Any])
        #expect(target["headSHA"] as? String == f.snapshot.request.sha)
        let files = try #require(payload["files"] as? [[String: String]])
        #expect(files == [["path": currentFiles[0].path, "sha256": currentFiles[0].sha256]])
    }

    @Test(arguments: AutomationAssistant.allCases)
    func aNewHeadRequiresCurrentFileEvidenceBeforeEitherProviderStarts(_ assistant: AutomationAssistant) async throws {
        let f = try Fixture()
        defer { f.clean() }
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        let script = f.folder.appending(path: "must-not-start")
        try Data("""
            #!/bin/sh
            touch "\(script.path).started"
            exit 17
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do {
            _ = try await DraftProofRecoveryVerifier.run(.init(snapshot: f.snapshot, origin: f.proof),
                assistant: assistant, model: "fixture", executable: script)
            Issue.record("Missing current file evidence must be rejected")
        } catch DraftProofRecoveryVerifier.Failure.invalidEvidence { }
        catch { Issue.record("Expected invalidEvidence before provider launch, got \(error)") }
        #expect(!FileManager.default.fileExists(atPath: script.path + ".started"))
    }

    @Test func aNewHeadSupersedesAnInFlightCheckEvenWhenDiscussionTextIsUnchanged() async throws {
        let f = try Fixture()
        defer { f.releaseVerification(); f.clean() }
        f.holdVerification = true
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        let deadline = ContinuousClock.now + .seconds(3)
        while f.verificationGate == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(f.verificationGate != nil)
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        let fingerprint = try #require(ReviewVerdict.fingerprint(f.snapshot.discussions))
        #expect(!coordinator.presentationIsCurrent(request: f.snapshot.request, host: f.work.host,
            fingerprint: fingerprint, configuration: f.settings.automation))
        coordinator.schedule(snapshot: f.snapshot, origin: f.proof, configuration: f.settings.automation)
        f.releaseVerification()
        try await f.settle(coordinator)
        #expect(f.assessments == 2)
        #expect(f.receipts().contains { $0.headSHA == f.snapshot.request.sha })
    }

    @Test func missingHistoricalFilesDoNotStrandAnotherKnownOriginForTheSameDraft() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let old = f.proof
        let other = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: old.runID,
            host: old.host, projectID: old.projectID, iid: old.iid, username: old.username, userID: old.userID,
            headSHA: old.headSHA, sourceProjectID: old.sourceProjectID, sourceBranch: old.sourceBranch,
            files: [.init(path: "Sources/Current.swift", sha256: old.files[0].sha256)], drafts: old.drafts)
        let archive = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: f.work,
            username: "me", in: f.folder).deletingPathExtension()
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try JSONEncoder().encode(other).write(to: archive.appending(path: "\(other.verificationID.uuidString).json"))
        f.snapshot.request = try f.request(head: String(repeating: "b", count: 40))
        f.snapshot.branchHead = f.snapshot.request.sha!
        f.live = f.snapshot
        f.unreadableFiles = ["Sources/Fixed.swift"]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: old, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 0 && f.receipts().isEmpty)
        coordinator.schedule(snapshot: f.snapshot, origin: other, configuration: f.settings.automation)
        try await f.settle(coordinator)
        #expect(f.assessments == 1)
        #expect(f.receipts().first?.files.map(\.path) == ["Sources/Current.swift"])
    }

    @Test func anotherOriginsPreflightFenceCannotInterruptANormalizedSiblingCheck() async throws {
        let f = try Fixture()
        defer { f.releaseVerification(); f.clean() }
        try f.addSibling()
        let old = f.proof
        let other = FollowUpVerification(version: 1, sealed: true, verificationID: UUID(), runID: old.runID,
            host: old.host, projectID: old.projectID, iid: old.iid, username: old.username, userID: old.userID,
            headSHA: old.headSHA, sourceProjectID: old.sourceProjectID, sourceBranch: old.sourceBranch,
            files: [.init(path: "Sources/Current.swift", sha256: old.files[0].sha256)], drafts: [old.drafts[1]])
        let archive = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: f.work,
            username: "me", in: f.folder).deletingPathExtension()
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try JSONEncoder().encode(other).write(to: archive.appending(path: "\(other.verificationID.uuidString).json"))
        ReviewVerdictStore.rememberDrafts(f.snapshot.drafts, host: f.work.host, projectID: 1, iid: 2,
            in: f.folder.appending(path: "verdicts"))
        f.unreadableFiles = ["Sources/Fixed.swift"]
        let coordinator = f.coordinator()
        coordinator.schedule(snapshot: f.snapshot, origin: old, draftIDs: [13], configuration: f.settings.automation)
        try await f.settle(coordinator)
        f.holdVerification = true
        coordinator.schedule(snapshot: f.snapshot, origin: other, draftIDs: [13], configuration: f.settings.automation)
        let started = ContinuousClock.now + .seconds(3)
        while f.verificationGate == nil, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(10)) }
        try #require(f.verificationGate != nil)
        f.publishKnownA()
        coordinator.schedule(snapshot: f.snapshot, origin: old, draftIDs: [13], configuration: f.settings.automation)
        #expect(coordinator.isChecking(work: f.work))
        #expect(coordinator.failure(work: f.work) == nil)
        f.releaseVerification()
        let finished = ContinuousClock.now + .seconds(3)
        while !f.receipts().contains(where: { $0.drafts.contains { $0.id == 13 } }), ContinuousClock.now < finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.receipts().contains { $0.drafts.contains { $0.id == 13 } })
        #expect(f.assessments == 1)
    }

    @MainActor private final class Fixture {
        let folder: URL
        let settings: SettingsManager
        let defaults: UserDefaults
        let suite: String
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 2)
        var proof: FollowUpVerification
        var snapshot: DraftProofRecoveryCoordinator.Snapshot
        var live: DraftProofRecoveryCoordinator.Snapshot
        var assessments = 0
        var verifierThinking: [VerificationThinking] = []
        var automationAvailable = true
        var verifyFails = false
        var verifyFailuresRemaining = 0
        var fetchFailuresAfterAssessment = 0
        var clock = Date()
        var holdVerification = false
        var verificationGate: CheckedContinuation<Void, Never>?
        var claimState = DraftProofRecoveryVerifier.Assessment.State.valid
        var claimsOverride: [DraftProofRecoveryVerifier.Assessment.Draft]?
        var duringAssessment: (() -> Void)?
        var unreadableFiles: Set<String> = []
        var remoteHash = AICommentAssessmentStore.digest("source and test")
        init() throws {
            folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            suite = "DraftProofRecoveryTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
            settings = SettingsManager(defaults: defaults)
            settings.automation.applyPreset(.full, for: .codex)
            let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
            let origin = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Historical follow-up", prompt: "", createdAt: Date(), allowsPush: false, followUpPushAllowed: true)
            settings.assistantHandoffs = [origin]
            proof = .init(version: 1, sealed: true, verificationID: UUID(), runID: origin.id, host: work.host, projectID: 1, iid: 2, username: "me", userID: 3, headSHA: String(repeating: "a", count: 40), sourceProjectID: 1, sourceBranch: "fix", files: [.init(path: "Sources/Fixed.swift", sha256: remoteHash)], drafts: [.init(id: 12, bodySHA256: AICommentAssessmentStore.digest("Fixed"))])
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Self.requestJSON().utf8))
            let threads = [GitLabMergeRequestDiscussion(id: "thread", notes: [.init(id: 10, author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Fix source and add a regression test")])]
            snapshot = .init(request: request, discussions: threads, drafts: [.init(id: 12, authorID: 3, note: "Fixed", discussionID: "thread", position: nil)], user: .init(id: 3, username: "me"), host: work.host, branchHead: request.sha!)
            live = snapshot
            let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(proof).write(to: path)
        }
        static func requestJSON(head: String = String(repeating: "a", count: 40), title: String = "Example MR", targetBranch: String = "main", targetProjectID: Int = 1, draft: Bool = false) -> String {
            #"{"project_id":1,"iid":2,"author":{"id":3,"name":"Me","username":"me"},"title":"\#(title)","web_url":"https://gitlab.example.org/group/repo/-/merge_requests/2","state":"opened","draft":\#(draft),"sha":"\#(head)","source_project_id":1,"source_branch":"fix","target_branch":"\#(targetBranch)","target_project_id":\#(targetProjectID),"labels":[]}"#
        }
        func request(head: String = String(repeating: "a", count: 40), title: String = "Example MR", targetBranch: String = "main", targetProjectID: Int = 1, draft: Bool = false) throws -> GitLabMergeRequest {
            try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Self.requestJSON(head: head, title: title, targetBranch: targetBranch, targetProjectID: targetProjectID, draft: draft).utf8))
        }
        func receipts() -> [FollowUpVerification] {
            FollowUpVerificationStore.contextReceipts(work: work, username: "me", settings: settings, in: folder)
        }
        func publication() -> [FollowUpVerification] {
            FollowUpVerificationStore.publicationReceipts(work: work, username: "me", settings: settings, in: folder)
        }
        func pendingAttemptPath() throws -> URL {
            let attempts = FollowUpVerificationStore.recordURL(kind: "follow-up-proof-recovery-attempts",
                work: work, username: "me", in: folder).deletingPathExtension()
            let paths = try FileManager.default.contentsOfDirectory(at: attempts, includingPropertiesForKeys: nil)
            return try #require(paths.first { $0.pathExtension == "json" && $0.lastPathComponent != "retry-generation.json" })
        }
        func editPendingAssessment(_ edit: (inout [String: Any], [String: Any]) throws -> Void) throws {
            let path = try pendingAttemptPath()
            let data = try Data(contentsOf: path)
            let object = try JSONSerialization.jsonObject(with: data)
            var attempt = try #require(object as? [String: Any])
            var pending = try #require(attempt["pendingAssessment"] as? [String: Any])
            try edit(&pending, attempt)
            attempt["pendingAssessment"] = pending
            try JSONSerialization.data(withJSONObject: attempt).write(to: path, options: .atomic)
        }
        var repairJobs: [AssistantAutomationRunner.Handoff] { settings.assistantHandoffs.filter { $0.draftRepair != nil } }
        func persist(_ proof: FollowUpVerification) throws {
            let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder)
            try JSONEncoder().encode(proof).write(to: path)
        }
        func archive(_ proof: FollowUpVerification) throws {
            let path = FollowUpVerificationStore.recordURL(kind: "follow-up-verifications-archive", work: work, username: "me", in: folder)
                .deletingPathExtension().appending(path: "\(proof.verificationID.uuidString).json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(proof).write(to: path)
        }
        func currentProof(runID: UUID, body: String, extraID: Int? = nil) -> FollowUpVerification {
            .init(version: 1, sealed: true, verificationID: UUID(), runID: runID, host: work.host, projectID: 1, iid: 2,
                username: "me", userID: 3, headSHA: snapshot.request.sha!, sourceProjectID: 1, sourceBranch: "fix", files: proof.files,
                drafts: [.init(id: 12, bodySHA256: AICommentAssessmentStore.digest(body))]
                    + (extraID.map { [.init(id: $0, bodySHA256: AICommentAssessmentStore.digest("Unrelated user reply"))] } ?? []),
                discussionFingerprint: ReviewVerdict.fingerprint(snapshot.discussions),
                semanticContextFingerprint: snapshot.request.semanticContextFingerprint,
                recoveryContextFingerprint: snapshot.request.draftProofRecoveryContextFingerprint,
                repairIntent: repairJobs.contains(where: { $0.id == runID })
                    ? .init(draftID: 12, bodySHA256: AICommentAssessmentStore.digest(body)) : nil)
        }
        func enableRepairs(_ coordinator: DraftProofRecoveryCoordinator) {
            coordinator.onNeedsRepair = { [self] snapshot, origin, assessment in
                let rejection = try #require(assessment.drafts.first)
                let context = try #require(DraftReplyRepair.context(snapshot: snapshot, origin: origin,
                    rejection: rejection, configuration: settings.automation))
                let handoff = AssistantAutomationRunner.Handoff(id: UUID(),
                    key: .init(assistant: settings.automation.assistant, work: work, username: "me", workspace: "", access: .gitLabRead),
                    title: "Repair", prompt: "Repair only the known reply", createdAt: Date(), allowsPush: false,
                    codingModel: context.codingModel, codingThinking: context.codingThinking, draftRepair: context,
                    followUpPushAllowed: true, execution: .init(state: .running), taskPrompt: "Repair only the known reply",
                    mergeRequestURL: snapshot.request.webURL, workflow: .followUp, expectedHeadSHA: snapshot.request.sha)
                settings.assistantHandoffs.append(handoff); settings.save()
                return handoff.id
            }
        }
        func waitForRepairs(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while repairJobs.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(repairJobs.count == count)
        }
        func addManualRetry() -> (AssistantAutomationRunner.Handoff, AssistantAutomationRunner.Handoff) {
            let origin = settings.assistantHandoffs[0]
            let stopped = AssistantAutomationRunner.Handoff(id: UUID(), key: origin.key, title: "Stopped follow-up", prompt: "",
                createdAt: origin.createdAt.addingTimeInterval(1), allowsPush: false, feedbackNoteIDs: [11],
                followUpPushAllowed: true, execution: .init(state: .blocked), taskPrompt: "Fix only reviewer note 11",
                mergeRequestURL: snapshot.request.webURL, workflow: .followUp, manual: false, expectedHeadSHA: proof.headSHA)
            let replacement = AssistantAutomationRunner.Handoff(id: UUID(), key: stopped.key, title: stopped.title, prompt: stopped.prompt,
                createdAt: stopped.createdAt.addingTimeInterval(1), allowsPush: stopped.allowsPush, feedbackNoteIDs: stopped.feedbackNoteIDs,
                followUpPushAllowed: true, execution: .init(state: .succeeded), taskPrompt: stopped.taskPrompt,
                mergeRequestURL: stopped.mergeRequestURL, workflow: stopped.workflow, manual: true, expectedHeadSHA: stopped.expectedHeadSHA)
            settings.assistantHandoffs += [stopped, replacement]
            settings.recordAutomationEvent(target: .init(host: work.host, username: "me", projectID: 1, iid: 2),
                action: .retry, origin: .manual, state: .queued, jobID: replacement.id, relatedJobID: stopped.id)
            return (stopped, replacement)
        }
        func publishKnownA() {
            snapshot.discussions = [.init(id: "thread", notes: snapshot.discussions[0].notes + [.init(id: 20,
                author: .init(id: 3, username: "me", name: "Me"), system: false,
                resolvable: true, resolved: false, resolvedBy: nil, body: "Fixed")])]
            snapshot.drafts.removeAll { $0.id == 12 }
            live = snapshot
        }
        func setPipeline(status: String) throws {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.request)) as? [String: Any])
            json["head_pipeline"] = ["id": 9, "project_id": 1, "status": status, "sha": snapshot.request.sha!]
            snapshot.request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: json))
            live = snapshot
        }
        func addSibling() throws {
            let old = proof
            proof = .init(version: old.version, sealed: old.sealed, verificationID: old.verificationID, runID: old.runID,
                host: old.host, projectID: old.projectID, iid: old.iid, username: old.username, userID: old.userID,
                headSHA: old.headSHA, sourceProjectID: old.sourceProjectID, sourceBranch: old.sourceBranch, files: old.files,
                drafts: old.drafts + [.init(id: 13, bodySHA256: AICommentAssessmentStore.digest("Another claim"))])
            snapshot.drafts.append(.init(id: 13, authorID: 3, note: "Another claim", discussionID: "thread", position: nil))
            live = snapshot
            try JSONEncoder().encode(proof).write(to: FollowUpVerificationStore.recordURL(kind: "follow-up-verifications", work: work, username: "me", in: folder))
        }
        func coordinator() -> DraftProofRecoveryCoordinator {
            DraftProofRecoveryCoordinator(settings: settings, directory: folder, canAutomate: { [self] _ in automationAvailable },
                fetch: { [self] _ in
                    if assessments > 0 && fetchFailuresAfterAssessment > 0 {
                        fetchFailuresAfterAssessment -= 1; throw DraftProofRecoveryVerifier.Failure.failed
                    }
                    return live
                }, hashFile: { [self] _, file in
                    if unreadableFiles.contains(file.path) { throw DraftProofRecoveryVerifier.Failure.failed }
                    return remoteHash
                }, verify: { [self] input, _, _ in
                    assessments += 1
                    verifierThinking.append(input.thinking)
                    if verifyFails { throw DraftProofRecoveryVerifier.Failure.failed }
                    if verifyFailuresRemaining > 0 { verifyFailuresRemaining -= 1; throw DraftProofRecoveryVerifier.Failure.failed }
                    duringAssessment?()
                    if holdVerification { await withCheckedContinuation { verificationGate = $0 } }
                    return .init(drafts: claimsOverride ?? input.requestedDraftIDs.map { .init(draftID: $0, state: claimState, reason: "Source and regression tests inspected against current live HEAD.") })
                }, retryWait: { _ in }, now: { [self] in clock })
        }
        func settle(_ coordinator: DraftProofRecoveryCoordinator) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while coordinator.isChecking(work: work), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!coordinator.isChecking(work: work))
        }
        func releaseVerification() {
            holdVerification = false
            let gate = verificationGate; verificationGate = nil; gate?.resume()
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
    }
}
