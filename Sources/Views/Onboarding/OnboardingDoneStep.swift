import SwiftUI

struct OnboardingDoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.Onboarding.onboardingDoneTitle)
                .font(.title3.weight(.semibold))

            Text(.Onboarding.onboardingDoneBody)
                .foregroundStyle(.secondary)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }
    }
}
