import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct CodexPermissionTemplateTests {
    @Test func legacySettingsEnableTheTemplateWithoutOptingIntoDispatch() throws {
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8))
        let fields = try encodedSettings(settings)
        #expect(fields["codexUseTemplate"] as? Bool == true)
        #expect(!settings.codexRelayEnabled)
    }

    @Test func explicitOptOutSurvivesRoundTripAndRecommendedReset() throws {
        var settings = try JSONDecoder().decode(AutomationSettings.self,
            from: Data(#"{"codexUseTemplate":false,"codexRelayEnabled":true}"#.utf8))
        #expect(try encodedSettings(settings)["codexUseTemplate"] as? Bool == false)
        settings.applyRecommended(for: .codex)
        #expect(try encodedSettings(settings)["codexUseTemplate"] as? Bool == false)
        #expect(settings.codexRelayEnabled)
    }

    @Test(arguments: [true, false])
    func retiredDispatchPreservesTemplatePreferenceAndExistingChatWithoutPublishing(useTemplate: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "CodexPermissionTemplateTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }
        let settings = SettingsManager(defaults: defaults)
        settings.automation = try JSONDecoder().decode(AutomationSettings.self, from: Data(
            "{\"codexRelayEnabled\":true,\"codexUseTemplate\":\(useTemplate)}".utf8))
        let key = AssistantAutomationRunner.ChatKey(assistant: .codex,
            work: .init(host: "gitlab.example.test", projectID: 1, iid: 42),
            username: "me", workspace: "", access: .gitLabRead)
        let thread = UUID().uuidString
        settings.assistantChats[key] = thread
        let handoff = AssistantAutomationRunner.Handoff(id: UUID(), key: key,
            title: "[MT] repo !42", prompt: "Review this MR.", createdAt: Date(), allowsPush: false,
            execution: .init(state: .queued))
        settings.assistantHandoffs = [handoff]

        CodexDesktopRelay.publish(handoff, settings: settings, directory: folder)

        let job = folder.appending(path: "jobs/\(handoff.id.uuidString.lowercased()).json")
        #expect(!FileManager.default.fileExists(atPath: job.path))
        #expect(!handoff.supportsCodexRelay)
        #expect(!AssistantAutomationRunner.usesRelay(handoff, settings: settings))
        #expect(settings.assistantChats[key] == thread)
        #expect(settings.assistantHandoffs.first?.execution?.state == .queued)
        #expect(try encodedSettings(settings.automation)["codexUseTemplate"] as? Bool == useTemplate)
        let restored = try JSONDecoder().decode(AssistantAutomationRunner.Handoff.self, from: JSONEncoder().encode(handoff))
        #expect(restored.execution?.state == .queued)
        #expect(restored.key == key)
    }

    @Test func templateLinkRequiresTheSupportedManifestAndARealThreadID() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = folder.appending(path: "template.json")
        #expect(CodexDesktopRelay.templateURL(in: folder) == nil)
        let thread = UUID()
        try Data("{\"version\":1,\"threadID\":\"\(thread.uuidString)\"}".utf8).write(to: manifest)
        #expect(CodexDesktopRelay.templateURL(in: folder)?.absoluteString == "codex://threads/\(thread.uuidString.lowercased())")
        for contents in ["{}", "not json", "{\"version\":2,\"threadID\":\"\(thread)\"}",
                         #"{"version":1,"threadID":"https://example.test"}"#] {
            try Data(contents.utf8).write(to: manifest)
            #expect(CodexDesktopRelay.templateURL(in: folder) == nil)
        }
    }

    @Test(arguments: ["{\"version\":1,\"threadID\":\"\(UUID())\"}", "malformed manifest"])
    func resetForgetsOnlyTheTemplateKeepingAllQueuedWork(contents: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preservedPaths = ["jobs/job.json", "claims/job", "receipts/job.json", "heartbeat.json"]
        for path in preservedPaths {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: file)
        }
        let manifest = folder.appending(path: "template.json")
        try Data(contents.utf8).write(to: manifest)

        try CodexDesktopRelay.resetTemplate(in: folder)

        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(CodexDesktopRelay.templateURL(in: folder) == nil)
        for path in preservedPaths {
            #expect(try Data(contentsOf: folder.appending(path: path)) == Data(path.utf8))
        }
        try CodexDesktopRelay.resetTemplate(in: folder)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func resetRefusesToRecursivelyDeleteAnUnexpectedDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nestedFile = folder.appending(path: "template.json/user-file")
        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nestedFile)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: (any Error).self) { try CodexDesktopRelay.resetTemplate(in: folder) }
        #expect(try Data(contentsOf: nestedFile) == Data("keep".utf8))
    }

    private func encodedSettings(_ settings: AutomationSettings) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
