import SwiftUI

struct OnboardingView: View {
    let monitor: TodoMonitorService
    let crashReporting: CrashReporting

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var steps: [Step]
    @State private var step: Step = .glabInstall
    @State private var automationEnabled = false
    @State private var automationChoice = AutomationPreset.safe
    @State private var assistant: AutomationAssistant?
    @State private var assistantSetup: AutomationAssistant?

    init(monitor: TodoMonitorService, crashReporting: CrashReporting) {
        self.monitor = monitor
        self.crashReporting = crashReporting
        _steps = State(initialValue: Step.allCases.filter { $0 != .crashReporting || crashReporting.needsConsent })
        let automation = monitor.settings.automation
        _assistant = State(initialValue: automation.selectedAssistant)
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
        case crashReporting
        case automation
        case done

        var isSkippable: Bool {
            switch self {
            case .notifications, .launchAtLogin, .crashReporting: true
            default: false
            }
        }
    }

    var body: some View {
        OnboardingShell(
            step: step,
            index: (steps.firstIndex(of: step) ?? 0) + 1,
            total: steps.count - 1,
            onBack: goBack,
            onSkip: skip,
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
            case .crashReporting:
                CrashReportingExplanation()
            case .automation:
                AutomationPackageStep(
                    monitor: monitor, enabled: $automationEnabled, assistant: $assistant, selection: $automationChoice
                )
            case .done:
                OnboardingDoneStep()
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
            monitor.settings.automation.packageDecision != .undecided || !automationEnabled
                || assistant.map(monitor.availableAssistants.contains) == true
        case .notifications, .launchAtLogin, .crashReporting, .done: true
        }
    }

    private func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    private func skip() {
        if step == .crashReporting { crashReporting.setEnabled(false) }
        advance()
    }

    private func goNext() {
        guard canContinue else { return }
        switch step {
        case .done:
            finish()
        case .crashReporting:
            crashReporting.setEnabled(true)
            advance()
        case .automation where monitor.settings.automation.packageDecision == .undecided && automationEnabled:
            assistantSetup = assistant
        default:
            advance()
        }
    }

    private func finish() {
        var updated = monitor.settings.automation
        updated.completeOnboardingAutomation(with: automationEnabled ? automationChoice : nil, assistant: assistant)
        monitor.settings.automation = updated
        monitor.settings.onboardingCompleted = true
        monitor.applySettings()
        monitor.start()
        dismissWindow(id: "onboarding")
    }
}
