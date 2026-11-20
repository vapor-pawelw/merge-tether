import Foundation
import MergeTetherRemote
import Testing
@testable import MergeTether

@MainActor
struct DraftRegenerationTests {
    private let host = "gitlab.example.test"

    @Test func updatingADraftWritesOnlyItsBodyAndPreservesItsAnchor() async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "me")
        let existing = GitLabDraftNote(id: 11, authorID: 7, note: "Original", discussionID: "thread",
                                      position: .init(newPath: "Sources/A.swift", newLine: 51, oldPath: nil, oldLine: nil))
        let replacement = "@alice, można uprościć ten warunek?\n\nPrzykład: `count > 1`."
        let updated = GitLabDraftNote(id: existing.id, authorID: existing.authorID, note: replacement,
                                     discussionID: existing.discussionID, position: existing.position)
        let body = try JSONEncoder().encode(updated)
        gitlab.handler = { call in
            #expect(call.arguments == ["api", "/projects/34/merge_requests/2/draft_notes/11", "--hostname",
                                      host, "--method", "PUT", "--raw-field", "note=\(replacement)"])
            return InMemoryGitLab.output(String(decoding: body, as: UTF8.self))
        }

        let result = try await glab.updateDraftNote(existing, body: replacement, projectID: 34, iid: 2,
                                                    host: host, shouldProceed: { true })

        #expect(result == updated)
        #expect(gitlab.requests.count == 1)
    }

    @Test(arguments: ["one", "mr", "all"])
    func previewUsesOnlyTheRequestedExistingDraftsAndChosenInstructions(_ scopeName: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.makeCoordinator()
        let scope: DraftRegenerationScope = switch scopeName {
        case "one": .draft(projectID: 34, iid: 2, draftID: 11)
        case "mr": .mergeRequest(projectID: 34, iid: 2)
        default: .all
        }
        let custom = scopeName == "one" ? nil : "Zachowaj prośbę.\nWyjaśnij jej przyczynę."
        let expected: Set<String> = switch scopeName {
        case "one": ["2/11"]
        case "mr": ["2/11", "2/12"]
        default: ["2/11", "2/12", "3/11"]
        }

        #expect(coordinator.count(for: scope) == expected.count)
        #expect(coordinator.start(scope, instructions: custom))
        let preview = try await fixture.waitForPreview(coordinator)

        let generated = fixture.inputs.flatMap { input in input.drafts.compactMap { draft in
            draft.id.map { "\(input.request.iid)/\($0)" }
        } }
        #expect(Set(generated) == expected)
        #expect(generated.count == expected.count)
        #expect(fixture.inputs.allSatisfy { $0.instructions == custom })
        #expect(preview.total == expected.count && preview.completed == expected.count)
        #expect(Set(preview.proposals.map(\.id)).count == expected.count)
        #expect(Set(preview.proposals.map { "\($0.iid)/\($0.draftID)" }) == expected)
        #expect(fixture.writes.isEmpty)
    }

    @Test func regenerationReplacesOnlyTheCheckedDraftAndKeepsItPrivateInMax() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.settings.automation.applyPreset(.full, for: .codex)
        let coordinator = fixture.makeCoordinator()
        let scope = DraftRegenerationScope.mergeRequest(projectID: 34, iid: 2)
        #expect(coordinator.start(scope, instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let chosen = try #require(preview.proposals.first { $0.draftID == 11 })
        let replacement = try #require(chosen.replacement)
        let unrelated = fixture.drafts[2]?.last

        #expect(fixture.writes.isEmpty)
        let status = await coordinator.apply([chosen.id], batchID: preview.id)

        #expect(status == .completed)
        #expect(fixture.writes.map(\.endpoint) == ["/projects/34/merge_requests/2/draft_notes/11"])
        #expect(fixture.drafts[2]?.last == unrelated)
        let saved = try #require(fixture.drafts[2]?.first)
        #expect(saved.note == replacement)
        #expect(saved.discussionID == fixture.originalDrafts[2]?.first?.discussionID)
        #expect(saved.position == fixture.originalDrafts[2]?.first?.position)
        #expect(coordinator.isHeldForAutomaticPublication(saved, in: .init(projectID: 34, iid: 2)))
        let restarted = fixture.makeCoordinator(settings: SettingsManager(defaults: fixture.defaults))
        #expect(restarted.isHeldForAutomaticPublication(saved, in: .init(projectID: 34, iid: 2)))
        #expect(!fixture.writes.contains { $0.endpoint.contains("publish") || $0.endpoint.contains("discussions") })
    }

    @Test func batchSelectionRecognizesOnlyDraftsWhoseGeneratedTextStillMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let drafts = try #require(fixture.drafts[2])
        let originalGenerated = try #require(drafts.first)
        let previousAIText = GitLabDraftNote(id: 12, authorID: 7, note: "Earlier AI text",
                                            discussionID: nil, position: nil)
        let previouslyGenerated = [originalGenerated, previousAIText]
        let claims = try previouslyGenerated.map { draft in
            try AssistantJobResult.GeneratedDraft(id: #require(draft.id),
                bodySHA256: AICommentAssessmentStore.digest(#require(draft.note)))
        }
        try AICommentProvenanceStore.recordGenerated(claims, baseline: [], current: previouslyGenerated,
            context: .init(host: host, username: "me", userID: 7, projectID: 34, iid: 2), runID: UUID(),
            headSHA: #require(fixture.requests.first?.sha), in: fixture.provenanceDirectory)

        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.all, instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)

        #expect(preview.proposals.filter(\.selectedByDefault).map(\.id) ==
                preview.proposals.filter { $0.iid == 2 && $0.draftID == 11 }.map(\.id))
        #expect(preview.proposals.allSatisfy { $0.replacement != nil })
        #expect(fixture.writes.isEmpty)
    }

    @Test(arguments: ["text", "head", "published", "discussion"])
    func aChangeAfterPreviewPreventsOverwritingTheDraft(_ change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.draft(projectID: 34, iid: 2, draftID: 11), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let proposal = try #require(preview.proposals.first)
        switch change {
        case "text": fixture.replaceBody(iid: 2, draftID: 11, body: "A more specific human correction")
        case "head": fixture.changedHeads.insert(2)
        case "published": fixture.drafts[2]?.removeAll { $0.id == 11 }
        default: fixture.discussionBody = "New evidence from the discussion"
        }

        let result = await coordinator.apply([proposal.id], batchID: preview.id)

        #expect(result != .completed)
        #expect(fixture.writes.isEmpty)
    }

    @Test func aRemoteScopeTokenCannotAuthorizeNewlyArrivedDrafts() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.makeCoordinator()
        let scope = DraftRegenerationScope.mergeRequest(projectID: 34, iid: 2)
        let originalToken = try #require(coordinator.scopeToken(for: scope))
        fixture.visibleDrafts[2]?.append(.init(id: 91, authorID: 7, note: "Arrived later",
                                              discussionID: nil, position: nil))

        #expect(coordinator.scopeToken(for: scope) != originalToken)
        #expect(!coordinator.start(scope, instructions: nil, expectedToken: originalToken))
        #expect(coordinator.batch == nil)
        #expect(fixture.inputs.isEmpty && fixture.writes.isEmpty)
    }

    @Test func savingAcrossMergeRequestsReportsTheSuccessfulAndFailedDraftsIndividually() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.failingDrafts = ["/projects/34/merge_requests/2/draft_notes/11"]
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.all, instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let selected = Set(preview.proposals.filter { $0.draftID == 11 }.map(\.id))

        let status = await coordinator.apply(selected, batchID: preview.id)

        #expect(status == .partial)
        #expect(Set(fixture.writes.map(\.endpoint)) == [
            "/projects/34/merge_requests/2/draft_notes/11", "/projects/34/merge_requests/3/draft_notes/11"
        ])
        #expect(fixture.drafts[2] == fixture.originalDrafts[2])
        #expect(fixture.drafts[3]?.first?.note == "Rewritten 3/11")
        #expect(coordinator.batch?.proposals.first { $0.iid == 3 && $0.draftID == 11 }?.issue == .saved)
        #expect(coordinator.batch?.proposals.first { $0.iid == 2 && $0.draftID == 11 }?.issue == .failed)
    }

    @Test func anOutdatedDraftOffersNoReplacementOrDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.outdatedDraftIDs.insert(11)
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.draft(projectID: 34, iid: 2, draftID: 11), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let proposal = try #require(preview.proposals.first)

        #expect(proposal.issue == .outdated && proposal.replacement == nil)
        #expect(await coordinator.apply([proposal.id], batchID: preview.id) != .completed)
        #expect(fixture.drafts == fixture.originalDrafts)
        #expect(fixture.writes.isEmpty)
    }

    @Test func proposedQuickActionsCannotBeSavedAsDraftText() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.generatedBodies[11] = "The text looks good.\n\n /resolve"
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.draft(projectID: 34, iid: 2, draftID: 11), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let proposal = try #require(preview.proposals.first)

        #expect(proposal.issue == .failed && proposal.replacement == nil)
        #expect(await coordinator.apply([proposal.id], batchID: preview.id) != .completed)
        #expect(fixture.writes.isEmpty)
    }

    @Test func aLostUpdateResponseIsReconciledWithoutSendingAnUpdateAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.lostResponses = ["/projects/34/merge_requests/2/draft_notes/11"]
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.draft(projectID: 34, iid: 2, draftID: 11), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let proposal = try #require(preview.proposals.first)

        let result = await coordinator.apply([proposal.id], batchID: preview.id)

        #expect(result == .completed)
        #expect(fixture.writes.count == 1)
        let saved = try #require(fixture.drafts[2]?.first)
        #expect(saved.note == proposal.replacement)
        #expect(coordinator.isHeldForAutomaticPublication(saved, in: .init(projectID: 34, iid: 2)))
    }

    @Test func anAccountRoundTripWhileLaunchingAnUpdateInvalidatesTheBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.draft(projectID: 34, iid: 2, draftID: 11), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)
        let proposal = try #require(preview.proposals.first)
        fixture.gitlab.beforeCommand = { call in
            guard call.method == "PUT" else { return }
            fixture.glab.currentUsername = "other"
            fixture.glab.currentUsername = "me"
        }

        let result = await coordinator.apply([proposal.id], batchID: preview.id)

        #expect(result != .completed)
        #expect(coordinator.batch == nil)
        #expect(fixture.writes.isEmpty)
    }

    @Test func aSecondGenerationCannotReplaceAnUnreviewedBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let coordinator = fixture.makeCoordinator()
        #expect(coordinator.start(.mergeRequest(projectID: 34, iid: 2), instructions: nil))
        let preview = try await fixture.waitForPreview(coordinator)

        #expect(!coordinator.start(.all, instructions: "A different request"))
        #expect(coordinator.batch == preview)
        #expect(coordinator.discard(preview.id))
        #expect(coordinator.batch == nil)
        #expect(fixture.writes.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let host = "gitlab.example.test"
        let gitlab = InMemoryGitLab()
        let glab: GlabService
        let suite = "DraftRegenerationTests.\(UUID())"
        let provenanceDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults: UserDefaults
        let settings: SettingsManager
        let requests: [GitLabMergeRequest]
        let originalDrafts: [Int: [GitLabDraftNote]]
        var drafts: [Int: [GitLabDraftNote]]
        var visibleDrafts: [Int: [GitLabDraftNote]]
        var inputs: [DraftRegenerationGenerationInput] = []
        var changedHeads: Set<Int> = []
        var outdatedDraftIDs: Set<Int> = []
        var failingDrafts: Set<String> = []
        var lostResponses: Set<String> = []
        var generatedBodies: [Int: String] = [:]
        var discussionBody = "Original discussion"

        var writes: [InMemoryGitLab.Request] { gitlab.requests.filter { $0.method != "GET" } }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = SettingsManager(defaults: defaults)
            glab = gitlab.service(host: host, username: "me")
            requests = try [2, 3].map { iid in
                try MRDependencyPresentationTests().request(iid, source: "topic-\(iid)", title: "Change \(iid)")
            }
            let anchor = GitLabDraftNote.Position(newPath: "Sources/Validator.swift", newLine: 20,
                                                  oldPath: nil, oldLine: nil)
            originalDrafts = [
                2: [.init(id: 11, authorID: 7, note: "Original finding", discussionID: "thread", position: anchor),
                    .init(id: 12, authorID: 7, note: "Handwritten draft", discussionID: nil, position: nil)],
                3: [.init(id: 11, authorID: 7, note: "Draft in another MR", discussionID: nil, position: nil)]
            ]
            drafts = originalDrafts
            visibleDrafts = originalDrafts
            gitlab.handler = { [weak self] call in
                guard let self else { throw CancellationError() }
                return try respond(to: call)
            }
        }

        func close() {
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: provenanceDirectory)
        }

        func makeCoordinator(settings: SettingsManager? = nil) -> DraftRegenerationCoordinator {
            .init(glab: glab, settings: settings ?? self.settings, provenanceDirectory: provenanceDirectory, candidates: { [self] in
                requests.map { .init(request: $0, drafts: visibleDrafts[$0.iid] ?? []) }
            }, generate: { [self] input in
                inputs.append(input)
                return input.drafts.compactMap { draft in
                    draft.id.map { id in
                        let body = generatedBodies[id] ?? "Rewritten \(input.request.iid)/\(id)"
                        return .init(draftID: id, body: outdatedDraftIDs.contains(id) ? nil : body)
                    }
                }
            })
        }

        func waitForPreview(_ coordinator: DraftRegenerationCoordinator) async throws -> DraftRegenerationBatch {
            let deadline = ContinuousClock.now + .seconds(5)
            while coordinator.batch?.phase == .generating, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let batch = try #require(coordinator.batch)
            try #require(batch.phase == .ready)
            return batch
        }

        func replaceBody(iid: Int, draftID: Int, body: String) {
            guard let index = drafts[iid]?.firstIndex(where: { $0.id == draftID }),
                  let original = drafts[iid]?[index] else { return }
            drafts[iid]?[index] = .init(id: original.id, authorID: original.authorID, note: body,
                                       discussionID: original.discussionID, resolveDiscussion: original.resolveDiscussion,
                                       position: original.position)
        }

        private func respond(to call: InMemoryGitLab.Request) throws -> ProcessRunner.Output {
            if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":7,"username":"me"}"#) }
            for request in requests {
                let iid = request.iid
                let prefix = "/projects/34/merge_requests/\(iid)"
                let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                let head = changedHeads.contains(iid) ? String(repeating: "b", count: 40) : request.sha ?? ""
                switch call.endpoint {
                case prefix:
                    return InMemoryGitLab.output(encoded.replacingOccurrences(of: request.sha ?? "", with: head))
                case let path where path.hasPrefix(prefix + "/draft_notes?"):
                    return try draftResponse(drafts[iid] ?? [])
                case let path where path.hasPrefix(prefix + "/discussions?"):
                    return try InMemoryGitLab.json([["id": "thread", "notes": [
                        ["id": 81, "body": discussionBody, "author": ["id": 20, "username": "reviewer"], "system": false]
                    ]]])
                case let path where path.hasPrefix(prefix + "/draft_notes/") && call.method == "PUT":
                    guard !failingDrafts.contains(path) else { return InMemoryGitLab.output(error: "request rejected", code: 1) }
                    guard let draftID = Int(path.dropFirst((prefix + "/draft_notes/").count)),
                          let field = call.arguments.first(where: { $0.hasPrefix("note=") }),
                          drafts[iid]?.contains(where: { $0.id == draftID }) == true else { return try gitlab.unexpected(call) }
                    let body = String(field.dropFirst("note=".count))
                    replaceBody(iid: iid, draftID: draftID, body: body)
                    if lostResponses.contains(path) { return InMemoryGitLab.output(error: "response lost", code: 1) }
                    return try draftResponse(#require(drafts[iid]?.first { $0.id == draftID }))
                default: break
                }
            }
            return try gitlab.unexpected(call)
        }

        private func draftResponse<T: Encodable>(_ value: T) throws -> ProcessRunner.Output {
            .init(stdout: try JSONEncoder().encode(value), stderr: "", exitCode: 0)
        }
    }
}
