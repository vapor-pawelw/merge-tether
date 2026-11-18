import Foundation
import Testing
@testable import GitLabTodos

struct AssistantAutomaticRetryPolicyTests {
    private let time = Date(timeIntervalSince1970: 1_000)
    private let target = AssistantAutomaticRetryTarget(host: "gitlab.example.test", username: "me", projectID: 1, iid: 2)

    @Test(arguments: [AssistantJobExecution.State.failed, .interrupted])
    func failuresHaveASeparateAttemptWithBoundedIncreasingBackoff(_ state: AssistantJobExecution.State) throws {
        var job = candidate(state: state)
        var attempts: [AssistantAutomaticRetryAttempt] = []
        for number in 1...3 {
            let plan = try #require(plans([job], attempts).first)
            #expect(plan.rootID == (job.automaticRetryIdentity?.rootID ?? job.id))
            #expect(plan.attempt == number)
            #expect(plan.dueAt == job.finishedAt!.addingTimeInterval([15.0, 60, 300][number - 1]))
            var reserved = plan.reservation(at: plan.dueAt)
            let childID = UUID()
            reserved.state = .started
            reserved.replacementJobID = childID
            attempts.append(reserved)
            job = candidate(id: childID, state: state, finishedAt: plan.dueAt,
                identity: reserved.identity, retryOf: job.id)
        }
        #expect(plans([job], attempts).isEmpty)
        #expect(AssistantAutomaticRetryPolicy.assess([job], attempts: attempts).contains {
            if case .exhausted(let parentID, _) = $0 { parentID == job.id } else { false }
        })
    }

    @Test(arguments: [AssistantJobExecution.State.cancelled, .blocked, .succeeded, .queued, .running])
    func explicitStopsSemanticBlockersAndActiveWorkNeverBecomeGenericRetries(_ state: AssistantJobExecution.State) {
        #expect(plans([candidate(state: state)], []).isEmpty)
    }

    @Test func newSameFamilyWorkSupersedesEarlierFailureButOtherFamiliesDoNot() {
        let failed = candidate()
        var later = candidate(state: .succeeded)
        later.createdAt = time.addingTimeInterval(1)
        #expect(plans([failed, later], []).isEmpty)
        later.family = "review"
        #expect(plans([failed, later], []).map(\.parentJobID) == [failed.id])
        later.state = .running
        #expect(plans([failed, later], []).isEmpty)
    }

    @Test func workflowLocalRecoveryAndLegacyNonExecutableRecordsAreExcluded() {
        var job = candidate()
        job.delegatesRecovery = true
        #expect(plans([job], []).isEmpty)
        job.delegatesRecovery = false
        job.isExecutable = false
        #expect(plans([job], []).isEmpty)
    }

    @Test func onlyPolicyCancellationCanResumeWithoutAnotherUserCommand() {
        var job = candidate(state: .cancelled)
        #expect(plans([job], []).isEmpty)
        job.cancellationOrigin = .user
        #expect(plans([job], []).isEmpty)
        job.cancellationOrigin = .policy
        #expect(plans([job], []).first?.attempt == 1)
    }

    @Test(arguments: [AssistantJobExecution.State.failed, .interrupted, .cancelled])
    func explicitStopVetoesRecoveryEvenIfTerminationOverwritesTheTerminalState(_ state: AssistantJobExecution.State) {
        var job = candidate(state: state)
        job.cancellationOrigin = .user
        #expect(plans([job], []).isEmpty)
    }

    @Test func preflightFailuresUseTheirReservationTimeAndConsumeTheSameDurableBudget() throws {
        let job = candidate()
        var first = try #require(plans([job], []).first).reservation(at: time.addingTimeInterval(100))
        first.state = .failed
        let second = try #require(plans([job], [first]).first)
        #expect(second.rootID == job.id && second.attempt == 2)
        #expect(second.dueAt == first.reservedAt.addingTimeInterval(60))
        first.finishedAt = first.reservedAt.addingTimeInterval(120)
        #expect(plans([job], [first]).first?.dueAt == first.finishedAt?.addingTimeInterval(60))
        let duplicate = first
        #expect(plans([job], [first, duplicate]).isEmpty)
    }

    @Test func aReservedOrLaunchedParentCannotLaunchAgainAfterHistoryPruning() throws {
        let job = candidate()
        var record = try #require(plans([job], []).first).reservation(at: time)
        #expect(plans([job], [record]).isEmpty)
        record.state = .started
        record.replacementJobID = UUID()
        #expect(plans([job], [record]).isEmpty)
        let child = candidate(id: record.replacementJobID!, identity: record.identity, retryOf: job.id)
        #expect(plans([child], [record]).first?.attempt == 2)
        #expect(plans([child], []).isEmpty, "Missing durable history cannot mint a new budget")
    }

    @Test func anotherAccountCannotAdoptARetryIdentity() throws {
        let job = candidate()
        var record = try #require(plans([job], []).first).reservation(at: time)
        let childID = UUID()
        record.state = .started; record.replacementJobID = childID
        var child = candidate(id: childID, identity: record.identity, retryOf: job.id)
        child.target = .init(host: target.host, username: "other", projectID: 1, iid: 2)
        #expect(plans([child], [record]).isEmpty)
    }

    @Test func anOriginalJobRetainsItsBudgetWatermarkAfterPreflightFailure() throws {
        var job = candidate()
        var record = try #require(plans([job], []).first).reservation(at: time)
        record.state = .failed
        job.automaticRetryIdentity = record.identity
        #expect(plans([job], [record]).first?.attempt == 2)
        #expect(plans([job], []).isEmpty)
    }

    private func candidate(id: UUID = UUID(), state: AssistantJobExecution.State = .failed,
                           finishedAt: Date? = nil, identity: AssistantAutomaticRetryIdentity? = nil,
                           retryOf: UUID? = nil) -> AssistantAutomaticRetryPolicy.Candidate {
        .init(id: id, target: target, family: "pipeline", createdAt: time,
            state: state, finishedAt: finishedAt ?? time, automaticRetryIdentity: identity, retryOf: retryOf)
    }
    private func plans(_ jobs: [AssistantAutomaticRetryPolicy.Candidate], _ attempts: [AssistantAutomaticRetryAttempt]) -> [AssistantAutomaticRetryPolicy.Plan] {
        AssistantAutomaticRetryPolicy.assess(jobs, attempts: attempts).compactMap {
            if case .planned(let plan) = $0 { plan } else { nil }
        }
    }
}
