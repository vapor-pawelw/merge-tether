import Foundation
import Testing
import MergeTetherRemote
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
        host.origin = "https://new-relay.example.test"
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
            host.origin = "https://new-relay.example.test"
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
        func host() -> RemoteHostController {
            let load = self.load
            return .init(monitor: monitor, loadPairing: { try await load.read(onMainThread: Self.readIsOnMainThread()) },
                savePairing: { [self] pair in
                    if saveFails { throw ProbeError.failed }
                    saved.append(pair)
                }, removePairing: { [self] in
                    removals += 1
                    if removeFails { throw ProbeError.failed }
                }, connectPairing: { [self] in connections.append($0) })
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}
