import Foundation
import Testing
@testable import GitLabTodos

@Suite("GlabService decoding")
struct GlabServiceDecodingTests {
    static let todos: [Todo] = {
        let url = Bundle.module.url(forResource: "todos", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        return try! GlabService.decodeTodos(data)
    }()

    @Test("decodes all fixture entries")
    func decodesAll() {
        #expect(Self.todos.count == 6)
    }

    @Test("decodes every to-do page when glab concatenates JSON arrays")
    func decodesConcatenatedPages() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let firstPage = try encoder.encode(Array(Self.todos.prefix(2)))
        let secondPage = try encoder.encode(Array(Self.todos.dropFirst(2)))
        let output = firstPage + secondPage + Data("\n[]".utf8)

        #expect(try GlabService.decodeTodos(output).map(\.id) == Self.todos.map(\.id))
    }

    @Test("maps top-level fields correctly for a review request")
    func topLevelMapping() {
        let mr = Self.todos.first { $0.id == 10001 }!
        #expect(mr.actionName == .reviewRequested)
        #expect(mr.targetType == .mergeRequest)
        #expect(mr.targetURL == URL(string: "https://gitlab.com/acme/frontend/-/merge_requests/1369"))
        #expect(mr.state == "pending")
        #expect(mr.project.pathWithNamespace == "acme/frontend")
        #expect(mr.author.username == "molesxiak")
        #expect(mr.author.name == "Mateusz Oleksiak")
        #expect(mr.author.avatarURL != nil)
        #expect(mr.target.iid == 1369)
        #expect(mr.target.state == "opened")
        #expect(mr.isDraft == false)
        #expect(mr.relativeIdentifier == "!1369")
    }

    @Test("draft MR is reflected via work_in_progress or draft")
    func draftDetection() {
        let draft = Self.todos.first { $0.id == 10002 }!
        #expect(draft.isDraft == true)
        #expect(draft.targetState == .draft)
    }

    @Test("merged MR surfaces merged state")
    func mergedState() {
        let merged = Self.todos.first { $0.id == 10003 }!
        #expect(merged.targetState == .merged)
        #expect(merged.relativeIdentifier == "!55")
    }

    @Test("issue uses # prefix for relative identifier")
    func issueIdentifier() {
        let issue = Self.todos.first { $0.id == 10004 }!
        #expect(issue.targetType == .issue)
        #expect(issue.relativeIdentifier == "#42")
    }

    @Test("missing avatar_url decodes as nil")
    func nilAvatarURL() {
        let draft = Self.todos.first { $0.id == 10002 }!
        #expect(draft.author.avatarURL == nil)
    }

    @Test("epic uses & prefix for relative identifier")
    func epicIdentifier() {
        let epic = Self.todos.first { $0.id == 10005 }!
        #expect(epic.targetType == .epic)
        #expect(epic.relativeIdentifier == "&7")
        #expect(epic.targetState == .none)
    }

    @Test("unknown action_name and target_type fall back gracefully")
    func unknownFallback() {
        let unknown = Self.todos.first { $0.id == 10006 }!
        #expect(unknown.actionName == .unknown("custom_future_action"))
        #expect(unknown.targetType == .unknown("SomeFutureType"))
        #expect(unknown.relativeIdentifier == "")
        #expect(unknown.displayTitle == "Unknown target kind")
    }

    @Test("decodes the GitLab approver action and encodes its canonical API name")
    func addedApproverAction() throws {
        let decoder = JSONDecoder()
        let action = try decoder.decode(ActionName.self, from: Data(#""added_approver""#.utf8))
        let legacyAction = try decoder.decode(ActionName.self, from: Data(#""added_approvers""#.utf8))
        let encodedAction = try JSONEncoder().encode(action)
        #expect(action == .addedApprovers)
        #expect(legacyAction == action)
        #expect(encodedAction == Data(#""added_approver""#.utf8))
    }

    @Test("createdAt parses ISO8601 with and without fractional seconds")
    func dateParsing() {
        let withFraction = Self.todos.first { $0.id == 10001 }!
        let withoutFraction = Self.todos.first { $0.id == 10003 }!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(withFraction.createdAt == formatter.date(from: "2026-04-12T09:15:00.000Z"))
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        #expect(withoutFraction.createdAt == plain.date(from: "2026-03-30T08:00:00Z"))
    }
}
