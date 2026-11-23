import Foundation
import Testing
@testable import MergeTether

@MainActor
struct ReadOnlyReviewJobTests {
    @Test(arguments: AutomationAssistant.allCases, ["inline", "outside-scope", "changed-head"])
    func reviewUsesScopedToolAndOnlyTheAppCanSaveDrafts(_ assistant: AutomationAssistant, _ scenario: String) async throws {
        let suite = "ReadOnlyReview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.safe, for: assistant)
        let host = "review-tool.example.test"
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: host, username: "reviewer")
        let head = String(repeating: "a", count: 40)
        let nextHead = String(repeating: "b", count: 40)
        let url = try #require(URL(string: "https://\(host)/team/service/-/merge_requests/7"))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = folder.appending(path: "fixture-finished")
        let base = "/projects/3/merge_requests/7"
        let patch = "@@ -1 +1 @@\n-old\n+new\n"
        func request(_ sha: String) -> [String: Any] {
            ["project_id": 3, "iid": 7, "title": "Fixture change", "state": "opened", "web_url": url.absoluteString,
             "sha": sha, "draft": false, "source_branch": "change", "target_branch": "main", "source_project_id": 3,
             "target_project_id": 3, "labels": [], "author": ["id": 5, "username": "author", "name": "Author"],
             "diff_refs": ["base_sha": nextHead, "start_sha": nextHead, "head_sha": sha]]
        }
        gitlab.handler = { call in
            switch call.endpoint {
            case "/user": return InMemoryGitLab.output(#"{"id":4,"username":"reviewer"}"#)
            case base:
                return try InMemoryGitLab.json(request(scenario == "changed-head" && FileManager.default.fileExists(atPath: finished.path) ? nextHead : head))
            case base + "/raw_diffs": return InMemoryGitLab.output(patch)
            case base + "/diffs?per_page=100": return try InMemoryGitLab.json([["old_path": "A.swift", "new_path": "A.swift", "diff": patch]])
            case base + "/discussions?per_page=100", base + "/draft_notes?per_page=100": return InMemoryGitLab.output("[]")
            case "/projects/3/merge_requests/21":
                var related = request(nextHead)
                related["iid"] = 21
                related["web_url"] = "https://\(host)/team/service/-/merge_requests/21"
                return try InMemoryGitLab.json(related)
            case "/projects/3/issues/15": return InMemoryGitLab.output(#"{"title":"Expected behavior","description":"Validate the new input","state":"opened"}"#)
            case base + "/draft_notes":
                #expect(call.method == "POST")
                let input = try #require(call.arguments.firstIndex(of: "--input"))
                let body = try Data(contentsOf: URL(fileURLWithPath: call.arguments[input + 1]))
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let position = try #require(payload["position"] as? [String: Any])
                #expect(position["new_line"] as? Int == 1)
                #expect(position["head_sha"] as? String == head)
                #expect(payload["resolve_discussion"] as? Bool == false)
                return InMemoryGitLab.output(#"{"id":90,"author_id":4,"note":"Validate the new input.","discussion_id":null,"resolve_discussion":false,"position":{"new_path":"A.swift","new_line":1}}"#)
            default: return try gitlab.unexpected(call)
            }
        }
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: assistant,
            work: .init(host: host, projectID: 3, iid: 7), username: "reviewer", workspace: "", access: .gitLabRead),
            title: "Fixture", prompt: "Fixture", createdAt: .now, allowsPush: false, execution: .init(state: .running),
            mergeRequestURL: url, workflow: .review, manual: true, expectedHeadSHA: head, readOnlyReview: true)
        defer { try? FileManager.default.removeItem(at: AssistantJobJournal.checkpointURL(for: handoff.id)) }
        settings.assistantHandoffs = [handoff]
        let invocation = AssistantJobInvocation(workspace: folder, evidenceRoot: folder)
        try invocation.prepareEvidenceDirectories()
        let cli = folder.appending(path: "fake-review")
        let helper = try #require(Bundle.main.executableURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let helperValue = String(decoding: try encoder.encode(helper.path), as: UTF8.self)
        let finishedValue = String(decoding: try encoder.encode(finished.path), as: UTF8.self)
        try Data("""
            #!/usr/bin/python3
            import json, pathlib, subprocess, sys
            values = sys.argv[1:]
            sys.stdin.read()
            for args in (["context"], ["diff"], ["discussions"], ["work-item", "show", "15"], ["change", "show", "21"]):
                reply = subprocess.run([\(helperValue), "--review-cli", *args], capture_output=True, text=True, timeout=10)
                assert reply.returncode == 0, f"{args}: {reply.stderr}"
            if "\(scenario)" == "outside-scope":
                attempt = subprocess.run([\(helperValue), "--review-cli", "work-item", "show", "other/private#15"], capture_output=True, timeout=10)
                assert attempt.returncode != 0
            pathlib.Path(\(finishedValue)).touch()
            result = {"status": "succeeded", "summary": "Fixture review", "blocker": None, "drafts": [
                {"body": "Validate the new input.", "path": "A.swift", "line": 1, "discussionID": None}]}
            if values[0] == 'exec':
                pathlib.Path(values[values.index('--output-last-message') + 1]).write_text(json.dumps(result))
                print(json.dumps({"type": "turn.completed"}))
            else:
                print(json.dumps({"is_error": False, "structured_output": result}))
            """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let target = try await glab.fetchMergeRequest(projectID: 3, iid: 7, host: host)
        let user = try await glab.fetchAuthenticatedUser(host: host, expectedUsername: "reviewer")
        let outcome: AssistantJobCoordinator.Outcome
        do {
            outcome = try await ReadOnlyReviewJob(handoff: handoff, settings: settings, glab: glab, target: target,
                user: user, invocation: invocation, executable: cli, timeout: 45,
                expectedAccountRevision: glab.accountRevision).run()
        } catch let failure as AssistantJobFailure {
            Issue.record("Fixture CLI error: \(failure.transcript)")
            return
        }
        let writes = gitlab.requests.filter { $0.method != "GET" }
        #expect(writes.map(\.endpoint) == (scenario == "inline" ? [base + "/draft_notes"] : []))
        #expect(outcome.result.status == (scenario == "inline" ? .succeeded : .blocked))
        #expect(!gitlab.requests.contains(where: { $0.endpoint.contains("other") }))
    }
}
