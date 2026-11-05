import Foundation

/// Delivery history for one MR; a confirmed delivery is not a task-completion signal.
@MainActor
struct AssistantTaskGroup: Identifiable {
    let id: AssistantAutomationRunner.MergeRequestWork
    let handoffs: [AssistantAutomationRunner.Handoff]

    var latest: AssistantAutomationRunner.Handoff { handoffs[0] }
    var title: String { latest.title }
    var updatedAt: Date { latest.createdAt }
    var pendingCount: Int { handoffs.filter { $0.relayComplete != true }.count }
    var deliveredCount: Int { handoffs.count - pendingCount }
    var chatHandoff: AssistantAutomationRunner.Handoff? {
        handoffs.first { $0.relayComplete == true && Self.chatURL(for: $0) != nil }
    }
    var chatURL: URL? { chatHandoff.flatMap(Self.chatURL(for:)) }

    private init(id: AssistantAutomationRunner.MergeRequestWork, handoffs: [AssistantAutomationRunner.Handoff]) {
        self.id = id
        self.handoffs = handoffs
    }

    static func groups(from handoffs: [AssistantAutomationRunner.Handoff], host: String, username: String) -> [Self] {
        let matching = handoffs.filter { $0.key.work.host == host && $0.key.username == username }
        return Dictionary(grouping: matching, by: { $0.key.work }).map { work, events in
            Self(id: work, handoffs: events.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            })
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.id.host, $0.id.projectID, $0.id.iid) < ($1.id.host, $1.id.projectID, $1.id.iid)
        }
    }

    private static func chatURL(for handoff: AssistantAutomationRunner.Handoff) -> URL? {
        guard let id = handoff.chatID else { return nil }
        return switch handoff.key.assistant {
        case .codex: AssistantAutomationRunner.codexChatURL(id)
        case .claude: AssistantAutomationRunner.claudeSessionURL(id)
        }
    }
}
