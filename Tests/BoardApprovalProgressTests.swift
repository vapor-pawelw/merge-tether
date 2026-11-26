import AppKit
import SwiftUI
import Testing
@testable import MergeTether

@MainActor struct BoardApprovalProgressTests {
    @Test func usesSecondaryColorWhenApprovalProgressIsUnknown() {
        let environment = EnvironmentValues()
        #expect(BoardApprovalProgressBadge(progress: nil).approvalColor.resolve(in: environment)
            == Color.secondary.resolve(in: environment))
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func colorsApprovalProgress(colorScheme: ColorScheme) throws {
        let orange = colorScheme == .dark
            ? Color(red: 0.83, green: 0.57, blue: 0.37)
            : Color(red: 0.59, green: 0.28, blue: 0.10)
        let yellow = colorScheme == .dark
            ? Color(red: 0.79, green: 0.70, blue: 0.32)
            : Color(red: 0.46, green: 0.38, blue: 0.04)
        let cases: [(Int, Int, Color)] = [
            (0, 0, .secondary),
            (1, 0, .green),
            (0, 2, .secondary),
            (1, 100, orange),
            (1, 3, orange),
            (49, 100, orange),
            (1, 2, yellow),
            (2, 3, yellow),
            (9, 10, yellow),
            (2, 2, .green),
        ]
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        for (completed, required, expected) in cases {
            let progress = try #require(MergeRequestApprovalProgress(completed: completed, required: required))
            let actual = BoardApprovalProgressBadge(progress: progress).approvalColor.resolve(in: environment)
            #expect(actual == expected.resolve(in: environment), "\(completed)/\(required)")
        }
    }

    @Test(arguments: [7, 14])
    func showsFullGreenWhenTheCountIsMetEvenIfARuleIsPending(completed: Int) throws {
        var progress = try #require(MergeRequestApprovalProgress(completed: completed, required: 7))
        progress.requirementsSatisfied = false
        let environment = EnvironmentValues()
        let actual = BoardApprovalProgressBadge(progress: progress).approvalColor.resolve(in: environment)
        #expect(actual == Color.green.resolve(in: environment))
    }

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

    @Test func aPendingRuleKeepsTheBadgeOnOneLine() throws {
        var progress = try #require(MergeRequestApprovalProgress(completed: 5, required: 2))
        progress.requirementsSatisfied = true
        let satisfied = NSHostingView(rootView: BoardApprovalProgressBadge(progress: progress))
        progress.requirementsSatisfied = false
        let pending = NSHostingView(rootView: BoardApprovalProgressBadge(progress: progress))
        #expect(pending.fittingSize.height <= satisfied.fittingSize.height + 1)
    }

    @Test func anApprovalNoteAddsNoSpaceToTheBadge() {
        let value = progress(approvedBy: [me], required: 1)
        let plain = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value,
            viewerUsername: "me", isOwnMergeRequest: false))
        let withNote = NSHostingView(rootView: BoardApprovalProgressBadge(progress: value,
            viewerUsername: "me", isOwnMergeRequest: false, showsOpenFindingsApproval: { true }))
        #expect(withNote.fittingSize == plain.fittingSize)
    }

    @Test func showsAssignedReviewersEvenWithoutRequiredApprovals() {
        let badge = BoardApprovalProgressBadge(progress: MergeRequestApprovalProgress(completed: 0, required: 0),
            reviewers: [me, other])
        #expect(NSHostingView(rootView: badge).fittingSize.width > 0)
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
            url: request.webURL, mergeRequest: request, isAuthored: isAuthored)
        return .init(item: item, latestJob: nil, intents: [])
    }

    @Test func treatsAuthoredOrSelfAuthoredRowsAsOwn() throws {
        #expect(try row(author: "someone", isAuthored: false).isOwnMergeRequest(viewer: "me") == false)
        #expect(try row(author: "someone", isAuthored: true).isOwnMergeRequest(viewer: "me"))
        #expect(try row(author: "Me", isAuthored: false).isOwnMergeRequest(viewer: "me"))
        #expect(try row(author: "someone", isAuthored: false).isOwnMergeRequest(viewer: nil))
    }
}
