import SwiftUI

struct CommentAuthorshipStep: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(.Onboarding.onboardingCommentAuthorshipTitle)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Image(.onboardingCommentAuthorship)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary)
                    }
                    .accessibilityLabel(Text(.Onboarding.onboardingCommentAuthorshipScreenshot))

                VStack(alignment: .leading, spacing: 8) {
                    detail(.Onboarding.onboardingCommentAuthorshipReuse, icon: "checkmark.circle")
                    detail(.Onboarding.onboardingCommentAuthorshipContext, icon: "chart.bar")
                    detail(.CommentAuthorship.commentAuthorshipThreadPublicationHelp, icon: "paperplane")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ message: LocalizedStringResource, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(message)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
