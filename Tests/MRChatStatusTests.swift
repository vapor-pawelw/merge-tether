import Foundation
import Testing
@testable import GitLabTodos

struct MRChatStatusTests {
    @Test func terminalStatesTakePriorityOverDraftAndUnknownDataDoesNotClearTags() throws {
        #expect(try MRChatStatus(request: request("closed", draft: true)) == .closed)
        #expect(try MRChatStatus(request: request("merged", draft: true)) == .merged)
        #expect(try MRChatStatus(request: request("opened", draft: true)) == .draft)
        #expect(try MRChatStatus(request: request("opened", draft: false)) == .open)
        #expect(try MRChatStatus(request: request("opened", draft: nil, mergeStatus: "draft_status")) == .draft)
        #expect(try MRChatStatus(request: request("opened", draft: nil)) == nil)
        #expect(try MRChatStatus(request: request("unknown", draft: true)) == nil)
    }

    @Test func statusTitleJobsDeduplicateAndPreservePendingDeliveryAcrossTransitions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = directory.appending(path: "receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let thread = UUID()
        CodexDesktopRelay.publishChatStatus(for: thread, status: .open, directory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "jobs").path))
        CodexDesktopRelay.publishChatStatus(for: thread, status: .draft, directory: directory)
        CodexDesktopRelay.publishChatStatus(for: thread, status: .draft, directory: directory)
        func jobs() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory.appending(path: "jobs"), includingPropertiesForKeys: nil)
        }
        let first = try #require(jobs().first)
        #expect(try jobs().count == 1)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
        #expect(fields["operation"] as? String == "set_mr_status")
        #expect(fields["status"] as? String == "draft")
        #expect(fields["threadID"] as? String == thread.uuidString)
        #expect(fields["prompt"] == nil)
        #expect(first.deletingPathExtension().lastPathComponent != thread.uuidString.lowercased())
        CodexDesktopRelay.publishChatStatus(for: thread, status: .closed, directory: directory)
        #expect(try jobs().count == 1)
        let receipt = try JSONSerialization.data(withJSONObject: ["version": 1,
            "jobID": first.deletingPathExtension().lastPathComponent, "threadID": thread.uuidString])
        try receipt.write(to: receipts.appending(path: first.lastPathComponent))
        CodexDesktopRelay.publishChatStatus(for: thread, status: .closed, directory: directory)
        CodexDesktopRelay.publishChatStatus(for: thread, status: .closed, directory: directory)
        #expect(try jobs().count == 2)
        let marker = directory.appending(path: "status-titles/\(thread.uuidString.lowercased()).json")
        let current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        #expect(current["status"] as? String == "closed")
        #expect(current["id"] as? String != fields["id"] as? String)
        let closedID = try #require(current["id"] as? String)
        let closedReceipt = try JSONSerialization.data(withJSONObject: ["version": 1,
            "jobID": closedID, "threadID": thread.uuidString])
        try closedReceipt.write(to: receipts.appending(path: "\(closedID.lowercased()).json"))
        let stackMarker = directory.appending(path: "stack-titles/\(thread.uuidString.lowercased()).json")
        try FileManager.default.createDirectory(at: stackMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stackMarker)
        CodexDesktopRelay.publishChatStatus(for: thread, status: .open, directory: directory)
        let reopened = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        #expect(reopened["status"] as? String == "open")
        #expect(reopened["id"] as? String != closedID)
        #expect(!FileManager.default.fileExists(atPath: stackMarker.path))
    }

    private func request(_ state: String, draft: Bool?, mergeStatus: String? = nil) throws -> GitLabMergeRequest {
        var fields: [String: Any] = ["project_id": 1, "iid": 42, "state": state,
            "author": ["id": 3, "username": "me", "name": "Author"], "title": "Validate requests",
            "web_url": "https://gitlab.example.org/team/cards-api/-/merge_requests/42",
            "source_branch": "fix", "target_branch": "main", "labels": []]
        fields["draft"] = draft
        fields["detailed_merge_status"] = mergeStatus
        return try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }
}
