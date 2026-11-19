import SwiftUI

struct ApprovalBadgeColor: ShapeStyle {
    let received: Int
    let required: Int?
    let isSatisfied: Bool

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        if isSatisfied { return Color.green.resolve(in: environment) }
        let secondary = Color.secondary.resolve(in: environment)
        guard let required, required > 0, received > 0 else { return secondary }

        let green = Color.green.resolve(in: environment)
        let greenWeight = min(Float(received) / Float(required) * 0.8, 0.7)
        // Blend premultiplied components so a translucent secondary color contributes its visible weight.
        let secondaryContribution = secondary.opacity * (1 - greenWeight)
        let greenContribution = green.opacity * greenWeight
        let opacity = secondaryContribution + greenContribution
        func blend(_ secondary: Float, _ green: Float) -> Float {
            (secondary * secondaryContribution + green * greenContribution) / opacity
        }
        return Color.Resolved(
            colorSpace: .sRGBLinear,
            red: blend(secondary.linearRed, green.linearRed),
            green: blend(secondary.linearGreen, green.linearGreen),
            blue: blend(secondary.linearBlue, green.linearBlue),
            opacity: opacity
        )
    }
}
