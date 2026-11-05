import Foundation
import Testing
@testable import GitLabTodos

@Test func mergeTitleJobsRequireARecordedChatAndStaySeparateFromPrompts() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let receipts = directory.appending(path: "receipts")
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 12, iid: 42)
    let key = AssistantAutomationRunner.ChatKey(assistant: .codex, work: work, username: "me", workspace: "", access: .gitLabRead)
    let chat = UUID()
    let conversation = try JSONEncoder().encode(key).base64EncodedString()
    let receipt = try JSONSerialization.data(withJSONObject: [
        "version": 1, "threadID": chat.uuidString, "conversationKey": conversation
    ])
    try receipt.write(to: receipts.appending(path: "\(UUID()).json"))

    #expect(CodexDesktopRelay.chatsNeedingMergeCheck(host: work.host, username: "another-user", directory: directory).isEmpty)
    #expect(CodexDesktopRelay.chatsNeedingMergeCheck(host: work.host, username: "me", directory: directory)[work] == [chat])
    CodexDesktopRelay.publishMergedTitle(for: chat, directory: directory)
    CodexDesktopRelay.publishMergedTitle(for: chat, directory: directory)
    #expect(CodexDesktopRelay.chatsNeedingMergeCheck(host: work.host, username: "me", directory: directory).isEmpty)
    let files = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "jobs"), includingPropertiesForKeys: nil)
    let file = try #require(files.first)
    #expect(files.count == 1)
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(json["operation"] as? String == "mark_merged")
    #expect(json["threadID"] as? String == chat.uuidString)
    #expect(json["prompt"] == nil)
}

struct CodexDesktopRelayTests {
    @Test func olderSettingsUseSolHighAndReviewSelectionPersists() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        #expect(settings.codexReviewModel.rawValue == "gpt-6.1-sol")
        #expect(settings.codexReviewThinking.rawValue == "high")
        settings.codexReviewModel = .luna
        settings.codexReviewThinking = .low
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @MainActor
    @Test func codexPreparationDraftDoesNotUseItsStoredWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory.path
        let work = AssistantAutomationRunner.MergeRequestWork(host: "gitlab.example.org", projectID: 1, iid: 42)
        func handoff(_ access: AssistantAutomationRunner.Access) -> AssistantAutomationRunner.Handoff {
            .init(id: UUID(), key: .init(assistant: .codex, work: work, username: "me",
                                       workspace: workspace, access: access),
                  title: "[MT] repo !42", prompt: "Prepare a review.", createdAt: Date(), allowsPush: false)
        }

        #expect(try AssistantAutomationRunner.draftWorkspace(for: handoff(.preparation)) == nil)
        #expect(try AssistantAutomationRunner.draftWorkspace(for: handoff(.configuredTools)) == workspace)
    }

    @Test func desktopLinkPreservesPromptAndWorkspace() throws {
        let prompt = "[MT] Review !42\nInvestigate a+b & café"
        let url = try #require(AssistantAutomationRunner.draftURL(for: .codex, prompt: prompt, path: "/tmp/work space"))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "codex")
        #expect(parts.host == "threads")
        #expect(parts.path == "/new")
        #expect(parts.queryItems == [.init(name: "prompt", value: prompt), .init(name: "path", value: "/tmp/work space")])
        #expect(url.absoluteString.contains("%2B"))
        #expect(AssistantAutomationRunner.codexChatURL("arbitrary URL") == nil)

        let claude = try #require(AssistantAutomationRunner.draftURL(for: .claude, prompt: prompt, path: "/tmp/work space"))
        let code = try #require(URLComponents(url: claude, resolvingAgainstBaseURL: false))
        #expect(code.scheme == "claude")
        #expect(code.host == "code")
        #expect(code.path == "/new")
        #expect(code.queryItems == [.init(name: "q", value: prompt), .init(name: "folder", value: "/tmp/work space")])
    }

    @MainActor
    @Test func relayOnlyPublishesForTheCurrentAccountAndRecordsConfirmedGUIChats() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "GitLabTodosTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        settings.automation.codexRelayEnabled = true

        let key = AssistantAutomationRunner.ChatKey(
            assistant: .codex, work: .init(host: "gitlab.example.org", projectID: 1, iid: 42),
            username: "me", workspace: "/tmp/prepare", access: .preparation
        )
        let feedbackTodo = Todo.FeedbackIdentity(
            id: 42, targetURL: try #require(URL(string: "https://gitlab.example.org/repo/-/merge_requests/42#note_10")),
            actorID: 3, action: .mentioned, createdAt: Date(), updatedAt: nil
        )
        let handoff = AssistantAutomationRunner.Handoff(
            id: UUID(), key: key, title: "[MT] repo !42", prompt: "Prepare a review.",
            createdAt: Date(), allowsPush: false, feedbackTodos: [feedbackTodo],
            reviewModel: .sol, reviewThinking: .high
        )
        settings.assistantHandoffs = [handoff]
        let filename = "\(handoff.id.uuidString.lowercased()).json"
        let job = folder.appending(path: "jobs/\(filename)")

        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: "other", directory: folder)
        #expect(!FileManager.default.fileExists(atPath: job.path))
        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: key.username, directory: folder)
        #expect(FileManager.default.fileExists(atPath: job.path))
        let jobFields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: job)) as? [String: Any])
        #expect(jobFields["model"] as? String == "gpt-6.1-sol")
        #expect(jobFields["thinking"] as? String == "high")

        let receipt = folder.appending(path: "receipts/\(filename)")
        let thread = UUID().uuidString
        try Data(#"{"version":1,"jobID":"\#(UUID())","threadID":"\#(thread)"}"#.utf8).write(to: receipt)
        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: key.username, directory: folder)
        #expect(settings.assistantHandoffs.first?.relayComplete != true)
        #expect(settings.assistantChats.isEmpty)
        #expect(settings.assistantHandoffs.flatMap(\.deliveredFeedbackTodos).isEmpty)

        try Data(#"{"version":1,"jobID":"\#(handoff.id)","threadID":"\#(thread)"}"#.utf8).write(to: receipt)
        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: key.username, directory: folder)
        #expect(settings.assistantHandoffs.first?.relayComplete == true)
        #expect(settings.assistantChats[key] == thread)
        #expect(settings.assistantHandoffs.flatMap(\.deliveredFeedbackTodos) == [feedbackTodo])
        #expect(!FileManager.default.fileExists(atPath: job.path))

        var openedDraft = AssistantAutomationRunner.Handoff(
            id: UUID(), key: key, title: "[MT] repo !42", prompt: "Prepare a follow-up.",
            createdAt: Date(), allowsPush: false
        )
        openedDraft.openedAt = Date()
        settings.assistantHandoffs.append(openedDraft)
        let draftJob = folder.appending(path: "jobs/\(openedDraft.id.uuidString.lowercased()).json")
        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: key.username, directory: folder)
        #expect(!FileManager.default.fileExists(atPath: draftJob.path))

        settings.automation.codexRelayEnabled = false
        CodexDesktopRelay.requestDispatch(openedDraft.id, settings: settings, directory: folder)
        #expect(settings.assistantHandoffs.last?.openedAt == nil)
        #expect(FileManager.default.fileExists(atPath: draftJob.path))
        CodexDesktopRelay.synchronize(settings: settings, host: key.work.host, username: key.username, directory: folder)
        #expect(FileManager.default.fileExists(atPath: draftJob.path))
    }
}
