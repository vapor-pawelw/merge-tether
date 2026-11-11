import Foundation
import Testing
@testable import MergeTetherRemote

@Suite struct CommandRecoveryStoreTests {
    @Test func lastPhoneCommandSurvivesStoreRecreationUntilExplicitAcknowledgement() throws {
        let memory = InMemorySecurity(), session = UUID()
        let store = RemoteCommandRecoveryStore(service: "phone", security: memory.client)
        let command = RemoteCommand(hostSession: UUID(), account: "me@host", cardID: "mr:1:2", actionID: "approve", token: "bound-content")
        let recovery = RemoteCommandRecovery(pairingSession: session, command: command)
        try store.save(recovery)
        let restarted = RemoteCommandRecoveryStore(service: "phone", security: memory.client)
        #expect(try restarted.load() == recovery)
        try restarted.remove()
        #expect(try store.load() == nil)
    }
    @Test(arguments: ["read", "add", "update", "remove"])
    func recoveryStorageFailuresAreNeverTreatedAsAnEmptyHistory(_ failure: String) throws {
        let memory = InMemorySecurity(failing: failure)
        let store = RemoteCommandRecoveryStore(service: "phone", security: memory.client)
        let recovery = RemoteCommandRecovery(pairingSession: UUID(), command: .init(hostSession: UUID(), account: "me@host", cardID: "mr:1:2", actionID: "approve", token: "bound-content"))
        switch failure {
        case "read": #expect(throws: (any Error).self) { try store.load() }
        case "remove": #expect(throws: (any Error).self) { try store.remove() }
        default: #expect(throws: (any Error).self) { try store.save(recovery) }
        }
    }
}
