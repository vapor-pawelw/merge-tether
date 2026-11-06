import SwiftUI

struct OnboardingView: View {
    let monitor: TodoMonitorService

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Step = .glabInstall
    @State private var automationChoice: AutomationPackageChoice?
    @State private var assistant: AutomationAssistant
    @State private var pendingAutomation: AutomationSettings?
    @State private var showingAssistantSetup = false

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
        _assistant = State(initialValue: monitor.settings.automation.assistant)
    }

    enum Step: Int, CaseIterable {
        case glabInstall
        case glabAuth
        case notifications
        case launchAtLogin
        case automation
        case done

        var index: Int { rawValue + 1 }
        static var totalUserFacing: Int { allCases.count - 1 }
        var isSkippable: Bool {
            switch self {
            case .notifications, .launchAtLogin: true
            default: false
            }
        }
    }

    var body: some View {
        OnboardingShell(
            step: step,
            onBack: goBack,
            onSkip: goNext,
            onContinue: goNext,
            continueEnabled: canContinue
        ) {
            switch step {
            case .glabInstall:
                GlabInstallStep(monitor: monitor)
            case .glabAuth:
                GlabAuthStep(monitor: monitor)
            case .notifications:
                NotificationsStep(monitor: monitor)
            case .launchAtLogin:
                LaunchAtLoginStep(monitor: monitor)
            case .automation:
                AutomationPackageStep(
                    monitor: monitor, assistant: $assistant, selection: $automationChoice
                )
            case .done:
                OnboardingDoneStep()
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .sheet(isPresented: $showingAssistantSetup) {
            if let pendingAutomation {
                AssistantSetupView(assistant: pendingAutomation.assistant, requireCLI: true) {
                    complete(automation: pendingAutomation)
                }
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .glabInstall: monitor.glab.glabPath != nil
        case .glabAuth: monitor.glab.currentUsername != nil
        case .automation:
            monitor.settings.automation.packageDecision != .undecided || automationChoice == .off
                || (automationChoice == .recommended && monitor.availableAssistants.contains(assistant))
        case .notifications, .launchAtLogin, .done: true
        }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func goNext() {
        if step == .done {
            finish()
            return
        }
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func finish() {
        var updated = monitor.settings.automation
        if monitor.settings.automation.packageDecision == .undecided, let automationChoice {
            automationChoice.apply(to: &updated, assistant: assistant)

            if automationChoice == .recommended {
                pendingAutomation = updated
                showingAssistantSetup = true
                return
            }
        }
        complete(automation: updated)
    }

    private func complete(automation: AutomationSettings) {
        monitor.settings.automation = automation
        monitor.settings.onboardingCompleted = true
        monitor.settings.save()
        monitor.start()
        dismissWindow(id: "onboarding")
    }
}
