import Foundation

enum MRTodoMentionDisposition: Equatable, Sendable { case informational, actionable, uncertain }

/// A durable action accepted from a GitLab event. Receiving the event and
/// finishing the action are deliberately separate states.
struct MRTodoIntent: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case review, followUp, pipeline, conflict, refresh }
    enum State: String, Codable, Hashable, Sendable { case pending, running, failed, completed }
    let id: UUID
    let target: MRAutomationScope.Target
    let kind: Kind
    var state: State
    var todoIDs: Set<Int>
    var noteIDs: Set<Int>
    var sourceEvents: [Todo.FeedbackIdentity]
    var request: GitLabMergeRequest
    var headSHA: String
    var jobID: UUID?
    var error: String?
    var updatedAt: Date
    var sourceTodo: Todo?

    /// A notice receipt retains routing history without enrolling its MR for work.
    var grantsManagement: Bool { kind != .refresh }

    /// Accepted review requests remain tracked while their author finishes a Draft.
    var isDeferredReview: Bool {
        kind == .review && state == .pending && jobID == nil
            && request.state == "opened" && request.draft == true
    }

    /// Only candidates with a concrete meaning are proposed. Discussion events
    /// still require matching live unresolved feedback before routing.
    static func kind(for todo: Todo, username: String) -> Kind? {
        guard todo.targetType == .mergeRequest, (todo.target.iid ?? 0) > 0 else { return nil }
        switch todo.actionName {
        case .reviewRequested, .approvalRequired:
            return todo.target.author?.username == username ? nil : .review
        case .buildFailed: return .pipeline
        case .unmergeable: return .conflict
        case .mentioned, .directlyAddressed:
            return todo.target.author?.username == username && todo.linkedNoteID != nil ? .followUp : nil
        case .reviewSubmitted:
            return todo.target.author?.username == username ? .followUp : nil
        default: return nil
        }
    }
}

struct MRTodoRouteReceipt: Codable, Hashable, Sendable {
    let target: MRAutomationScope.Target
    let event: Todo.FeedbackIdentity
    let intentID: UUID?
}
