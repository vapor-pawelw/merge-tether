import AppKit
import MergeTetherRemote

@MainActor
func confirmMRAction(_ action: MRActionCTA, title: LocalizedStringResource, variant: String? = nil,
                     detail: String? = nil, monitor: TodoMonitorService? = nil) -> Bool {
    if action.requiresCodingAssistant, let monitor, !requireCodingAssistant(monitor) { return false }
    return confirmMRAction(id: action.confirmationID(variant: variant), title: title,
        message: [action.help, detail].compactMap { $0 }.joined(separator: "\n\n"))
}

@MainActor
func requireCodingAssistant(_ monitor: TodoMonitorService, for provider: AutomationAssistant? = nil) -> Bool {
    let selected = monitor.settings.automation.selectedAssistant
    if selected != nil, let assistant = provider ?? selected, monitor.availableAssistants.contains(assistant) { return true }
    presentCodingAssistantSetup()
    return false
}

@MainActor
func presentCodingAssistantSetup() {
    let alert = NSAlert()
    alert.messageText = String(localized: .Settings.settingsAssistantRequiredTitle)
    alert.informativeText = String(localized: .Settings.settingsAssistantRequiredBody)
    alert.addButton(withTitle: String(localized: .Settings.settingsAssistantSetupAction))
    alert.addButton(withTitle: String(localized: .Settings.settingsAssistantSetupCancel)).keyEquivalent = "\u{1b}"
    if alert.runModal() == .alertFirstButtonReturn { SettingsNavigation.shared.showCodingAgent() }
}

@MainActor
func confirmMRAction(id: String, title: LocalizedStringResource, button: LocalizedStringResource? = nil,
                     message: String) -> Bool {
    let preferences = MRActionConfirmationPreferences()
    guard preferences.requiresConfirmation(for: id) else { return true }

    let alert = NSAlert()
    alert.messageText = String(localized: title)
    alert.informativeText = message
    let accept = alert.addButton(withTitle: String(localized: button ?? title))
    let cancel = alert.addButton(withTitle: String(localized: .Menu.menuScopeCancel))
    accept.keyEquivalent = ""
    cancel.keyEquivalent = "\r"
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = String(localized: .CommandCenter.commandCenterAutomationConfirmDontAskAgain)
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    preferences.accept(id, remember: alert.suppressionButton?.state == .on)
    return true
}

@MainActor
func confirmSelectedDraftPublication(title: LocalizedStringResource, publishesAll: Bool) -> Bool {
    !publishesAll || confirmMRAction(.publishComments, title: title, variant: "selected",
        detail: String(localized: .CommentReview.commentReviewPublishSelectedHelp))
}
