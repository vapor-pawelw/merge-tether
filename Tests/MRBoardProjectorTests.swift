import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor
struct MRBoardProjectorTests {
    private let account = MRBoardProjector.Account(host: "gitlab.test", username: "me", revision: 1)
    private func request(_ changes: [String: Any] = [:]) throws -> GitLabMergeRequest {
        var data: [String: Any] = ["project_id": 1, "iid": 42,
            "author": ["id": 3, "username": "me", "name": "Me"], "title": "Checked", "description": "Body",
            "web_url": "https://gitlab.test/g/p/-/merge_requests/42", "state": "opened", "draft": false,
            "sha": "a", "source_branch": "feature", "target_branch": "main", "labels": []]
        for (key, value) in changes { data[key] = value }
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: data))
    }
    private func item(_ request: GitLabMergeRequest) -> MergeRequestAttentionMonitor.Item {
        .init(id: .init(projectID: request.projectID, iid: request.iid), title: request.title,
            url: request.webURL, mergeRequest: request, isAuthored: request.author.username == account.username)
    }
    private func input(evidence: MergeRequestAttentionMonitor.Item, catalog: MergeRequestAttentionMonitor.Item) -> MRBoardProjector.Input {
        var input = MRBoardProjector.Input(account: account)
        input.attention = .init(host: account.host, username: account.username, revision: account.revision,
            evidence: [evidence], attention: [evidence], catalog: [catalog])
        input.automation.applyPreset(.manual, for: .codex)
        input.assistantReady = true
        input.reviewAssistantReady = true
        input.trackedReviewedTargets = [.init(host: account.host, username: account.username, projectID: 1, iid: 42)]
        return input
    }

    @Test func rawAutomaticOwnershipCannotHideAnOlderPrivateCheckpointAfterDraftFlip() throws {
        var evidence = item(try request())
        evidence.draftCount = 1
        evidence.drafts = [.init(id: 7, authorID: 3, note: "Private A", discussionID: nil, position: nil)]
        evidence.canApprove = true
        evidence.autoApproveReady = true
        evidence.automaticDraftIDs = [7]
        evidence.observedDiscussionFingerprint = "conversation-a"
        let catalog = item(try request(["draft": true]))
        var input = input(evidence: evidence, catalog: catalog)
        input.automation.applyPreset(.full, for: .codex)
        input.publicationAutomaticTargets = input.trackedReviewedTargets
        evidence.automaticPublicationPolicy = input.automation.automaticPublicationPolicy
        input.attention = .init(host: account.host, username: account.username, revision: account.revision,
            evidence: [evidence], attention: [evidence], catalog: [catalog])
        let projector = MRBoardProjector(input: input)
        let pending = projector.pendingUserAttention
        let presenter = BoardAttentionPresenter()
        presenter.updateAttention(pending)
        let attention = presenter.userAttention(account: account.presentationKey)
        #expect(attention.hasAttention)
        let row = try #require(projector.board(humanAttention: attention).own.first)
        let model = MRCardPresentation(row: row, reviewingContext: projector.reviewingContext(for: row),
            allowsRemoval: false, assistantReady: true)
        let human = try #require(model.humanAction)
        #expect(human.kind == .uncheckedDrafts && human.action == .reviewDrafts)
        #expect(pending.humanActions.values.first?.kind == human.kind)
        #expect(row.item.mergeRequest?.draft == false && row.displayRequest?.draft == true)
        #expect(row.item.drafts == evidence.drafts && row.item.observedDiscussionFingerprint == "conversation-a")
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(row.item, account: "me@gitlab.test"), model: model)
        #expect(phone.detail == human.explanation && phone.needsAttention == attention.hasAttention)
        #expect(phone.primaryCTA?.title == String(localized: human.actionLabel))
        #expect(phone.actions.allSatisfy { ![RemoteActionKind.publish, .approve, .merge, .enqueueMerge].contains($0.kind) })
        #expect(input.attention?.evidence.first?.canApprove == true)
    }

    @Test(arguments: ["host", "username", "revision"])
    func aSnapshotCannotCrossItsAccountOrRevision(_ change: String) throws {
        let evidence = item(try request())
        var input = input(evidence: evidence, catalog: evidence)
        input.attention = .init(host: change == "host" ? "other.test" : account.host,
            username: change == "username" ? "other" : account.username,
            revision: change == "revision" ? 0 : account.revision,
            evidence: [evidence], attention: [evidence], catalog: [evidence])
        let projector = MRBoardProjector(input: input)
        #expect(projector.board().own.isEmpty && projector.board().reviewed.isEmpty)
        #expect(projector.attentionItems.isEmpty && projector.pendingUserAttention.candidates.isEmpty)
    }

    @Test(arguments: ["sha", "target_branch"])
    func displayDependenciesComeFromTheCurrentCatalogWithoutRewritingEvidence(_ change: String) throws {
        var evidence = item(try request())
        evidence.draftCount = 1
        let oldParent = try request(["iid": 40, "web_url": "https://gitlab.test/g/p/-/merge_requests/40"])
        evidence.dependencies = .init(request: try request(), stack: nil,
            dependencies: .init(requests: [oldParent], hasHiddenDependency: false))
        var catalog = item(try request([change: "b"]))
        let newParent = try request(["iid": 41, "web_url": "https://gitlab.test/g/p/-/merge_requests/41"])
        catalog.dependencies = .init(request: try request([change: "b"]), stack: nil,
            dependencies: .init(requests: [newParent], hasHiddenDependency: false))
        let projector = MRBoardProjector(input: input(evidence: evidence, catalog: catalog))
        let row = try #require(projector.board().own.first)
        #expect(row.item.dependencies?.predecessors.first?.iid == 40)
        #expect(row.displayItem.dependencies?.predecessors.first?.iid == 41)
        let phone = RemoteBoardAdapter.presentation(RemoteBoardAdapter.card(row.item, account: "me@gitlab.test"), row: row)
        #expect(phone.dependencies?.predecessors.first?.url == newParent.webURL)
    }

    @Test func aRetainedCatalogObservationDoesNotErasePrivateMaterialsOrChangeTheirAuthorRole() throws {
        var evidence = item(try request())
        evidence.requiresCommentReview = true
        evidence.draftCount = 1
        var input = input(evidence: evidence, catalog: evidence)
        input.retainedRequests = [try request(["author": ["id": 8, "username": "other", "name": "Other"]])]
        let projector = MRBoardProjector(input: input)
        let row = try #require(projector.board().reviewed.first)
        #expect(row.item.isAuthored && row.item.mergeRequest?.author.username == "me")
        #expect(!row.displayItem.isAuthored && row.displayRequest?.author.username == "other")
        #expect(row.item.requiresCommentReview && row.item.draftCount == 1)
        #expect(!row.evidenceMatchesCatalogContext)
    }
    @Test func aDetailsSelectionCannotAdoptTheSameNumericMRFromAnotherHost() throws {
        let selected = item(try request())
        let foreign = item(try request(["web_url": "https://other.test/g/p/-/merge_requests/42"]))
        let board = MergeRequestBoardSnapshot(own: [foreign], reviewed: [], todos: [], attention: [],
            handoffs: [], host: "other.test", username: "me")
        #expect(board.row(matching: selected, host: "other.test", username: "me") == nil)
        #expect(board.row(matching: foreign, host: "other.test", username: "me")?.id == foreign.id)
        #expect(board.row(matching: foreign, host: "other.test", username: nil) == nil)
    }

    @Test func aContextMismatchRetainsFreshManualChecksWhileWithholdingCheckedWrites() throws {
        let evidence = item(try request())
        let catalog = item(try request(["target_branch": "release"]))
        let projection = MRCurrentRowProjection(evidence: evidence, catalog: catalog, username: "me")
        let row = MergeRequestBoardSnapshot.Row(item: projection.item, latestJob: nil, intents: [],
            catalog: projection.catalog, evidenceMatchesCatalogContext: projection.evidenceMatchesCatalogContext)
        var original = RemoteBoardAdapter.card(row.item, account: "me@gitlab.test")
        original.actions = [RemoteActionKind.checkThreads, .finishCommentReview, .deleteDraft, .verify,
                            .publish, .approve, .merge, .enqueueMerge].map { .init(id: $0.rawValue, kind: $0, token: "checked-a") }
        let phone = RemoteBoardAdapter.presentation(original, row: row)
        #expect(Set(phone.actions.map(\.kind)) == [.checkThreads, .finishCommentReview, .deleteDraft, .verify])
    }

    @Test(arguments: ["pipeline", "conflict"])
    func currentFactsDoNotInheritBusyStateFromAnOlderSameContextRequest(_ change: String) throws {
        let old = try request(["head_pipeline": ["id": 10, "status": "failed"], "has_conflicts": true])
        let current = try request(["head_pipeline": ["id": change == "pipeline" ? 11 : 10,
            "status": change == "pipeline" ? "success" : "failed"], "has_conflicts": change != "conflict"])
        #expect(MRAttentionRecord.sameContext(old, current))
        var evidence = item(old)
        evidence.draftCount = 1
        evidence.drafts = [.init(id: 7, authorID: 3, note: "Private reply", discussionID: nil, position: nil)]
        var input = input(evidence: evidence, catalog: item(current))
        input.requestFacts = [.init(request: old, conflictProcessing: change == "conflict", pipelineProcessing: change == "pipeline"),
            .init(request: current)]
        let projector = MRBoardProjector(input: input)
        let row = try #require(projector.board().own.first)
        #expect(row.item.mergeRequest?.headPipeline?.id == (change == "pipeline" ? 11 : 10))
        let pending = projector.pendingUserAttention
        #expect(UserAttentionSnapshot(candidates: pending.candidates).hasAttention)
        #expect(pending.humanActions.values.first?.action == .reviewDrafts)
    }

    @Test func pointQueriesPreserveReviewAndRefreshReasonsWithoutBuildingACatalog() throws {
        var evidence = item(try request(["author": ["id": 8, "username": "other", "name": "Other"]]))
        evidence.reviewingProgress = .needsReview
        let row = MergeRequestBoardSnapshot.Row(item: evidence, latestJob: nil, intents: [])
        var configuration = AutomationSettings()
        configuration.applyPreset(.manual, for: .codex)
        var point = MRBoardProjector.RowInput(account: account, automation: configuration, workflowEntries: [],
            assistantReady: true, catalogLoading: true)
        let review = MRBoardProjector.reviewingContext(for: row, input: point)
        #expect(review.status == .reviewNeeded && review.nextStep == .runReview)
        #expect(MRBoardProjector.isRecheckingAttention(for: row, input: point))
        #expect(!MRBoardProjector.attentionRefreshFailed(for: row, input: point))
        point.catalogLoading = false
        point.catalogReadFailed = true
        #expect(!MRBoardProjector.isRecheckingAttention(for: row, input: point))
        #expect(MRBoardProjector.attentionRefreshFailed(for: row, input: point))
        point.confirmationBusy = true
        #expect(!MRBoardProjector.attentionRefreshFailed(for: row, input: point))
        #expect(!MRBoardProjector.isRecheckingAttention(for: row, input: point))
        #expect(MRBoardProjector.reviewingContext(for: row, input: point).nextStep == review.nextStep)
    }

    @Test(arguments: ["project_id", "iid", "web_url", "sha", "source_project_id", "source_branch",
        "target_project_id", "target_branch", "state", "title", "description", "authorID", "authorUsername",
        "draft", "pipelineID", "pipelineProjectID", "pipelineStatus", "pipelineSHA", "pipelineRef",
        "has_conflicts", "detailed_merge_status", "blocking_discussions_resolved", "merge_when_pipeline_succeeds",
        "user", "labels"])
    func preparedFactsRequireEveryOriginalBindingField(_ change: String) throws {
        // given
        var fields: [String: Any] = ["source_project_id": 1, "target_project_id": 1,
            "head_pipeline": ["id": 10, "project_id": 1, "status": "failed", "sha": "a", "ref": "feature"],
            "has_conflicts": false, "detailed_merge_status": "mergeable", "blocking_discussions_resolved": true,
            "merge_when_pipeline_succeeds": false, "user": ["can_merge": true], "labels": ["first", "second"]]
        let original = try request(fields)
        switch change {
        case "project_id", "iid", "source_project_id", "target_project_id": fields[change] = 99
        case "web_url": fields[change] = "https://other.test/g/p/-/merge_requests/42"
        case "sha", "source_branch", "target_branch", "state", "title", "description", "detailed_merge_status":
            fields[change] = "changed"
        case "authorID": fields["author"] = ["id": 8, "username": "me", "name": "Me"]
        case "authorUsername": fields["author"] = ["id": 3, "username": "other", "name": "Me"]
        case "draft", "has_conflicts", "merge_when_pipeline_succeeds": fields[change] = true
        case "blocking_discussions_resolved": fields[change] = false
        case "user": fields[change] = ["can_merge": false]
        case "labels": fields[change] = ["second", "first"]
        default:
            var pipeline = try #require(fields["head_pipeline"] as? [String: Any])
            switch change {
            case "pipelineID": pipeline["id"] = 11
            case "pipelineProjectID": pipeline["project_id"] = 2
            case "pipelineStatus": pipeline["status"] = "success"
            case "pipelineSHA": pipeline["sha"] = "b"
            default: pipeline["ref"] = "other"
            }
            fields["head_pipeline"] = pipeline
        }
        let changed = try request(fields)
        let index = MRBoardProjector.RequestFacts.Index([.init(request: original, pipelineProcessing: true)])

        // when + then
        #expect(index.facts(for: original)?.pipelineProcessing == true)
        #expect(index.facts(for: changed) == nil)
    }

    @Test func preparedFactsKeepFirstMatchAndEquivalentAbsentBody() throws {
        let original = try request(["description": NSNull()])
        let equivalent = try request(["description": ""])
        let index = MRBoardProjector.RequestFacts.Index([
            .init(request: original, conflictProcessing: true), .init(request: equivalent, pipelineProcessing: true)])
        #expect(index.values.count == 1)
        #expect(index.facts(for: equivalent)?.conflictProcessing == true)
        #expect(index.facts(for: equivalent)?.pipelineProcessing == false)
    }

    @Test(arguments: ["title", "description"])
    func preparedFactsPreserveByteSensitiveSemanticFingerprints(_ field: String) throws {
        // given
        let composed = try request([field: "\u{00e9}"])
        let decomposed = try request([field: "e\u{0301}"])
        #expect(composed.semanticContextFingerprint != decomposed.semanticContextFingerprint)
        var index = MRBoardProjector.RequestFacts.Index()

        // when
        index.insert(composed) { .init(request: composed, conflictProcessing: true) }
        index.insert(decomposed) { .init(request: decomposed, pipelineProcessing: true) }

        // then
        #expect(index.values.count == 2)
        #expect(index.facts(for: composed)?.conflictProcessing == true)
        #expect(index.facts(for: composed)?.pipelineProcessing == false)
        #expect(index.facts(for: decomposed)?.conflictProcessing == false)
        #expect(index.facts(for: decomposed)?.pipelineProcessing == true)
    }

    @Test func preparedFactsDistinguishWhitespaceFromAnEmptyBody() throws {
        let empty = try request(["description": ""])
        let whitespace = try request(["description": " "])
        let index = MRBoardProjector.RequestFacts.Index([.init(request: empty, pipelineProcessing: true)])
        #expect(index.facts(for: whitespace) == nil)
    }

    @Test(arguments: [10, 100], [false, true])
    func projectionPreparesEachDistinctRequestFingerprintOnce(_ count: Int, _ includeFacts: Bool) throws {
        // given
        let requests = try (1...count).map { iid in
            try request(["iid": iid, "web_url": "https://gitlab.test/g/p/-/merge_requests/\(iid)"])
        }
        var fingerprintCount = 0
        let fingerprint: (GitLabMergeRequest) -> String = {
            fingerprintCount += 1
            return $0.semanticContextFingerprint
        }
        var index = MRBoardProjector.RequestFacts.Index(semanticFingerprint: fingerprint)
        if includeFacts {
            for request in requests + requests {
                index.insert(request) { .init(request: request, pipelineProcessing: true, semanticFingerprint: fingerprint) }
            }
        }
        let items = requests.map(item)
        var input = MRBoardProjector.Input(account: account)
        input.requestFacts = index.values
        input.attention = .init(host: account.host, username: account.username, revision: account.revision,
            evidence: items, attention: items, catalog: items)

        // when
        let projector = MRBoardProjector(input: input, semanticFingerprint: fingerprint)
        let rows = items.map { MergeRequestBoardSnapshot.Row(item: $0, latestJob: nil, intents: []) }
        for _ in 0..<3 {
            for row in rows { #expect(projector.rowInput(for: row).pipelineProcessing == includeFacts) }
        }

        // then
        #expect(index.values.count == (includeFacts ? count : 0))
        #expect(fingerprintCount == count)
    }

    @Test func evidenceAndCatalogFactsRemainSeparateAtTheSameHead() throws {
        let evidence = item(try request())
        let catalog = item(try request(["description": "New text", "head_pipeline": ["id": 11, "status": "success"]]))
        var input = input(evidence: evidence, catalog: catalog)
        input.requestFacts = [.init(request: try #require(evidence.mergeRequest), pipelineProcessing: true),
            .init(request: try #require(catalog.mergeRequest), workflowReadFailed: true)]
        let projector = MRBoardProjector(input: input)
        let evidenceRow = MergeRequestBoardSnapshot.Row(item: evidence, latestJob: nil, intents: [])
        let catalogRow = MergeRequestBoardSnapshot.Row(item: catalog, latestJob: nil, intents: [])
        #expect(projector.rowInput(for: evidenceRow).pipelineProcessing)
        #expect(!projector.rowInput(for: evidenceRow).workflowReadFailed)
        #expect(!projector.rowInput(for: catalogRow).pipelineProcessing)
        #expect(projector.rowInput(for: catalogRow).workflowReadFailed)
    }

    @Test func feedbackFailurePresentationUsesTheCurrentCanonicalDecisionRevision() throws {
        var evidence = item(try request())
        evidence.needsDiscussion = true
        evidence.observedDiscussionFingerprint = "checked-discussions"
        evidence.feedback = [.init(id: 20, author: .init(id: 7, username: "reviewer", name: "Reviewer"),
            system: false, resolvable: true, resolved: false, resolvedBy: nil, body: "Please rename X")]
        var input = input(evidence: evidence, catalog: evidence)
        input.automation.applyPreset(.full, for: .codex)
        input.automation.scope.setEnabled(true, for: .init(host: account.host, username: account.username, projectID: 1, iid: 42))
        let context = MRFeedbackLaunchCoordinator.Context(request: try request(), noteIDs: [20],
            fingerprint: evidence.observedDiscussionFingerprint, notes: evidence.feedback,
            configuration: input.automation, decisionRevision: "decision-a")
        input.feedbackLaunchFailures = [.init(account: .init(host: account.host, username: account.username, revision: account.revision), context: context)]
        input.feedbackDecisionRevisions[evidence.id] = "decision-a"
        #expect(MRBoardProjector(input: input).attentionItems.first?.feedback.count == 1)
        input.feedbackDecisionRevisions[evidence.id] = "decision-b"
        #expect(MRBoardProjector(input: input).attentionItems.isEmpty)
    }

}
