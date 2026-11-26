import SwiftUI

struct OnboardingShell<Content: View>: View {
    let step: OnboardingView.Step
    let index: Int
    let total: Int
    let onBack: () -> Void
    let onSkip: () -> Void
    let onContinue: () -> Void
    let continueEnabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)

            Divider()

            footer
        }
    }

    private var header: some View {
        HStack {
            Text(.Onboarding.onboardingTitle)
                .font(.title2.weight(.semibold))
            Spacer()
            if step != .done {
                Text(.Onboarding.onboardingStepOf(index, total))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            if step.rawValue > 0 {
                Button {
                    onBack()
                } label: {
                    Text(.Onboarding.onboardingBack)
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if step.isSkippable {
                Button(step == .crashReporting ? .CrashReporting.crashReportingDecline : .Onboarding.onboardingSkip,
                       action: onSkip)
            }

            if step == .crashReporting {
                Button(.CrashReporting.crashReportingEnable, action: onContinue)
            } else {
                Button(step == .done ? .Onboarding.onboardingFinish : .Onboarding.onboardingContinue, action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!continueEnabled)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
