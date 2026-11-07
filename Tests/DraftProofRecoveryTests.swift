import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct DraftProofRecoveryTests {
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
        #expect(fixture.assessments == 1)
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
        let record = try JSONDecoder().decode(FollowUpVerificationStore.RecoveryRecord.self, from: Data(contentsOf: path))
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
        #expect(f.assessments == 1)
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

    @Test(arguments: AutomationAssistant.allCases)
    func headlessClaimVerifierReceivesTheCurrentHeadInsteadOfTheHistoricalHead(_ assistant: AutomationAssistant) async throws {
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
            result={'drafts':[{'draftID':12,'state':'valid','reason':'Current source and regression tests checked.'}]}
            if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
            else: print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let currentFiles = [FollowUpVerification.FileEvidence(path: "Sources/Fixed.swift",
            sha256: AICommentAssessmentStore.digest("new committed source and tests"))]
        let result = try await DraftProofRecoveryVerifier.run(.init(snapshot: f.snapshot, origin: f.proof, currentFiles: currentFiles),
            assistant: assistant, model: "fixture", executable: script)
        #expect(result.drafts.first?.state == .valid)
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
        var verifyFails = false
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
        static func requestJSON(head: String = String(repeating: "a", count: 40), title: String = "Example MR", targetBranch: String = "main", targetProjectID: Int = 1) -> String {
            #"{"project_id":1,"iid":2,"author":{"id":3,"name":"Me","username":"me"},"title":"\#(title)","web_url":"https://gitlab.example.org/group/repo/-/merge_requests/2","state":"opened","draft":false,"sha":"\#(head)","source_project_id":1,"source_branch":"fix","target_branch":"\#(targetBranch)","target_project_id":\#(targetProjectID),"labels":[]}"#
        }
        func request(head: String = String(repeating: "a", count: 40), title: String = "Example MR", targetBranch: String = "main", targetProjectID: Int = 1) throws -> GitLabMergeRequest {
            try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(Self.requestJSON(head: head, title: title, targetBranch: targetBranch, targetProjectID: targetProjectID).utf8))
        }
        func receipts() -> [FollowUpVerification] {
            FollowUpVerificationStore.contextReceipts(work: work, username: "me", settings: settings, in: folder)
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
            DraftProofRecoveryCoordinator(settings: settings, directory: folder, canAutomate: { _ in true },
                fetch: { [self] _ in live }, hashFile: { [self] _, file in
                    if unreadableFiles.contains(file.path) { throw DraftProofRecoveryVerifier.Failure.failed }
                    return remoteHash
                }, verify: { [self] input, _, _ in
                    assessments += 1
                    if verifyFails { throw DraftProofRecoveryVerifier.Failure.failed }
                    duringAssessment?()
                    if holdVerification { await withCheckedContinuation { verificationGate = $0 } }
                    return .init(drafts: claimsOverride ?? input.requestedDraftIDs.map { .init(draftID: $0, state: claimState, reason: "Source and regression tests inspected against current live HEAD.") })
                })
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
