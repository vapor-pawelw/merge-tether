import Foundation
import Testing
@testable import MergeTether

struct EvidenceContextTests {
    private let evidence = EvidenceContext(
        account: .init(host: "gitlab.example.test", username: "reviewer"), accountRevision: 7,
        mergeRequestID: .init(projectID: 1, iid: 2), head: "head",
        target: .init(projectID: 1, branch: "main", base: "base"),
        discussionContent: .init("comments"), activeDiscussionContent: .init("active"),
        discussionState: .init("note revisions"), semanticContext: .init("MR text"), recoveryContext: .init("recovery")
    )

    @Test(arguments: EvidenceContext.BindingPolicy.allCases)
    func matchesCapturedEvidence(_ policy: EvidenceContext.BindingPolicy) {
        #expect(evidence.binds(to: evidence, policy: policy))
    }

    @Test func comparesOnlyTheComponentsEachPolicyUses() {
        check(\.account, .init(host: "gitlab.example.test", username: "other"),
              rejects: [.accountIdentity, .accountSession, .accountAndRequest, .reReviewAssessment])
        check(\.accountRevision, 8, rejects: [.accountSession, .reReviewAssessment])
        check(\.mergeRequestID, .init(projectID: 1, iid: 3), rejects: [.accountAndRequest, .reReviewAssessment])
        check(\.head, "new head", rejects: [.head, .requestText, .approvalTarget, .reviewContent,
            .feedbackProgress, .observedFeedback, .verifiedFeedback, .feedbackPresentation, .followUpPresentation,
            .reReviewAssessment, .draftRecovery, .legacyFollowUpProof, .uncertainReReviewReceipt])
        check(\.target, .init(projectID: 1, branch: "release", base: "base"), rejects: [.approvalTarget])
        check(\.target, .init(projectID: 1, branch: "main", base: "new base"), rejects: [.approvalTarget])
        check(\.target, .init(projectID: 3, branch: "main", base: "base"), rejects: [.approvalTarget])
        check(\.discussionContent, .init("edited comment"), rejects: [.discussionContent, .reviewContent,
            .observedFeedback, .verifiedFeedback, .feedbackPresentation, .followUpPresentation, .reReviewAssessment])
        check(\.activeDiscussionContent, .init("resolved"), rejects: [.reReviewAssessment])
        check(\.discussionState, .init("edited timestamp"), rejects: [.discussionState])
        check(\.semanticContext, .init("new title"), rejects: [.semanticText, .requestText, .feedbackProgress,
            .observedFeedback, .verifiedFeedback, .feedbackPresentation, .reReviewAssessment, .legacyFollowUpProof])
        check(\.recoveryContext, .init("new recovery context"), rejects: [.draftRecovery, .legacyFollowUpProof])
    }

    @Test func missingEvidenceRequiresTheOriginalPolicyToAllowIt() {
        let empty = EvidenceContext()
        let acceptsTwoEmptyContexts: Set<EvidenceContext.BindingPolicy> = [.head, .feedbackPresentation, .followUpPresentation]
        for policy in EvidenceContext.BindingPolicy.allCases {
            #expect(empty.binds(to: empty, policy: policy) == acceptsTwoEmptyContexts.contains(policy))
        }

        var legacyFeedback = evidence
        legacyFeedback.semanticContext = nil
        #expect(legacyFeedback.binds(to: evidence, policy: .feedbackProgress))
        #expect(!legacyFeedback.binds(to: evidence, policy: .observedFeedback))
        #expect(!legacyFeedback.binds(to: evidence, policy: .verifiedFeedback))
        #expect(!evidence.binds(to: legacyFeedback, policy: .observedFeedback))

        var legacyProof = legacyFeedback
        legacyProof.recoveryContext = nil
        #expect(legacyProof.binds(to: evidence, policy: .legacyFollowUpProof))
        #expect(!legacyProof.binds(to: evidence, policy: .draftRecovery))
        #expect(!evidence.binds(to: legacyProof, policy: .legacyFollowUpProof))

        var legacyReceipt = evidence
        legacyReceipt.head = nil
        #expect(!legacyReceipt.binds(to: evidence, policy: .uncertainReReviewReceipt))
        #expect(!legacyReceipt.binds(to: evidence, policy: .head))
        #expect(!legacyReceipt.binds(to: evidence, policy: .approvalTarget))

        var missingBase = evidence
        missingBase.target = nil
        #expect(!missingBase.binds(to: evidence, policy: .approvalTarget))
        var missingRevision = evidence
        missingRevision.accountRevision = nil
        #expect(!missingRevision.binds(to: evidence, policy: .accountSession))
        #expect(missingRevision.binds(to: evidence, policy: .accountIdentity))
    }

    @Test func discussionDigestsKeepTheirExistingSensitivity() throws {
        let open = try discussions(resolved: false)
        let closed = try discussions(resolved: true)
        let closedWithNewTimestamp = try discussions(resolved: true, updated: "later")
        let edited = try discussions(resolved: false, body: "Edited comment")
        let added = open + [GitLabMergeRequestDiscussion(id: "new-thread", notes: [
            .init(id: 6, author: .init(id: 4, username: "reviewer", name: nil), system: false,
                  resolvable: false, resolved: nil, resolvedBy: nil, body: "New comment"),
        ])]
        let recorded = context(for: open)
        #expect(recorded.binds(to: context(for: closed), policy: .reviewContent))
        #expect(recorded.binds(to: context(for: closedWithNewTimestamp), policy: .reviewContent))
        #expect(!recorded.binds(to: context(for: closed), policy: .reReviewAssessment))
        #expect(recorded.binds(to: context(for: closed), policy: .discussionState))
        #expect(!recorded.binds(to: context(for: closedWithNewTimestamp), policy: .discussionState))
        #expect(!recorded.binds(to: context(for: edited), policy: .reviewContent))
        #expect(!recorded.binds(to: context(for: added), policy: .reviewContent))
        #expect(!recorded.binds(to: context(for: edited), policy: .discussionState))
        #expect(!recorded.binds(to: context(for: added), policy: .discussionState))
        #expect(recorded.discussionContent?.rawValue == ReviewVerdict.fingerprint(open))
        #expect(recorded.discussionState?.rawValue == ManualDiscussionResolution.fingerprint(open))
    }

    @Test func digestsEncodeAsPlainStrings() throws {
        try assertWireValue(DiscussionContentDigest.self, #""comments""#)
        try assertWireValue(DiscussionStateDigest.self, #""note revisions""#)
        try assertWireValue(SemanticContextDigest.self, #""title and description""#)
        try assertWireValue(DraftRecoveryDigest.self, #""recovery""#)
    }

    @Test func reviewVerdictDecodesBothLegacyAndBoundRecords() throws {
        let legacy = #"{"headSHA":"head","host":"gitlab.example.test","iid":2,"projectID":1,"verdict":"no_objections","version":1}"#
        let verdict = try assertWireValue(ReviewVerdict.self, legacy)
        #expect(verdict.evidenceContext.head == "head")
        #expect(verdict.evidenceContext.discussionContent == nil)
        #expect(verdict.evidenceContext.semanticContext == nil)
        let bound = #"{"discussionFingerprint":"comments","headSHA":"head","host":"gitlab.example.test","iid":2,"projectID":1,"semanticContextFingerprint":"text","username":"reviewer","verdict":"no_objections","version":1}"#
        let boundVerdict = try assertWireValue(ReviewVerdict.self, bound)
        #expect(boundVerdict.evidenceContext.discussionContent == .init("comments"))
        #expect(boundVerdict.evidenceContext.semanticContext == .init("text"))
    }

    @Test func followUpProofDecodesWithoutOptionalEvidence() throws {
        let legacy = #"{"drafts":[],"files":[],"headSHA":"head","host":"gitlab.example.test","iid":2,"projectID":1,"runID":"00000000-0000-0000-0000-000000000001","sealed":true,"sourceBranch":"feature","sourceProjectID":1,"userID":4,"username":"reviewer","verificationID":"00000000-0000-0000-0000-000000000002","version":1}"#
        let proof = try assertWireValue(FollowUpVerification.self, legacy)
        #expect(proof.evidenceContext.discussionContent == nil)
        #expect(proof.evidenceContext.semanticContext == nil)
        #expect(proof.evidenceContext.recoveryContext == nil)
        #expect(proof.evidenceContext.binds(to: evidence, policy: .legacyFollowUpProof))
    }

    @Test func reviewedTargetAndUncertainReceiptKeepTheirLegacyKeys() throws {
        let target = try assertWireValue(ReviewTargetBinding.self,
            #"{"baseSHA":"base","headSHA":"head","targetBranch":"main","targetProjectID":1}"#)
        #expect(target.evidenceContext.binds(to: evidence, policy: .approvalTarget))
        let uncertain = try assertWireValue(ReReviewReceipt.self, #"{"noteID":3,"unconfirmed":true}"#)
        let confirmed = try assertWireValue(ReReviewReceipt.self, #"{"noteID":3,"requested":true,"unconfirmed":false}"#)
        #expect(uncertain.covers(noteID: 3, headSHA: "head"))
        #expect(!confirmed.covers(noteID: 3, headSHA: "head"))
    }

    private func context(for discussions: [GitLabMergeRequestDiscussion]) -> EvidenceContext {
        var result = evidence
        result.discussionContent = ReviewVerdict.discussionContentDigest(discussions)
        result.activeDiscussionContent = ReviewVerdict.discussionContentDigest(GitLabMergeRequestDiscussion.activeForReview(discussions))
        result.discussionState = ManualDiscussionResolution.discussionStateDigest(discussions)
        return result
    }

    private func discussions(resolved: Bool, body: String = "Comment", updated: String = "first") throws -> [GitLabMergeRequestDiscussion] {
        let data = try JSONSerialization.data(withJSONObject: [
            ["id": "thread", "notes": [["id": 5, "author": ["id": 4], "system": false,
                "resolvable": true, "resolved": resolved, "body": body, "updated_at": updated]]]
        ])
        return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: data)
    }

    @discardableResult
    private func assertWireValue<Value: Codable>(_ type: Value.Type, _ json: String) throws -> Value {
        let data = Data(json.utf8)
        let value = try JSONDecoder().decode(type, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(value) == data)
        return value
    }

    private func check<Value>(_ keyPath: WritableKeyPath<EvidenceContext, Value>, _ value: Value,
                              rejects: Set<EvidenceContext.BindingPolicy>) {
        var current = evidence
        current[keyPath: keyPath] = value
        for policy in EvidenceContext.BindingPolicy.allCases {
            #expect(evidence.binds(to: current, policy: policy) == !rejects.contains(policy), "\(keyPath), \(policy)")
        }
    }
}
