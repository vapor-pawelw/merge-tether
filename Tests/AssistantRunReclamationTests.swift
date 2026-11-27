import Darwin
import Foundation
import Testing
@testable import MergeTether

@MainActor
struct AssistantRunReclamationTests {
    @Test(arguments: ["closed", "merged", "opened"])
    func reclaimsRepositoriesFromKnownRunAndLeavesEvidenceAcrossRetries(_ state: String) async throws {
        let fixture = try Fixture(useLegacyStorage: state == "merged")
        defer { fixture.remove() }
        let upstream = fixture.home.appending(path: "upstream", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        let head = try await initialize(upstream)
        let clone = fixture.run.appending(path: "repo", directoryHint: .isDirectory)
        try await git(["clone", "--no-hardlinks", "--", upstream.path, clone.path], in: fixture.home)
        let linked = fixture.run.appending(path: "tmp/linked checkout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(["worktree", "add", "--detach", linked.path, head], in: clone)
        let proofPaths = ["seal-receipt.json", "push-receipt.json", "result.json", "draft-origin.json", "approval-proof.json"]
        for path in proofPaths { try Data(path.utf8).write(to: fixture.run.appending(path: path)) }
        try FileManager.default.createDirectory(at: fixture.storage.checkpoints, withIntermediateDirectories: true)
        let checkpoint = fixture.storage.checkpoints.appending(path: "\(fixture.job.id).json")
        try Data("checkpoint".utf8).write(to: checkpoint)

        var job = fixture.job
        job.execution?.finishedAt = Date().addingTimeInterval(state == "opened" ? -2 * 86_400 : -3_600)
        try await fixture.clean(state: state, head: head, authorize: false, job: job)
        #expect(exists(clone) && exists(linked))
        try await fixture.clean(state: state, head: head, job: job)
        try await fixture.clean(state: state, head: head, job: job)
        #expect(!exists(clone) && !exists(linked))
        for path in proofPaths { #expect(try Data(contentsOf: fixture.run.appending(path: path)) == Data(path.utf8)) }
        #expect(try Data(contentsOf: checkpoint) == Data("checkpoint".utf8))
    }

    @Test(arguments: ["clean", "ignored", "outside"])
    func reclaimsOnlyReproducibleBareRepositoriesAndTheirLinkedWorktrees(_ scenario: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let upstream = fixture.home.appending(path: "upstream", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: false)
        let head = try await initialize(upstream)
        let bare = fixture.run.appending(path: "mirror.git", directoryHint: .isDirectory)
        try await git(["clone", "--bare", "--no-tags", "--no-hardlinks", "--", upstream.path, bare.path], in: fixture.home)
        let owner = scenario == "outside" ? fixture.home : fixture.run
        let checkout = owner.appending(path: "working tree", directoryHint: .isDirectory)
        try await git(["worktree", "add", "--detach", checkout.path, head], in: bare)
        if scenario == "ignored" {
            let ignored = checkout.appending(path: "target", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: false)
            try Data("local work".utf8).write(to: ignored.appending(path: "local.patch"))
        }

        try await fixture.clean(state: "opened", head: head)
        #expect(exists(bare) == (scenario != "clean"))
        #expect(exists(checkout) == (scenario != "clean"))
        #expect(exists(upstream))
    }

    @Test(arguments: ["listed", "omitted", "accountChanged", "activeRun", "readFailed", "staleWorkflow", "preparedWorkflow"])
    func monitorReclaimsAnExpiredFailedRunOnAnOpenMergeRequest(_ scenario: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clone = try fixture.directory("repo")
        let head = try await initialize(clone)
        let logs = try fixture.directory("cli-output")
        let stdout = logs.appending(path: "stdout")
        let diagnostics = Data(repeating: 65, count: 262_144)
        try diagnostics.write(to: stdout)
        try FileManager.default.setAttributes([.modificationDate: fixture.finishedAt], ofItemAtPath: stdout.path)
        let suite = "AssistantRunReclamationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        var run = fixture.job
        run.execution?.state = .failed
        settings.assistantHandoffs = [run]
        if scenario == "activeRun" {
            settings.assistantHandoffs.append(.init(id: UUID(), key: run.key, title: "Active", prompt: "Active",
                createdAt: Date(), allowsPush: false, execution: .init(state: .running)))
        }
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let glab = gitlab.service(host: run.key.work.host, username: run.key.username)
        let request = fixture.requestJSON(state: "opened", head: head)
        if scenario == "staleWorkflow" || scenario == "preparedWorkflow" {
            let mergeRequest = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(request.utf8))
            let prepared = scenario == "preparedWorkflow"
            settings.workflowActivity = [.init(id: "review-update",
                event: .init(kind: .reviewUpdate, mergeRequest: mergeRequest, identity: "review-update", context: "Updated review"),
                createdAt: fixture.finishedAt, host: run.key.work.host, user: .init(id: 21, username: run.key.username),
                state: prepared ? .running : .waitingForAssistant, assistantJobID: prepared ? nil : run.id,
                preparedReviewJobID: prepared ? run.id : nil)]
        }
        var exactReads = 0
        var accountReads = 0
        gitlab.handler = { command in
            switch command.endpoint {
            case "/user":
                accountReads += 1
                let id = scenario == "accountChanged" && accountReads > 1 ? 22 : 21
                return InMemoryGitLab.output(#"{"id":\#(id),"username":"me","name":"Viewer"}"#)
            case "/projects/7/merge_requests/11":
                exactReads += 1
                if scenario == "readFailed" { throw GlabError.notAuthenticated }
                return InMemoryGitLab.output(request)
            case let path where path.hasPrefix("/merge_requests?"):
                return InMemoryGitLab.output(scenario == "omitted" ? "[]" : "[\(request)]")
            default: return InMemoryGitLab.output("[]")
            }
        }
        let monitor = MergeRequestAttentionMonitor(glab: glab, settings: settings, provenanceDirectory: fixture.home,
            runStorage: fixture.storage, canAutomate: { _ in false })
        func refresh() async {
            await withCheckedContinuation { continuation in
                monitor.onRefreshed = { monitor.onRefreshed = nil; continuation.resume() }
                monitor.refresh(host: run.key.work.host, username: run.key.username, todos: [])
            }
        }
        await refresh()

        let shouldReclaim = ["listed", "omitted", "staleWorkflow"].contains(scenario)
        #expect(exists(clone) == !shouldReclaim)
        #expect(try Data(contentsOf: stdout) == diagnostics)
        #expect(settings.assistantHandoffs.contains(where: { $0.id == run.id }))
        if scenario == "listed" {
            #expect(exactReads == 1)
            await refresh()
            #expect(exactReads == 1)
        }
        #expect(gitlab.requests.allSatisfy { $0.method == "GET" })
    }

    @Test(arguments: ["modified", "untracked", "ignored", "unpublished", "dangling", "outside-worktree", "linked-dirty", "skip-worktree", "outside-gitdir"])
    func retainsUniqueWorkAndUnverifiableGitRelationships(_ scenario: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clone = try fixture.directory("repo")
        let head = try await initialize(clone)
        switch scenario {
        case "modified": try Data("local changes".utf8).write(to: clone.appending(path: "pom.xml"))
        case "untracked": try Data("local patch".utf8).write(to: clone.appending(path: "work.patch"))
        case "ignored":
            let target = try fixture.directory("repo/target")
            try Data("local patch".utf8).write(to: target.appending(path: "work.patch"))
        case "unpublished", "dangling":
            try await git(["commit", "--allow-empty", "-m", "Local commit"], in: clone)
            if scenario == "dangling" { try await git(["reset", "--hard", head], in: clone) }
        case "outside-worktree", "linked-dirty":
            let parent = scenario == "outside-worktree" ? fixture.home : fixture.run
            let linked = parent.appending(path: "linked", directoryHint: .isDirectory)
            try await git(["worktree", "add", "--detach", linked.path, head], in: clone)
            if scenario == "linked-dirty" { try Data("local edits".utf8).write(to: linked.appending(path: "pom.xml")) }
        case "skip-worktree":
            try await git(["update-index", "--skip-worktree", "pom.xml"], in: clone)
            try Data("hidden edit".utf8).write(to: clone.appending(path: "pom.xml"))
        case "outside-gitdir":
            let metadata = clone.appending(path: ".git")
            let external = fixture.home.appending(path: "moved-gitdir")
            try FileManager.default.moveItem(at: metadata, to: external)
            try Data("gitdir: \(external.path)\n".utf8).write(to: metadata)
        default: Issue.record("Unknown Git fixture")
        }
        try await fixture.clean(state: "merged", head: head)
        #expect(exists(clone))
    }

    @Test func successHookReclaimsOnlyRecognizableIgnoredArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clone = try fixture.directory("repo")
        _ = try await initialize(clone)
        let classes = try fixture.directory("repo/target/classes/com/example")
        let bytecode = classes.appending(path: "Generated.class")
        let fakeClass = classes.appending(path: "Notes.class")
        let untrackedWork = clone.appending(path: "local.patch")
        try Data([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x41]).write(to: bytecode)
        try Data("keep locally created text".utf8).write(to: fakeClass)
        try Data("patch".utf8).write(to: untrackedWork)
        let performance = try fixture.directory("tmp/hsperfdata_fixture").appending(path: "2147483647")
        try Data([0xca, 0xfe, 0xc0, 0xc0] + Array(repeating: 0, count: 32)).write(to: performance)
        let unknown = try fixture.directory("tmp/mktemp-work").appending(path: "summary.txt")
        try Data("notes".utf8).write(to: unknown)

        await AssistantRunReclamation.reclaimGeneratedFiles(after: fixture.job, storage: fixture.storage)

        #expect(!exists(bytecode) && !exists(performance))
        #expect(exists(clone) && exists(fakeClass) && exists(untrackedWork) && exists(unknown))
    }

    @Test func rejectsOrphanRunAndFilesystemIndirections() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let foreign = fixture.home.appending(path: "outside")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let head = try await initialize(foreign)
        let orphan = fixture.storage.runs.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let orphanRepository = orphan.appending(path: "repo")
        try FileManager.default.copyItem(at: foreign, to: orphanRepository)
        let symlink = fixture.run.appending(path: "repo")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        let logs = try fixture.directory("cli-output")
        let externalLog = fixture.home.appending(path: "external-log")
        let raw = Data(repeating: 65, count: 262_144)
        try raw.write(to: externalLog)
        try FileManager.default.setAttributes([.modificationDate: fixture.finishedAt], ofItemAtPath: externalLog.path)
        try FileManager.default.createSymbolicLink(at: logs.appending(path: "stdout"), withDestinationURL: externalLog)
        try FileManager.default.linkItem(at: externalLog, to: logs.appending(path: "stderr"))

        try await fixture.clean(state: "closed", head: head)
        try FileManager.default.removeItem(at: fixture.run)
        try FileManager.default.createSymbolicLink(at: fixture.run, withDestinationURL: orphan)
        try await fixture.clean(state: "closed", head: head)

        #expect(exists(foreign) && exists(orphanRepository))
        #expect(try Data(contentsOf: externalLog) == raw)
        var mismatched = fixture.job
        mismatched.execution?.workingDirectory = orphan.path
        #expect(AssistantRunReclamation.candidate(mismatched, storage: fixture.storage, finishedBy: Date()) == nil)
    }

    @Test func preservesRecentlyWrittenLogsAndTheExpiredDiagnosticTail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let logs = try fixture.directory("cli-output")
        let stdout = logs.appending(path: "stdout")
        let stderr = logs.appending(path: "stderr")
        let raw = Data(repeating: 65, count: 262_144) + Data("diagnostic tail".utf8)
        try raw.write(to: stdout)
        try raw.write(to: stderr)
        try FileManager.default.setAttributes([.modificationDate: fixture.finishedAt], ofItemAtPath: stdout.path)

        try await fixture.clean(state: "closed", head: String(repeating: "a", count: 40))

        #expect(try Data(contentsOf: stdout) == Data(raw.suffix(131_072)))
        #expect(try Data(contentsOf: stderr) == raw)
    }

    @Test func liveProcessInCompletedRunDefersCleanupUntilNextAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clone = try fixture.directory("repo")
        let head = try await initialize(clone)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.currentDirectoryURL = clone
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        try await fixture.clean(state: "closed", head: head)
        #expect(exists(clone))
        process.terminate()
        process.waitUntilExit()
        try await fixture.clean(state: "closed", head: head)
        #expect(!exists(clone))
    }

    @Test(arguments: [AssistantJobExecution.State.queued, .running, .blocked, .failed, .cancelled, .interrupted, .feedbackResolved])
    func retainsActiveRunsAndGivesUnsuccessfulRunsTimeForDiagnosis(_ state: AssistantJobExecution.State) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var job = fixture.job
        let now = Date()
        job.execution?.state = state
        #expect((AssistantRunReclamation.candidate(job, storage: fixture.storage, finishedBy: now) == nil) == state.isActive)
        job.execution?.finishedAt = now.addingTimeInterval(-86_400)
        #expect(AssistantRunReclamation.candidate(job, storage: fixture.storage, finishedBy: now) == nil)
    }

    @Test func openCleanupProtectsRecentRunsAndDoesNotTrustTheOldExpectedHead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let clone = try fixture.directory("repo")
        let liveHead = try await initialize(clone)
        var job = fixture.job
        job.execution?.finishedAt = Date().addingTimeInterval(-3_600)
        try await fixture.clean(state: "opened", head: liveHead, job: job)
        #expect(exists(clone))

        try await git(["commit", "--allow-empty", "-m", "Old head replaced on GitLab"], in: clone)
        job.expectedHeadSHA = try await git(["rev-parse", "HEAD"], in: clone)
        job.execution?.finishedAt = fixture.finishedAt
        try await fixture.clean(state: "opened", head: liveHead, job: job)
        #expect(exists(clone))
    }

    private struct Fixture {
        let home: URL
        let storage: InstallationStorage
        let run: URL
        let job: AssistantAutomationRunner.Handoff
        let finishedAt = Date().addingTimeInterval(-8 * 86_400)

        init(useLegacyStorage: Bool = false) throws {
            home = try makeAssistantRunFixtureHome()
            storage = InstallationStorage(bundleIdentifier: "test.mergetether", home: home)
            let id = UUID()
            run = (useLegacyStorage ? storage.legacyRuns : storage.runs).appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            job = .init(id: id, key: .init(assistant: .codex,
                work: .init(host: "gitlab.example.test", projectID: 7, iid: 11), username: "me", workspace: "", access: .gitLabRead),
                title: "Run", prompt: "Run", createdAt: finishedAt, allowsPush: false,
                execution: .init(state: .succeeded, finishedAt: finishedAt, workingDirectory: run.path))
        }

        func remove() { try? FileManager.default.removeItem(at: home) }

        func directory(_ relativePath: String) throws -> URL {
            let directory = run.appending(path: relativePath, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        func clean(state: String, head: String, authorize: Bool = true, job: AssistantAutomationRunner.Handoff? = nil) async throws {
            let observedAt = Date()
            let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(requestJSON(state: state, head: head).utf8))
            let candidate = try #require(AssistantRunReclamation.candidate(job ?? self.job, storage: storage, finishedBy: observedAt))
            await AssistantRunReclamation.reclaimObservedRuns([candidate], request: request, readStartedAt: observedAt) { _ in authorize }
        }

        func requestJSON(state: String, head: String) -> String {
            #"{"project_id":7,"iid":11,"author":{"id":21,"username":"me","name":"Viewer"},"title":"Fixture","web_url":"https://gitlab.example.test/team/repo/-/merge_requests/11","state":"\#(state)","sha":"\#(head)","source_branch":"feature","target_branch":"main","labels":[]}"#
        }
    }

    private func exists(_ path: URL) -> Bool { FileManager.default.fileExists(atPath: path.path) }

    private func initialize(_ directory: URL) async throws -> String {
        try await git(["init", "--quiet"], in: directory)
        try Data("<project/>\n".utf8).write(to: directory.appending(path: "pom.xml"))
        try Data("target/\n".utf8).write(to: directory.appending(path: ".gitignore"))
        try await git(["add", "--", "pom.xml", ".gitignore"], in: directory)
        try await git(["commit", "-m", "Published tree"], in: directory)
        return try await git(["rev-parse", "HEAD"], in: directory)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "user.email=fixture@example.test", "-c", "user.name=Fixture"] + arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/var/empty", "GIT_CONFIG_NOSYSTEM": "1",
                          "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ALLOW_PROTOCOL": "file"], currentDirectory: directory)
        try #require(result.exitCode == 0, "\(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func makeAssistantRunFixtureHome() throws -> URL {
    // Foundation can leave Darwin's /var alias in this URL after resolving links.
    let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path)).appending(path: UUID().uuidString)
}
