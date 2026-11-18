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

    private let me = Todo.Author(id: 7, username: "Me", name: "Me Myself", avatarURL: nil)
    private let other = Todo.Author(id: 9, username: "other", name: "Other", avatarURL: nil)

    private func progress(approvedBy: [Todo.Author], resetFor: [Todo.Author] = [],
                          completed: Int = 1, required: Int = 2) -> MergeRequestApprovalProgress {
        var result = MergeRequestApprovalProgress(completed: completed, required: required, approvedBy: approvedBy)!
        for author in resetFor {
            result.reviewHistory.activities[author.id] = .init(author: author, previouslyApproved: true)
        }
        return result
    }

    @Test func reportsTheViewersCurrentApprovalOnReviewedMRs() {
        let value = progress(approvedBy: [other, me])
        #expect(value.viewerApproval(username: "me", reviewers: [], isOwnMergeRequest: false) == .approved(me))
    }

    @Test func reportsAnApprovalThatNoLongerCounts() {
        let value = progress(approvedBy: [other], resetFor: [me])
        #expect(value.viewerApproval(username: "Me", reviewers: [], isOwnMergeRequest: false) == .noLongerCounts(me))
    }

    @Test func hidesTheViewerApprovalOnOwnMRsUnknownViewersAndNonApprovers() {
        let approved = progress(approvedBy: [me])
        #expect(approved.viewerApproval(username: "me", reviewers: [], isOwnMergeRequest: true) == nil)
        #expect(approved.viewerApproval(username: nil, reviewers: [], isOwnMergeRequest: false) == nil)
        #expect(approved.viewerApproval(username: "  ", reviewers: [], isOwnMergeRequest: false) == nil)
        let assigned = progress(approvedBy: [other])
        #expect(assigned.viewerApproval(username: "me", reviewers: [me], isOwnMergeRequest: false) == nil)
    }

    @Test func addsTheViewerSegmentOnlyOnReviewedMRs() {
        let value = progress(approvedBy: [me], required: 1)
        let plain = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value))
        let own = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value,
            viewerUsername: "me", isOwnMergeRequest: true))
        let reviewed = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value,
            viewerUsername: "me", isOwnMergeRequest: false))
        #expect(own.fittingSize == plain.fittingSize)
        #expect(reviewed.fittingSize.width > plain.fittingSize.width)
    }

    @Test func showsAnApprovalThatNoLongerCountsEvenWithoutRequiredApprovals() {
        let value = progress(approvedBy: [], resetFor: [me], completed: 0, required: 0)
        let hidden = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value))
        let reviewed = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value,
            viewerUsername: "me", isOwnMergeRequest: false))
        #expect(hidden.fittingSize == .zero)
        #expect(reviewed.fittingSize.width > 0)
    }

    private func row(author: String, isAuthored: Bool) throws -> MergeRequestBoardSnapshot.Row {
        let json = #"{"project_id":1,"iid":42,"title":"MR","author":{"id":3,"username":"AUTHOR","name":"A"},"web_url":"https://gitlab.example.org/g/p/-/merge_requests/42","state":"opened","draft":false,"source_branch":"f","target_branch":"main","labels":[],"sha":"abc"}"#
            .replacingOccurrences(of: "AUTHOR", with: author)
        let request = try JSONDecoder().decode(GitLabMergeRequest.self, from: Data(json.utf8))
        let item = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: 42), title: request.title,
            url: request.webURL, needsDiscussion: false, mergeRequest: request, isAuthored: isAuthored)
        return .init(item: item, latestJob: nil, intents: [])
    }

    @Test func treatsAuthoredOrSelfAuthoredRowsAsOwn() throws {
        #expect(try row(author: "someone", isAuthored: false).isOwnMergeRequest(viewer: "me") == false)
        #expect(try row(author: "someone", isAuthored: true).isOwnMergeRequest(viewer: "me"))
        #expect(try row(author: "Me", isAuthored: false).isOwnMergeRequest(viewer: "me"))
        #expect(try row(author: "someone", isAuthored: false).isOwnMergeRequest(viewer: nil))
    }
}
