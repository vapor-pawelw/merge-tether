import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteHostDetailTests {
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

    @Test func duplicateReadsCoalesceAndAThrottledRequestDoesNotCancelTheExistingRead() async throws {
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
        #expect(f.transport.messages.filter { $0.detailResponse?.status == .current }.map { $0.detailResponse?.request.id } == [request.id])
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
        let source: GitLabMergeRequest
        lazy var host = RemoteHostController(monitor: monitor, relayConfiguration: .init(rawOrigin: pair.origin.absoluteString),
            loadPairing: { [pair] in pair }, savePairing: { _ in }, removePairing: {}, commandGate: RemoteCommandGate(store: nil),
            now: { [unowned self] in date }, detailReader: { [unowned self] _, _, _ in
                readerCount += 1; let index = readerCount
                gitlab.write("detail-entered-\(index)")
                if heldReads.contains(index) { try await gitlab.waitFor("release-\(index)") }
                return .init(checkedAt: date, description: "Read \(index)",
                    threads: detailNotes.isEmpty ? nil : [.init(id: "thread", state: .open, notes: detailNotes)], truncated: detailsTruncated)
            }, makeConnection: { [transport] _ in transport })

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = false
            settings.automation.applyPreset(.manual, for: .codex)
            let glab = gitlab.service(host: "gitlab.example.test", username: "me")
            settings.glabPath = glab.glabPath; settings.resolvedHost = glab.resolvedHost
            let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","description":"Context","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_branch":"feature","target_branch":"main","has_conflicts":false,"blocking_discussions_resolved":true,"detailed_merge_status":"mergeable","user":{"can_merge":false}}"#
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
            source = request
            settings.mrLifecycleLedger.record(request, for: .init(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2))
            settings.save()
            gitlab.handler = { call in
                if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output("gitlab.example.test") }
                if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to gitlab.example.test as me") }
                if call.endpoint == "/user" { return InMemoryGitLab.output(#"{"id":3,"username":"me"}"#) }
                if call.endpoint.hasSuffix("/approvals") { return InMemoryGitLab.output(#"{"approvals_required":0,"approvals_left":0,"approved_by":[]}"#) }
                if call.endpoint.hasSuffix("/approval_state") { return InMemoryGitLab.output(#"{"rules":[]}"#) }
                if call.endpoint == "/projects/1/merge_requests/2" { return InMemoryGitLab.output(raw) }
                if call.endpoint.contains("/merge_requests?scope=created_by_me") { return InMemoryGitLab.output("[" + raw + "]") }
                return InMemoryGitLab.output("[]")
            }
            monitor = TodoMonitorService(settings: settings, glab: glab)
            pair = try .generate(origin: #require(URL(string: "https://relay.example.test")), access: String(repeating: "a", count: 43))
        }
        func board(originUpdates: Bool = false) async throws -> RemoteBoard {
            await host.startupLoadTask?.value
            let capabilities = [RemoteMessage.detailsCapability]
                + (originUpdates ? [RemoteMessage.detailOriginsCapability] : [])
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
                $0.mergeRequest?.state != "opened" || $0.dependencies != nil
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
