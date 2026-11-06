import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct BoardCardPinTests {
    private let host = "gitlab.example.org"
    private func pin(_ iid: Int, username: String = "me", host: String = "gitlab.example.org") -> BoardCardPin {
        .init(host: host, username: username, item: .mergeRequest(projectID: 1, iid: iid))
    }
    private func item(_ iid: Int, attention: Bool = false, draft: Bool = false) -> MergeRequestAttentionMonitor.Item {
        var result = MergeRequestAttentionMonitor.Item(id: .init(projectID: 1, iid: iid), title: "MR \(iid)",
            url: URL(string: "https://\(host)/g/p/-/merge_requests/\(iid)")!, needsDiscussion: attention)
        result.draftFromTodo = draft
        return result
    }
    private func board(own: [MergeRequestAttentionMonitor.Item] = [], reviewed: [MergeRequestAttentionMonitor.Item] = [],
                       attention: [MergeRequestAttentionMonitor.Item] = [], pins: Set<BoardCardPin> = []) -> MergeRequestBoardSnapshot {
        .init(own: own, reviewed: reviewed, todos: [], attention: attention, handoffs: [],
            host: host, username: "me", pinnedCards: pins)
    }

    @Test func pinnedAlwaysFirstWhileBothGroupsKeepAttentionOrder() {
        let items = [item(1), item(2, attention: true), item(3), item(4, attention: true), item(5)]
        let result = board(own: items, pins: [pin(1), pin(3), pin(4)])
        #expect(result.own.map(\.id.iid) == [4, 1, 3, 2, 5])
        #expect(board(own: items).own.map(\.id.iid) == [2, 4, 1, 3, 5])
    }

    @Test func draftLastAppliesWithinEachPinGroup() {
        let result = board(reviewed: [item(1, attention: true, draft: true), item(2),
            item(3, attention: true), item(4, draft: true), item(5)], pins: [pin(1), pin(2)])
        #expect(result.reviewed.map(\.id.iid) == [2, 1, 3, 5, 4])
    }

    @Test func anotherAccountOrHostCannotPromoteTheSameMR() {
        let items = [item(1), item(2)]
        #expect(board(own: items, pins: [pin(2, username: "other"), pin(2, host: "elsewhere.example.org")]).own.map(\.id.iid) == [1, 2])
    }

    @Test func pinsFollowAProposalIntoTheManagedLane() throws {
        let pins: Set<BoardCardPin> = [pin(2)]
        let proposed = board(attention: [item(1), item(2)], pins: pins)
        #expect(proposed.proposals.map(\.target.iid) == [2, 1])
        let adopted = board(reviewed: [item(1), item(2)], attention: [item(2)], pins: pins)
        #expect(adopted.reviewed.map(\.id.iid) == [2, 1])
        #expect(adopted.proposals.isEmpty)
    }

    @Test func mixedOtherCardsPutPinnedTodosAndJobsAheadOfUnpinnedProposals() {
        let todo = Todo(id: 100, actionName: .unknown("new_event"), targetType: .issue,
            targetURL: URL(string: "https://gitlab.example.org/g/p/-/issues/7")!, body: "Read this",
            createdAt: Date(), state: "pending", project: .init(id: 1, nameWithNamespace: "G / P", pathWithNamespace: "g/p"),
            author: .init(id: 9, username: "author", name: "Author", avatarURL: nil),
            target: .init(id: 7, iid: 7, title: "Event", state: "opened", draft: false, workInProgress: false))
        let job = AssistantAutomationRunner.Handoff(id: UUID(), key: .init(assistant: .codex,
            work: .init(host: host, projectID: 1, iid: 3), username: "me", workspace: "", access: .gitLabRead),
            title: "Job", prompt: "", createdAt: Date(), allowsPush: false, execution: .init(state: .failed))
        let snapshot = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo], attention: [item(1), item(2)],
            handoffs: [], host: host, username: "me")
        let todoPin = BoardCardPin(host: host, username: "me", item: .todo(100))
        let cards = snapshot.otherCards(jobs: [job], host: host, username: "me", pinnedCards: [todoPin, pin(3)])
        #expect(cards.map(\.id) == [todoPin, pin(3), pin(1), pin(2)])
        #expect(snapshot.otherCards(jobs: [job], host: nil, username: nil, pinnedCards: [todoPin]).isEmpty)
    }

    @Test func proposalKeepsLatestRunWithoutDuplicateAndPinsNeverResurrectMissingCards() throws {
        func job(_ date: Date, username: String = "me", host: String = "gitlab.example.org") -> AssistantAutomationRunner.Handoff {
            .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: 2),
                username: username, workspace: "", access: .gitLabRead), title: "Run", prompt: "", createdAt: date,
                allowsPush: false, execution: .init(state: .failed))
        }
        let current = job(Date(timeIntervalSince1970: 10))
        let jobs = [job(.distantPast), current, job(.distantFuture, username: "other"),
            job(.distantFuture, host: "elsewhere.example.org")]
        let todo = Todo(id: 2, actionName: .reviewRequested, targetType: .mergeRequest,
            targetURL: URL(string: "https://gitlab.example.org/g/p/-/merge_requests/2")!, body: "Review",
            createdAt: Date(), state: "pending", project: .init(id: 1, nameWithNamespace: "G / P", pathWithNamespace: "g/p"),
            author: .init(id: 9, username: "author", name: "Author", avatarURL: nil),
            target: .init(id: 2, iid: 2, title: "Review", state: "opened", draft: false, workInProgress: false))
        let result = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo], attention: [], handoffs: jobs,
            host: host, username: "me", pinnedCards: [pin(2), pin(999)])
        #expect(result.proposals.first?.latestJob?.id == current.id)
        let cards = result.otherCards(jobs: jobs, host: host, username: "me", pinnedCards: [pin(2), pin(999)])
        #expect(cards.map(\.id) == [pin(2)])
        #expect(Set(cards.map(\.id)).count == cards.count)
        #expect(board(pins: [pin(999)]).own.isEmpty)
        let ignored = MergeRequestBoardSnapshot(own: [], reviewed: [], todos: [todo], attention: [], handoffs: jobs,
            host: host, username: "me", ignoredTargets: [.init(host: host, username: "me", projectID: 1, iid: 2)],
            pinnedCards: [pin(2)])
        #expect(ignored.otherCards(jobs: jobs, host: host, username: "me", pinnedCards: [pin(2)]).isEmpty)
    }

    @Test func unattachedRunsUseLatestStateAndCurrentAccountOnly() {
        func job(_ iid: Int, state: AssistantJobExecution.State, date: Date = .distantPast,
                 username: String = "me") -> AssistantAutomationRunner.Handoff {
            .init(id: UUID(), key: .init(assistant: .codex, work: .init(host: host, projectID: 1, iid: iid),
                username: username, workspace: "", access: .gitLabRead), title: "Run", prompt: "", createdAt: date,
                allowsPush: false, execution: .init(state: state))
        }
        let jobs = [job(1, state: .failed), job(1, state: .succeeded, date: .distantFuture),
            job(2, state: .running), job(3, state: .failed, username: "other")]
        let cards = board().otherCards(jobs: jobs, host: host, username: "me", pinnedCards: [pin(3)])
        #expect(cards.map(\.id) == [pin(2)])
    }

    @Test func pinPersistenceIsExplicitAndSurvivesReloadAndRemoval() throws {
        let suite = "BoardPinsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsManager(defaults: defaults)
        let pins: Set<BoardCardPin> = [pin(7), pin(7, username: "other"),
            .init(host: host, username: "me", item: .todo(7))]
        settings.boardPins = pins
        #expect(SettingsManager(defaults: defaults).boardPins.isEmpty)
        settings.save()
        #expect(SettingsManager(defaults: defaults).boardPins == pins)
        settings.boardPins.remove(pin(7))
        settings.save()
        #expect(SettingsManager(defaults: defaults).boardPins == pins.subtracting([pin(7)]))
    }
}
