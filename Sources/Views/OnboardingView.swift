import SwiftUI

struct OnboardingView: View {
    let monitor: TodoMonitorService

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Step = .glabInstall
    @State private var automationChoice: AutomationPackageChoice?
    @State private var assistant: AutomationAssistant?
    @State private var assistantSetup: AutomationAssistant?
    @State private var isImportingReviews = false

    init(monitor: TodoMonitorService) {
        self.monitor = monitor
        let automation = monitor.settings.automation
        _assistant = State(initialValue: automation.selectedAssistant)
        _automationChoice = State(initialValue: AutomationPreset.onboardingDefault(for: automation.packageDecision))
        _step = State(initialValue: Self.startingStep(hasCompletedSetup: monitor.settings.onboardingCompleted,
            cliAvailable: monitor.glab.glabPath != nil))
    }

    static func startingStep(hasCompletedSetup: Bool, cliAvailable: Bool) -> Step {
        hasCompletedSetup && cliAvailable ? .glabAuth : .glabInstall
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
            continueEnabled: canContinue,
            isBusy: isImportingReviews
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
                OnboardingDoneStep(monitor: monitor, isImporting: $isImportingReviews)
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .sheet(item: $assistantSetup) { candidate in
            AssistantSetupView(assistant: candidate) {
                step = .done
            }
        }
    }

    private var canContinue: Bool {
        switch step {
        case .glabInstall: monitor.glab.glabPath != nil
        case .glabAuth: monitor.glab.currentUsername != nil
        case .automation:
            monitor.settings.automation.packageDecision != .undecided || effectiveAutomationChoice == .manual
                || (effectiveAutomationChoice?.requiresCLI == true && assistant.map(monitor.availableAssistants.contains) == true)
        case .notifications, .launchAtLogin, .done: true
        }
    }

    private var effectiveAutomationChoice: AutomationPackageChoice? {
        assistant == nil && automationChoice != nil ? .manual : automationChoice
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func goNext() {
        guard canContinue else { return }
        switch step {
        case .done:
            finish()
        case .automation where monitor.settings.automation.packageDecision == .undecided
            && effectiveAutomationChoice?.requiresCLI == true:
            assistantSetup = assistant
        default:
            if let next = Step(rawValue: step.rawValue + 1) { step = next }
        }
    }

    private func finish() {
        var updated = monitor.settings.automation
        if updated.packageDecision == .undecided, let automationChoice = effectiveAutomationChoice {
            automationChoice.apply(to: &updated, assistant: assistant)
        }
        monitor.settings.automation = updated
        monitor.settings.onboardingCompleted = true
        monitor.applySettings()
        monitor.start()
        dismissWindow(id: "onboarding")
    }
}
