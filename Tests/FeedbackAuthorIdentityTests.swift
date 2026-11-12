import Foundation
import Testing
@testable import GitLabTodos

@MainActor @Suite struct FeedbackAuthorIdentityTests {
    @Test(arguments: [
        (#"{"id":7,"username":"reviewer","state":"active","bot":false,"user_type":"human"}"#, true),
        (#"{"id":7,"username":"reviewer","state":"active","bot":false}"#, true),
        (#"{"id":7,"username":"reviewer","state":"active","bot":false,"user_type":"service_account"}"#, false),
        (#"{"id":7,"username":"reviewer","state":"active","bot":false,"user_type":"duo_code_review_bot"}"#, false),
        (#"{"id":7,"username":"reviewer","state":"active","bot":false,"user_type":"unknown_type"}"#, false),
        (#"{"id":7,"username":"reviewer","state":"active","user_type":"human"}"#, false),
        (#"{"id":7,"username":"reviewer","state":"blocked","bot":false}"#, false),
        (#"{"id":99,"username":"reviewer","state":"active","bot":false}"#, false),
        (#"{"id":7,"username":"","state":"active","bot":false}"#, false)
    ])
    func humanReviewSelectionUsesTheSameAuthorClassifierWithOneMetadataRead(_ response: String, _ human: Bool) async throws {
        let gitlab = InMemoryGitLab(); defer { gitlab.close() }
        let service = gitlab.service(host: "gitlab.example.test", username: "me")
        gitlab.handler = { request in
            #expect(request.endpoint == "/users/7" && request.method == "GET")
            return InMemoryGitLab.output(response)
        }
        let username = try await service.activeHumanReviewerUsername(userID: 7, host: "gitlab.example.test")
        #expect(username == (human ? "reviewer" : nil))
        #expect(gitlab.requests.count == 1)
    }

    @Test func localDesignationUpdatesDisplayWithoutChangingFreshServerIdentityOrOtherAccounts() async throws {
        let gitlab = InMemoryGitLab(); defer { gitlab.close() }
        let service = gitlab.service(host: "gitlab.example.test", username: "me")
        var events: [FeedbackAccountKindUpdate] = []
        let token = service.observeFeedbackAccountKinds { events.append($0) }
        defer { service.removeFeedbackAccountObserver(token) }
        gitlab.handler = { _ in InMemoryGitLab.output(#"{"id":7,"bot":false}"#) }
        let server = try await service.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        #expect(server == .regular)
        service.updateLocalAutomationAuthors([7], host: "other.example.test", username: "me")
        #expect(events.count == 1)
        service.updateLocalAutomationAuthors([7], host: "gitlab.example.test", username: "me")
        #expect(events.last?.kind == .automation)
        service.updateLocalAutomationAuthors([], host: "gitlab.example.test", username: "me")
        #expect(events.last?.kind == .regular)
        #expect(gitlab.requests.count == 1)
    }

    @Test func successfulMetadataNotifiesOnlyItsCurrentAccountAndObserversCanUnsubscribe() async throws {
        let gitlab = InMemoryGitLab(); defer { gitlab.close() }
        let service = gitlab.service(host: "gitlab.example.test", username: "me")
        var events: [FeedbackAccountKindUpdate] = []
        let token = service.observeFeedbackAccountKinds { events.append($0) }
        gitlab.handler = { _ in InMemoryGitLab.output(#"{"id":7,"bot":true}"#) }
        _ = try await service.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        #expect(events.count == 1 && events.first?.kind == .automation)
        #expect(events.first?.username == "me" && events.first?.accountRevision == service.accountRevision)
        service.removeFeedbackAccountObserver(token)
        _ = try await service.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        #expect(events.count == 1)
        let other = service.observeFeedbackAccountKinds { events.append($0) }
        defer { service.removeFeedbackAccountObserver(other) }
        gitlab.handler = { _ in
            service.currentUsername = "other"; service.currentUsername = "me"
            return InMemoryGitLab.output(#"{"id":7,"bot":true}"#)
        }
        let obsolete = try await service.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        #expect(obsolete == .unknown && events.count == 1)
    }

    @Test(arguments: [
        (#"{"id":7,"bot":true}"#, "automation"),
        (#"{"id":7,"user_type":"duo_code_review_bot"}"#, "automation"),
        (#"{"id":7,"user_type":"automation_bot"}"#, "automation"),
        (#"{"id":7,"user_type":"security_policy_bot"}"#, "automation"),
        (#"{"id":7,"user_type":"project_bot"}"#, "automation"),
        (#"{"id":7,"user_type":"service_account"}"#, "automation"),
        (#"{"id":7,"bot":false,"user_type":"human"}"#, "regular"),
        (#"{"id":7,"bot":false}"#, "regular"),
        (#"{"id":7,"user_type":"human"}"#, "unknown"),
        (#"{"id":7,"bot":false,"user_type":"ghost"}"#, "unknown"),
        (#"{"id":7,"bot":false,"user_type":"placeholder"}"#, "unknown"),
        (#"{"id":7,"bot":false,"user_type":"service_user"}"#, "unknown"),
        (#"{"id":7,"username":"automation-looking-name"}"#, "unknown"),
        (#"{"id":99,"bot":true,"user_type":"duo_code_review_bot"}"#, "unknown")
    ])
    func accountKindUsesMatchingGitLabMetadataWithoutGuessingFromNames(_ response: String, _ expected: String) async throws {
        let gitlab = InMemoryGitLab()
        defer { gitlab.close() }
        let service = gitlab.service(host: "gitlab.example.test", username: "me")
        gitlab.handler = { request in
            #expect(request.endpoint == "/users/7" && request.method == "GET")
            return InMemoryGitLab.output(response)
        }
        let kind = try await service.feedbackAccountKind(userID: 7, host: "gitlab.example.test")
        let actual: String = switch kind {
        case .regular: "regular"
        case .automation: "automation"
        case .unknown: "unknown"
        }
        #expect(actual == expected)
        #expect(gitlab.requests.count == 1)
    }
}
