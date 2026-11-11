import Foundation
import Testing
import MergeTetherRemote
@testable import GitLabTodos

@MainActor @Suite struct RemoteHostDetailTests {
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
        f.transport.beforeSend = { message in
            guard message.detailResponse?.status == .current else { return }
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
        lazy var host = RemoteHostController(monitor: monitor, relayConfiguration: .init(rawOrigin: pair.origin.absoluteString),
            loadPairing: { [pair] in pair }, savePairing: { _ in }, removePairing: {}, commandGate: RemoteCommandGate(store: nil),
            now: { [unowned self] in date }, detailReader: { [unowned self] _, _, _ in
                readerCount += 1; let index = readerCount
                gitlab.write("detail-entered-\(index)")
                if heldReads.contains(index) { try await gitlab.waitFor("release-\(index)") }
                return .init(checkedAt: date, description: "Read \(index)", truncated: detailsTruncated)
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
        func board() async throws -> RemoteBoard {
            await host.startupLoadTask?.value
            await transport.onMessage?(.init(type: .hello, challenge: UUID(), capabilities: [RemoteMessage.detailsCapability]))
            let board = try #require(transport.messages.last(where: { $0.type == .snapshot })?.board)
            try #require(board.cards.contains { $0.id == "mr:1:2" })
            return board
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
