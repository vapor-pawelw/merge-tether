import AppKit
import Testing
@testable import MergeTether

@MainActor
struct MergeRequestLinkCopyTests {
    @Test func copyWritesTheExactLinkAndShowsConfirmation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = try #require(URL(string: "https://gitlab.example.org/group/repo/-/merge_requests/42"))
        var feedback = MergeRequestLinkCopyFeedback()

        feedback.copy(url, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == url.absoluteString)
        let confirmation = try #require(feedback.confirmationID)
        feedback.dismiss(confirmation)
        #expect(feedback.confirmationID == nil)
    }

    @Test func anotherCopyRestartsTheConfirmation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = try #require(URL(string: "https://gitlab.example.org/group/repo/-/merge_requests/42"))
        var feedback = MergeRequestLinkCopyFeedback()
        feedback.copy(url, to: pasteboard)
        let first = try #require(feedback.confirmationID)

        feedback.copy(url, to: pasteboard)
        let latest = try #require(feedback.confirmationID)
        feedback.dismiss(first)

        #expect(latest != first)
        #expect(feedback.confirmationID == latest)
    }
}
