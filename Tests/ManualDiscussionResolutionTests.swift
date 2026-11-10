import Foundation
import Testing
@testable import GitLabTodos

struct ManualDiscussionResolutionTests {
    @Test func consciousManualResolutionDoesNotNeedReviewerApprovalButNeedsAnAnsweredVerifiedConcern() throws {
        let threads = try discussions()
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10, state: .addressed, reason: "Verified implementation", publishedReplyNoteID: 11)])
        let plan = ManualDiscussionResolution.plan(discussions: threads, assessment: assessment, authorID: 3, pendingDraftCount: 0)
        #expect(plan.eligibleIDs == ["thread"] && plan.heldIDs.isEmpty)
    }

    @Test(arguments: ["blocking", "uncertain", "unanswered", "draft", "noAssessment", "ignored"])
    func unresolvedWorkAndPrivateRepliesNeverAcquireManualResolutionPermission(_ reason: String) throws {
        let threads = try discussions(answered: reason != "unanswered")
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10,
            state: reason == "blocking" ? .blocking : reason == "uncertain" ? .uncertain : reason == "ignored" ? .ignoredByUser : .addressed,
            reason: "Current evidence")])
        let plan = ManualDiscussionResolution.plan(discussions: threads, assessment: reason == "noAssessment" ? nil : assessment,
            authorID: 3, pendingDraftCount: reason == "draft" ? 1 : 0)
        #expect(plan.eligibleIDs.isEmpty && plan.heldIDs == ["thread"])
    }

    @Test func aNewOrEditedThreadCannotEnterAnAlreadyConfirmedPlan() throws {
        let original = try discussions()
        let changed = try discussions(body: "Changed request")
        #expect(ReviewVerdict.fingerprint(original) != ReviewVerdict.fingerprint(changed))
        let initial = ManualDiscussionResolution.plan(discussions: original,
            assessment: .init(notes: [.init(noteID: 10, state: .addressed, reason: "Verified")]), authorID: 3, pendingDraftCount: 0)
        #expect(initial.eligibleIDs == ["thread"])
        #expect(!initial.matches(changed))
    }

    @MainActor @Test(arguments: ["success", "resolutionTimestamp", "partial", "newThread", "editedThread", "head", "target", "account", "draft", "settings"])
    func resolutionWritesOnlyTheConfirmedIDsAndReportsPartialResults(_ scenario: String) async throws {
        let gitlab = InMemoryGitLab()
        let suite = "ManualDiscussionResolutionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { gitlab.close(); defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let host = "gitlab.example.test"
        let raw = #"{"project_id":1,"iid":2,"author":{"id":3,"username":"me","name":"Me"},"title":"Feature","labels":[],"web_url":"https://gitlab.example.test/g/p/-/merge_requests/2","state":"opened","draft":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_project_id":1,"target_project_id":1,"source_branch":"feature","target_branch":"main","detailed_merge_status":"discussions_not_resolved","has_conflicts":false,"user":{"can_merge":true}}"#
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(raw.utf8))
        var threads = try discussions()
        let second = try JSONDecoder().decode(GitLabMergeRequestDiscussion.self,
            from: Data(#"{"id":"second","notes":[{"id":20,"author":{"id":7},"body":"Another fix","system":false,"resolvable":true,"resolved":false},{"id":21,"author":{"id":3},"body":"Fixed too","system":false,"resolvable":true,"resolved":false}]}"#.utf8))
        threads.append(second)
        gitlab.write("threads", String(decoding: try JSONEncoder().encode(threads), as: UTF8.self))
        let assessment = ReReviewAssessment(notes: [.init(noteID: 10, state: .addressed, reason: "Verified", publishedReplyNoteID: 11),
            .init(noteID: 20, state: .addressed, reason: "Verified", publishedReplyNoteID: 21)])
        let plan = ManualDiscussionResolution.plan(discussions: threads, assessment: assessment, authorID: 3, pendingDraftCount: 0)
        let glab = gitlab.service(host: host, username: "me")
        let prepared = ManualDiscussionResolution.Prepared(request: request, user: .init(id: 3, username: "me"), host: host,
            revision: glab.accountRevision, configuration: try MergeSubmissionFingerprint.configuration(settings), plan: plan)
        if scenario == "settings" { settings.automation.autoMergeEnabled = true }
        gitlab.handler = { call in
            switch call.endpoint {
            case "/user": return InMemoryGitLab.output(scenario == "account" ? #"{"id":99,"username":"me"}"# : #"{"id":3,"username":"me"}"#)
            case "/projects/1/merge_requests/2":
                return InMemoryGitLab.output(scenario == "head" ? raw.replacingOccurrences(of: String(repeating: "a", count: 40), with: String(repeating: "b", count: 40))
                    : scenario == "target" ? raw.replacingOccurrences(of: #""target_branch":"main""#, with: #""target_branch":"parent""#) : raw)
            case let path where path.contains("/draft_notes?"):
                return InMemoryGitLab.output(scenario == "draft" ? #"[{"id":1,"author_id":3,"note":"Unpublished reply"}]"# : "[]")
            case let path where path.contains("/discussions?"): return try gitlab.response("threads")
            case let path where path.contains("/discussions/"):
                if scenario == "partial", path.hasSuffix("/thread") { throw GlabError.timedOut }
                let id = String(path.split(separator: "/").last!)
                var objects = try #require(JSONSerialization.jsonObject(with: gitlab.data("threads")) as? [[String: Any]])
                let index = try #require(objects.firstIndex { $0["id"] as? String == id })
                var notes = try #require(objects[index]["notes"] as? [[String: Any]])
                for n in notes.indices {
                    notes[n]["resolved"] = true
                    if scenario == "resolutionTimestamp" { notes[n]["updated_at"] = "2026-11-10T11:00:00Z" }
                }
                objects[index]["notes"] = notes
                let response = try InMemoryGitLab.json(objects[index])
                if scenario == "newThread" {
                    objects.append(["id": "unseen", "notes": [["id": 30, "author": ["id": 7], "body": "New condition", "system": false, "resolvable": true, "resolved": false]]])
                }
                if scenario == "editedThread" {
                    notes[0]["body"] = "Changed after the write"
                    objects[index]["notes"] = notes
                }
                gitlab.write("threads", String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self))
                return response
            default: return try gitlab.unexpected(call)
            }
        }
        let result = await ManualDiscussionResolution.resolve(prepared, glab: glab, settings: settings)
        let writes = gitlab.requests.filter { $0.method != "GET" }
        if scenario == "success" || scenario == "resolutionTimestamp" { #expect(result.isComplete && result.resolved == 2) }
        else if scenario == "partial" { #expect(!result.isComplete && result.resolved == 1) }
        else if scenario == "newThread" { #expect(!result.isComplete && result.resolved == 1 && writes.count == 1) }
        else if scenario == "editedThread" { #expect(!result.isComplete && writes.count == 1) }
        else { #expect(result.resolved == 0 && writes.isEmpty) }
        #expect(writes.allSatisfy { $0.endpoint.hasSuffix("/thread") || $0.endpoint.hasSuffix("/second") })
    }

    @Test func aSameTextEditOrMovedThreadCannotReuseTheConfirmedResolutionScope() throws {
        let threads = try discussions()
        let plan = ManualDiscussionResolution.plan(discussions: threads,
            assessment: .init(notes: [.init(noteID: 10, state: .addressed, reason: "Verified", publishedReplyNoteID: 11)]),
            authorID: 3, pendingDraftCount: 0)
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(threads)) as! [[String: Any]]
        var moved = original
        moved[0]["id"] = "different-id"
        let movedThreads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: JSONSerialization.data(withJSONObject: moved))
        #expect(!plan.matches(movedThreads))
        var edited = original
        var notes = edited[0]["notes"] as! [[String: Any]]
        notes[0]["updated_at"] = "2026-11-10T10:00:00Z"
        edited[0]["notes"] = notes
        let editedThreads = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: JSONSerialization.data(withJSONObject: edited))
        #expect(!plan.matches(editedThreads))
    }

    private func discussions(answered: Bool = true, body: String = "Please fix this") throws -> [GitLabMergeRequestDiscussion] {
        let reply = answered ? #",{"id":11,"author":{"id":3,"username":"me"},"body":"Fixed and verified","system":false,"resolvable":true,"resolved":false}"# : ""
        return try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: Data(#"[{"id":"thread","notes":[{"id":10,"author":{"id":7,"username":"reviewer"},"body":"\#(body)","system":false,"resolvable":true,"resolved":false}\#(reply)]}]"#.utf8))
    }
}
