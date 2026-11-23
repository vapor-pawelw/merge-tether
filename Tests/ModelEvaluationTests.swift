import Foundation
import Testing
@testable import MergeTether

@MainActor
struct ModelEvaluationTests {
    private final class FixtureBundleToken: NSObject {}

    @Test(arguments: AutomationAssistant.allCases)
    func capturesProductionRequestsForSyntheticScenarios(_ assistant: AutomationAssistant) async throws {
        let fixture = try #require(Bundle(for: FixtureBundleToken.self).url(forResource: "ModelEvaluation", withExtension: "json"))
        let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        #expect(cases.count >= 6)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, scenario) in cases.enumerated() {
            let role = try #require(scenario["role"] as? String)
            let cli = folder.appending(path: "\(index)-fixture-cli")
            try installCaptureCLI(at: cli, role: role)
            if role == "verifier" {
                try await captureVerifier(scenario, assistant: assistant, cli: cli)
            } else {
                #expect(role == "review")
                try await captureReview(scenario, assistant: assistant, cli: cli, iid: index + 1)
            }
            let raw = try Data(contentsOf: URL(fileURLWithPath: cli.path + ".json"))
            var capture = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            let prompt = try #require(capture["prompt"] as? String)
            #expect(prompt.contains(role == "verifier" ? "Required external note IDs:" : "This is review-only work"))
            #expect((capture["model"] as? String)?.isEmpty == false)
            capture["scenario"] = scenario
            capture["provider"] = assistant.rawValue
            if let directory = ProcessInfo.processInfo.environment["MERGETETHER_EVAL_EXPORT_DIR"] {
                let id = try #require(scenario["id"] as? String)
                let destination = URL(fileURLWithPath: directory).appending(path: "\(assistant.rawValue)-\(id).json")
                try JSONSerialization.data(withJSONObject: capture, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination, options: .withoutOverwriting)
            }
        }
    }

    private func captureVerifier(_ scenario: [String: Any], assistant: AutomationAssistant, cli: URL) async throws {
        let title = try #require(scenario["title"] as? String)
        let diff = try #require(scenario["diff"] as? String)
        let threads = try #require(scenario["discussions"] as? [[String: Any]])
        let discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
            from: JSONSerialization.data(withJSONObject: threads))
        let defaults = AutomationSettings()
        let model = assistant == .codex ? defaults.codexVerificationModel.rawValue : defaults.claudeVerificationModel.rawValue
        let input = ReReviewVerifier.Input(authorID: 3, headSHA: String(repeating: "a", count: 40), title: title,
            description: scenario["description"] as? String, diff: diff, discussions: discussions,
            thinking: defaults.verificationThinking)
        let captured = try await ReReviewVerifier.runSingleAttempt(input, assistant: assistant, model: model, executable: cli)
        let expected = try #require(scenario["expectedStates"] as? [String: [String]])
        #expect(Set(captured.notes.map { String($0.noteID) }) == Set(expected.keys))
    }

    private func captureReview(_ scenario: [String: Any], assistant: AutomationAssistant, cli: URL, iid: Int) async throws {
        let suite = "ModelEvaluation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = "model-evaluation.\(assistant.rawValue).example.test"
        let url = try #require(URL(string: "https://\(host)/sample/renewal/-/merge_requests/\(iid)"))
        let title = try #require(scenario["title"] as? String)
        let description = try #require(scenario["description"] as? String)
        let path = "/projects/7/merge_requests/\(iid)"
        let request: [String: Any] = ["project_id": 7, "iid": iid, "title": title, "description": description,
            "author": ["id": 2, "username": "author", "name": "Fixture Author"], "state": "opened", "web_url": url.absoluteString,
            "sha": String(repeating: "a", count: 40), "source_project_id": 7, "target_project_id": 7,
            "source_branch": "fixture", "target_branch": "main", "labels": [], "draft": false]
        let discussions = try #require(scenario["discussions"] as? [[String: Any]])
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        gitlab.handler = { call in
            if call.arguments == ["config", "get", "host"] { return InMemoryGitLab.output(host) }
            if call.arguments == ["auth", "status"] { return InMemoryGitLab.output(error: "Logged in to \(host) as operator") }
            switch call.endpoint {
            case "/user": return try InMemoryGitLab.json(["id": 3, "username": "operator"])
            case "/merge_requests?scope=created_by_me&state=opened&with_merge_status_recheck=true&per_page=100",
                 "/merge_requests?scope=all&state=opened&reviewer_id=3&per_page=100",
                 path + "/reviewers?per_page=100", path + "/blocks?per_page=100":
                return InMemoryGitLab.output("[]")
            case "/projects/7": return InMemoryGitLab.output(#"{"id":7,"default_branch":"main"}"#)
            case "/projects/7/merge_requests?state=opened&scope=all&per_page=100":
                return try InMemoryGitLab.json([request])
            case path: return try InMemoryGitLab.json(request)
            case let endpoint where endpoint.hasPrefix(path + "/discussions"): return try InMemoryGitLab.json(discussions)
            case let endpoint where endpoint.hasPrefix(path + "/draft_notes"): return InMemoryGitLab.output("[]")
            case path + "/approvals": return InMemoryGitLab.output(#"{"approved_by":[]}"#)
            default: return try gitlab.unexpected(call)
            }
        }
        let glab = gitlab.service(host: host, username: "operator")
        let settings = SettingsManager(defaults: defaults)
        settings.automation.applyPreset(.safe, for: assistant)
        settings.resolvedHost = host
        settings.glabPath = glab.glabPath
        let dependencies = AssistantDependencyMonitor(probe: { _ in .ready(cli) })
        let coordinator = AssistantJobCoordinator(healthStore: AssistantCLIHealthStore(defaults: defaults), execute: { handoff, settings in
            try await AssistantJobExecutor.execute(handoff, settings: settings, glab: glab, detectCLI: { _ in .ready(cli) })
        })
        let monitor = TodoMonitorService(settings: settings, glab: glab,
            assistantDependencies: dependencies, reviewJobCoordinator: coordinator)
        defer { monitor.stopTimer() }
        dependencies.refresh()
        while dependencies.isChecking { await Task.yield() }
        let current = try await glab.fetchMergeRequest(projectID: 7, iid: iid, host: host)
        var item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 7, iid: iid), title: title, url: url)
        item.mergeRequest = current
        await monitor.runReview(for: item)
        let handoff = try #require(settings.assistantHandoffs.last)
        await coordinator.waitForTermination()
        defer {
            try? FileManager.default.removeItem(at: InstallationStorage.current.runs.appending(path: handoff.id.uuidString))
            try? FileManager.default.removeItem(at: AssistantJobJournal.checkpointURL(for: handoff.id))
        }
        #expect(monitor.assistantJobActionError == nil)
        #expect(!coordinator.isRunning(handoff.id))
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
        // Include the exact synthetic API response used by the review entry point.
        let captured = URL(fileURLWithPath: cli.path + ".json")
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: captured)) as? [String: Any])
        var prompt = try #require(value["prompt"] as? String)
        // The replay has synthetic paths and a fixed run ID for comparable prompt hashes.
        let paths: [(String?, String)] = [(InstallationStorage.current.root.path, "/fixture/storage"),
                                          (Bundle.main.resourceURL?.path, "/fixture/resources")]
        for (path, replacement) in paths {
            if let path, !path.isEmpty {
                let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                prompt = prompt.replacingOccurrences(of: escaped, with: replacement)
            }
        }
        value["prompt"] = prompt.replacingOccurrences(of: handoff.id.uuidString,
            with: "00000000-0000-4000-8000-000000000001", options: .caseInsensitive)
        value["mergeRequest"] = request
        try JSONSerialization.data(withJSONObject: value).write(to: captured)
    }

    private func installCaptureCLI(at cli: URL, role: String) throws {
        try Data("""
            #!/usr/bin/python3
            import json, pathlib, sys
            args = sys.argv[1:]
            codex = args[0] == 'exec'
            role = '\(role)'
            incoming = sys.stdin.read()
            if codex:
                schema = json.loads(pathlib.Path(args[args.index('--output-schema') + 1]).read_text())
                effort = next((value.split('=', 1)[1].strip('"') for value in args if value.startswith('model_reasoning_effort=')), None)
                prompt = incoming
                if role == 'verifier':
                    prompt, evidence = incoming.rsplit('\\n\\n', 1)
                    assert json.loads(evidence)['requiredExternalNoteIDs']
            else:
                schema = json.loads(args[args.index('--json-schema') + 1])
                effort = args[args.index('--effort') + 1]
                prompt = args[args.index('-p') + 1] if role == 'verifier' else incoming
                evidence = incoming if role == 'verifier' else ''
            if role == 'verifier':
                if not codex: assert json.loads(evidence)['requiredExternalNoteIDs']
                note_ids = schema['properties']['notes']['items']['properties']['noteID']['enum']
                result = {'notes': [{'noteID': note, 'state': 'blocking', 'reason': 'Fixture response.'} for note in note_ids]}
            else:
                evidence = ''
                result = {'status': 'blocked', 'blocker': 'The offline CLI fixture stops after capturing the request.', 'summary': 'Captured the review request.', 'generatedDrafts': []}
            capture = {'prompt': prompt, 'schema': schema, 'evidence': evidence, 'model': args[args.index('--model') + 1], 'effort': effort}
            pathlib.Path(__file__ + '.json').write_text(json.dumps(capture))
            if codex:
                output = '-o' if role == 'verifier' else '--output-last-message'
                pathlib.Path(args[args.index(output) + 1]).write_text(json.dumps(result))
                print(json.dumps({'type': 'turn.completed'}))
            else:
                print(json.dumps({'is_error': False, 'structured_output': result}))
            """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }
}
