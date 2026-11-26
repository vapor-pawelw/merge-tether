import Foundation
import Testing
import MergeTetherRemote
@testable import MergeTether

@MainActor @Suite struct RemoteHostDetailTests {
    @Test func inboxReadRejectsAnOlderSelectionWhenANewTodoArrives() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401])
        let displayed = try await f.board()
        let command = try f.inboxReadCommand(from: displayed)
        f.setInboxTodos([401, 402])

        await f.transport.onMessage?(.init(type: .command, command: command))

        #expect(f.transport.messages.last?.result?.status == .changed)
        #expect(f.gitlab.requests.allSatisfy { $0.method != "POST" })
        let current = try await f.board()
        #expect(Set(current.cards.filter { $0.id.hasPrefix("todo:") }.map(\.id)) == ["todo:401", "todo:402"])
    }

    @Test func inboxReadSelectionExcludesProposalsAndAssistantJobs() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401])
        let board = try await f.board()
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let pin = try #require(BoardCardPin.mergeRequest(host: target.host, username: target.username, projectID: 1, iid: 2))
        let proposal = MergeRequestBoardSnapshot.OtherCard(id: pin, content: .proposal(
            .init(target: target, title: "Review proposal", url: f.source.webURL, item: nil, todos: [], intents: [])))
        let work = AssistantAutomationRunner.MergeRequestWork(host: target.host, projectID: 1, iid: 2)
        let key = AssistantAutomationRunner.JobKey(assistant: .codex, work: work, username: target.username,
            workspace: "", access: .gitLabRead)
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(), key: key, title: "Review job", prompt: "",
            createdAt: Date(), allowsPush: false)
        let job = MergeRequestBoardSnapshot.OtherCard(id: pin, content: .job(handoff))

        let selection = RemoteInboxReadSelection(f.monitor.inboxItems + [proposal, job])
        #expect(board.inboxReadAction != nil)
        #expect(selection?.action(hostSession: board.hostSession, account: board.account) == board.inboxReadAction)
        #expect(RemoteInboxReadSelection([proposal, job]) == nil)
    }

    @Test func inboxReadKeepsFailedTodosAndRecoversThePartialReceiptWithoutReplayingWrites() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401, 402])
        f.gitlab.write("fail-todo-401")
        let displayed = try await f.board()
        let command = try f.inboxReadCommand(from: displayed)

        await f.transport.onMessage?(.init(type: .command, command: command))

        #expect(f.transport.messages.last?.result?.status == .partial)
        #expect(f.monitor.currentAccountTodos.map(\.id) == [401])
        await f.transport.onMessage?(.init(type: .receipt, challenge: UUID(), command: command))
        #expect(f.transport.messages.last?.result?.status == .partial)
        let writes = f.gitlab.requests.filter { $0.method == "POST" }.map(\.endpoint)
        #expect(writes.sorted() == ["/todos/401/mark_as_done", "/todos/402/mark_as_done"])
    }

    @Test func inboxReadAcknowledgesLocalUpdatesAndKeepsTheHiddenReviewHidden() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401])
        let settings = f.monitor.settings
        let finishedTarget = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 6)
        let finishedURL = try #require(URL(string: "https://gitlab.example.test/g/p/-/merge_requests/6"))
        let original = f.gitlab.text("request").replacingOccurrences(of: #""iid":2"#, with: #""iid":6"#)
            .replacingOccurrences(of: f.source.webURL.absoluteString, with: finishedURL.absoluteString)
        let open = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(original.utf8))
        let closed = try JSONDecoder().decode(GitLabMergeRequest.self,
            from: Data(original.replacingOccurrences(of: #""state":"opened""#, with: #""state":"closed""#).utf8))
        settings.mrLifecycleLedger.record(open, for: finishedTarget)
        settings.mrLifecycleLedger.record(closed, for: finishedTarget)
        settings.save()
        let hidden = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 7)
        let hiddenURL = try #require(URL(string: "https://gitlab.example.test/g/p/-/merge_requests/7"))
        try #require(settings.hideFilteredReviews([.init(target: hidden, title: "Hidden review", url: hiddenURL)]))

        let displayed = try await f.board()
        let command = try f.inboxReadCommand(from: displayed)
        #expect(displayed.cards.filter { $0.id.hasPrefix("completion:") }.count == 2)
        await f.transport.onMessage?(.init(type: .command, command: command))

        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(f.monitor.lifecycleCompletions.isEmpty)
        #expect(f.monitor.hiddenReviewNotifications.isEmpty)
        // Saved targets stay bound to the GitLab user ID until a restart reads /user again.
        let persisted = SettingsManager(defaults: f.defaults)
        #expect(persisted.bindAuthenticatedAccount(.init(host: "gitlab.example.test", username: "me", userID: 3)))
        #expect(persisted.ignoredMergeRequests.contains(hidden))
        #expect(persisted.filteredHiddenReviewDetails[hidden]?.inboxNotification == nil)
        #expect(persisted.mrLifecycleLedger.isSuppressed(finishedTarget))
        #expect(f.gitlab.requests.filter { $0.method == "POST" }.map(\.endpoint) == ["/todos/401/mark_as_done"])
    }

    @Test func inboxReadRevokesQueuedTodoWritesAfterTheAccountEpochChanges() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401, 402])
        let command = try f.inboxReadCommand(from: await f.board())
        f.gitlab.beforeCommand = { request in
            if request.method == "POST" {
                f.monitor.glab.currentUsername = "other"
                f.monitor.glab.currentUsername = "me"
            }
        }

        await f.transport.onMessage?(.init(type: .command, command: command))

        #expect(f.transport.messages.last?.result?.status == .uncertain)
        #expect(f.gitlab.requests.allSatisfy { $0.method != "POST" })
    }

    @Test func standaloneInboxTodoAcknowledgementOnlyPostsTheDisplayedTodo() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.setInboxTodos([401, 402])
        let displayed = try await f.board()
        let card = try #require(displayed.cards.first { $0.id == "todo:402" })
        let action = try #require(card.actions.first { $0.id == "markDone" })
        let command = RemoteCommand(hostSession: displayed.hostSession, account: displayed.account, cardID: card.id,
            actionID: action.id, token: action.token)

        await f.transport.onMessage?(.init(type: .command, command: command))

        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(f.monitor.currentAccountTodos.map(\.id) == [401])
        #expect(f.gitlab.requests.filter { $0.method == "POST" }.map(\.endpoint) == ["/todos/402/mark_as_done"])
    }

    @Test func draftCardAdvertisesDraftStateSeparatelyFromTheBadge() async throws {
        let f = try Fixture(draft: true); defer { f.clean() }
        let displayed = try await f.board()
        let card = try #require(displayed.cards.first { $0.id == "mr:1:2" })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect((json["presentation"] as? [String: Any])?["isDraft"] as? Bool == true)
    }

    @Test func phonePinSurvivesAutomaticSortingAndRejectsAnOlderPinState() async throws {
        let f = try Fixture(); defer { f.clean() }
        let settings = f.monitor.settings
        settings.boardOrderingMethod = .automatic
        let pin = try #require(BoardCardPin.mergeRequest(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2))
        settings.boardPins.insert(pin)
        settings.save()
        let olderPhone = try await f.board()
        #expect(olderPhone.cards.allSatisfy { $0.actions.allSatisfy { $0.id != "editCard" } })

        let board = try await f.board(cardActions: true)
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as? [String: Any])
        #expect(card.orderGroup == nil)
        #expect(wire["pinned"] as? Bool == true)
        let action = try #require(card.actions.first { $0.id == "editCard" })

        settings.boardPins.remove(pin)
        settings.save()
        let unpin = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: card.id,
            actionID: action.id, token: action.token, argument: #"{"pin":{"_0":false}}"#)
        await f.transport.onMessage?(.init(type: .command, command: unpin))
        #expect(f.transport.messages.last?.result?.status == .changed)

        let latest = try await f.board(cardActions: true)
        let current = try #require(latest.cards.first { $0.id == card.id }?.actions.first { $0.id == "editCard" })
        let repin = RemoteCommand(hostSession: latest.hostSession, account: latest.account, cardID: card.id,
            actionID: current.id, token: current.token, argument: #"{"pin":{"_0":true}}"#)
        await f.transport.onMessage?(.init(type: .command, command: repin))
        #expect(f.transport.messages.last?.result?.status == .completed)
        let restarted = SettingsManager(defaults: f.defaults)
        #expect(restarted.bindAuthenticatedAccount(.init(host: "gitlab.example.test", username: "me", userID: 3)))
        #expect(restarted.boardPins.contains(pin))
    }

    @Test func phoneEditsTheDisplayedDraftPolicyAndKeepsRepositoryScopeSeparate() async throws {
        let f = try Fixture(draft: true); defer { f.clean() }
        let settings = f.monitor.settings
        settings.automation.applyPreset(.safe, for: .codex)
        settings.setAutomationGloballyEnabled(false)
        settings.save()
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)

        let board = try await f.board(cardActions: true)
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let action = try #require(card.actions.first { $0.id == "editCard" })
        let edit = RemoteCommand(hostSession: board.hostSession, account: board.account, cardID: card.id,
            actionID: action.id, token: action.token, argument: #"{"automation":{"_0":"on"}}"#)
        await f.transport.onMessage?(.init(type: .command, command: edit))
        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(settings.configuredAutomation.scope[target] == .forceOn)
        #expect(settings.configuredAutomation.scope[target.repository] == .inherit)
        #expect(!settings.automationGloballyEnabled)

        let latest = try await f.board(cardActions: true)
        let current = try #require(latest.cards.first { $0.id == card.id }?.actions.first { $0.id == "editCard" })
        let change = RemoteCommand(hostSession: latest.hostSession, account: latest.account, cardID: card.id,
            actionID: current.id, token: current.token, argument: #"{"repository":{"_0":"off"}}"#)
        await f.transport.onMessage?(.init(type: .command, command: change))
        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(settings.configuredAutomation.scope[target] == .forceOn)
        #expect(settings.configuredAutomation.scope[target.repository] == .paused)
    }

    @Test func detailAvatarsComeFromDeliveredPeopleAndOnlyApprovedOrigins() async throws {
        let gitLab = try #require(URL(string: "https://gitlab.example.test/uploads/person.png"))
        let gravatar = try #require(URL(string: "https://secure.gravatar.com/avatar/hash"))
        let unrelated = try #require(URL(string: "https://external.example.net/profile.png"))
        let f = try Fixture(readAvatarThumbnail: { _ in Data([1, 2, 3]) })
        defer { f.clean() }
        f.detailNotes = [
            .init(id: "1", body: "A comment", avatarURL: gitLab),
            .init(id: "2", body: "Another comment", avatarURL: gravatar),
            .init(id: "3", body: "External avatar", avatarURL: unrelated)
        ]
        let board = try await f.board(detailAvatars: true)
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let request = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        await f.host.detailTask?.value
        await f.host.detailAvatarTask?.value
        let responses = f.transport.messages.filter { $0.detailResponse?.request == request || $0.challenge == request.id }
        #expect(responses.map(\.type) == [.details, .avatarThumbnails])
        #expect(Set(responses.last?.avatarThumbnails?.map(\.url) ?? []) == [gitLab, gravatar])
    }

    @Test func hostSendsBoardBeforeAvatarsAndSkipsCachedImagesAndOlderPhones() async throws {
        let avatar = try #require(URL(string: "https://gitlab.example.test/uploads/avatar.png"))
        let jpeg = Data([1, 2, 3])
        let f = try Fixture(avatar: avatar, readAvatarThumbnail: { url in url == avatar ? jpeg : nil })
        defer { f.clean() }
        _ = try await f.board()
        #expect(f.transport.messages.allSatisfy { $0.type != .avatarThumbnails })

        let challenge = UUID()
        await f.transport.onMessage?(.init(type: .hello, challenge: challenge,
            capabilities: [RemoteMessage.boardAvatarsCapability]))
        await f.host.avatarTask?.value
        let responses = f.transport.messages.filter { $0.challenge == challenge }
        #expect(responses.map(\.type) == [.snapshot, .avatarThumbnails])
        #expect(responses.last?.avatarThumbnails == [.init(url: avatar, jpeg: jpeg)])

        let cachedChallenge = UUID()
        await f.transport.onMessage?(.init(type: .hello, challenge: cachedChallenge,
            capabilities: [RemoteMessage.boardAvatarsCapability], cachedAvatarURLs: [avatar]))
        await f.host.avatarTask?.value
        #expect(f.transport.messages.filter { $0.challenge == cachedChallenge }.map(\.type) == [.snapshot])
    }

    @Test func cachedDetailsReturnCurrentMacDiscussionsWithoutAGitLabRead() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Old comment")]
        let board = try await f.board()
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let live = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: live))
        await f.host.detailTask?.value
        #expect(f.readerCount == 1)

        let handler = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint.contains("/discussions?") {
                return InMemoryGitLab.output(#"[{"id":"local","notes":[{"id":2,"body":"New Mac comment","system":false,"created_at":"2026-11-24T09:30:00Z"}]}]"#)
            }
            return try await handler(call)
        }
        _ = try await f.monitor.glab.fetchMergeRequestDiscussions(projectID: 1, iid: 2, host: "gitlab.example.test")
        let count = f.gitlab.requests.count
        let request = try RemoteDetailRequest(card: card, board: board, cachedOnly: true)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        await f.host.detailTask?.value
        let result = try #require(f.transport.messages.last?.detailResponse)
        #expect(result.request == request && result.status == .current && result.isPreview != true)
        #expect(result.details?.threads?.first?.notes.first?.body == "New Mac comment")
        #expect(result.details?.activity.map(\.id) == ["note/2"])
        #expect(f.readerCount == 1 && f.gitlab.requests.count == count)
    }

    @Test func phoneEventLogInterleavesGitLabAndAppEventsAndKeepsLastKnownEventsOnPartialFailure() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.usesLiveDetailReader = true
        var failLabels = false
        let handler = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            switch call.endpoint {
            case "/projects/1/merge_requests/2/discussions?per_page=100":
                return InMemoryGitLab.output("""
                [{"id":"discussion-id","notes":[{"id":7,"created_at":"1970-01-01T00:00:40Z","body":"Published reply"},
                {"id":8,"created_at":"1970-01-01T00:00:30Z","body":"changed the description","system":true}]}]
                """)
            case "/projects/1/merge_requests/2/resource_state_events?per_page=100":
                return InMemoryGitLab.output(#"[{"id":1,"created_at":"1970-01-01T00:00:10Z","state":"opened"}]"#)
            case "/projects/1/merge_requests/2/resource_label_events?per_page=100":
                if failLabels { return InMemoryGitLab.output(error: "HTTP 503", code: 1) }
                return InMemoryGitLab.output(#"[{"id":2,"created_at":"1970-01-01T00:00:50Z","action":"add","label":{"name":"Ready"}}]"#)
            case "/projects/1/merge_requests/2/resource_milestone_events?per_page=100":
                return InMemoryGitLab.output(#"[{"id":3,"created_at":"1970-01-01T00:00:15Z","action":"add","milestone":{"title":"Release"}}]"#)
            default: return try await handler(call)
            }
        }
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        f.monitor.settings.recordAutomationEvent(target: target, action: .publication, origin: .automatic,
            state: .completed, publishedNoteID: 7, now: Date(timeIntervalSince1970: 43))
        f.monitor.settings.recordAutomationEvent(target: target, action: .review, origin: .manual,
            state: .completed, now: Date(timeIntervalSince1970: 20))
        let reviewID = "event/\(try #require(f.monitor.settings.automationEvents.first { $0.action == .review }).id)"
        let board = try await f.board()
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let expected = ["label/2", "note/7", "note/8", reviewID, "milestone/3", "state/1"]

        let first = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: first))
        await f.host.detailTask?.value
        let details = try #require(f.transport.messages.last?.detailResponse?.details)
        #expect(details.activity.map(\.id) == expected)
        #expect(details.activityPartial == nil)
        #expect(details.activity.first { $0.id == "note/7" }?.note?.matchingThread(in: details.threads)?.id == "discussion/discussion-id")
        #expect(details.activity.first { $0.id == "note/8" }?.note == .init(id: 8))
        let activityReads = f.gitlab.requests.filter { $0.endpoint.contains("/resource_") }
        #expect(activityReads.count == 3)
        #expect(activityReads.allSatisfy { $0.method == "GET" && $0.arguments.contains("--paginate") })

        failLabels = true
        f.date += 1
        let retry = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: retry))
        await f.host.detailTask?.value
        let partial = try #require(f.transport.messages.last?.detailResponse?.details)
        #expect(partial.activity.map(\.id) == expected)
        #expect(partial.activityPartial == true)

        let count = f.gitlab.requests.count
        let cached = try RemoteDetailRequest(card: card, board: board, cachedOnly: true)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: cached))
        await f.host.detailTask?.value
        let reopened = try #require(f.transport.messages.last?.detailResponse?.details)
        #expect(reopened.activity.map(\.id) == expected)
        #expect(reopened.activityPartial == true)
        #expect(f.gitlab.requests.count == count)
    }

    @Test func phoneEventLogCapDoesNotMarkTheDiscussionAsTruncated() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.usesLiveDetailReader = true
        let handler = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint == "/projects/1/merge_requests/2/resource_label_events?per_page=100" {
                return try InMemoryGitLab.json((1...31).map { id in
                    ["id": id, "created_at": "1970-01-01T00:00:50Z", "action": "add", "label": ["name": "Label \(id)"]] as [String: Any]
                })
            }
            return try await handler(call)
        }
        let board = try await f.board()
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let request = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        await f.host.detailTask?.value
        let details = try #require(f.transport.messages.last?.detailResponse?.details)
        #expect(details.activity.count == 30)
        #expect(details.activityPartial == nil)
        #expect(!details.truncated)
    }

    @Test func phoneReceivesLocalDetailsBeforeGitLabAndCachedDiscussionsOnReopen() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Previously loaded comment")]
        f.heldReads = [1, 2]
        let board = try await f.board(detailPreviews: true)
        let handler = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint.contains("/discussions?") {
                return InMemoryGitLab.output(#"[{"id":"local","notes":[{"id":2,"body":"Already read on the Mac","system":false}]}]"#)
            }
            return try await handler(call)
        }
        _ = try await f.monitor.glab.fetchMergeRequestDiscussions(projectID: 1, iid: 2, host: "gitlab.example.test")
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let first = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: first))
        try await f.waitForRead(1)
        let local = f.transport.messages.last { $0.detailResponse?.request == first }?.detailResponse
        #expect(local?.details?.description == "Context")
        #expect(local?.details?.threads?.first?.notes.first?.body == "Already read on the Mac")
        #expect(local?.details?.activityPartial == nil)
        #expect(local?.isPreview == true)
        f.gitlab.write("release-1")
        await f.host.detailTask?.value
        #expect(f.transport.messages.last?.detailResponse?.details?.description == "Read 1")
        #expect(f.transport.messages.last?.detailResponse?.isPreview != true)

        f.date += 1
        let reopened = try RemoteDetailRequest(card: card, board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: reopened))
        try await f.waitForRead(2)
        let cached = f.transport.messages.last { $0.detailResponse?.request == reopened }?.detailResponse
        #expect(cached?.details?.threads?.first?.notes.first?.body == "Previously loaded comment")
        f.gitlab.write("release-2")
        await f.host.detailTask?.value
    }

    @Test(arguments: ["current", "otherHead", "otherAccount"])
    func phoneApprovalsShowOpenFindingsOnlyForTheApprovedHeadAndAccount(_ scenario: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let target = MRAutomationScope.Target(host: "gitlab.example.test",
            username: scenario == "otherAccount" ? "other" : "me", projectID: 1, iid: 2)
        let head = scenario == "otherHead" ? String(repeating: "b", count: 40) : try #require(f.source.sha)
        f.monitor.settings.recordAutomationEvent(target: target, action: .approval, origin: .automatic,
            state: .completed, approvedHeadSHA: head)

        let board = try await f.board()
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let presentation = try #require(card.presentation)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(presentation)) as? [String: Any]
        #expect(payload?["approvedWithOpenFindings"] as? Bool == (scenario == "current" ? true : nil))

        // An older phone drops the new field before computing its detail request digest.
        var olderCard = card
        var olderPayload = try #require(payload)
        olderPayload["approvedWithOpenFindings"] = nil
        olderCard.presentation = try JSONDecoder().decode(RemoteCardText.self,
            from: JSONSerialization.data(withJSONObject: olderPayload))
        #expect(try RemoteDetailRequest(card: olderCard, board: board).matches(board))
    }

    @Test(arguments: ["ready", "headChanged", "lostResponse"])
    func phoneMarkReadyUsesTheMacWorkflowAndNeverReplaysAnUncertainWrite(_ scenario: String) async throws {
        let f = try Fixture(draft: true); defer { f.clean() }
        let board = try await f.board(markReady: true)
        let card = try #require(board.cards.first { $0.id == "mr:1:2" })
        let action = try #require(card.actions.first { $0.kind == .markReady })
        let command = RemoteCommand(hostSession: board.hostSession, account: board.account,
            cardID: card.id, actionID: action.id, token: action.token)
        if scenario == "headChanged" {
            f.gitlab.write("request", f.gitlab.text("request").replacingOccurrences(
                of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40)))
        }
        if scenario == "lostResponse" { f.gitlab.write("lose-ready-response") }
        await f.transport.onMessage?(.init(type: .command, command: command))
        let result = try #require(f.transport.messages.last { $0.type == .result }?.result)
        #expect(result.status == (scenario == "ready" ? .completed : scenario == "headChanged" ? .changed : .uncertain))
        let writes = f.gitlab.requests.filter { $0.arguments.starts(with: ["mr", "update"]) }
        #expect(writes.count == (scenario == "headChanged" ? 0 : 1))
        if scenario != "headChanged" {
            #expect(writes.first?.arguments.contains("--ready") == true)
            #expect(f.gitlab.text("request").contains("\"draft\":false"))
            await f.transport.onMessage?(.init(type: .command, command: command))
            #expect(f.gitlab.requests.filter { $0.arguments.starts(with: ["mr", "update"]) }.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func lateAuthorIdentityPaintsAnOpenPhoneWithoutAnotherDetailsRead(_ supported: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Root", origin: .ai, authorID: 7)]
        let board = try await f.board(originUpdates: supported)
        let phone = RemoteDetailState()
        let request = try #require(phone.begin(card: board.cards[0], board: board))
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        await f.host.detailTask?.value
        let response = try #require(f.transport.messages.last(where: { $0.detailResponse?.request == request })?.detailResponse)
        phone.receive(response, board: board)
        let reads = f.gitlab.requests.count
        let previous = f.gitlab.handler
        f.gitlab.handler = { call in
            if call.endpoint == "/users/7" { return InMemoryGitLab.output(#"{"id":7,"bot":true}"#) }
            return try await previous!(call)
        }
        _ = try await f.monitor.glab.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        if supported {
            try await waitForOrigins(1, f)
            let update = try #require(f.transport.messages.last?.detailOrigins)
            #expect(update.changes.isEmpty && update.authorKinds?.first?.authorKind == .automation)
            #expect(phone.receiveOrigins(update, board: board))
            #expect(phone.response?.details?.threads?[0].notes[0].authorKind == .automation)
            #expect(phone.response?.details?.threads?[0].notes[0].origin == .ai)
        }
        #expect(f.readerCount == 1)
        #expect(f.gitlab.requests.dropFirst(reads).allSatisfy { $0.endpoint == "/users/7" && $0.method == "GET" })
        #expect(f.transport.messages.compactMap(\.detailOrigins).count == (supported ? 1 : 0))
    }

    @Test(arguments: [RemoteDetailNote.Origin.human, .uncertain])
    func markingAndUnmarkingABotUpdatesPhoneMachineBadgesWithoutReplacingTextEvidence(_ underlying: RemoteDetailNote.Origin) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Pipeline completed successfully", origin: underlying,
            authorID: 7, authorKind: .regular)]
        let previous = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint == "/users/7" { return InMemoryGitLab.output(#"{"id":7,"bot":false}"#) }
            return try await previous(call)
        }
        _ = try await f.monitor.glab.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        let board = try await f.board(originUpdates: true)
        let phone = RemoteDetailState()
        let request = try #require(phone.begin(card: board.cards[0], board: board))
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        await f.host.detailTask?.value
        let response = try #require(f.transport.messages.last(where: { $0.detailResponse?.request == request })?.detailResponse)
        phone.receive(response, board: board)
        let reads = f.gitlab.requests.count
        let marked = f.monitor.settings.markAutomationAuthor(.init(host: "gitlab.example.test", entityID: 7, label: "@automation"),
            host: "gitlab.example.test", user: .init(id: 3, username: "me"))
        #expect(marked)
        f.monitor.synchronizeLocalAutomationAuthors()
        try await waitForOrigins(1, f)
        let markedUpdate = try #require(f.transport.messages.last?.detailOrigins)
        #expect(markedUpdate.changes.isEmpty)
        #expect(phone.receiveOrigins(markedUpdate, board: board))
        let markedNote = try #require(phone.response?.details?.threads?.first?.notes.first)
        #expect(markedNote.origin == underlying && markedNote.displayOrigin == .ai)
        #expect(phone.response?.details?.threads?.first?.origin == .ai)
        let declaration = try #require(f.monitor.settings.reviewParticipationPreferences.localAutomationAuthors.first)
        let removed = f.monitor.settings.unmarkAutomationAuthor(declaration.id, host: "gitlab.example.test", username: "me")
        #expect(removed)
        f.monitor.synchronizeLocalAutomationAuthors()
        try await waitForOrigins(2, f)
        let removedUpdate = try #require(f.transport.messages.last?.detailOrigins)
        #expect(removedUpdate.changes.isEmpty)
        #expect(phone.receiveOrigins(removedUpdate, board: board))
        let restoredNote = try #require(phone.response?.details?.threads?.first?.notes.first)
        #expect(restoredNote.origin == underlying && restoredNote.displayOrigin == underlying)
        #expect(phone.response?.details?.threads?.first?.origin == underlying)
        #expect(f.readerCount == 1 && f.gitlab.requests.count == reads)
    }

    @Test(arguments: ["server", "local"], ["ai", "human", "uncertain", "automatic"])
    func knownBotAuthorsRejectManualOriginChangesWithoutWritingOverrides(_ identity: String, _ choice: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let noteID = 78_430 + (identity == "server" ? 0 : 10) + ["ai", "human", "uncertain", "automatic"].firstIndex(of: choice)!
        let source = GitLabMergeRequestDiscussion.Note(id: noteID,
            author: .init(id: 7, username: "automation", name: "Automation"), system: false,
            resolvable: true, resolved: false, resolvedBy: nil, body: "Pipeline completed successfully")
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [source])]
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let key = AICommentOriginOverrideStore.Key(host: target.host, projectID: target.projectID, iid: 2, noteID: noteID)
        let directory = f.monitor.commentOrigins.directory
        defer { try? AICommentOriginOverrideStore.remove(key, in: directory) }
        let previous = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint == "/users/7" {
                return InMemoryGitLab.output(identity == "server" ? #"{"id":7,"bot":true}"# : #"{"id":7,"bot":false}"#)
            }
            return try await previous(call)
        }
        if identity == "local" {
            let marked = f.monitor.settings.markAutomationAuthor(.init(host: target.host, entityID: 7, label: "@automation"),
                host: target.host, user: .init(id: 3, username: "me"))
            #expect(marked)
        }
        let classification = choice == "automatic" ? nil : AICommentOriginOverride.Classification(rawValue: choice)
        await #expect(throws: (any Error).self) {
            try await f.monitor.setCommentOrigin(classification, notes: [source], in: discussions, for: target)
        }
        #expect(AICommentOriginOverrideStore.stored(key, in: directory) == nil)
        #expect(f.monitor.commentOrigins.revision == 0 && f.monitor.commentOrigins.pending.isEmpty)
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["regular", "unknown", "accountRoundtrip"])
    func originChangesRemainAvailableForNonbotsButCannotSurviveAnAccountRoundtrip(_ identity: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let noteID = 78_460 + ["regular", "unknown", "accountRoundtrip"].firstIndex(of: identity)!
        let source = GitLabMergeRequestDiscussion.Note(id: noteID,
            author: .init(id: 7, username: "reviewer", name: "Reviewer"), system: false,
            resolvable: true, resolved: false, resolvedBy: nil, body: "Please cover the retry case")
        let discussions = [GitLabMergeRequestDiscussion(id: "thread", notes: [source])]
        let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
        let key = AICommentOriginOverrideStore.Key(host: target.host, projectID: target.projectID, iid: 2, noteID: noteID)
        let directory = f.monitor.commentOrigins.directory
        defer { try? AICommentOriginOverrideStore.remove(key, in: directory) }
        let previous = try #require(f.gitlab.handler)
        f.gitlab.handler = { call in
            if call.endpoint == "/users/7" {
                if identity == "accountRoundtrip" {
                    f.monitor.glab.currentUsername = "other"; f.monitor.glab.currentUsername = "me"
                }
                return InMemoryGitLab.output(identity == "unknown" ? #"{"id":7}"# : #"{"id":7,"bot":false}"#)
            }
            return try await previous(call)
        }
        if identity == "accountRoundtrip" {
            await #expect(throws: (any Error).self) {
                try await f.monitor.setCommentOrigin(.human, notes: [source], in: discussions, for: target)
            }
            #expect(AICommentOriginOverrideStore.stored(key, in: directory) == nil)
            #expect(f.monitor.commentOrigins.revision == 0)
        } else {
            try await f.monitor.setCommentOrigin(.human, notes: [source], in: discussions, for: target)
            #expect(AICommentOriginOverrideStore.stored(key, in: directory)?.classification == .human)
        }
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    private func origins(_ f: Fixture, revision: UInt64 = 1,
                         classification: AICommentOriginAssessment.Classification = .aiAssisted) -> AICommentDisplayCoordinator.PersistedOrigins {
        .init(target: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2), request: f.source,
            accountRevision: f.monitor.glab.accountRevision, origins: f.detailNotes.compactMap { note in
                guard let id = Int(note.id), let author = note.authorID else { return nil }
                return .init(noteID: id, authorID: author, bodySHA256: AICommentAssessmentStore.digest(note.body),
                             classification: classification, confidence: .high, revision: revision)
            })
    }

    private func waitForOrigins(_ count: Int, _ f: Fixture) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while f.transport.messages.compactMap(\.detailOrigins).count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(f.transport.messages.compactMap(\.detailOrigins).count == count)
    }

    @Test(arguments: [false, true])
    func completedOriginsUpdateOnlyNegotiatedOpenDetailsWithoutAnotherDetailsRead(_ supported: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Root", authorID: 7), .init(id: "2", body: "Reply", authorID: 3)]
        let board = try await f.board(originUpdates: supported)
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let read = try #require(f.host.detailTask)
        await read.value
        let requests = f.gitlab.requests.count
        f.host.receivePersistedOrigins(origins(f))
        if supported { try await waitForOrigins(1, f) }
        else { for _ in 0..<20 { await Task.yield() } }
        #expect(f.readerCount == 1)
        #expect(f.gitlab.requests.dropFirst(requests).allSatisfy { !$0.endpoint.contains("/discussions?") })
        #expect(f.transport.messages.compactMap(\.detailOrigins).count == (supported ? 1 : 0))
        if supported {
            let update = try #require(f.transport.messages.last?.detailOrigins)
            #expect(update.request == request && update.changes.map(\.noteID) == ["1", "2"])
            f.host.receivePersistedOrigins(origins(f, revision: 2))
            for _ in 0..<20 { await Task.yield() }
            #expect(f.transport.messages.compactMap(\.detailOrigins).count == 1)
        }
        await f.transport.onMessage?(.init(type: .cancelDetails, detailRequest: request))
        f.host.receivePersistedOrigins(origins(f, revision: 3, classification: .manualLikely))
        for _ in 0..<20 { await Task.yield() }
        #expect(f.transport.messages.compactMap(\.detailOrigins).count == (supported ? 1 : 0))
    }

    @Test func aNewCompletionDuringMetadataSendIsSentAfterTheEarlierResult() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Root", authorID: 7)]
        let board = try await f.board(originUpdates: true)
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let read = try #require(f.host.detailTask); await read.value
        var held = false, release: CheckedContinuation<Void, Never>?
        f.transport.beforeSend = { message in
            if message.detailOrigins != nil, !held {
                held = true
                await withCheckedContinuation { release = $0 }
            }
        }
        f.host.receivePersistedOrigins(origins(f, classification: .uncertain))
        let deadline = ContinuousClock.now + .seconds(3)
        while !held, ContinuousClock.now < deadline { await Task.yield() }
        try #require(held)
        f.host.receivePersistedOrigins(origins(f, revision: 2))
        release?.resume()
        try await waitForOrigins(2, f)
        let updates = f.transport.messages.compactMap(\.detailOrigins)
        #expect(updates.map { $0.changes[0].revision } == [1, 2])
        #expect(updates.last?.changes[0].origin == .ai && f.readerCount == 1)
    }

    @Test(arguments: ["account", "disable", "disconnect"])
    func aQueuedOriginSendRechecksItsSubscriptionBeforeTouchingTheTransport(_ change: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.detailNotes = [.init(id: "1", body: "Root", authorID: 7)]
        let board = try await f.board(originUpdates: true)
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let read = try #require(f.host.detailTask); await read.value
        f.host.receivePersistedOrigins(origins(f))
        switch change {
        case "account": f.monitor.glab.currentUsername = "other"; f.monitor.glab.currentUsername = "me"
        case "disable": f.host.disable()
        default: f.transport.onStatus?(false, false)
        }
        for _ in 0..<30 { await Task.yield() }
        #expect(f.transport.messages.compactMap(\.detailOrigins).isEmpty)
    }

    @Test func aCurrentTruncatedDetailsDeliveryReadsTheCompleteOriginSourceAfterSending() async throws {
        let f = try Fixture(); defer { f.clean() }
        f.monitor.settings.automation.packageDecision = .enabled
        f.monitor.settings.automation.scope.mode = .all
        let board = try await f.board()
        f.detailsTruncated = true
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        var readsAtSend: Int?
        f.transport.beforeSend = { message in
            if message.detailResponse?.request == request, message.detailResponse?.status == .current {
                readsAtSend = f.gitlab.requests.count
            }
        }
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let pending = try #require(f.host.detailTask)
        await pending.value
        let delivered = try #require(f.transport.messages.last(where: { $0.detailResponse?.request == request })?.detailResponse)
        try #require(delivered.status == .current,
            "Assistant dependency check active: \(f.monitor.assistantDependencies.isChecking)")
        let reads = try #require(readsAtSend)
        let deadline = ContinuousClock.now + .seconds(3)
        while !f.gitlab.requests.dropFirst(reads).contains(where: { $0.endpoint.contains("/discussions?") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(f.gitlab.requests.dropFirst(reads).filter { $0.endpoint.contains("/discussions?") }.count == 1)
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["account", "transport", "cancel"])
    func aChangeDuringDetailsSendCannotStartDisplayClassification(_ change: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        f.monitor.settings.automation.packageDecision = .enabled
        f.monitor.settings.automation.scope.mode = .all
        let board = try await f.board()
        f.detailsTruncated = true
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        var readsAtSend: Int?
        var delivered: RemoteDetailResponse?
        var cardAtSend: RemoteCard?
        f.transport.beforeSend = { message in
            guard let response = message.detailResponse, response.request == request else { return }
            delivered = response
            cardAtSend = RemoteBoardAdapter.board(monitor: f.monitor, session: board.hostSession, account: board.account)
                .forClient(supportsCommentReview: false).cards.first { $0.id == request.cardID }
            guard response.status == .current else { return }
            readsAtSend = f.gitlab.requests.count
            switch change {
            case "account": f.monitor.glab.currentUsername = "other"; f.monitor.glab.currentUsername = "me"
            case "transport": f.transport.onStatus?(false, false)
            default: await f.transport.onMessage?(.init(type: .cancelDetails, detailRequest: request))
            }
        }
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let pending = try #require(f.host.detailTask)
        await pending.value
        try #require(delivered?.status == .current,
            "Initial card: \(board.cards[0]); delivered card: \(String(describing: cardAtSend)); dependency checking: \(f.monitor.assistantDependencies.isChecking)")
        let reads = try #require(readsAtSend)
        let endpoints = f.gitlab.requests.dropFirst(reads).map(\.endpoint)
        #expect(!endpoints.contains { $0.contains("/discussions?") }, "Post-send endpoints: \(endpoints)")
        #expect(f.monitor.attention.displayAIOriginCoordinator?.isChecking(work: .init(host: "gitlab.example.test", projectID: 1, iid: 2)) == false,
            "Post-send endpoints: \(endpoints)")
    }

    @Test func forgedOrRemovedCardsDoNotEnterTheDetailReaderOrStartAGitLabRead() async throws {
        let f = try Fixture(); defer { f.clean() }
        let board = try await f.board()
        var forged = board
        forged.lanes[0].cards[0].id = "mr:999:999"
        let request = try RemoteDetailRequest(card: forged.cards[0], board: forged)
        let reads = f.gitlab.requests.count
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        #expect(f.readerCount == 0)
        #expect(f.gitlab.requests.count == reads)
        #expect(f.host.detailTask == nil)
    }

    @Test(arguments: ["account", "pairing", "transport"])
    func anIdentityChangeWhileReadingCannotSendTheEarlierDetails(_ change: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let board = try await f.board()
        f.heldReads = [1]
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let read = try #require(f.host.detailTask)
        try await f.waitForRead(1)
        switch change {
        case "account": f.monitor.glab.currentUsername = "other"; f.monitor.glab.currentUsername = "me"
        case "pairing": f.host.disable()
        case "transport": f.transport.onStatus?(false, false); f.transport.onStatus?(true, false)
        default: break
        }
        f.gitlab.write("release-1")
        await read.value
        #expect(f.transport.messages.allSatisfy { $0.detailResponse?.status != .current })
    }

    @Test func duplicateReadsCoalesceAndAFastReplacementLoadsWithoutAFalseFailure() async throws {
        let f = try Fixture(); defer { f.clean() }
        let board = try await f.board()
        f.heldReads = [1]
        let request = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let read = try #require(f.host.detailTask)
        try await f.waitForRead(1)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: request))
        let replacement = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: replacement))
        #expect(f.readerCount == 1)
        f.gitlab.write("release-1")
        await read.value
        await f.host.detailTask?.value
        #expect(f.readerCount == 2)
        #expect(f.transport.messages.filter { $0.detailResponse?.status == .current }.map { $0.detailResponse?.request.id } == [replacement.id])
        #expect(f.transport.messages.allSatisfy { $0.detailResponse?.status != .unavailable })
    }

    @Test func replacementAndCancellationDiscardTheOldReadWithoutTouchingAnyWriteState() async throws {
        let f = try Fixture(); defer { f.clean() }
        let board = try await f.board()
        f.heldReads = [1, 3]
        let first = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: first))
        let oldRead = try #require(f.host.detailTask)
        try await f.waitForRead(1)
        f.date += 2
        let second = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: second))
        await f.host.detailTask?.value
        f.gitlab.write("release-1")
        await oldRead.value
        #expect(f.transport.messages.filter { $0.detailResponse?.status == .current }.map { $0.detailResponse?.request.id } == [second.id])
        f.date += 2
        let third = try RemoteDetailRequest(card: board.cards[0], board: board)
        await f.transport.onMessage?(.init(type: .detailRequest, detailRequest: third))
        let cancelled = try #require(f.host.detailTask)
        try await f.waitForRead(3)
        await f.transport.onMessage?(.init(type: .cancelDetails, detailRequest: third))
        f.gitlab.write("release-3")
        await cancelled.value
        #expect(f.transport.messages.allSatisfy { $0.detailResponse?.request != third })
        #expect(f.gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @MainActor private final class Transport: RemoteHostTransport {
        var onPairingEstablished: (@MainActor (RemotePairing) throws -> Void)?
        var onMessage: (@MainActor (RemoteMessage) async -> Void)?
        var onStatus: (@MainActor (Bool, Bool) -> Void)?
        var messages: [RemoteMessage] = []
        var beforeSend: ((RemoteMessage) async -> Void)?
        func start() { onStatus?(true, false) }
        func stop() { onStatus?(false, false) }
        func send(_ message: RemoteMessage) async throws { await beforeSend?(message); messages.append(message) }
    }

    @MainActor private final class Fixture {
        let suite = "RemoteHostDetailTests.\(UUID())"
        let defaults: UserDefaults
        let gitlab = InMemoryGitLab()
        let monitor: TodoMonitorService
        let transport = Transport()
        let pair: RemotePairing
        var date = Date()
        var readerCount = 0
        var heldReads: Set<Int> = []
        var detailsTruncated = false
        var detailNotes: [RemoteDetailNote] = []
        var usesLiveDetailReader = false
        let source: GitLabMergeRequest
        let readAvatarThumbnail: @Sendable (URL) async -> Data?
        lazy var host = RemoteHostController(monitor: monitor, relayConfiguration: .init(rawOrigin: pair.origin.absoluteString),
            loadPairing: { [pair] in pair }, savePairing: { _ in }, removePairing: {}, commandGate: RemoteCommandGate(store: nil),
            now: { [unowned self] in date }, detailReader: { [unowned self] source, drafts, glab, criteria in
                readerCount += 1; let index = readerCount
                gitlab.write("detail-entered-\(index)")
                if heldReads.contains(index) { try await gitlab.waitFor("release-\(index)") }
                if usesLiveDetailReader {
                    return try await RemoteMRDetailLoader.load(source: source, drafts: drafts, glab: glab, criteriaOverride: criteria)
                }
                return .init(details: .init(checkedAt: date, description: "Read \(index)",
                    threads: detailNotes.isEmpty ? nil : [.init(id: "thread", state: .open, notes: detailNotes)], truncated: detailsTruncated))
            }, readAvatarThumbnail: readAvatarThumbnail, makeConnection: { [transport] _ in transport })

        init(draft: Bool = false, avatar: URL? = nil, readAvatarThumbnail: @escaping @Sendable (URL) async -> Data? = { _ in nil }) throws {
            self.readAvatarThumbnail = readAvatarThumbnail
            defaults = try #require(UserDefaults(suiteName: suite))
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = false
            settings.automation.applyPreset(.manual, for: .codex)
            let glab = gitlab.service(host: "gitlab.example.test", username: "me")
            settings.glabPath = glab.glabPath; settings.resolvedHost = glab.resolvedHost
            let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","description":"Context","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","has_conflicts":false,"blocking_discussions_resolved":true,"detailed_merge_status":"mergeable","user":{"can_merge":false}}"#
            var initial = raw.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":\(draft)")
            if let avatar {
                initial = initial.replacingOccurrences(of: "\"name\":\"Me\"", with: "\"name\":\"Me\",\"avatar_url\":\"\(avatar.absoluteString)\"")
            }
            gitlab.write("request", initial)
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(initial.utf8))
            source = request
            settings.mrLifecycleLedger.record(request, for: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2))
            settings.save()
            gitlab.handler = { [gitlab] call in
                if call.arguments.contains(where: { $0.hasPrefix("/todos?") }), gitlab.has("inbox-todos") {
                    return try gitlab.response("inbox-todos")
                }
                if call.method == "POST", call.endpoint == "/todos/401/mark_as_done", gitlab.has("fail-todo-401") {
                    return InMemoryGitLab.output(error: "network unavailable", code: 1)
                }
                if call.arguments.starts(with: ["mr", "update"]) {
                    gitlab.write("request", gitlab.text("request").replacingOccurrences(of: "\"draft\":true", with: "\"draft\":false"))
                    if gitlab.has("lose-ready-response") { throw GlabError.timedOut }
                    return InMemoryGitLab.output()
                }
                if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output("gitlab.example.test") }
                if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to gitlab.example.test as me") }
                if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#) }
                if call.endpoint.hasSuffix("/approvals") { return InMemoryGitLab.output(#"{"approvals_required":0,"approvals_left":0,"approved_by":[]}"#) }
                if call.endpoint.hasSuffix("/approval_state") { return InMemoryGitLab.output(#"{"rules":[]}"#) }
                if call.endpoint == "/projects/1/merge_requests/2" { return try gitlab.response("request") }
                if call.endpoint.contains("/merge_requests?scope=created_by_me") { return InMemoryGitLab.output("[" + gitlab.text("request") + "]") }
                return InMemoryGitLab.output("[]")
            }
            monitor = TodoMonitorService(settings: settings, glab: glab)
            pair = try .generate(origin: #require(URL(string: "https://relay.example.test")), access: String(repeating: "a", count: 43))
        }
        func setInboxTodos(_ ids: [Int]) {
            let todo = #"{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/g/p/-/issues/42","body":"Unread issue","state":"pending","created_at":"2026-11-06T10:00:00Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"g/p"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}"#
            let todos = ids.map { todo.replacingOccurrences(of: #""id":401"#, with: "\"id\":\($0)") }
            gitlab.write("inbox-todos", "[" + todos.joined(separator: ",") + "]")
        }
        func inboxReadCommand(from board: RemoteBoard) throws -> RemoteCommand {
            let card = try #require(board.inboxReadCard)
            let action = try #require(card.actions.first)
            return .init(hostSession: board.hostSession, account: board.account, cardID: card.id,
                actionID: action.id, token: action.token)
        }
        func board(originUpdates: Bool = false, markReady: Bool = false, detailPreviews: Bool = false,
                   detailAvatars: Bool = false, cardActions: Bool = false) async throws -> RemoteBoard {
            await host.startupLoadTask?.value
            if monitor.lastRefresh == nil { await monitor.refreshNow() }
            let capabilities = [RemoteMessage.detailsCapability]
                + (originUpdates ? [RemoteMessage.detailOriginsCapability] : [])
                + (markReady ? [RemoteMessage.markReadyCapability] : [])
                + (detailPreviews ? [RemoteMessage.detailPreviewCapability] : [])
                + (detailAvatars ? [RemoteMessage.detailAvatarsCapability] : [])
                + (cardActions ? ["card-actions-v1"] : [])
            await transport.onMessage?(.init(type: .hello, challenge: UUID(), capabilities: capabilities))
            // Both background dependency reads can change the card digest after the catalog is idle.
            let deadline = ContinuousClock.now + .seconds(3)
            while monitor.assistantDependencies.isChecking || !dependencyPresentationReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(!monitor.assistantDependencies.isChecking)
            try #require(dependencyPresentationReady)
            await transport.onMessage?(.init(type: .hello, challenge: UUID(), capabilities: capabilities))
            let board = try #require(transport.messages.last(where: { $0.type == .snapshot })?.board)
            try #require(board.cards.contains { $0.id == "mr:1:2" })
            return board
        }
        private var dependencyPresentationReady: Bool {
            (monitor.attention.currentOpenItems + monitor.attention.currentItems).allSatisfy {
                $0.mergeRequest?.state != .opened || $0.dependencies != nil
            }
        }
        func waitForRead(_ index: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !gitlab.has("detail-entered-\(index)"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(gitlab.has("detail-entered-\(index)"))
        }
        func clean() {
            host.disable(); monitor.stopTimer(); gitlab.close()
            transport.onMessage = nil; transport.onStatus = nil
            transport.beforeSend = nil
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
