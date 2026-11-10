import Foundation
import Darwin
import Testing
@testable import GitLabTodos

@MainActor
@Suite(.serialized)
struct MRNoticeClassifierTests {
    @Test(arguments: AutomationAssistant.allCases)
    func nondefaultPortUsesExactSelectedHostForPromptAndUsage(_ assistant: AutomationAssistant) async throws {
        let host = "GitLab.Port.Example.Test:8443"
        let projectID = assistant == .codex ? 934_771 : 934_772
        let fixture = try Fixture(host: host, projectID: projectID)
        defer { fixture.cleanUp() }
        let usageFile = await AssistantUsageStore.shared.file
        try #require(!usageFile.path.contains("Library/Application Support/com.vaporpw.GitLabTodos/Assistant Usage"))

        let result = try await MRNoticeClassifier.run(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: assistant,
            model: "fixture", executable: fixture.script, expectedHost: host)
        #expect(result == .informational)
        let captured = try String(contentsOf: fixture.directory.appending(path: "capture"), encoding: .utf8)
        #expect(captured.contains("--hostname \(host)\n"))
        let snapshot = try await AssistantUsageStore.shared.snapshot()
        let entries = snapshot.entries.filter { $0.mergeRequest?.projectID == projectID && $0.mergeRequest?.iid == 2 }
        #expect(entries.count == 1)
        let attribution = try #require(entries.first?.mergeRequest)
        #expect(attribution.host == host && attribution.username == "me")
        #expect(attribution.id == "\(host)/me/\(projectID)!2")
    }

    @Test func selectedHostMismatchRejectsEvidenceBeforeLaunchingClassifier() async throws {
        let fixture = try Fixture(projectID: 934_773)
        defer { fixture.cleanUp() }
        await #expect(throws: (any Error).self) {
            _ = try await MRNoticeClassifier.run(request: fixture.request, discussions: fixture.discussions,
                user: .init(id: 3, username: "me"), noteID: 10, assistant: .codex,
                model: "fixture", executable: fixture.script, expectedHost: "other.example.test:8443")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "capture").path))
    }

    @Test func omittedSelectedHostStillPreservesTheURLPort() async throws {
        let host = "gitlab.port.example.test:8443"
        let fixture = try Fixture(host: host, projectID: 934_774)
        defer { fixture.cleanUp() }
        let result = try await MRNoticeClassifier.run(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: .codex,
            model: "fixture", executable: fixture.script)
        #expect(result == .informational)
        let captured = try String(contentsOf: fixture.directory.appending(path: "capture"), encoding: .utf8)
        #expect(captured.contains("--hostname \(host)\n"))
        let snapshot = try await AssistantUsageStore.shared.snapshot()
        let attribution = try #require(snapshot.entries.first { $0.mergeRequest?.projectID == 934_774 }?.mergeRequest)
        #expect(attribution.host == host && attribution.username == "me")
    }

    @Test func cachedDispositionIsScopedToTheExactSelectedHost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.installClassifier(mode: "ready")
        defer { installed.restore() }
        let model = UUID().uuidString
        let first = await MRNoticeClassifier.classify(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: .claude, model: model,
            expectedHost: "GitLab.Example.Test")
        let second = await MRNoticeClassifier.classify(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: .claude, model: model,
            expectedHost: "gitlab.example.test")
        #expect(first == .informational && second == .informational)
        let calls = try String(contentsOf: fixture.directory.appending(path: "classification-count"), encoding: .utf8)
        #expect(calls == "2")
    }

    @Test func transientClassifierFailureDoesNotCacheAnUncertainResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.installClassifier(mode: "fail-first")
        defer { installed.restore() }
        let model = UUID().uuidString
        let first = await MRNoticeClassifier.classify(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: .claude, model: model)
        let second = await MRNoticeClassifier.classify(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: .claude, model: model)
        #expect(first == .uncertain)
        #expect(second == .informational)
    }

    @Test(arguments: ["ready", "resolved"])
    func changedClassifierContextCannotReuseAnEarlierNoticeAssessment(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.installClassifier(mode: change)
        defer { installed.restore() }
        let model = UUID().uuidString
        let user = GitLabAuthenticatedUser(id: 3, username: "me")
        let first = await MRNoticeClassifier.classify(request: fixture.request, discussions: fixture.discussions,
            user: user, noteID: 10, assistant: .claude, model: model)
        var request = fixture.request
        var discussions = fixture.discussions
        if change == "ready" {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            object["draft"] = false
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: JSONSerialization.data(withJSONObject: object))
        } else {
            discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self,
                from: JSONEncoder().encode(fixture.discussions).replacingJSONFalseResolution())
        }
        let second = await MRNoticeClassifier.classify(request: request, discussions: discussions,
            user: user, noteID: 10, assistant: .claude, model: model)
        #expect(first == .informational)
        #expect(second == .actionable)
    }

    @Test(arguments: ["undecided", "shell", "enabled-without-agent", "manual", "full", "legacy-agent", "enabled-agent"])
    func incomingNoticeClassificationRequiresAnEnabledAgentWorkflow(configuration: String) {
        var settings = AutomationSettings()
        switch configuration {
        case "shell":
            settings.reviewRequested.isEnabled = true
            settings.reviewRequested.runner = .shell
            settings.reviewRequested.command = "exit 0"
        case "enabled-without-agent": settings.packageDecision = .enabled
        case "manual": settings.applyPreset(.manual, for: .claude)
        case "full": settings.applyPreset(.full, for: .claude)
        case "legacy-agent": settings.authorFeedback.isEnabled = true
        case "enabled-agent":
            settings.packageDecision = .enabled
            settings.authorFeedback.isEnabled = true
        default: break
        }
        #expect(settings.canClassifyIncomingNotices == ["full", "enabled-agent"].contains(configuration))
    }

    @Test(arguments: AutomationAssistant.allCases)
    func informationalMentionUsesLiveReadToolsAndExactSelectedContext(_ assistant: AutomationAssistant) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let result = try await MRNoticeClassifier.run(request: fixture.request, discussions: fixture.discussions,
            user: .init(id: 3, username: "me"), noteID: 10, assistant: assistant, model: "fixture", executable: fixture.script)
        #expect(result == .informational)
        let captured = try String(contentsOf: fixture.directory.appending(path: "capture"), encoding: .utf8)
        #expect(captured.contains("gitlab.example.test"))
        #expect(captured.contains("Wait for the author"))
    }

    @Test func aDifferentSelectedNoteCannotAuthorizeAcknowledgement() async throws {
        let fixture = try Fixture(noteID: 99)
        defer { fixture.cleanUp() }
        await #expect(throws: (any Error).self) {
            _ = try await MRNoticeClassifier.run(request: fixture.request, discussions: fixture.discussions,
                user: .init(id: 3, username: "me"), noteID: 10, assistant: .codex, model: "fixture", executable: fixture.script)
        }
    }

    private struct Fixture {
        let directory: URL
        let script: URL
        let request: GitLabMergeRequest
        let discussions: [GitLabMergeRequestDiscussion]

        init(noteID: Int = 10, host: String = "gitlab.example.test", projectID: Int = 1) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            script = directory.appending(path: "cli")
            request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data("""
                {"project_id":\(projectID),"iid":2,"author":{"id":7,"username":"other","name":"Other"},
                 "title":"Unfinished work","web_url":"https://\(host)/group/repo/-/merge_requests/2",
                 "state":"opened","draft":true,"sha":"\(String(repeating: "a", count: 40))",
                 "source_branch":"feature","target_branch":"main","labels":[]}
                """.utf8))
            discussions = try JSONDecoder().decode([GitLabMergeRequestDiscussion].self, from: Data("""
                [{"id":"thread","notes":[{"id":10,"author":{"id":8,"username":"reviewer"},"system":false,
                "body":"Wait for the author to finish the draft before reviewing. @me","resolvable":true,"resolved":false}]}]
                """.utf8))
            try Data("""
                #!/usr/bin/python3
                import json,pathlib,sys
                args=sys.argv[1:]
                incoming=sys.stdin.read()
                codex=args[0]=='exec'
                prompt=incoming if codex else args[args.index('-p')+1]+'\\n'+incoming
                role='read-only' in prompt.lower() and 'glab api' in prompt and 'do not publish' in prompt.lower()
                full=('--dangerously-bypass-approvals-and-sandbox' in args and '--sandbox' not in args) if codex else ('--dangerously-skip-permissions' in args and args[args.index('--tools')+1]=='default')
                pathlib.Path(__file__).with_name('capture').write_text(prompt)
                result={'noteID':\(noteID),'disposition':'informational' if role and full else 'uncertain','reason':'No personal action is currently requested.'}
                if codex: json.dump(result,open(args[args.index('-o')+1],'w'))
                else: print(json.dumps({'is_error':False,'structured_output':result}))
                """.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        struct InstalledCLI {
            let path: URL
            let backup: Data?
            func restore() {
                if let backup { try? backup.write(to: path) }
                else { try? FileManager.default.removeItem(at: path) }
            }
        }

        func installClassifier(mode: String) throws -> InstalledCLI {
            let account = try #require(getpwuid(getuid()))
            let accountHome = String(cString: account.pointee.pw_dir)
            let home = URL.homeDirectory
            try #require(home.path != accountHome, "Classifier tests require the documented isolated test-runner home")
            let executable = home.appending(path: ".local/bin/claude")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = try? Data(contentsOf: executable)
            try Data("""
            #!/usr/bin/python3
            import json,pathlib,sys
            args=sys.argv[1:]
            if '--version' in args: print('fixture');sys.exit(0)
            if '--help' in args: print('--json-schema --tools --safe-mode --dangerously-skip-permissions');sys.exit(0)
            if args[:2]==['auth','status']: print('{"loggedIn":true}');sys.exit(0)
            count=pathlib.Path('\(directory.path)/classification-count')
            previous=int(count.read_text()) if count.exists() else 0
            count.write_text(str(previous+1))
            if '\(mode)'=='fail-first' and previous==0: sys.exit(1)
            payload=json.loads(sys.stdin.read())
            changed=(not payload['request'].get('draft',False)) if '\(mode)'=='ready' else any(n.get('resolved') for d in payload['discussions'] for n in d['notes']) if '\(mode)'=='resolved' else False
            result={'noteID':payload['selectedNoteID'],'disposition':'actionable' if changed else 'informational','reason':'Current selected context verified.'}
            print(json.dumps({'is_error':False,'structured_output':result}))
            """.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return .init(path: executable, backup: backup)
        }


    }
}

private extension Data {
    func replacingJSONFalseResolution() throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: self) as? [[String: Any]])
        var notes = try #require(object[0]["notes"] as? [[String: Any]])
        notes[0]["resolved"] = true
        object[0]["notes"] = notes
        return try JSONSerialization.data(withJSONObject: object)
    }
}
