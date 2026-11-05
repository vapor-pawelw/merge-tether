import Foundation
import Testing
@testable import GitLabTodos

struct SingleInstanceLockTests {
    @Test func anotherLaunchIsRejectedUntilTheOwnerReleasesTheLock() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let acquired = try SingleInstanceLock.acquire(in: directory)
            let owner = try #require(acquired)
            let competing = try SingleInstanceLock.acquire(in: directory)
            #expect(competing == nil)
            withExtendedLifetime(owner) {}
        }
        let next = try SingleInstanceLock.acquire(in: directory)
        #expect(next != nil)
    }
}
