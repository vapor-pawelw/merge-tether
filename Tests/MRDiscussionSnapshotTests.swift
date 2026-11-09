import Foundation
import Testing
@testable import GitLabTodos

struct MRDiscussionSnapshotTests {
    @Test func publicationContextAndOtherDiscussionsPartitionThePageWithoutDuplicateDrafts() throws {
        // given
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"active"},{"id":11,"author_id":9,"note":"General draft"},{"id":12,"author_id":9,"note":"Orphan reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: try threads(), drafts: drafts,
            origins: [2: .assessed(evidence: "Recorded assessment")])
        // when
        let publication = snapshot.pendingPublication
        let other = snapshot.remainingDiscussions
        // then
        #expect(publication.threads.map(\.discussionID) == ["active"])
        #expect(publication.threads.first?.notes.compactMap(\.id) == [2, 3])
        #expect(publication.threads.first?.origins[2] != nil)
        #expect(publication.threads.flatMap(\.drafts) + publication.standaloneDrafts == drafts)
        #expect(other.threads.map(\.discussionID) == ["done", "general"])
        #expect(other.threads.flatMap(\.drafts).isEmpty && other.standaloneDrafts.isEmpty)
    }

    private func threads() throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(#"[{"id":"done","notes":[{"id":1,"author":{"id":7,"username":"alice"},"body":"First finding","system":false,"resolvable":true,"resolved":true}]},{"id":"active","notes":[{"id":2,"author":{"id":7,"username":"alice"},"body":"Please check","system":false,"resolvable":true,"resolved":false,"position":{"new_path":"src/File.swift","new_line":12}},{"id":3,"author":{"id":9,"username":"me"},"body":"Author reply","system":false}]},{"id":"general","notes":[{"id":4,"author":{"id":7},"body":"Summary","system":false}]},{"id":"system","notes":[{"id":5,"system":true,"body":"pushed new commits"}]}]"#.utf8))
    }

    @Test func fullThreadsPreserveRepliesAndResolvedCommentsWhilePendingDraftsLead() throws {
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"active"},{"id":11,"author_id":9,"note":"General draft"},{"id":12,"author_id":9,"note":"Orphan reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: try threads(), drafts: drafts,
            origins: [2: .assessed(evidence: "Recorded assessment")])
        #expect(snapshot.threads.count == 3)
        let first = try #require(snapshot.threads.first)
        #expect(first.discussionID == "active")
        #expect(first.notes.compactMap(\.id) == [2, 3])
        #expect(first.drafts.compactMap(\.id) == [10])
        #expect(first.location == "src/File.swift:12")
        #expect(first.state == .open)
        #expect(first.origins[2] != nil && first.origins[3] == nil)
        #expect(snapshot.threads.first { $0.discussionID == "done" }?.state == .resolved)
        #expect(snapshot.threads.first { $0.discussionID == "general" }?.state == .general)
        #expect(snapshot.standaloneDrafts.compactMap(\.id) == [11, 12])
    }

    @Test func unavailableDiscussionContextNeverHidesPrivateDrafts() throws {
        let drafts = try JSONDecoder().decode([GitLabDraftNote].self, from: Data(#"[{"id":10,"author_id":9,"note":"Pending reply","discussion_id":"missing"}]"#.utf8))
        let snapshot = MRDiscussionSnapshot(discussions: [], drafts: drafts, origins: [:])
        #expect(snapshot.standaloneDrafts == drafts)
        #expect(snapshot.pendingPublication.standaloneDrafts == drafts)
        #expect(snapshot.remainingDiscussions.standaloneDrafts.isEmpty)
    }

    @Test func onlyCurrentQualifyingConfidenceEvidenceCanLabelANote() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = try #require(threads().first?.notes.first)
        let path = AICommentAssessmentStore.fileURL(host: "gitlab.example.test", projectID: 1, iid: 2, noteID: 1, in: folder)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = AICommentAssessment(version: 1, host: "gitlab.example.test", projectID: 1, iid: 2, noteID: 1,
            bodySHA256: AICommentAssessmentStore.digest(note.body!), confidence: "very_high", evidence: "Explicit model attribution")
        try JSONEncoder().encode(record).write(to: path)
        #expect(AICommentAssessmentStore.assessment(for: note, host: "gitlab.example.test", projectID: 1, iid: 2, in: folder)?.evidence == record.evidence)
        var edited = note; edited.body = "Edited finding"
        #expect(AICommentAssessmentStore.assessment(for: edited, host: "gitlab.example.test", projectID: 1, iid: 2, in: folder) == nil)
        #expect(AICommentAssessmentStore.assessment(for: note, host: "other.example.test", projectID: 1, iid: 2, in: folder) == nil)
    }
}
