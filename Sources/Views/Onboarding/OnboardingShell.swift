import SwiftUI

struct OnboardingShell<Content: View>: View {
    let step: OnboardingView.Step
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
                Text(.Onboarding.onboardingStepOf(step.index, OnboardingView.Step.totalUserFacing))
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
                Button {
                    onSkip()
                } label: {
                    Text(.Onboarding.onboardingSkip)
                }
            }

            Button {
                onContinue()
            } label: {
                Text(step == .done ? .Onboarding.onboardingFinish : .Onboarding.onboardingContinue)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!continueEnabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
