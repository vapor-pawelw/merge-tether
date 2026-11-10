import AppKit
import SwiftUI
import Testing
@testable import GitLabTodos

@MainActor struct BoardApprovalProgressTests {
    @Test func hidesTheCounterWhenGitLabRequiresNoApprovals() {
        let view = NSHostingView(rootView: BoardApprovalProgressBadge(
            progress: MergeRequestApprovalProgress(completed: 0, required: 0)))
        #expect(view.fittingSize == .zero)
    }

    @Test func showsRequiredAndUnknownCounters() {
        let required = NSHostingView(rootView: BoardApprovalProgressBadge(
            progress: MergeRequestApprovalProgress(completed: 1, required: 2)))
        let unknown = NSHostingView(rootView: BoardApprovalProgressBadge(progress: nil))
        #expect(required.fittingSize.width > 0)
        #expect(unknown.fittingSize.width > 0)
    }

    @Test func showsOptionalApprovalsOnceSomeoneApproves() {
        let view = NSHostingView(rootView: BoardApprovalProgressBadge(
            progress: MergeRequestApprovalProgress(completed: 2, required: 0)))
        #expect(view.fittingSize.width > 0)
    }
}
