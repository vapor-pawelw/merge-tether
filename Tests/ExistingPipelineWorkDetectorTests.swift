import Foundation
import Testing
@testable import GitLabTodos

@Suite("Existing pipeline work")
struct ExistingPipelineWorkDetectorTests {
    @Test("a missing registration is unverified and an external MR claim covers later pipelines")
    func externalRegistration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root)
        let first = key(pipelineID: 12)
        let next = key(pipelineID: 13)
        #expect(detector.status(for: first) == .unverified)

        let marker = try detector.externalRegistrationURL(for: first)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        #expect(detector.status(for: next) == .registered)
        #expect(try !detector.registerHandoff(for: next))
        try detector.finishHandoff(for: next)
        #expect(detector.status(for: first) == .registered)

        try FileManager.default.removeItem(at: marker)
        #expect(detector.status(for: first) == .unverified)
    }

    @Test("a handoff remains registered for its exact pipeline after active work finishes")
    func exactPipelineReceipt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ExistingPipelineWorkDetector(directory: root)
        let first = key(pipelineID: 12)
        let next = key(pipelineID: 13)

        #expect(try detector.registerHandoff(for: first))
        #expect(try !detector.registerHandoff(for: next))
        try detector.finishHandoff(for: first)

        let relaunched = ExistingPipelineWorkDetector(directory: root)
        #expect(relaunched.status(for: first) == .registered)
        #expect(relaunched.status(for: next) == .unverified)
        #expect(try !relaunched.registerHandoff(for: first))
        #expect(try relaunched.registerHandoff(for: next))
    }

    @Test("independent callers can only claim one handoff for the same merge request")
    func atomicHandoff() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = key(pipelineID: 12)
        let second = key(pipelineID: 13)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for candidate in [first, second] {
                group.addTask {
                    let detector = ExistingPipelineWorkDetector(directory: root)
                    return (try? detector.registerHandoff(for: candidate)) ?? false
                }
            }
            var claims: [Bool] = []
            for await claim in group {
                claims.append(claim)
            }
            return claims
        }
        #expect(results.filter { $0 }.count == 1)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func key(pipelineID: Int) -> ExistingPipelineWorkDetector.Key {
        .init(host: "gitlab.example.org", projectID: 42, mergeRequestIID: 7, pipelineID: pipelineID)
    }
}
