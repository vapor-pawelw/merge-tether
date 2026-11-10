import Foundation
import Testing
@testable import GitLabTodos

@MainActor
struct MRActivityTimelineTests {
    private let target = MRAutomationScope.Target(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func pollingAndReopeningDetailsKeepTheCurrentStageStart() {
        var timeline = MRActivityTimeline()
        let check = MRActivity(status: "Checking feedback")
        timeline.update([target: check], now: start)
        timeline.update([target: check], now: start.addingTimeInterval(50))
        #expect(timeline.startedAt(for: target, activity: check) == start)
    }

    @Test func aNewStageOrRunResetsOnlyItsOwnTimer() {
        // given
        var timeline = MRActivityTimeline()
        let other = MRAutomationScope.Target(host: target.host, username: "me", projectID: 1, iid: 3)
        let check = MRActivity(status: "Checking feedback")
        let firstRun = MRActivity(status: "Handling feedback", jobID: UUID())
        timeline.update([target: check, other: check], now: start)
        // when
        timeline.update([target: firstRun, other: check], now: start.addingTimeInterval(50))
        // then
        #expect(timeline.startedAt(for: target, activity: firstRun) == start.addingTimeInterval(50))
        #expect(timeline.startedAt(for: other, activity: check) == start)
        let secondRun = MRActivity(status: "Handling feedback", jobID: UUID())
        timeline.update([target: secondRun], now: start.addingTimeInterval(90))
        #expect(timeline.startedAt(for: target, activity: secondRun) == start.addingTimeInterval(90))
        #expect(timeline.startedAt(for: other, activity: check) == nil)
    }

    @Test func idleAndAccountChangesDiscardOldTimers() {
        var timeline = MRActivityTimeline()
        let check = MRActivity(status: "Checking feedback")
        timeline.update([target: check], now: start)
        timeline.update([:], now: start.addingTimeInterval(50))
        #expect(timeline.startedAt(for: target, activity: check) == nil)
        let anotherAccount = MRAutomationScope.Target(host: target.host, username: "someone", projectID: 1, iid: 2)
        timeline.update([anotherAccount: check], now: start.addingTimeInterval(90))
        #expect(timeline.startedAt(for: anotherAccount, activity: check) == start.addingTimeInterval(90))
        #expect(timeline.startedAt(for: target, activity: check) == nil)
    }

    @Test func runningJobsUseTheirRecordedStartEvenWhenFirstObservedLater() {
        var timeline = MRActivityTimeline()
        let work = MRActivity(status: "Handling feedback", jobID: UUID(), startedAt: start)
        timeline.update([target: work], now: start.addingTimeInterval(50))
        #expect(timeline.startedAt(for: target, activity: work) == start)
    }

    @Test(arguments: [(0.0, "0s"), (50, "50s"), (60, "1m 0s"), (260, "4m 20s"),
                      (3_599, "59m 59s"), (3_600, "1h 0m"), (4_500, "1h 15m"), (-1, "0s")])
    func elapsedTimeUsesCompactSecondsMinutesAndHours(seconds: TimeInterval, expected: String) {
        #expect(MRActivity.elapsed(since: start, now: start.addingTimeInterval(seconds)) == expected)
    }
}
