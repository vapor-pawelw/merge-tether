import Foundation

struct AssistantChatLink: Identifiable {
    let assistant: AutomationAssistant
    let url: URL
    var id: String { assistant.rawValue }
}
