import Foundation
import Testing
@testable import MergeTetherRemote
import Security
@testable import GitLabTodos

@MainActor
struct RemoteHostStartupTests {
    @Test func initializerReturnsWhilePairingReadIsPendingAndReadsAwayFromTheMainThread() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        #expect(host.pairing == nil)
        #expect(!host.failed)
        await f.load.finish(.success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(host.pairing == f.oldPair)
        #expect(host.origin == f.oldPair.origin.absoluteString)
        #expect(host.invitation == f.oldPair.access)
        #expect(await f.load.readWasOnMainThread == false)
        #expect(f.connections == [f.oldPair])
    }

    @Test func failedOptionalPairingReadDoesNotPreventControllerCreation() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        #expect(!host.failed)
        await f.load.finish(.failure(ProbeError.failed))
        await host.startupLoadTask?.value
        #expect(host.failed)
        #expect(host.pairing == nil)
        #expect(f.connections.isEmpty)
    }

    @Test(arguments: [false, true])
    func disableCannotBeUndoneByALateStartupResult(_ failure: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        host.disable()
        await f.load.finish(failure ? .failure(ProbeError.failed) : .success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(f.removals == 1)
        #expect(host.pairing == nil)
        #expect(!host.failed)
        #expect(!host.connected)
        #expect(f.connections.isEmpty)
    }

    @Test(arguments: [false, true])
    func explicitNewPairingWinsOverALateStartupResult(_ failure: Bool) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        host.origin = f.oldPair.origin.absoluteString
        host.invitation = String(repeating: "b", count: 43)
        host.enable()
        let current = try #require(host.pairing)
        await f.load.finish(failure ? .failure(ProbeError.failed) : .success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(host.pairing == current)
        #expect(f.saved == [current])
        #expect(f.connections == [current])
        #expect(!host.failed)
    }

    @Test(arguments: ["origin", "invitation"])
    func typingNewPairingDetailsPreventsTheOldLoadFromReplacingThem(_ field: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        if field == "origin" { host.origin = "https://chosen-relay.example.test" }
        else { host.invitation = String(repeating: "c", count: 43) }
        let origin = host.origin, invitation = host.invitation
        await f.load.finish(.success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(host.origin == origin)
        #expect(host.invitation == invitation)
        #expect(host.pairing == nil)
        #expect(f.connections.isEmpty)
    }

    @Test(arguments: ["save", "remove"])
    func failedExplicitPairingChangeStillInvalidatesTheStartupRead(_ operation: String) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        if operation == "save" {
            f.saveFails = true
            host.origin = f.oldPair.origin.absoluteString
            host.invitation = String(repeating: "b", count: 43)
            host.enable()
        } else {
            f.removeFails = true
            host.disable()
        }
        await f.load.finish(.success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(host.failed)
        #expect(host.pairing == nil)
        #expect(f.connections.isEmpty)
    }

    @Test(arguments: [nil, "http://insecure.example.test"] as [String?])
    func unavailableRelayConfigurationDoesNotReadPairingOrCreateTransport(_ origin: String?) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host(configuration: .init(rawOrigin: origin))
        #expect(host.startupLoadTask == nil)
        #expect(await f.load.readWasOnMainThread == nil)
        #expect(host.pairing == nil)
        #expect(f.connections.isEmpty)
        host.invitation = String(repeating: "a", count: 43)
        host.enable()
        #expect(host.failed)
        #expect(f.saved.isEmpty)
        #expect(f.removals == 0)
    }

    @Test func storedPairingForAnotherOriginIsKeptWithoutReconnectingOrMigratingTrust() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let configured = RemoteRelayConfiguration(rawOrigin: "https://new-relay.example.test")
        let host = f.host(configuration: configured)
        await f.load.finish(.success(f.oldPair))
        await host.startupLoadTask?.value
        #expect(host.pairing == nil)
        #expect(host.relayMismatch)
        #expect(host.origin == configured.origin?.absoluteString)
        #expect(host.invitation.isEmpty)
        #expect(f.saved.isEmpty)
        #expect(f.removals == 0)
        #expect(f.connections.isEmpty)
    }

    @Test func manuallyChangedOriginCannotReplaceConfiguredPairing() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let host = f.host()
        await f.load.finish(.success(f.oldPair))
        await host.startupLoadTask?.value
        host.origin = "https://other-relay.example.test"
        host.enable()
        #expect(host.failed)
        #expect(host.pairing == f.oldPair)
        #expect(f.saved.isEmpty)
        #expect(f.connections == [f.oldPair])
    }

    private enum ProbeError: Error { case failed }
    private actor LoadGate {
        var readWasOnMainThread: Bool?
        private var continuation: CheckedContinuation<RemotePairing?, Error>?
        private var result: Result<RemotePairing?, Error>?
        func read(onMainThread: Bool) async throws -> RemotePairing? {
            readWasOnMainThread = onMainThread
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish(_ result: Result<RemotePairing?, Error>) {
            self.result = result
            continuation?.resume(with: result); continuation = nil
        }
    }
    @MainActor private final class Fixture {
        let suite = "RemoteHostStartupTests.\(UUID())"
        let defaults: UserDefaults
        let monitor: TodoMonitorService
        let oldPair: RemotePairing
        let load = LoadGate()
        var saved: [RemotePairing] = []
        var removals = 0
        var connections: [RemotePairing] = []
        var saveFails = false
        var removeFails = false
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            monitor = TodoMonitorService(settings: SettingsManager(defaults: defaults), glab: GlabService())
            oldPair = try .generate(origin: URL(string: "https://old-relay.example.test")!, access: String(repeating: "a", count: 43))
        }
        nonisolated private static func readIsOnMainThread() -> Bool { Thread.isMainThread }
        func host(configuration: RemoteRelayConfiguration? = nil) -> RemoteHostController {
            let load = self.load
            return .init(monitor: monitor, relayConfiguration: configuration ?? .init(rawOrigin: oldPair.origin.absoluteString), loadPairing: { try await load.read(onMainThread: Self.readIsOnMainThread()) },
                savePairing: { [self] pair in
                    if saveFails { throw ProbeError.failed }
                    saved.append(pair)
                }, removePairing: { [self] in
                    removals += 1
                    if removeFails { throw ProbeError.failed }
                }, connectPairing: { [self] in connections.append($0) }, commandGate: RemoteCommandGate(store: nil))
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}

@MainActor
struct RemoteHostSessionTests {
    @Test func reconnectRejectsAnEncryptedCommandFromThePreviousSession() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let before = try await f.board()
        let command = try f.command(before)
        let phone = try RemoteCipher(pairing: RemotePairing(url: f.pair.deepLink), role: .phone, saveEstablishedPairing: { _ in })
        let hostCipher = try RemoteCipher(pairing: f.pair, role: .host, saveEstablishedPairing: { _ in })
        let wire = try phone.seal(RemoteMessage(type: .command, command: command))

        f.transport.onStatus?(false, false)
        f.transport.onStatus?(true, false)
        let after = try await f.board()
        #expect(after.hostSession != before.hostSession)
        #expect(f.host.pairing == f.pair)
        // This previously undelivered frame is not in the retained nonce cache.
        let reopened = try hostCipher.open(wire, as: RemoteMessage.self)
        await f.transport.onMessage?(reopened)
        #expect(f.transport.messages.last?.result?.status == .changed)
        #expect(f.monitor.lifecycleCompletions.count == 1)
        await f.transport.onMessage?(.init(type: .command, command: try f.command(after)))
        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(f.monitor.lifecycleCompletions.isEmpty)
    }

    @Test func accountRoundTripRejectsTheEarlierCommandEvenWhenAccountTextMatches() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let before = try await f.board()
        f.monitor.glab.currentUsername = "other"
        f.monitor.glab.currentUsername = "me"
        let after = try await f.board()
        #expect(after.account == before.account)
        #expect(after.hostSession != before.hostSession)
        await f.transport.onMessage?(.init(type: .command, command: try f.command(before)))
        #expect(f.transport.messages.last?.result?.status == .changed)
        #expect(f.monitor.lifecycleCompletions.count == 1)
    }

    @Test func reconnectKeepsTheLockOfAnAlreadyStartedGitLabWrite() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let read = try #require(f.gitlab.handler)
        let todo = #"[{"id":401,"action_name":"assigned","target_type":"Issue","target_url":"https://gitlab.example.test/group/repo/-/issues/42","body":"Unread issue","state":"pending","created_at":"2026-11-06T10:00:00.000Z","project":{"id":1,"name_with_namespace":"Group / Repo","path_with_namespace":"group/repo"},"author":{"id":9,"username":"reviewer","name":"Reviewer"},"target":{"id":42,"iid":42,"title":"Unread issue","state":"opened"}}]"#
        f.gitlab.handler = { call in
            if call.method == "GET", call.command.contains("/todos?") { return InMemoryGitLab.output(todo) }
            if call.method == "POST", call.endpoint == "/todos/401/mark_as_done" {
                f.gitlab.write("entered")
                try await f.gitlab.waitFor("release")
                return InMemoryGitLab.output()
            }
            return try await read(call)
        }
        let before = try await f.board()
        let command = try f.command(before, cardID: "todo:401")
        let first = Task { await f.transport.onMessage?(.init(type: .command, command: command)) }
        defer { f.gitlab.write("release"); first.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !f.gitlab.has("entered"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(f.gitlab.has("entered"))
        f.transport.onStatus?(false, false)
        f.transport.onStatus?(true, false)
        let reconnected = try await f.board()
        let completionID = try #require(reconnected.cards.first { $0.id.hasPrefix("completion:") }?.id)
        await f.transport.onMessage?(.init(type: .command, command: try f.command(reconnected, cardID: completionID)))
        #expect(f.transport.messages.last?.result?.status == .changed)
        #expect(f.monitor.lifecycleCompletions.count == 1)
        f.gitlab.write("release")
        await first.value
        #expect(f.gitlab.requests.filter { $0.method == "POST" }.count == 1)
        await f.transport.onMessage?(.init(type: .command, command: try f.command(reconnected, cardID: completionID)))
        #expect(f.transport.messages.last?.result?.status == .completed)
        #expect(f.monitor.lifecycleCompletions.isEmpty)
    }

    @Test func lateStatusFromADisabledTransportCannotReconnectTheHost() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let status = f.transport.onStatus
        f.host.disable()
        status?(true, false)
        #expect(f.host.pairing == nil)
        #expect(!f.host.connected)
    }

    @Test func disconnectDuringAcceptancePreventsAnUnstartedWrite() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let board = try await f.board()
        f.transport.onSend = { message in
            if message.type == .accepted { f.transport.onStatus?(false, false) }
        }
        await f.transport.onMessage?(.init(type: .command, command: try f.command(board)))
        #expect(f.transport.messages.last?.result?.status == .changed)
        #expect(f.monitor.lifecycleCompletions.count == 1)
    }

    @Test func newPairingRotatesKeysAndSessionAndOldCommandsCannotReturnCachedSuccess() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let before = try await f.board(), command = try f.command(before)
        await f.transport.onMessage?(.init(type: .command, command: command))
        #expect(f.transport.messages.last?.result?.status == .completed)
        f.host.enable()
        let replacement = try #require(f.host.pairing)
        #expect(replacement.sessionID != f.pair.sessionID)
        #expect(replacement.publicKey != f.pair.publicKey)
        let after = try await f.board(requireCards: false)
        #expect(after.hostSession != before.hostSession)
        await f.transport.onMessage?(.init(type: .command, command: command))
        #expect(f.transport.messages.last?.result?.status == .changed)
    }

    @Test func enrollmentPinIsSavedBeforeTheControllerExposesItAndFailureKeepsOldTrust() async throws {
        let f = try Fixture()
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let phone = try RemoteCipher(pairing: RemotePairing(url: f.pair.deepLink), role: .phone, saveEstablishedPairing: { _ in })
        var established: RemotePairing?
        let cipher = try RemoteCipher(pairing: f.pair, role: .host, saveEstablishedPairing: { established = $0 })
        _ = try cipher.open(phone.seal(["type": "hello"]), as: [String: String].self)
        let bound = try #require(established)
        f.saveFails = true
        #expect(throws: (any Error).self) { try f.transport.onPairingEstablished?(bound) }
        #expect(f.host.pairing == f.pair)
        f.saveFails = false
        try f.transport.onPairingEstablished?(bound)
        #expect(f.saved == [bound])
        #expect(f.host.pairing == bound)
        f.host.enable()
        #expect(throws: (any Error).self) { try f.transport.onPairingEstablished?(bound) }
    }

    @Test(arguments: [false, true])
    func controllerRecreationRecoversStoredResultsWithoutReexecutingAnOldSession(_ crashedActive: Bool) async throws {
        let memory = InMemoryRemoteSecurity()
        let store = RemoteCommandReceiptStore(service: "controller-recovery", security: memory.client)
        let f = try Fixture(receiptStore: store)
        defer { f.clean() }
        await f.host.startupLoadTask?.value
        let before = try await f.board(), command = try f.command(before)
        if crashedActive {
            try store.save(.init(pairingSession: f.pair.sessionID, receipts: [.init(command: command, result: .init(id: command.id, status: .running))]))
        } else {
            await f.transport.onMessage?(.init(type: .command, command: command))
            #expect(f.transport.messages.last?.result?.status == .completed)
        }
        f.host.disable()
        let transport = Transport(), pair = f.pair
        let restarted = RemoteHostController(monitor: f.monitor, relayConfiguration: .init(rawOrigin: pair.origin.absoluteString), loadPairing: { pair }, savePairing: { _ in }, removePairing: {},
            commandGate: RemoteCommandGate(store: store), makeConnection: { _ in transport })
        defer { restarted.disable() }
        await restarted.startupLoadTask?.value
        await transport.onMessage?(.init(type: .hello, challenge: UUID()))
        let current = try #require(transport.messages.last(where: { $0.type == .snapshot })?.board)
        #expect(current.hostSession != before.hostSession)
        await transport.onMessage?(.init(type: .command, command: command))
        #expect(transport.messages.last?.result?.status == .changed)
        let challenge = UUID()
        await transport.onMessage?(.init(type: .receipt, challenge: challenge, command: command))
        #expect(transport.messages.last?.type == .receiptResult)
        #expect(transport.messages.last?.challenge == challenge)
        #expect(transport.messages.last?.result?.status == (crashedActive ? .uncertain : .completed))
        #expect(f.monitor.lifecycleCompletions.count == (crashedActive ? 1 : 0))
        f.monitor.glab.currentUsername = "other"
        await transport.onMessage?(.init(type: .receipt, challenge: UUID(), command: command))
        #expect(transport.messages.last?.result?.status == .changed)
    }

    @MainActor private final class Transport: RemoteHostTransport {
        var onPairingEstablished: (@MainActor (RemotePairing) throws -> Void)?
        var onMessage: (@MainActor (RemoteMessage) async -> Void)?
        var onStatus: (@MainActor (Bool, Bool) -> Void)?
        var onSend: ((RemoteMessage) async -> Void)?
        var messages: [RemoteMessage] = []
        func start() { onStatus?(true, false) }
        func stop() { onStatus?(false, false) }
        func send(_ message: RemoteMessage) async throws {
            messages.append(message)
            await onSend?(message)
        }
    }

    @MainActor private final class Fixture {
        let suite = "RemoteHostSessionTests.\(UUID())"
        let defaults: UserDefaults
        let gitlab = InMemoryGitLab()
        let monitor: TodoMonitorService
        let transport = Transport()
        let pair: RemotePairing
        let host: RemoteHostController
        final class SaveState { var fails = false; var saved: [RemotePairing] = [] }
        let saveState = SaveState()
        var saveFails: Bool { get { saveState.fails } set { saveState.fails = newValue } }
        var saved: [RemotePairing] { saveState.saved }
        init(receiptStore: RemoteCommandReceiptStore? = nil) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let settings = SettingsManager(defaults: defaults)
            settings.onboardingCompleted = false
            settings.automation.applyPreset(.manual, for: .codex)
            let glab = gitlab.service(host: "gitlab.example.test", username: "me")
            settings.glabPath = glab.glabPath
            settings.resolvedHost = glab.resolvedHost
            gitlab.handler = { call in
                if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output("gitlab.example.test") }
                if call.arguments == ["auth", "status"] {
                    return InMemoryGitLab.output(error: "Logged in to gitlab.example.test as me")
                }
                guard call.method == "GET", call.command.contains("/todos?") else {
                    throw GlabError.unknown("Unexpected session fixture request: \(call.command)")
                }
                return InMemoryGitLab.output("[]")
            }
            // Bootstrap must not mistake fixture setup for a new automation policy.
            settings.save()
            monitor = TodoMonitorService(settings: settings, glab: glab)
            let raw = #"{"project_id":7,"iid":11,"author":{"id":1,"username":"me","name":"Synthetic author"},"title":"Completion","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"opened","draft":false,"sha":"head","source_branch":"feature","target_branch":"main","labels":[]}"#
            var request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
            let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 7, iid: 11)
            settings.mrLifecycleLedger.record(request, for: target)
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.replacingOccurrences(of: "opened", with: "closed").utf8))
            settings.mrLifecycleLedger.record(request, for: target)
            pair = try .generate(origin: #require(URL(string: "https://relay.example.test")), access: String(repeating: "a", count: 43))
            let pair = self.pair, transport = self.transport, saveState = self.saveState
            host = RemoteHostController(monitor: monitor, relayConfiguration: .init(rawOrigin: pair.origin.absoluteString), loadPairing: { pair }, savePairing: {
                if saveState.fails { throw RemoteProtocolError.invalid }; saveState.saved.append($0)
            }, removePairing: {}, commandGate: RemoteCommandGate(store: receiptStore), makeConnection: { _ in transport })
        }
        func board(requireCards: Bool = true) async throws -> RemoteBoard {
            await transport.onMessage?(.init(type: .hello, challenge: UUID(), capabilities: [RemoteMessage.mergeActionsCapability]))
            let board = try #require(transport.messages.last(where: { $0.type == .snapshot })?.board)
            try #require(!board.partial, "refresh=\(monitor.boardRefreshState) error=\(String(describing: monitor.lastError)) attention=\(monitor.attention.hasError)/\(monitor.attention.isLoading) authored=\(monitor.authoredMergeRequests.hasError)/\(monitor.authoredMergeRequests.isLoading) loading=\(monitor.isLoading)")
            if requireCards { try #require(!board.cards.isEmpty) }
            return board
        }
        func command(_ board: RemoteBoard, cardID: String? = nil) throws -> RemoteCommand {
            let card = try #require(board.cards.first { cardID == nil || $0.id == cardID })
            let action = try #require(card.actions.first)
            return .init(hostSession: board.hostSession, account: board.account, cardID: card.id, actionID: action.id, token: action.token)
        }
        func clean() {
            host.disable()
            transport.onSend = nil
            transport.onMessage = nil
            transport.onStatus = nil
            monitor.stopTimer()
            gitlab.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class InMemoryRemoteSecurity: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var client: RemotePairingStore.SecurityClient {
        .init(read: { [self] query in
            lock.lock(); defer { lock.unlock() }
            let data = values[key(query)]
            return (data == nil ? errSecItemNotFound : errSecSuccess, data)
        }, update: { [self] query, attributes in
            lock.lock(); defer { lock.unlock() }
            guard values[key(query)] != nil else { return errSecItemNotFound }
            values[key(query)] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { [self] query in
            lock.lock(); defer { lock.unlock() }
            values[key(query)] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }, remove: { [self] query in
            lock.lock(); defer { lock.unlock() }
            return values.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
        })
    }
    private func key(_ query: [String: Any]) -> String {
        (query[kSecAttrService as String] as? String ?? "") + "|" + (query[kSecAttrAccount as String] as? String ?? "")
    }
}
