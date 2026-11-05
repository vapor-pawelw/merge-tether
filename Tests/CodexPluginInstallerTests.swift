import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct CodexPluginInstallerTests {
    @Test func opensOnlyTheChatBoundToTheMergeTetherHeartbeat() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = home.appending(path: ".codex/automations/mergetether-dispatch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = directory.appending(path: "automation.toml")
        let target = "8797c316-44a4-4de8-a7db-99f4f414c504"
        let record = """
            id = "mergetether-dispatch"
            kind = "heartbeat"
            name = "MergeTether dispatch"
            status = "ACTIVE"
            target_thread_id = "\(target)"
            """
        try Data(record.utf8).write(to: file)
        #expect(CodexPluginInstaller.listenerURL(home: home)?.absoluteString == "codex://threads/\(target)")
        try Data(record.replacingOccurrences(of: target, with: "threads/new").utf8).write(to: file)
        #expect(CodexPluginInstaller.listenerURL(home: home) == nil)
        try Data(record.replacingOccurrences(of: "heartbeat", with: "cron").utf8).write(to: file)
        #expect(CodexPluginInstaller.listenerURL(home: home) == nil)
    }

    @Test func distinguishesAvailableInstalledAndDisabledPlugins() throws {
        let listing = Data("""
        {"available":[{"pluginId":"merge-tether@merge-tether-local","enabled":false}],
         "installed":[{"pluginId":"merge-tether@merge-tether-desktop","enabled":false},
                      {"pluginId":"merge-tether@unrelated-marketplace","enabled":true}]}
        """.utf8)
        #expect(try CodexPluginInstaller.installation(in: listing) == .disabled)
    }

    @Test func recognizesAnEnabledDeveloperInstallationWithoutInstallingAnotherCopy() throws {
        let listing = Data("""
        {"installed":[{"pluginId":"merge-tether@merge-tether-local","enabled":true}]}
        """.utf8)
        #expect(try CodexPluginInstaller.installation(in: listing) == .enabled)
        let candidate = try CodexPluginInstaller.setupURL(in: listing)
        let url = try #require(candidate)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "new")
        let prompt = try #require(parts.queryItems?.first(where: { $0.name == "prompt" })?.value)
        #expect(prompt.contains("[@MergeTether](plugin://merge-tether@merge-tether-local)"))
        #expect(prompt.contains("Do not claim any jobs during setup."))
    }

    @Test func rejectsAnUnknownListingFormat() {
        #expect(throws: DecodingError.self) {
            try CodexPluginInstaller.installation(in: Data("{}".utf8))
        }
    }
}

struct CodexListenerHealthTests {
    @Test @MainActor func anOldOrMissingCheckDoesNotCountAsListening() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let heartbeat = directory.appending(path: "heartbeat.json")
        #expect(CodexDesktopRelay.listenerHealth(in: directory, now: now) == .waiting)

        try Data("{}".utf8).write(to: heartbeat)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)],
                                              ofItemAtPath: heartbeat.path)
        #expect(CodexDesktopRelay.listenerHealth(in: directory, now: now) == .listening)

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-901)],
                                              ofItemAtPath: heartbeat.path)
        #expect(CodexDesktopRelay.listenerHealth(in: directory, now: now) == .stale)
    }
}
