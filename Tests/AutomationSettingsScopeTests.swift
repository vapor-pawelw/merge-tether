import Foundation
import Testing
@testable import GitLabTodos

struct AutomationSettingsScopeTests {
    @Test func savingAgentSettingsPreservesNewerScopeEdits() {
        var current = AutomationSettings()
        let mr = MRAutomationScope.Target(host: "gitlab.example.org", username: "me", projectID: 1, iid: 42)
        var draft = current
        draft.codexReviewThinking = .low
        current.scope.mode = .selected
        current.scope[mr] = .active
        let merged = draft.preservingScope(from: current)
        #expect(merged.codexReviewThinking == .low)
        #expect(merged.scope.resolve(mr).active && merged.scope.mode == .selected)
    }
}
