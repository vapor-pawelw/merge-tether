import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct IncrementalReviewScopeTests {
    @Test func diffDigestIgnoresBlobIDsAndHunkOffsetsButNotContent() {
        let reviewed = "diff --git a/A b/A\nindex 1111111..2222222 100644\n@@ -1,2 +1,3 @@ func a()\n context\n+added\n"
        let rebased = "diff --git a/A b/A\nindex 3333333..4444444 100644\n@@ -40,2 +40,3 @@ func a()\n context\n+added\n"
        let changed = "diff --git a/A b/A\nindex 3333333..5555555 100644\n@@ -40,2 +40,3 @@ func a()\n context\n+added differently\n"
        #expect(MergeRequestDiffDigest.normalized(reviewed) == MergeRequestDiffDigest.normalized(rebased))
        #expect(MergeRequestDiffDigest.normalized(reviewed) != MergeRequestDiffDigest.normalized(changed))
    }

    @Test func changedNotesListOnlyNewOrEditedNotesOfOtherParticipants() throws {
        let before = try discussions(#"[{"id":"t","notes":[{"id":1,"author":{"id":2},"system":false,"body":"A"},{"id":2,"author":{"id":9},"system":false,"body":"Mine"}]}]"#)
        let after = try discussions(#"[{"id":"t","notes":[{"id":1,"author":{"id":2},"system":false,"body":"A"},{"id":2,"author":{"id":9},"system":false,"body":"Mine, edited"},{"id":3,"author":{"id":3},"system":false,"body":"New"},{"id":4,"author":{"id":3},"system":true,"body":"pushed"}]}]"#)
        let previous = MergeRequestDiffDigest.noteRevisions(before, excludingAuthor: 9)
        let current = MergeRequestDiffDigest.noteRevisions(after, excludingAuthor: 9)
        #expect(MergeRequestDiffDigest.changedNotes(from: previous, to: current) == [3])
    }

    @Test func instructionsLimitEachPassToWhatChanged() {
        let reviewed = String(repeating: "a", count: 40), current = String(repeating: "b", count: 40)
        #expect(IncrementalReviewScope(currentHead: current).instructions.isEmpty)
        #expect(IncrementalReviewScope(reviewedHead: current, currentHead: current).instructions.isEmpty)

        let incremental = IncrementalReviewScope(reviewedHead: reviewed, currentHead: current).instructions
        #expect(incremental.contains("Incremental re-review") && incremental.contains(reviewed) && incremental.contains("/versions"))
        #expect(incremental.contains("Do not raise new findings about code or discussions you already assessed"))

        let rebase = IncrementalReviewScope(reviewedHead: reviewed, currentHead: current, diffUnchanged: true).instructions
        #expect(rebase.contains("identical") && rebase.contains("raise no new code findings") && !rebase.contains("Incremental"))

        let notes = IncrementalReviewScope(currentHead: current, changedNoteIDs: [5, 8]).instructions
        #expect(notes.contains("5, 8") && notes.contains("Assess only these notes") && !notes.contains("Incremental"))

        let unknownHead = IncrementalReviewScope(reviewedHead: reviewed).instructions
        #expect(unknownHead.contains("If the current head differs") && unknownHead.contains(reviewed))

        let full = IncrementalReviewScope(reviewedHead: reviewed, currentHead: current, changedNoteIDs: [5], fullReview: true).instructions
        #expect(full.contains("Full review from scratch") && !full.contains("Incremental") && !full.contains("Assess only"))
    }

    @Test func repeatedReviewRequestScopesToTheRecordedReviewOfTheSameUser() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.test", projectID: 7, iid: 13)
        #expect(TodoAutomationService.reviewScope(work: work, username: "owner", directory: directory).isEmpty)
        let head = String(repeating: "a", count: 40)
        let verdict = ReviewVerdict(version: 1, host: work.host, projectID: 7, iid: 13, headSHA: head,
            verdict: .objections, discussionFingerprint: "x", username: "owner", userID: 1)
        let file = ReviewVerdictStore.fileURL(host: work.host, projectID: 7, iid: 13, in: directory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(verdict).write(to: file)
        #expect(TodoAutomationService.reviewScope(work: work, username: "owner", directory: directory).contains(head))
        #expect(TodoAutomationService.reviewScope(work: work, username: "someone-else", directory: directory).isEmpty)
    }

    private func discussions(_ json: String) throws -> [GitLabMergeRequestDiscussion] {
        try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data(json.utf8))
    }
}
